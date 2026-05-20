# Real-provider smoke for `lisp_task`.
#
# Usage from mcp_server/:
#
#   mix run --no-start bench/agentic_real_provider_smoke.exs
#   mix run --no-start bench/agentic_real_provider_smoke.exs --model=sonnet --runs=2
#
# Requires OPENROUTER_API_KEY. The script exits 0 with a skip message when
# the key or `npx` is unavailable, so it is safe to run in local preflight.

PtcRunner.Dotenv.load()

defmodule Bench.AgenticRealProviderSmoke do
  @moduledoc false

  alias PtcRunnerMcp.Agentic

  @repo_root Path.expand(Path.join([__DIR__, "..", ".."]))
  @tmp_dir Path.join(@repo_root, "tmp/agentic-real-provider-smoke")
  @upstreams_path Path.join(@tmp_dir, "upstreams.json")

  def main(argv) do
    {opts, _positional, _invalid} =
      OptionParser.parse(argv,
        strict: [
          model: :string,
          runs: :integer,
          report: :string,
          task: :string,
          fail_on_skip: :boolean
        ]
      )

    model = opts[:model] || "gemini-flash-lite"
    runs = opts[:runs] || 1

    with :ok <- check_openrouter_key(opts),
         :ok <- check_npx(opts),
         :ok <- boot_mcp(model) do
      cases = selected_cases(opts[:task])

      results =
        for run <- 1..runs,
            test_case <- cases do
          run_case(run, model, test_case)
        end

      report = render_report(model, results)
      IO.puts(report)

      if path = opts[:report] do
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, report)
      end

      if Enum.all?(results, & &1.passed?) do
        System.halt(0)
      else
        System.halt(1)
      end
    else
      {:skip, message} ->
        IO.puts("SKIP: #{message}")
        System.halt(if opts[:fail_on_skip], do: 1, else: 0)
    end
  end

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

  defp boot_mcp(model) do
    write_upstreams_config!()

    System.put_env("PTC_RUNNER_MCP_UPSTREAMS", @upstreams_path)
    System.put_env("PTC_RUNNER_MCP_AGENTIC", "true")
    System.put_env("PTC_RUNNER_MCP_AGENTIC_MODEL", model)
    System.put_env("PTC_RUNNER_MCP_AGGREGATOR_READ_ONLY", "true")
    System.put_env("PTC_RUNNER_MCP_AGENTIC_TASK_TIMEOUT_MS", "45000")
    System.put_env("PTC_RUNNER_MCP_AGENTIC_PLANNER_TIMEOUT_MS", "15000")
    System.put_env("PTC_RUNNER_MCP_AGENTIC_MAX_OUTPUT_TOKENS", "1200")

    Application.put_env(:ptc_runner_mcp, :attach_stdio, false)

    case Application.ensure_all_started(:ptc_runner_mcp) do
      {:ok, _apps} ->
        PtcRunnerMcp.Log.set_level("error")
        start_upstream_subsystem!()

      {:error, {:already_started, _app}} ->
        PtcRunnerMcp.Log.set_level("error")
        start_upstream_subsystem!()

      {:error, reason} ->
        raise "failed to start :ptc_runner_mcp: #{inspect(reason)}"
    end
  end

  defp start_upstream_subsystem! do
    %{upstreams: upstreams, credentials: bindings} =
      PtcRunnerMcp.Application.load_aggregator_config(%{upstreams_config: @upstreams_path})

    if Process.whereis(PtcRunnerMcp.Credentials) == nil do
      {:ok, _} = PtcRunnerMcp.Credentials.start_link(bindings: bindings)
    end

    if Process.whereis(PtcRunnerMcp.Upstream.Supervisor) == nil do
      {:ok, _} = PtcRunnerMcp.Upstream.Supervisor.start_link(upstreams: upstreams)
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

  defp selected_cases(nil), do: default_cases()

  defp selected_cases(task) when is_binary(task) do
    [
      %{
        name: "custom",
        task: task,
        constraints: %{},
        check: fn payload -> Map.get(payload, "status") == "ok" end
      }
    ]
  end

  defp default_cases do
    [
      %{
        name: "read_readme",
        task: "Read README.md and return the first 5 non-empty lines exactly as text.",
        constraints: %{"max_items" => 5},
        check: fn payload ->
          answer = to_string(Map.get(payload, "answer", ""))

          Map.get(payload, "status") == "ok" and
            String.contains?(answer, "ptc_runner") and
            upstream_ok?(payload, "read_text_file")
        end
      },
      %{
        name: "list_repo_root",
        task:
          "Use filesystem list_directory with path \".\". Tell the user the first 5 listed entry names.",
        constraints: %{"max_items" => 5},
        check: fn payload ->
          answer = to_string(Map.get(payload, "answer", ""))

          Map.get(payload, "status") == "ok" and
            upstream_ok?(payload, "list_directory") and
            String.contains?(answer, ".gitignore") and
            not String.contains?(answer, "[null]")
        end
      }
    ]
  end

  defp run_case(run, model, test_case) do
    started = System.monotonic_time(:millisecond)

    result =
      with {:ok, validated} <-
             Agentic.validate(%{
               "task" => test_case.task,
               "constraints" => test_case.constraints
             })
             |> normalize_validation_result(),
           envelope <- Agentic.run_validated(validated, request_id: "#{test_case.name}-#{run}") do
        envelope
      end

    duration_ms = System.monotonic_time(:millisecond) - started
    payload = result_payload(result)
    passed? = test_case.check.(payload)

    %{
      run: run,
      name: test_case.name,
      model: model,
      passed?: passed?,
      duration_ms: duration_ms,
      status: Map.get(payload, "status"),
      reason: Map.get(payload, "reason"),
      message: Map.get(payload, "message"),
      answer: Map.get(payload, "answer"),
      structured_result: Map.get(payload, "structured_result"),
      planner: Map.get(payload, "planner", %{}),
      upstream_calls: Map.get(payload, "upstream_calls", []),
      program: Map.get(payload, "program")
    }
  end

  defp normalize_validation_result({:ok, validated}), do: {:ok, validated}

  defp normalize_validation_result({:error, envelope}) do
    {:error, result_payload(envelope)}
  end

  defp result_payload(%{"structuredContent" => payload}) when is_map(payload), do: payload
  defp result_payload(%{} = payload), do: payload
  defp result_payload(other), do: %{"status" => "error", "reason" => inspect(other)}

  defp upstream_ok?(payload, tool_name) do
    payload
    |> Map.get("upstream_calls", [])
    |> Enum.any?(&(Map.get(&1, "tool") == tool_name and Map.get(&1, "status") == "ok"))
  end

  defp render_report(model, results) do
    passed = Enum.count(results, & &1.passed?)
    total = length(results)

    rows =
      Enum.map_join(results, "\n", fn result ->
        planner = result.planner || %{}
        tokens = Map.get(planner, "tokens", %{})
        cost = Map.get(tokens, "total_cost")

        [
          result.run,
          result.name,
          if(result.passed?, do: "PASS", else: "FAIL"),
          result.status || "",
          result.reason || "",
          result.message || "",
          result.duration_ms,
          Map.get(planner, "duration_ms", ""),
          Map.get(tokens, "input", ""),
          Map.get(tokens, "output", ""),
          if(is_number(cost), do: :erlang.float_to_binary(cost, decimals: 6), else: "")
        ]
        |> Enum.map(&to_string/1)
        |> Enum.join(" | ")
      end)

    details =
      results
      |> Enum.reject(& &1.passed?)
      |> Enum.map_join("\n\n", fn result ->
        """
        ### #{result.name} run #{result.run}

        Status: #{inspect(result.status)}
        Reason: #{inspect(result.reason)}
        Message: #{inspect(result.message)}
        Answer: #{inspect(result.answer, printable_limit: 500)}
        Structured: #{inspect(result.structured_result, printable_limit: 500)}
        Program:
        ```clojure
        #{result.program}
        ```
        """
      end)

    """
    # Agentic real-provider smoke

    Model: #{model}
    Result: #{passed}/#{total} passed

    run | case | result | status | reason | message | ms | planner_ms | in_tok | out_tok | cost
    --- | --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---:
    #{rows}
    #{if(details == "", do: "", else: "\n" <> details)}
    """
  end
end

Bench.AgenticRealProviderSmoke.main(System.argv())
