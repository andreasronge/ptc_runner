# Tier-2 real-LLM agentic eval for `lisp_task`.
#
# This is intentionally not a CI-default benchmark. It spends real provider
# tokens through OpenRouter and measures end-to-end behavior, not deterministic
# prompt-size accounting.
#
# Usage from mcp_server/:
#
#   mix run --no-start bench/agentic_real_eval.exs --runs=1
#   mix run --no-start bench/agentic_real_eval.exs \
#     --runs=10 \
#     --models=gemini-flash-lite \
#     --catalog-modes=inline,lazy \
#     --json-out=../tmp/agentic_real_eval.json \
#     --md-out=../tmp/agentic_real_eval.md

PtcRunner.Dotenv.load()

defmodule Bench.AgenticRealEval do
  @moduledoc false

  alias PtcRunnerMcp.{AgenticConfig, CatalogConfig, JsonRpc, TraceConfig, TraceFile}

  @repo_root Path.expand(Path.join([__DIR__, "..", ".."]))
  @mcp_root Path.expand(Path.join(__DIR__, ".."))
  @tmp_dir Path.join(@mcp_root, "tmp/agentic-real-eval")
  @fixture_dir Path.join(@tmp_dir, "filesystem-fixture")
  @upstreams_path Path.join(@tmp_dir, "upstreams.json")
  @trace_dir Path.join(@tmp_dir, "traces")
  @default_json_out Path.join(@repo_root, "tmp/agentic_real_eval.json")
  @default_md_out Path.join(@repo_root, "tmp/agentic_real_eval.md")

  def main(argv) do
    opts = parse!(argv)

    with :ok <- check_openrouter_key(opts),
         :ok <- check_npx(opts),
         :ok <- boot_mcp() do
      cases = select_cases(opts.case_names)

      results =
        for model <- opts.models,
            test_case <- cases,
            catalog_mode <- effective_catalog_modes(test_case, opts.catalog_modes),
            run <- 1..opts.runs do
          run_case(run, model, catalog_mode, test_case, opts)
        end

      if results == [] do
        abort("no eval cells selected; check --case and --catalog-modes")
      end

      report = build_report(opts, results)
      markdown = render_markdown(report)

      IO.puts(markdown)

      write_json!(opts.json_out, report)
      write_markdown!(opts.md_out, markdown)

      if Enum.all?(results, & &1["passed"]) do
        System.halt(0)
      else
        System.halt(1)
      end
    else
      {:skip, message} ->
        IO.puts("SKIP: #{message}")
        System.halt(if opts.fail_on_skip, do: 1, else: 0)
    end
  end

  defp parse!(argv) do
    {opts, _positional, invalid} =
      OptionParser.parse(argv,
        strict: [
          models: :string,
          runs: :integer,
          case: :keep,
          catalog_modes: :string,
          max_turns: :integer,
          json_out: :string,
          md_out: :string,
          fail_on_skip: :boolean,
          help: :boolean
        ],
        aliases: [h: :help]
      )

    if invalid != [] do
      abort("Invalid options: #{inspect(invalid)}")
    end

    if Keyword.get(opts, :help, false) do
      IO.puts("""
      Usage:
        mix run --no-start bench/agentic_real_eval.exs [options]

      Options:
        --models=a,b          Planner model aliases or ids (default: gemini-flash-lite)
        --runs=N             Runs per case/model/catalog-mode (default: 1)
        --case=NAME          Restrict to a case; repeatable
        --catalog-modes=a,b  Catalog modes: inline,lazy,auto (default: inline,lazy)
        --max-turns=N        Override every selected case's max_turns
        --json-out=PATH      Write raw JSON report (default: ../tmp/agentic_real_eval.json)
        --md-out=PATH        Write markdown findings (default: ../tmp/agentic_real_eval.md)
        --fail-on-skip       Exit non-zero when prerequisites are missing
      """)

      System.halt(0)
    end

    runs = Keyword.get(opts, :runs, 1)

    if not is_integer(runs) or runs < 1 do
      abort("--runs must be a positive integer")
    end

    catalog_modes =
      opts
      |> Keyword.get(:catalog_modes, "inline,lazy")
      |> split_csv()
      |> Enum.map(&parse_catalog_mode!/1)

    %{
      models: opts |> Keyword.get(:models, "gemini-flash-lite") |> split_csv(),
      runs: runs,
      case_names: Keyword.get_values(opts, :case),
      catalog_modes: catalog_modes,
      max_turns_override: Keyword.get(opts, :max_turns),
      json_out: Keyword.get(opts, :json_out, @default_json_out),
      md_out: Keyword.get(opts, :md_out, @default_md_out),
      fail_on_skip: Keyword.get(opts, :fail_on_skip, false)
    }
  end

  defp abort(message) do
    IO.puts(:stderr, message)
    System.halt(2)
  end

  defp split_csv(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_catalog_mode!("auto"), do: :auto
  defp parse_catalog_mode!("inline"), do: :inline
  defp parse_catalog_mode!("lazy"), do: :lazy
  defp parse_catalog_mode!(other), do: abort("invalid --catalog-modes entry: #{inspect(other)}")

  defp check_openrouter_key(_opts) do
    case System.get_env("OPENROUTER_API_KEY") do
      nil -> {:skip, "OPENROUTER_API_KEY is not set"}
      "" -> {:skip, "OPENROUTER_API_KEY is empty"}
      _ -> :ok
    end
  end

  defp check_npx(_opts) do
    if System.find_executable("npx") do
      :ok
    else
      {:skip, "npx is not available; filesystem MCP upstream cannot be started"}
    end
  end

  defp boot_mcp do
    prepare_filesystem_fixture!()
    write_upstreams_config!()

    System.put_env("PTC_RUNNER_MCP_UPSTREAMS", @upstreams_path)
    System.put_env("PTC_RUNNER_MCP_AGENTIC", "true")
    System.put_env("PTC_RUNNER_MCP_AGGREGATOR_READ_ONLY", "true")
    System.put_env("PTC_RUNNER_MCP_AGENTIC_TASK_TIMEOUT_MS", "60000")
    System.put_env("PTC_RUNNER_MCP_AGENTIC_PLANNER_TIMEOUT_MS", "30000")
    System.put_env("PTC_RUNNER_MCP_AGENTIC_MAX_OUTPUT_TOKENS", "1400")
    System.put_env("PTC_RUNNER_MCP_AGENTIC_MAX_TURNS", "3")
    System.put_env("PTC_RUNNER_MCP_AGENTIC_RETRY_TURNS", "2")
    System.put_env("PTC_RUNNER_MCP_TRACE_DIR", @trace_dir)
    System.put_env("PTC_RUNNER_MCP_TRACE_PAYLOADS", "full")

    Application.put_env(:ptc_runner_mcp, :attach_stdio, false)

    case Application.ensure_all_started(:ptc_runner_mcp) do
      {:ok, _apps} ->
        PtcRunnerMcp.Log.set_level("error")
        enable_trace_files!()
        start_upstream_subsystem!()

      {:error, {:already_started, _app}} ->
        PtcRunnerMcp.Log.set_level("error")
        enable_trace_files!()
        start_upstream_subsystem!()

      {:error, reason} ->
        raise "failed to start :ptc_runner_mcp: #{inspect(reason)}"
    end
  end

  defp enable_trace_files! do
    File.rm_rf!(@trace_dir)
    File.mkdir_p!(@trace_dir)
    TraceConfig.set(%{trace_dir: @trace_dir, trace_payloads: :full, trace_max_files: 2_000})
  end

  defp start_upstream_subsystem! do
    %{upstreams: upstreams, credentials: bindings} =
      PtcRunnerMcp.Application.load_aggregator_config(%{upstreams_config: @upstreams_path})

    if Process.whereis(PtcRunnerMcp.Credentials) == nil do
      {:ok, _pid} = PtcRunnerMcp.Credentials.start_link(bindings: bindings)
    end

    if Process.whereis(PtcRunnerMcp.Upstream.Supervisor) == nil do
      {:ok, _pid} = PtcRunnerMcp.Upstream.Supervisor.start_link(upstreams: upstreams)
    end

    :ok
  end

  defp prepare_filesystem_fixture! do
    File.rm_rf!(@fixture_dir)
    File.mkdir_p!(Path.join(@fixture_dir, "docs"))
    File.mkdir_p!(Path.join(@fixture_dir, "notes"))

    write_fixture_file!("README.md", [
      "PTC Runner Fixture",
      "",
      "Stable benchmark root for MCP filesystem evals."
    ])

    write_fixture_file!(".gitignore", ["tmp", "node_modules"])
    write_fixture_file!("alpha.txt", ["alpha"])
    write_fixture_file!("docs/short.md", ["short doc", "line two", "line three", "line four"])

    write_fixture_file!("notes/long.md", [
      "long note",
      "line two",
      "line three",
      "line four",
      "line five",
      "line six",
      "line seven",
      "line eight"
    ])
  end

  defp write_fixture_file!(relative_path, lines) do
    path = Path.join(@fixture_dir, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.join(lines, "\n") <> "\n")
  end

  defp write_upstreams_config! do
    File.mkdir_p!(@tmp_dir)

    config = %{
      "upstreams" => %{
        "filesystem" => %{
          "command" => "npx",
          "cd" => @fixture_dir,
          "args" => [
            "--yes",
            "@modelcontextprotocol/server-filesystem@2026.1.14",
            @fixture_dir
          ],
          "handshake_timeout_ms" => 60_000
        }
      }
    }

    File.write!(@upstreams_path, Jason.encode!(config, pretty: true))
  end

  defp select_cases([]), do: cases()

  defp select_cases(names) do
    all = cases()
    wanted = MapSet.new(names)
    selected = Enum.filter(all, &MapSet.member?(wanted, &1.name))
    found = MapSet.new(Enum.map(selected, & &1.name))
    missing = MapSet.difference(wanted, found) |> MapSet.to_list()

    if missing != [] do
      abort("unknown --case value(s): #{Enum.join(missing, ", ")}")
    end

    selected
  end

  defp cases do
    [
      %{
        name: "single_read",
        category: "single-tool read",
        max_turns: 1,
        retry_turns: 0,
        task:
          "Read README.md and return the first non-empty line plus one sentence saying what repository this is.",
        constraints: %{"max_items" => 2},
        pass: fn payload, result ->
          answer = answer(payload)

          ok?(payload) and String.contains?(String.downcase(answer), "ptc") and
            upstream_ok_any?(payload, ["read_text_file", "read_file"]) and
            result.upstream_ok_count >= 1
        end
      },
      %{
        name: "multi_file_reduce",
        category: "multi-call aggregation",
        max_turns: 1,
        retry_turns: 0,
        task:
          "Read README.md, docs/short.md, and notes/long.md. Count lines in each and return only the path with the most lines and the three counts.",
        constraints: %{"max_items" => 3},
        pass: fn payload, result ->
          answer = answer(payload)

          ok?(payload) and String.contains?(answer, "notes/long.md") and
            (count_tool(payload, "read_text_file") >= 3 or count_tool(payload, "read_file") >= 3 or
               count_tool(payload, "read_multiple_files") >= 1) and result.upstream_ok_count >= 1
        end
      },
      %{
        name: "lazy_catalog_discovery",
        category: "catalog discovery",
        max_turns: 1,
        retry_turns: 0,
        catalog_modes: [:lazy],
        task:
          "The upstream catalog is not inlined. Discover the filesystem tool for listing a directory, list the repository root, and return exactly five entry names.",
        constraints: %{"max_items" => 5},
        pass: fn payload, result ->
          answer = answer(payload)

          ok?(payload) and String.contains?(answer, ".gitignore") and
            upstream_ok?(payload, "list_directory") and result.catalog_op_mentions >= 1
        end
      },
      %{
        name: "retry_after_bad_path_type",
        category: "error recovery",
        max_turns: 3,
        retry_turns: 2,
        task:
          "First call the filesystem read_text_file tool incorrectly with path set to the number 123. After that fails, correct the mistake, read README.md, and return the first line.",
        constraints: %{"max_items" => 1},
        pass: fn payload, result ->
          ok?(payload) and String.contains?(String.downcase(answer(payload)), "ptc") and
            result.upstream_error_count >= 1 and result.upstream_ok_count >= 1
        end
      },
      %{
        name: "negative_missing_capability",
        category: "negative capability",
        max_turns: 1,
        retry_turns: 0,
        task:
          "Use the configured upstream MCP servers to send an email to nobody@example.com saying hello. If no configured server can send email, fail explicitly.",
        constraints: %{},
        pass: fn payload, _result ->
          text =
            String.downcase(answer(payload) <> " " <> to_string(Map.get(payload, "message", "")))

          Map.get(payload, "status") == "error" or
            String.contains?(text, "no") or
            String.contains?(text, "cannot") or
            String.contains?(text, "not configured") or
            String.contains?(text, "unavailable")
        end
      }
    ]
  end

  defp effective_catalog_modes(test_case, requested_modes) do
    case Map.get(test_case, :catalog_modes) do
      nil -> requested_modes
      modes -> Enum.filter(requested_modes, &(&1 in modes))
    end
  end

  defp run_case(run, model, catalog_mode, test_case, opts) do
    CatalogConfig.set(%{catalog_mode: catalog_mode})
    max_turns = opts.max_turns_override || test_case.max_turns

    AgenticConfig.set(%{
      enabled: true,
      model: model,
      max_turns: max_turns,
      retry_turns: test_case.retry_turns,
      include_program: true,
      capability_summary: nil
    })

    started = System.monotonic_time(:millisecond)
    request_id = "#{test_case.name}-#{catalog_mode}-#{run}"
    envelope = call_lisp_task_via_json_rpc(request_id, test_case)

    duration_ms = System.monotonic_time(:millisecond) - started
    payload = result_payload(envelope)
    program = Map.get(payload, "program", "")
    metrics = summarize_payload(payload, program)
    passed? = test_case.pass.(payload, metrics)

    %{
      "run" => run,
      "request_id" => request_id,
      "case" => test_case.name,
      "category" => test_case.category,
      "model" => model,
      "catalog_mode" => Atom.to_string(catalog_mode),
      "max_turns" => max_turns,
      "retry_turns" => test_case.retry_turns,
      "passed" => passed?,
      "duration_ms" => duration_ms,
      "status" => Map.get(payload, "status"),
      "reason" => Map.get(payload, "reason"),
      "message" => Map.get(payload, "message"),
      "answer" => Map.get(payload, "answer"),
      "planner" => Map.get(payload, "planner", %{}),
      "execution" => Map.get(payload, "execution", %{}),
      "ptc_metrics" => Map.get(payload, "ptc_metrics", %{}),
      "upstream_calls" => Map.get(payload, "upstream_calls", []),
      "upstream_results" => Map.get(payload, "upstream_results", []),
      "trace_path" => trace_path_for(request_id),
      "program" => program,
      "metrics" => Map.from_struct(metrics)
    }
  end

  defp call_lisp_task_via_json_rpc(request_id, test_case) do
    frame = %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "method" => "tools/call",
      "params" => %{
        "name" => "lisp_task",
        "arguments" => %{
          "task" => test_case.task,
          "constraints" => test_case.constraints
        }
      }
    }

    case JsonRpc.dispatch({:ok, frame}) do
      {:async_call, ^request_id, work_fn, _on_busy, _on_discard, :continue} ->
        work_fn.()

      {:reply, %{"result" => envelope}, _lifecycle} ->
        envelope

      other ->
        %{
          "isError" => true,
          "structuredContent" => %{
            "status" => "error",
            "reason" => "json_rpc_error",
            "message" => inspect(other)
          }
        }
    end
  end

  defp trace_path_for(request_id) do
    hash = TraceFile.request_id_hash8(request_id)

    case File.ls(@trace_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&(String.contains?(&1, hash) and String.ends_with?(&1, ".jsonl")))
        |> Enum.sort()
        |> List.last()
        |> case do
          nil -> nil
          file -> Path.join(@trace_dir, file)
        end

      {:error, _reason} ->
        nil
    end
  end

  defp result_payload(%{"structuredContent" => payload}) when is_map(payload), do: payload
  defp result_payload(%{} = payload), do: payload
  defp result_payload(other), do: %{"status" => "error", "reason" => inspect(other)}

  defp summarize_payload(payload, program) do
    planner = Map.get(payload, "planner", %{}) || %{}
    upstream_calls = Map.get(payload, "upstream_calls", []) || []

    %{
      planner_calls: int(Map.get(planner, "calls")),
      planner_duration_ms: int(Map.get(planner, "duration_ms")),
      prompt_bytes: int(Map.get(planner, "prompt_bytes")),
      completion_bytes: int(Map.get(planner, "completion_bytes")),
      provider_input_tokens: token_field(planner, :input),
      provider_output_tokens: token_field(planner, :output),
      upstream_call_count: length(upstream_calls),
      upstream_ok_count: Enum.count(upstream_calls, &(Map.get(&1, "status") == "ok")),
      upstream_error_count: Enum.count(upstream_calls, &(Map.get(&1, "status") == "error")),
      catalog_op_mentions: count_catalog_mentions(program)
    }
    |> then(&struct!(Bench.AgenticRealEval.Metrics, &1))
  end

  defmodule Metrics do
    @moduledoc false
    defstruct [
      :planner_calls,
      :planner_duration_ms,
      :prompt_bytes,
      :completion_bytes,
      :provider_input_tokens,
      :provider_output_tokens,
      :upstream_call_count,
      :upstream_ok_count,
      :upstream_error_count,
      :catalog_op_mentions
    ]
  end

  defp ok?(payload), do: Map.get(payload, "status") == "ok"
  defp answer(payload), do: to_string(Map.get(payload, "answer", ""))

  defp upstream_ok?(payload, tool_name) do
    payload
    |> Map.get("upstream_calls", [])
    |> Enum.any?(&(Map.get(&1, "tool") == tool_name and Map.get(&1, "status") == "ok"))
  end

  defp upstream_ok_any?(payload, tool_names) do
    Enum.any?(tool_names, &upstream_ok?(payload, &1))
  end

  defp count_tool(payload, tool_name) do
    payload
    |> Map.get("upstream_calls", [])
    |> Enum.count(&(Map.get(&1, "tool") == tool_name))
  end

  defp int(value) when is_integer(value), do: value
  defp int(_), do: nil

  defp token_field(planner, key) do
    case Map.get(planner, "tokens", %{}) do
      %{} = tokens ->
        case Map.get(tokens, key) || Map.get(tokens, Atom.to_string(key)) do
          n when is_integer(n) -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp count_catalog_mentions(program) when is_binary(program) do
    Regex.scan(
      ~r/catalog\/(?:summary|list-servers|search-tools|list-tools|describe-tool)/,
      program
    )
    |> length()
  end

  defp count_catalog_mentions(_), do: 0

  defp build_report(opts, results) do
    %{
      "benchmark" => "agentic_real_eval",
      "issue" => 931,
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "repo_root" => @repo_root,
      "models" => opts.models,
      "runs" => opts.runs,
      "catalog_modes" => Enum.map(opts.catalog_modes, &Atom.to_string/1),
      "cases" =>
        Enum.map(
          select_cases(opts.case_names),
          &Map.take(&1, [:name, :category, :max_turns, :retry_turns])
        ),
      "notes" => [
        "Real provider eval; results can drift by model/provider behavior.",
        "catalog_op_mentions is inferred from generated program text because catalog op counts are not surfaced in lisp_task metrics yet."
      ],
      "summary" => summarize_results(results),
      "results" => results
    }
  end

  defp summarize_results(results) do
    grouped =
      Enum.group_by(results, fn result ->
        {result["model"], result["catalog_mode"], result["case"]}
      end)

    grouped
    |> Enum.map(fn {{model, catalog_mode, case_name}, rows} ->
      passed = Enum.count(rows, & &1["passed"])
      total = length(rows)
      metrics = Enum.map(rows, & &1["metrics"])

      %{
        "model" => model,
        "catalog_mode" => catalog_mode,
        "case" => case_name,
        "passed" => passed,
        "total" => total,
        "pass_rate" => Float.round(passed / max(total, 1), 3),
        "median_duration_ms" => median(Enum.map(rows, & &1["duration_ms"])),
        "median_planner_ms" => median(Enum.map(metrics, &metric(&1, :planner_duration_ms))),
        "median_prompt_bytes" => median(Enum.map(metrics, &metric(&1, :prompt_bytes))),
        "median_completion_bytes" => median(Enum.map(metrics, &metric(&1, :completion_bytes))),
        "median_upstream_calls" => median(Enum.map(metrics, &metric(&1, :upstream_call_count))),
        "median_catalog_op_mentions" =>
          median(Enum.map(metrics, &metric(&1, :catalog_op_mentions)))
      }
    end)
    |> Enum.sort_by(&{&1["model"], &1["catalog_mode"], &1["case"]})
  end

  defp metric(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp median(values) do
    cleaned = values |> Enum.reject(&is_nil/1) |> Enum.sort()

    case cleaned do
      [] -> nil
      list -> Enum.at(list, div(length(list), 2))
    end
  end

  defp render_markdown(report) do
    summary_rows =
      report["summary"]
      |> Enum.map_join("\n", fn row ->
        [
          row["model"],
          row["catalog_mode"],
          row["case"],
          "#{row["passed"]}/#{row["total"]}",
          row["median_duration_ms"],
          row["median_planner_ms"],
          row["median_prompt_bytes"],
          row["median_completion_bytes"],
          row["median_upstream_calls"],
          row["median_catalog_op_mentions"]
        ]
        |> Enum.map(&to_string(&1 || ""))
        |> Enum.join(" | ")
      end)

    failures =
      report["results"]
      |> Enum.reject(& &1["passed"])
      |> Enum.map_join("\n\n", fn result ->
        """
        ### #{result["case"]} / #{result["catalog_mode"]} / run #{result["run"]}

        Status: #{inspect(result["status"])}
        Reason: #{inspect(result["reason"])}
        Message: #{inspect(result["message"])}
        Answer: #{inspect(result["answer"], printable_limit: 800)}
        Trace: #{result["trace_path"] || "none"}

        ```clojure
        #{result["program"]}
        ```
        """
      end)

    """
    # Agentic real-LLM eval findings

    Issue: ##{report["issue"]}
    Generated: #{report["generated_at"]}
    Models: #{Enum.join(report["models"], ", ")}
    Runs per cell: #{report["runs"]}
    Catalog modes: #{Enum.join(report["catalog_modes"], ", ")}

    This eval uses the real OpenRouter-backed planner. It is not deterministic
    and is not intended for default CI.

    catalog_op_mentions is inferred from generated program text because
    `lisp_task` does not currently expose catalog op counts as structured
    metrics.

    ## Summary

    model | catalog_mode | case | pass | median_ms | median_planner_ms | median_prompt_bytes | median_completion_bytes | median_upstream_calls | median_catalog_op_mentions
    --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---:
    #{summary_rows}

    #{if(failures == "", do: "## Failures\n\nNone.", else: "## Failures\n\n" <> failures)}
    """
  end

  defp write_json!(path, report) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(report, pretty: true))
  end

  defp write_markdown!(path, markdown) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, markdown)
  end
end

Bench.AgenticRealEval.main(System.argv())
