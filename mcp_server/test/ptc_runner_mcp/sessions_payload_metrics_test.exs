defmodule PtcRunnerMcp.SessionsPayloadMetricsTest do
  @moduledoc """
  Regression coverage for GitHub issue #944 finding #2: `ptc_session_eval`
  responses must carry a `ptc_metrics` block when the eval made upstream
  calls, mirroring the stateless `ptc_lisp_execute` path.

  Combines the aggregator-mode setup from `AggregatorPhase1aTest` with
  the session enablement from `SessionsTest`.
  """
  use ExUnit.Case, async: false

  import PtcRunnerMcp.McpTestHelpers, only: [stop_existing_registry: 1]

  alias PtcRunnerMcp.{AggregatorConfig, ConcurrencyGate, Limits, Sessions, Tools}
  alias PtcRunnerMcp.Sessions.Config, as: SessionsConfig
  alias PtcRunnerMcp.Sessions.Registry, as: SessionsRegistry
  alias PtcRunnerMcp.Upstream.Registry, as: UpstreamRegistry

  @registry_name PtcRunnerMcp.Upstream.Registry

  setup do
    stop_existing_registry(@registry_name)
    stop_sessions_processes()

    {:ok, _pid} = UpstreamRegistry.start_link(name: @registry_name)
    Limits.set(Limits.defaults())
    AggregatorConfig.set(AggregatorConfig.defaults())
    SessionsConfig.set(%{enabled: true})
    ConcurrencyGate.reset()
    assert :ok = Sessions.ensure_started()

    on_exit(fn ->
      stop_existing_registry(@registry_name)
      stop_sessions_processes()
      Limits.set(Limits.defaults())
      AggregatorConfig.set(AggregatorConfig.defaults())
      SessionsConfig.reset()
      ConcurrencyGate.reset()
    end)

    :ok
  end

  describe "ptc_metrics on session eval responses" do
    test "successful eval with upstream call attaches ptc_metrics block" do
      put_fake("alpha", %{"echo" => fn args, _ -> {:ok, %{"echo" => args["msg"]}} end})

      session_id = start_session()

      response =
        eval(session_id, ~S|(tool/mcp-call {:server "alpha" :tool "echo" :args {:msg "hi"}})|)

      assert response["status"] == "ok"

      metrics = response["ptc_metrics"]

      assert is_map(metrics),
             "expected ptc_metrics on session eval response, got: #{inspect(response)}"

      assert metrics["schema_version"] == 1
      assert metrics["upstream_call_count"] == 1
      assert metrics["upstream_ok_count"] == 1
      assert metrics["upstream_error_count"] == 0
      assert is_integer(metrics["upstream_result_bytes"]) and metrics["upstream_result_bytes"] > 0
      assert is_integer(metrics["final_result_bytes"]) and metrics["final_result_bytes"] > 0
    end

    test "eval that makes no upstream calls omits ptc_metrics" do
      put_fake("alpha", %{"echo" => fn _, _ -> {:ok, "ok"} end})

      session_id = start_session()
      response = eval(session_id, "(+ 1 2)")

      assert response["status"] == "ok"
      refute Map.has_key?(response, "ptc_metrics")
    end

    test "failed eval still surfaces ptc_metrics for calls made before failure" do
      put_fake("alpha", %{"echo" => fn _, _ -> {:ok, "value"} end})

      session_id = start_session()

      # `(/ 1 0)` survives analyze but raises at runtime, so the upstream
      # call runs and is drained before the crash.
      response =
        eval(
          session_id,
          ~S|(do (tool/mcp-call {:server "alpha" :tool "echo" :args {}}) (/ 1 0))|
        )

      assert response["status"] == "error"

      metrics = response["ptc_metrics"]
      assert is_map(metrics), "expected ptc_metrics on failed eval, got: #{inspect(response)}"
      assert metrics["upstream_call_count"] == 1
      # On error final_result_bytes degrades: the projection has no "result"
      # field, so byte size is 0 and the ratio is null (PayloadMetrics §7 #2).
      assert metrics["final_result_bytes"] == 0
      assert metrics["payload_reduction_ratio"] == nil
    end

    test "limit-exceeded eval still surfaces ptc_metrics for the calls it made" do
      # Lower max_session_memory_bytes so storing the upstream result
      # via (def ...) makes the candidate state fail validate_candidate
      # AFTER the upstream call already ran and drained.
      SessionsConfig.set(%{enabled: true, max_session_memory_bytes: 64})

      put_fake("alpha", %{
        "echo" => fn _, _ -> {:ok, String.duplicate("x", 512)} end
      })

      session_id = start_session()

      response =
        eval(
          session_id,
          ~S|(def big (tool/mcp-call {:server "alpha" :tool "echo" :args {}}))|
        )

      assert response["status"] == "error"
      assert response["reason"] == "session_limit_exceeded"

      metrics = response["ptc_metrics"]

      assert is_map(metrics),
             "expected ptc_metrics on limit-exceeded eval, got: #{inspect(response)}"

      assert metrics["upstream_call_count"] == 1
      assert metrics["upstream_ok_count"] == 1
    end

    test "metrics count each per-eval batch separately, not cumulative session calls" do
      put_fake("alpha", %{"echo" => fn _, _ -> {:ok, "v"} end})

      session_id = start_session()

      first = eval(session_id, ~S|(tool/mcp-call {:server "alpha" :tool "echo" :args {}})|)
      second = eval(session_id, ~S|(tool/mcp-call {:server "alpha" :tool "echo" :args {}})|)

      assert first["ptc_metrics"]["upstream_call_count"] == 1
      assert second["ptc_metrics"]["upstream_call_count"] == 1
    end
  end

  defp tools_config(tools) do
    %{
      tools:
        Map.new(tools, fn {n, fun} ->
          {n, {%{name: n, input_schema: %{}}, fun}}
        end)
    }
  end

  defp put_fake(name, tools) do
    :ok = UpstreamRegistry.put_fake(name, tools_config(tools), @registry_name)
  end

  defp start_session do
    call!("ptc_session_start", %{})["session_id"]
  end

  defp eval(session_id, program) do
    call!("ptc_session_eval", %{"session_id" => session_id, "program" => program})
  end

  defp call!(name, args) do
    envelope = Tools.call(%{"name" => name, "arguments" => args})
    envelope["structuredContent"]
  end

  defp stop_sessions_processes do
    stop_if_alive(SessionsRegistry)
    stop_if_alive(PtcRunnerMcp.Sessions.Supervisor)
    stop_if_alive(PtcRunnerMcp.Sessions.Names)
  end

  defp stop_if_alive(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> stop_process(pid)
    end
  end

  defp stop_process(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal, 5_000)
    end
  catch
    :exit, _ -> :ok
  end
end
