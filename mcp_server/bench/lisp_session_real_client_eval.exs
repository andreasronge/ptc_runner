# Real-LLM client-loop eval for the advertised `lisp_session_*` MCP tools.
#
# This is intentionally not a CI-default benchmark. It spends real provider
# tokens through OpenRouter and measures whether a model that sees the MCP
# `tools/list` descriptions can choose the stateful session tools, create a
# session, write useful PTC-Lisp programs, consume tool results, and answer.
#
# Usage from mcp_server/:
#
#   mix run --no-start bench/lisp_session_real_client_eval.exs --runs=1
#   mix run --no-start bench/lisp_session_real_client_eval.exs \
#     --runs=3 \
#     --models=gemini-flash-lite \
#     --json-out=../tmp/lisp_session_real_client_eval.json \
#     --md-out=../tmp/lisp_session_real_client_eval.md

PtcRunner.Dotenv.load()

defmodule Bench.LispSessionRealClientEval do
  @moduledoc false

  alias PtcRunnerMcp.{AggregatorConfig, CatalogConfig, ResponseProfile, Sessions, Tools}
  alias PtcRunnerMcp.Sessions.Config, as: SessionsConfig

  @repo_root Path.expand(Path.join([__DIR__, "..", ".."]))
  @tmp_dir Path.join(@repo_root, "tmp/lisp-session-real-client-eval")
  @upstreams_path Path.join(@tmp_dir, "upstreams.json")
  @default_json_out Path.join(@repo_root, "tmp/lisp_session_real_client_eval.json")
  @default_md_out Path.join(@repo_root, "tmp/lisp_session_real_client_eval.md")

  def main(argv) do
    opts = parse!(argv)

    with :ok <- check_openrouter_key(opts),
         :ok <- check_npx(opts),
         :ok <- boot_mcp(opts) do
      cases = select_cases(opts.case_names)

      results =
        for model <- opts.models,
            test_case <- cases,
            profile <- effective_profiles(test_case, opts.profiles),
            catalog_mode <- effective_catalog_modes(profile, test_case, opts.catalog_modes),
            run <- 1..opts.runs do
          run_case(run, model, profile, catalog_mode, test_case)
        end

      if results == [] do
        abort("no eval cells selected; check --case, --profiles, and --catalog-modes")
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
          profiles: :string,
          catalog_modes: :string,
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
        mix run --no-start bench/lisp_session_real_client_eval.exs [options]

      Options:
        --models=a,b          Model aliases or ids (default: gemini-flash-lite)
        --runs=N             Runs per case/model/catalog-mode (default: 1)
        --case=NAME          Restrict to a case; repeatable
        --profiles=a,b       Profiles: no-upstreams,with-upstreams (default: no-upstreams)
        --catalog-modes=a,b  Catalog modes: inline,lazy,auto (default: inline,lazy)
        --json-out=PATH      Write raw JSON report (default: ../tmp/lisp_session_real_client_eval.json)
        --md-out=PATH        Write markdown findings (default: ../tmp/lisp_session_real_client_eval.md)
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

    profiles =
      opts
      |> Keyword.get(:profiles, "no-upstreams")
      |> split_csv()
      |> Enum.map(&parse_profile!/1)

    %{
      models: opts |> Keyword.get(:models, "gemini-flash-lite") |> split_csv(),
      runs: runs,
      case_names: Keyword.get_values(opts, :case),
      profiles: profiles,
      catalog_modes: catalog_modes,
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

  defp parse_profile!("no-upstreams"), do: :no_upstreams
  defp parse_profile!("no_upstreams"), do: :no_upstreams
  defp parse_profile!("without-upstreams"), do: :no_upstreams
  defp parse_profile!("with-upstreams"), do: :with_upstreams
  defp parse_profile!("with_upstreams"), do: :with_upstreams
  defp parse_profile!(other), do: abort("invalid --profiles entry: #{inspect(other)}")

  defp check_openrouter_key(_opts) do
    case System.get_env("OPENROUTER_API_KEY") do
      nil -> {:skip, "OPENROUTER_API_KEY is not set"}
      "" -> {:skip, "OPENROUTER_API_KEY is empty"}
      _ -> :ok
    end
  end

  defp check_npx(opts) do
    if :with_upstreams not in opts.profiles or System.find_executable("npx") do
      :ok
    else
      {:skip, "npx is not available; filesystem MCP upstream cannot be started"}
    end
  end

  defp boot_mcp(opts) do
    if :with_upstreams in opts.profiles do
      write_upstreams_config!()
      System.put_env("PTC_RUNNER_MCP_UPSTREAMS", @upstreams_path)
    else
      System.delete_env("PTC_RUNNER_MCP_UPSTREAMS")
    end

    System.put_env("PTC_RUNNER_MCP_AGENTIC", "false")
    System.put_env("PTC_RUNNER_MCP_SESSIONS", "true")
    System.put_env("PTC_RUNNER_MCP_AGGREGATOR_READ_ONLY", "true")
    System.put_env("PTC_RUNNER_MCP_TOOL_TIMEOUT_MS", "60000")
    System.put_env("PTC_RUNNER_MCP_MAX_PROGRAM_BYTES", "20000")

    Application.put_env(:ptc_runner_mcp, :attach_stdio, false)

    case Application.ensure_all_started(:ptc_runner_mcp) do
      {:ok, _apps} ->
        finish_boot(opts)

      {:error, {:already_started, _app}} ->
        finish_boot(opts)

      {:error, reason} ->
        raise "failed to start :ptc_runner_mcp: #{inspect(reason)}"
    end
  end

  defp finish_boot(opts) do
    PtcRunnerMcp.Log.set_level("error")
    AggregatorConfig.set(%{read_only?: true})
    ResponseProfile.set(:debug)
    SessionsConfig.set(%{enabled: true})
    :ok = Sessions.ensure_started()
    maybe_start_upstream_subsystem!(opts)
  end

  defp maybe_start_upstream_subsystem!(opts) do
    if :with_upstreams in opts.profiles do
      start_upstream_subsystem!()
    else
      :ok
    end
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

  defp write_upstreams_config! do
    File.mkdir_p!(@tmp_dir)

    config = %{
      "upstreams" => %{
        "filesystem" => %{
          "command" => "npx",
          "args" => [
            "--yes",
            "@modelcontextprotocol/server-filesystem@2026.1.14",
            @repo_root
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
        name: "state_persists",
        category: "stateful eval",
        profiles: [:no_upstreams, :with_upstreams],
        max_turns: 6,
        prompt:
          "Use MCP session tools. Start a PTC-Lisp session. Make one lisp_session_eval call whose program only defines x as 41. After that returns, make a second lisp_session_eval call in the same session to evaluate (+ x 1). Return only the final number.",
        pass: fn result ->
          ok_tool_count?(result, "lisp_session_start", 1) and
            ok_tool_count?(result, "lisp_session_eval", 2) and
            String.contains?(result["answer"], "42")
        end
      },
      %{
        name: "inspect_context",
        category: "session inspection",
        profiles: [:no_upstreams, :with_upstreams],
        max_turns: 6,
        prompt:
          "Use MCP session tools. Start a PTC-Lisp session, print \"alpha-ready\", define project as \"alpha\", inspect the session, and answer with the printed marker and project value.",
        pass: fn result ->
          ok_tool_count?(result, "lisp_session_start", 1) and
            ok_tool_count?(result, "lisp_session_eval", 1) and
            tool_called?(result, "lisp_session_inspect") and
            String.contains?(String.downcase(result["answer"]), "alpha")
        end
      },
      %{
        name: "recover_after_error",
        category: "error recovery",
        profiles: [:no_upstreams, :with_upstreams],
        max_turns: 7,
        prompt:
          "Use MCP session tools. Start a session, define x as 10, intentionally evaluate missing_symbol once, then recover by evaluating (+ x 5). Return only the recovered number.",
        pass: fn result ->
          ok_tool_count?(result, "lisp_session_start", 1) and
            tool_error_count?(result, "lisp_session_eval") >= 1 and
            ok_tool_count?(result, "lisp_session_eval", 2) and
            String.contains?(result["answer"], "15")
        end
      },
      %{
        name: "close_session",
        category: "session lifecycle",
        profiles: [:no_upstreams, :with_upstreams],
        max_turns: 6,
        prompt:
          "Use MCP session tools. Start a session, evaluate (+ 2 3), close the session, and answer with the computed number and whether the close succeeded.",
        pass: fn result ->
          ok_tool_count?(result, "lisp_session_start", 1) and
            ok_tool_count?(result, "lisp_session_eval", 1) and
            ok_tool_count?(result, "lisp_session_close", 1) and
            String.contains?(result["answer"], "5")
        end
      },
      %{
        name: "session_upstream_shape_probe",
        category: "session upstream exploration",
        profiles: [:with_upstreams],
        catalog_modes: [:inline, :lazy],
        max_turns: 8,
        prompt:
          "Use MCP session tools. Start a session, call the filesystem upstream from session Lisp to inspect the repository root result shape, then list the repository root and answer with exactly three entry names.",
        pass: fn result ->
          ok_tool_count?(result, "lisp_session_start", 1) and
            ok_tool_count?(result, "lisp_session_eval", 1) and
            upstream_ok?(result, "list_directory") and
            String.contains?(result["answer"], ".gitignore")
        end
      }
    ]
  end

  defp effective_profiles(test_case, requested_profiles) do
    supported = Map.get(test_case, :profiles, [:no_upstreams, :with_upstreams])
    Enum.filter(requested_profiles, &(&1 in supported))
  end

  defp effective_catalog_modes(:no_upstreams, _test_case, _requested_modes), do: [:none]

  defp effective_catalog_modes(:with_upstreams, test_case, requested_modes) do
    case Map.get(test_case, :catalog_modes) do
      nil -> requested_modes
      modes -> Enum.filter(requested_modes, &(&1 in modes))
    end
  end

  defp run_case(run, model, profile, catalog_mode, test_case) do
    if profile == :with_upstreams do
      CatalogConfig.set(%{catalog_mode: catalog_mode})
    end

    started = System.monotonic_time(:millisecond)

    result =
      case run_client_loop(model, profile, test_case.prompt, test_case.max_turns) do
        {:ok, result} -> result
        {:error, reason, result} -> Map.merge(result, %{"error" => inspect(reason)})
      end

    duration_ms = System.monotonic_time(:millisecond) - started

    result =
      result
      |> Map.merge(%{
        "run" => run,
        "case" => test_case.name,
        "category" => test_case.category,
        "model" => model,
        "profile" => profile_name(profile),
        "catalog_mode" => catalog_mode_name(catalog_mode),
        "duration_ms" => duration_ms
      })

    Map.put(result, "passed", test_case.pass.(result))
  end

  defp run_client_loop(model, profile, prompt, max_turns) do
    llm = PtcRunner.LLM.callback(model, max_tokens: 1400, temperature: 0.0)
    tools = tool_schemas(profile)
    system = system_prompt()
    messages = [%{role: :user, content: prompt}]

    result =
      empty_result()
      |> Map.put("system_prompt", system)
      |> Map.put("user_prompt", prompt)
      |> Map.put("tool_names", Enum.map(tools, &get_in(&1, ["function", "name"])))
      |> Map.put(
        "tool_description_bytes",
        tools
        |> Enum.map(&(get_in(&1, ["function", "description"]) || ""))
        |> Enum.map(&byte_size/1)
        |> Enum.sum()
      )

    do_client_loop(llm, system, messages, tools, max_turns, 1, result)
  end

  defp do_client_loop(_llm, _system, _messages, _tools, 0, _turn_index, result) do
    {:error, :max_turns_exhausted, result}
  end

  defp do_client_loop(llm, system, messages, tools, turns_left, turn_index, result) do
    request = %{system: system, messages: messages, tools: tools}

    case llm.(request) do
      {:ok, %{tool_calls: tool_calls} = response} when is_list(tool_calls) and tool_calls != [] ->
        {tool_results, tool_messages} = execute_tool_calls(tool_calls)

        result =
          result
          |> record_provider_response(response)
          |> record_tool_results(tool_calls, tool_results)
          |> record_transcript_turn(
            turn_index,
            turns_left,
            messages,
            response,
            tool_calls,
            tool_results
          )

        messages = messages ++ [assistant_message(tool_calls)] ++ tool_messages
        do_client_loop(llm, system, messages, tools, turns_left - 1, turn_index + 1, result)

      {:ok, %{content: content} = response} ->
        result =
          result
          |> merge_tokens(response)
          |> Map.put("answer", to_string(content || ""))
          |> record_final_answer_turn(turn_index, turns_left, messages, response)

        {:ok, result}

      {:error, reason} ->
        {:error, reason, result}
    end
  end

  defp system_prompt do
    """
    You are an MCP client. Use the advertised `lisp_session_*` tools when the
    user asks for stateful PTC-Lisp work. Start a session before session evals,
    reuse the returned session_id, and answer from the tool results. Keep the
    final answer concise and do not include code unless explicitly requested.
    """
  end

  defp tool_schemas(:with_upstreams) do
    Tools.list()
    |> Map.fetch!("tools")
    |> Enum.filter(&String.starts_with?(&1["name"], "lisp_session_"))
    |> Enum.map(&provider_tool_schema/1)
  end

  defp tool_schemas(:no_upstreams) do
    Tools.list()
    |> Map.fetch!("tools")
    |> Enum.filter(&String.starts_with?(&1["name"], "lisp_session_"))
    |> Enum.map(fn
      %{"name" => "lisp_session_eval"} = entry ->
        entry
        |> Map.put(
          "description",
          PtcRunnerMcp.PromptRegistry.render(:mcp_session_eval_description, [])
        )
        |> provider_tool_schema()

      entry ->
        provider_tool_schema(entry)
    end)
  end

  defp provider_tool_schema(entry) do
    %{
      "type" => "function",
      "function" => %{
        "name" => entry["name"],
        "description" => entry["description"],
        "parameters" => entry["inputSchema"]
      }
    }
  end

  defp execute_tool_calls(tool_calls) do
    tool_results =
      Enum.map(tool_calls, fn tool_call ->
        {tool_call, execute_tool_call(tool_call)}
      end)

    tool_messages =
      Enum.map(tool_results, fn {tool_call, tool_result} ->
        tool_message(tool_call, tool_result)
      end)

    {tool_results, tool_messages}
  end

  defp execute_tool_call(%{name: name, args: args}) when is_binary(name) and is_map(args) do
    if String.starts_with?(name, "lisp_session_") do
      Tools.call(%{"name" => name, "arguments" => args})
      |> result_payload()
    else
      %{"status" => "error", "reason" => "unknown_tool", "message" => name}
    end
  end

  defp execute_tool_call(%{name: name}) when is_binary(name) do
    if String.starts_with?(name, "lisp_session_") do
      Tools.call(%{"name" => name, "arguments" => %{}})
      |> result_payload()
    else
      %{"status" => "error", "reason" => "unknown_tool", "message" => name}
    end
  end

  defp execute_tool_call(tool_call) do
    %{"status" => "error", "reason" => "bad_tool_call", "message" => inspect(tool_call)}
  end

  defp assistant_message(tool_calls) do
    %{
      role: :assistant,
      content: nil,
      tool_calls:
        Enum.map(tool_calls, fn tool_call ->
          %{
            id: tool_call[:id],
            function: %{
              name: tool_call.name,
              arguments: Jason.encode!(tool_call.args || %{})
            }
          }
        end)
    }
  end

  defp tool_message(tool_call, tool_result) do
    %{
      role: :tool,
      tool_call_id: tool_call[:id],
      content: Jason.encode!(tool_result)
    }
  end

  defp result_payload(%{"structuredContent" => payload}) when is_map(payload), do: payload

  defp result_payload(%{
         "isError" => false,
         "content" => [%{"type" => "text", "text" => text} | _]
       }) do
    %{"status" => "ok", "result" => strip_repl_prefix(text), "raw_text" => text}
  end

  defp result_payload(%{
         "isError" => true,
         "content" => [%{"type" => "text", "text" => text} | _]
       }) do
    case Jason.decode(text) do
      {:ok, payload} when is_map(payload) -> payload
      _ -> %{"status" => "error", "reason" => "tool_error", "message" => text}
    end
  end

  defp result_payload(%{} = payload), do: payload
  defp result_payload(other), do: %{"status" => "error", "reason" => inspect(other)}

  defp strip_repl_prefix("user=> " <> rest), do: rest
  defp strip_repl_prefix(text), do: text

  defp empty_result do
    %{
      "answer" => "",
      "programs" => [],
      "session_ids" => [],
      "tool_call_count" => 0,
      "tool_counts" => %{},
      "tool_ok_counts" => %{},
      "tool_error_counts" => %{},
      "last_tool_status" => nil,
      "last_tool_reason" => nil,
      "upstream_calls" => [],
      "upstream_ok_count" => 0,
      "upstream_error_count" => 0,
      "catalog_op_mentions" => 0,
      "transcript" => [],
      "tokens" => %{}
    }
  end

  defp record_transcript_turn(
         result,
         turn_index,
         turns_left,
         messages,
         response,
         tool_calls,
         tool_results
       ) do
    append_transcript(result, %{
      "turn" => turn_index,
      "turns_left_before_call" => turns_left,
      "messages_seen" => summarize_messages(messages),
      "provider_response" => summarize_provider_response(response),
      "tool_calls" => Enum.map(tool_calls, &summarize_tool_call/1),
      "tool_results" =>
        Enum.map(tool_results, fn {tool_call, tool_result} ->
          %{
            "tool" => tool_call.name,
            "result" => summarize_tool_result(tool_result)
          }
        end)
    })
  end

  defp record_final_answer_turn(result, turn_index, turns_left, messages, response) do
    append_transcript(result, %{
      "turn" => turn_index,
      "turns_left_before_call" => turns_left,
      "messages_seen" => summarize_messages(messages),
      "provider_response" => summarize_provider_response(response),
      "final_answer" => excerpt(to_string(Map.get(response, :content) || ""), 2_000)
    })
  end

  defp append_transcript(result, turn) do
    Map.update!(result, "transcript", &(&1 ++ [turn]))
  end

  defp summarize_messages(messages) do
    Enum.map(messages, fn message ->
      content = Map.get(message, :content) || Map.get(message, "content")

      %{
        "role" => message |> Map.get(:role, Map.get(message, "role")) |> to_string(),
        "content" => excerpt(to_string(content || ""), 2_000),
        "content_bytes" => byte_size(to_string(content || "")),
        "tool_call_id" => Map.get(message, :tool_call_id) || Map.get(message, "tool_call_id")
      }
    end)
  end

  defp summarize_provider_response(response) do
    %{
      "content" => excerpt(to_string(Map.get(response, :content) || ""), 2_000),
      "content_bytes" => byte_size(to_string(Map.get(response, :content) || "")),
      "tool_calls" => response |> Map.get(:tool_calls, []) |> Enum.map(&summarize_tool_call/1),
      "tokens" => response |> Map.get(:tokens, %{}) |> stringify_keys()
    }
  end

  defp summarize_tool_call(tool_call) do
    args = Map.get(tool_call, :args) || Map.get(tool_call, "args") || %{}
    program = Map.get(args, "program") || Map.get(args, :program) || ""

    %{
      "id" => Map.get(tool_call, :id) || Map.get(tool_call, "id"),
      "name" => Map.get(tool_call, :name) || Map.get(tool_call, "name"),
      "args" => stringify_keys(args),
      "program" => program,
      "program_bytes" => byte_size(program)
    }
  end

  defp summarize_tool_result(tool_result) do
    tool_result
    |> Map.take([
      "status",
      "session_id",
      "result",
      "reason",
      "message",
      "feedback",
      "prints",
      "upstream_results",
      "upstream_calls",
      "count",
      "sessions",
      "ptc_metrics"
    ])
    |> Map.update("result", nil, &excerpt(to_string(&1), 4_000))
    |> Map.update("message", nil, &excerpt(to_string(&1), 2_000))
  end

  defp excerpt(text, max_bytes) when is_binary(text) and byte_size(text) <= max_bytes, do: text

  defp excerpt(text, max_bytes) when is_binary(text) do
    size = byte_size(text)
    kept = binary_part(text, 0, max_bytes)
    kept <> "... (truncated #{size - max_bytes} bytes)"
  end

  defp record_provider_response(result, response) do
    merge_tokens(result, response)
  end

  defp record_tool_results(result, tool_calls, tool_results) do
    Enum.zip(tool_calls, tool_results)
    |> Enum.reduce(result, fn {tool_call, {_same_tool_call, tool_result}}, acc ->
      record_tool_result(acc, tool_call, tool_result)
    end)
  end

  defp record_tool_result(result, tool_call, tool_result) do
    name = Map.get(tool_call, :name) || Map.get(tool_call, "name")
    args = Map.get(tool_call, :args) || Map.get(tool_call, "args") || %{}
    program = Map.get(args, "program") || Map.get(args, :program) || ""
    upstream_calls = Map.get(tool_result, "upstream_calls", []) || []
    all_upstream_calls = Map.get(result, "upstream_calls", []) ++ upstream_calls

    catalog_op_mentions =
      Map.get(result, "catalog_op_mentions", 0) + count_catalog_mentions(program)

    session_id =
      Map.get(tool_result, "session_id") || Map.get(args, "session_id") ||
        Map.get(args, :session_id)

    result
    |> Map.update!("tool_call_count", &(&1 + 1))
    |> update_nested_count("tool_counts", name)
    |> maybe_update_status_count(name, tool_result)
    |> maybe_append_program(program)
    |> maybe_append_session_id(session_id)
    |> Map.put("last_tool_status", Map.get(tool_result, "status"))
    |> Map.put("last_tool_reason", Map.get(tool_result, "reason"))
    |> Map.put(
      "last_tool_result",
      Map.take(tool_result, ["status", "result", "reason", "message"])
    )
    |> Map.put("upstream_calls", all_upstream_calls)
    |> Map.put(
      "upstream_ok_count",
      Enum.count(all_upstream_calls, &(Map.get(&1, "status") == "ok"))
    )
    |> Map.put(
      "upstream_error_count",
      Enum.count(all_upstream_calls, &(Map.get(&1, "status") == "error"))
    )
    |> Map.put("catalog_op_mentions", catalog_op_mentions)
  end

  defp update_nested_count(result, key, name) when is_binary(name) do
    Map.update!(result, key, fn counts ->
      Map.update(counts, name, 1, &(&1 + 1))
    end)
  end

  defp update_nested_count(result, _key, _name), do: result

  defp maybe_update_status_count(result, name, %{"status" => "ok"}) when is_binary(name) do
    update_nested_count(result, "tool_ok_counts", name)
  end

  defp maybe_update_status_count(result, name, %{"status" => "error"}) when is_binary(name) do
    update_nested_count(result, "tool_error_counts", name)
  end

  defp maybe_update_status_count(result, _name, _tool_result), do: result

  defp maybe_append_program(result, ""), do: result

  defp maybe_append_program(result, program),
    do: Map.update!(result, "programs", &(&1 ++ [program]))

  defp maybe_append_session_id(result, session_id)
       when is_binary(session_id) and session_id != "" do
    Map.update!(result, "session_ids", fn ids ->
      if session_id in ids, do: ids, else: ids ++ [session_id]
    end)
  end

  defp maybe_append_session_id(result, _session_id), do: result

  defp merge_tokens(result, %{tokens: tokens}) when is_map(tokens) do
    merged =
      Map.merge(result["tokens"] || %{}, stringify_keys(tokens), fn _key, left, right ->
        if is_number(left) and is_number(right), do: left + right, else: right
      end)

    Map.put(result, "tokens", merged)
  end

  defp merge_tokens(result, _response), do: result

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp tool_called?(result, name), do: Map.get(result["tool_counts"] || %{}, name, 0) > 0

  defp ok_tool_count?(result, name, min_count) do
    Map.get(result["tool_ok_counts"] || %{}, name, 0) >= min_count
  end

  defp tool_error_count?(result, name) do
    Map.get(result["tool_error_counts"] || %{}, name, 0)
  end

  defp upstream_ok?(result, tool_name) do
    result
    |> Map.get("upstream_calls", [])
    |> Enum.any?(&(Map.get(&1, "tool") == tool_name and Map.get(&1, "status") == "ok"))
  end

  defp count_catalog_mentions(program) when is_binary(program) do
    Regex.scan(
      ~r/catalog\/(?:summary|list-servers|search-tools|list-tools|describe-tool)/,
      program
    )
    |> length()
  end

  defp count_catalog_mentions(_), do: 0

  defp profile_name(:no_upstreams), do: "no-upstreams"
  defp profile_name(:with_upstreams), do: "with-upstreams"

  defp catalog_mode_name(:none), do: "none"
  defp catalog_mode_name(mode) when is_atom(mode), do: Atom.to_string(mode)

  defp build_report(opts, results) do
    %{
      "benchmark" => "lisp_session_real_client_eval",
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "repo_root" => @repo_root,
      "models" => opts.models,
      "runs" => opts.runs,
      "profiles" => Enum.map(opts.profiles, &profile_name/1),
      "catalog_modes" => Enum.map(opts.catalog_modes, &Atom.to_string/1),
      "cases" =>
        Enum.map(
          select_cases(opts.case_names),
          fn test_case ->
            test_case
            |> Map.take([:name, :category, :max_turns, :profiles])
            |> Map.update(:profiles, [], &Enum.map(&1, fn p -> profile_name(p) end))
          end
        ),
      "notes" => [
        "Real provider eval; results can drift by model/provider behavior.",
        "This simulates an MCP client loop by converting advertised MCP session tool entries into provider-native function tools, then executing PtcRunnerMcp.Tools.call/1."
      ],
      "summary" => summarize_results(results),
      "results" => results
    }
  end

  defp summarize_results(results) do
    results
    |> Enum.group_by(fn result ->
      {result["model"], result["profile"], result["catalog_mode"], result["case"]}
    end)
    |> Enum.map(fn {{model, profile, catalog_mode, case_name}, rows} ->
      passed = Enum.count(rows, & &1["passed"])
      total = length(rows)

      %{
        "model" => model,
        "profile" => profile,
        "catalog_mode" => catalog_mode,
        "case" => case_name,
        "passed" => passed,
        "total" => total,
        "pass_rate" => Float.round(passed / max(total, 1), 3),
        "median_duration_ms" => median(Enum.map(rows, & &1["duration_ms"])),
        "median_tool_calls" => median(Enum.map(rows, & &1["tool_call_count"])),
        "median_upstream_calls" => median(Enum.map(rows, &length(&1["upstream_calls"] || []))),
        "median_catalog_op_mentions" => median(Enum.map(rows, & &1["catalog_op_mentions"]))
      }
    end)
    |> Enum.sort_by(&{&1["model"], &1["profile"], &1["catalog_mode"], &1["case"]})
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
          row["profile"],
          row["catalog_mode"],
          row["case"],
          "#{row["passed"]}/#{row["total"]}",
          row["median_duration_ms"],
          row["median_tool_calls"],
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
        ### #{result["case"]} / #{result["profile"]} / #{result["catalog_mode"]} / run #{result["run"]}

        Last tool status: #{inspect(result["last_tool_status"])}
        Last tool reason: #{inspect(result["last_tool_reason"])}
        Error: #{inspect(result["error"])}
        Answer: #{inspect(result["answer"], printable_limit: 800)}
        Tool counts: #{inspect(result["tool_counts"])}
        Last tool result: #{inspect(result["last_tool_result"], printable_limit: 800)}

        ```clojure
        #{Enum.join(result["programs"] || [], "\n\n;; ---\n\n")}
        ```
        """
      end)

    """
    # lisp_session real-client eval findings

    Generated: #{report["generated_at"]}
    Models: #{Enum.join(report["models"], ", ")}
    Runs per cell: #{report["runs"]}
    Profiles: #{Enum.join(report["profiles"], ", ")}
    Catalog modes: #{Enum.join(report["catalog_modes"], ", ")}

    This eval uses a real OpenRouter-backed model as an MCP client. It is not
    deterministic and is not intended for default CI.

    ## Summary

    model | profile | catalog_mode | case | pass | median_ms | median_tool_calls | median_upstream_calls | median_catalog_op_mentions
    --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---:
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

Bench.LispSessionRealClientEval.main(System.argv())
