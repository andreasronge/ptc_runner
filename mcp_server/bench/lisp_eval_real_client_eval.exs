# Real-LLM client-loop eval for the advertised `lisp_eval` MCP tool.
#
# This is intentionally not a CI-default benchmark. It spends real provider
# tokens through OpenRouter and measures whether a model that sees the MCP
# `tools/list` description can choose `lisp_eval`, write a useful
# PTC-Lisp program, consume the tool result, and answer the user.
#
# Usage from mcp_server/:
#
#   mix run --no-start bench/lisp_eval_real_client_eval.exs --runs=1
#   mix run --no-start bench/lisp_eval_real_client_eval.exs \
#     --runs=10 \
#     --models=gemini-flash-lite \
#     --profiles=no-upstreams,with-upstreams \
#     --catalog-modes=inline,lazy \
#     --json-out=../tmp/lisp_eval_real_client_eval.json \
#     --md-out=../tmp/lisp_eval_real_client_eval.md

PtcRunner.Dotenv.load()

defmodule Bench.LispExecuteRealClientEval do
  @moduledoc false

  alias PtcRunnerMcp.{AggregatorConfig, CatalogConfig, ResponseProfile, Tools}

  @repo_root Path.expand(Path.join([__DIR__, "..", ".."]))
  @tmp_dir Path.join(@repo_root, "tmp/lisp-execute-real-client-eval")
  @upstreams_path Path.join(@tmp_dir, "upstreams.json")
  @default_json_out Path.join(@repo_root, "tmp/lisp_eval_real_client_eval.json")
  @default_md_out Path.join(@repo_root, "tmp/lisp_eval_real_client_eval.md")

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
        mix run --no-start bench/lisp_eval_real_client_eval.exs [options]

      Options:
        --models=a,b          Model aliases or ids (default: gemini-flash-lite)
        --runs=N             Runs per case/model/catalog-mode (default: 1)
        --case=NAME          Restrict to a case; repeatable
        --profiles=a,b       Profiles: no-upstreams,with-upstreams (default: both)
        --catalog-modes=a,b  Catalog modes: inline,lazy,auto (default: inline,lazy)
        --json-out=PATH      Write raw JSON report (default: ../tmp/lisp_eval_real_client_eval.json)
        --md-out=PATH        Write markdown findings (default: ../tmp/lisp_eval_real_client_eval.md)
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
      |> Keyword.get(:profiles, "no-upstreams,with-upstreams")
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
    System.put_env("PTC_RUNNER_MCP_AGGREGATOR_READ_ONLY", "true")
    System.put_env("PTC_RUNNER_MCP_TOOL_TIMEOUT_MS", "60000")
    System.put_env("PTC_RUNNER_MCP_MAX_PROGRAM_BYTES", "20000")

    Application.put_env(:ptc_runner_mcp, :attach_stdio, false)

    case Application.ensure_all_started(:ptc_runner_mcp) do
      {:ok, _apps} ->
        PtcRunnerMcp.Log.set_level("error")
        AggregatorConfig.set(%{read_only?: true})
        ResponseProfile.set(:debug)
        maybe_start_upstream_subsystem!(opts)

      {:error, {:already_started, _app}} ->
        PtcRunnerMcp.Log.set_level("error")
        AggregatorConfig.set(%{read_only?: true})
        ResponseProfile.set(:debug)
        maybe_start_upstream_subsystem!(opts)

      {:error, reason} ->
        raise "failed to start :ptc_runner_mcp: #{inspect(reason)}"
    end
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
        name: "pure_compute",
        category: "no-upstream compute",
        profiles: [:no_upstreams, :with_upstreams],
        max_turns: 3,
        prompt:
          "Use the MCP tool to compute the sum of squares for 1 through 10. Return only the number.",
        pass: fn result ->
          tool_ok?(result) and result["tool_call_count"] == 1 and
            String.contains?(result["answer"], "385")
        end
      },
      %{
        name: "context_reduce",
        category: "context data",
        profiles: [:no_upstreams, :with_upstreams],
        max_turns: 3,
        prompt:
          "Use the MCP tool with a context object containing records [{name:\"alpha\",score:3},{name:\"beta\",score:7},{name:\"gamma\",score:5}]. Return only the name with the highest score.",
        pass: fn result ->
          tool_ok?(result) and String.contains?(String.downcase(result["answer"]), "beta") and
            String.contains?(result["program"], "data/")
        end
      },
      %{
        name: "context_filter_count",
        category: "context data",
        profiles: [:no_upstreams, :with_upstreams],
        max_turns: 3,
        prompt:
          "Use the MCP tool with a context object containing orders [{id:\"a1\",status:\"paid\",total:12},{id:\"b2\",status:\"draft\",total:9},{id:\"c3\",status:\"paid\",total:20}]. Return only the count of paid orders with total greater than 10.",
        pass: fn result ->
          tool_ok?(result) and result["tool_call_count"] == 1 and
            String.contains?(result["answer"], "2") and
            String.contains?(result["program"], "data/")
        end
      },
      %{
        name: "upstream_list_root",
        category: "single upstream call",
        profiles: [:with_upstreams],
        max_turns: 5,
        prompt:
          "Use the MCP tool to list the repository root through the filesystem upstream. Return exactly five entry names, comma-separated.",
        pass: fn result ->
          tool_ok?(result) and upstream_ok?(result, "list_directory") and
            String.contains?(result["answer"], ".gitignore")
        end
      },
      %{
        name: "lazy_catalog_discovery",
        category: "catalog discovery",
        profiles: [:with_upstreams],
        max_turns: 5,
        catalog_modes: [:lazy],
        prompt:
          "The upstream catalog is not inlined. Use the MCP tool to discover the filesystem directory-listing tool, list the repository root, and return exactly five entry names.",
        pass: fn result ->
          tool_ok?(result) and upstream_ok?(result, "list_directory") and
            String.contains?(result["answer"], ".gitignore") and
            result["catalog_op_mentions"] >= 1
        end
      },
      %{
        name: "upstream_error_recovery",
        category: "error recovery",
        profiles: [:with_upstreams],
        max_turns: 5,
        prompt:
          "Use the MCP tool. First try to read a filesystem path that does not exist, then recover by reading README.md and return the first non-empty line.",
        pass: fn result ->
          tool_ok?(result) and result["upstream_error_count"] >= 1 and
            result["upstream_ok_count"] >= 1 and
            String.contains?(String.downcase(result["answer"]), "ptc")
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
    tool = tool_schema(profile)
    system = system_prompt()
    messages = [%{role: :user, content: prompt}]

    result =
      empty_result()
      |> Map.put("system_prompt", system)
      |> Map.put("user_prompt", prompt)
      |> Map.put("tool_name", get_in(tool, ["function", "name"]))
      |> Map.put(
        "tool_description_bytes",
        byte_size(get_in(tool, ["function", "description"]) || "")
      )

    do_client_loop(llm, system, messages, tool, max_turns, 1, result)
  end

  defp do_client_loop(_llm, _system, _messages, _tool, 0, _turn_index, result) do
    {:error, :max_turns_exhausted, result}
  end

  defp do_client_loop(llm, system, messages, tool, turns_left, turn_index, result) do
    request = %{system: system, messages: messages, tools: [tool]}

    case llm.(request) do
      {:ok, %{tool_calls: tool_calls} = response} when is_list(tool_calls) and tool_calls != [] ->
        [tool_call | extra_calls] = tool_calls
        result = record_provider_response(result, response, extra_calls)

        case execute_tool_call(tool_call) do
          {:ok, tool_result, assistant_message, tool_message} ->
            result =
              result
              |> record_tool_result(tool_call, tool_result)
              |> record_transcript_turn(
                turn_index,
                turns_left,
                messages,
                response,
                tool_call,
                extra_calls,
                tool_result
              )

            messages = messages ++ [assistant_message, tool_message]
            do_client_loop(llm, system, messages, tool, turns_left - 1, turn_index + 1, result)

          {:error, reason, tool_result, assistant_message, tool_message} ->
            result =
              result
              |> record_tool_result(tool_call, tool_result)
              |> Map.put("tool_error", inspect(reason))
              |> record_transcript_turn(
                turn_index,
                turns_left,
                messages,
                response,
                tool_call,
                extra_calls,
                tool_result
              )

            messages = messages ++ [assistant_message, tool_message]
            do_client_loop(llm, system, messages, tool, turns_left - 1, turn_index + 1, result)
        end

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
    You are an MCP client. Use the advertised `lisp_eval` tool when the
    user asks you to compute, transform data, or call configured upstream MCP
    servers. After a tool result, answer the user from the tool result. Keep the
    final answer concise and do not include code unless explicitly requested.
    """
  end

  defp tool_schema(:with_upstreams) do
    entry =
      Tools.list()
      |> Map.fetch!("tools")
      |> Enum.find(&(&1["name"] == "lisp_eval"))

    provider_tool_schema(entry)
  end

  defp tool_schema(:no_upstreams) do
    entry =
      Tools.list()
      |> Map.fetch!("tools")
      |> Enum.find(&(&1["name"] == "lisp_eval"))
      |> Map.put(
        "description",
        Tools.advertised_description(:mcp_no_tools, ResponseProfile.current(), catalog: nil)
      )

    provider_tool_schema(entry)
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

  defp execute_tool_call(%{name: "lisp_eval", args: args} = tool_call) when is_map(args) do
    envelope = Tools.call(%{"name" => "lisp_eval", "arguments" => args})
    tool_result = result_payload(envelope)

    assistant_message = assistant_message(tool_call)
    tool_message = tool_message(tool_call, tool_result)

    if Map.get(tool_result, "status") == "ok" do
      {:ok, tool_result, assistant_message, tool_message}
    else
      {:error, Map.get(tool_result, "reason"), tool_result, assistant_message, tool_message}
    end
  end

  defp execute_tool_call(%{name: other} = tool_call) do
    tool_result = %{"status" => "error", "reason" => "unknown_tool", "message" => other}
    assistant_message = assistant_message(tool_call)
    tool_message = tool_message(tool_call, tool_result)
    {:error, :unknown_tool, tool_result, assistant_message, tool_message}
  end

  defp assistant_message(tool_call) do
    %{
      role: :assistant,
      content: nil,
      tool_calls: [
        %{
          id: tool_call[:id],
          function: %{
            name: tool_call.name,
            arguments: Jason.encode!(tool_call.args || %{})
          }
        }
      ]
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
      "program" => "",
      "tool_call_count" => 0,
      "extra_tool_call_count" => 0,
      "tool_status" => nil,
      "tool_reason" => nil,
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
         tool_call,
         extra_calls,
         tool_result
       ) do
    append_transcript(result, %{
      "turn" => turn_index,
      "turns_left_before_call" => turns_left,
      "messages_seen" => summarize_messages(messages),
      "provider_response" => summarize_provider_response(response),
      "tool_call" => summarize_tool_call(tool_call),
      "extra_tool_calls" => Enum.map(extra_calls, &summarize_tool_call/1),
      "tool_result" => summarize_tool_result(tool_result)
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
      "result",
      "reason",
      "message",
      "feedback",
      "prints",
      "upstream_results",
      "upstream_calls",
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

  defp record_provider_response(result, response, extra_calls) do
    result
    |> merge_tokens(response)
    |> Map.update!("extra_tool_call_count", &(&1 + length(extra_calls)))
  end

  defp record_tool_result(result, tool_call, tool_result) do
    program = get_in(tool_call, [:args, "program"]) || get_in(tool_call, [:args, :program]) || ""
    upstream_calls = Map.get(tool_result, "upstream_calls", []) || []
    all_upstream_calls = Map.get(result, "upstream_calls", []) ++ upstream_calls
    catalog_op_mentions = Map.get(result, "catalog_op_mentions", 0) + count_catalog_mentions(program)

    result
    |> Map.update!("tool_call_count", &(&1 + 1))
    |> Map.put("program", program)
    |> Map.put("tool_status", Map.get(tool_result, "status"))
    |> Map.put("tool_reason", Map.get(tool_result, "reason"))
    |> Map.put("tool_result", Map.take(tool_result, ["status", "result", "reason", "message"]))
    |> Map.put("upstream_calls", all_upstream_calls)
    |> Map.put("upstream_ok_count", Enum.count(all_upstream_calls, &(Map.get(&1, "status") == "ok")))
    |> Map.put(
      "upstream_error_count",
      Enum.count(all_upstream_calls, &(Map.get(&1, "status") == "error"))
    )
    |> Map.put("catalog_op_mentions", catalog_op_mentions)
  end

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

  defp tool_ok?(result), do: result["tool_status"] == "ok"

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
      "benchmark" => "lisp_eval_real_client_eval",
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
        "This simulates an MCP client loop by converting the advertised MCP tool entry into a provider-native function tool, then executing PtcRunnerMcp.Tools.call/1."
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

        Tool status: #{inspect(result["tool_status"])}
        Tool reason: #{inspect(result["tool_reason"])}
        Error: #{inspect(result["error"])}
        Answer: #{inspect(result["answer"], printable_limit: 800)}
        Tool result: #{inspect(result["tool_result"], printable_limit: 800)}

        ```clojure
        #{result["program"]}
        ```
        """
      end)

    """
    # lisp_eval real-client eval findings

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

Bench.LispExecuteRealClientEval.main(System.argv())
