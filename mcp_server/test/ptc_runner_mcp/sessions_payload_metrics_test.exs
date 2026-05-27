defmodule PtcRunnerMcp.SessionsPayloadMetricsTest do
  @moduledoc """
  Regression coverage for session eval response bloat: normal responses must
  not inline verbose upstream accounting, while `lisp_debug` still retains the
  diagnostic payload for explicit retrieval.
  """
  use ExUnit.Case, async: false

  import PtcRunnerMcp.McpTestHelpers, only: [stop_existing_registry: 1]

  alias PtcRunnerMcp.{
    AggregatorConfig,
    ConcurrencyGate,
    DebugBuffer,
    DebugConfig,
    JsonRpc,
    Limits,
    ResponseProfile,
    Sessions,
    Tools
  }

  alias PtcRunnerMcp.Sessions.Config, as: SessionsConfig
  alias PtcRunnerMcp.Sessions.Registry, as: SessionsRegistry
  alias PtcRunnerMcp.Upstream.Registry, as: UpstreamRegistry

  @registry_name PtcRunnerMcp.Upstream.Registry

  setup do
    old_debug = DebugConfig.get()
    old_profile = ResponseProfile.current()
    stop_existing_registry(@registry_name)
    stop_sessions_processes()
    stop_buffer()

    {:ok, _pid} = UpstreamRegistry.start_link(name: @registry_name)
    Limits.set(Limits.defaults())
    AggregatorConfig.set(AggregatorConfig.defaults())
    DebugConfig.set(%{enabled: false, ring_size: 500, max_response_bytes: 65_536})
    ResponseProfile.set(:slim)
    SessionsConfig.set(%{enabled: true})
    ConcurrencyGate.reset()
    assert :ok = Sessions.ensure_started()

    on_exit(fn ->
      stop_existing_registry(@registry_name)
      stop_sessions_processes()
      stop_buffer()
      Limits.set(Limits.defaults())
      AggregatorConfig.set(AggregatorConfig.defaults())
      DebugConfig.set(old_debug)
      ResponseProfile.set(old_profile)
      SessionsConfig.reset()
      ConcurrencyGate.reset()
    end)

    :ok
  end

  describe "session eval upstream diagnostics" do
    test "structured session eval omits inline ptc_metrics and full upstream_calls" do
      ResponseProfile.set(:structured)
      put_fake("alpha", %{"echo" => fn args, _ -> {:ok, %{"echo" => args["msg"]}} end})
      session_id = start_session()

      envelope =
        eval_envelope(
          session_id,
          ~S|(tool/call {:server "alpha" :tool "echo" :args {:msg "hi"}})|
        )

      response = envelope["structuredContent"]
      assert response["status"] == "ok"
      assert response["session"]["session_id"] == session_id
      assert response["result"] =~ "user=>"
      refute Map.has_key?(response, "ptc_metrics")
      refute Map.has_key?(response, "upstream_calls")
      refute inspect(envelope) =~ "ptc_metrics"
      refute inspect(envelope) =~ "upstream_calls"
    end

    test "slim session eval omits structured diagnostics from the public envelope" do
      put_fake("alpha", %{"echo" => fn _, _ -> {:ok, "value"} end})
      session_id = start_session()

      envelope =
        eval_envelope(session_id, ~S|(tool/call {:server "alpha" :tool "echo" :args {}})|)

      assert envelope["isError"] == false
      refute Map.has_key?(envelope, "structuredContent")
      assert get_in(envelope, ["content", Access.at(0), "text"]) =~ "user=>"
      refute inspect(envelope) =~ "ptc_metrics"
      refute inspect(envelope) =~ "upstream_calls"
    end

    test "debug recording keeps ptc_metrics and redacted upstream_calls for slim session eval" do
      enable_debug()
      put_fake("alpha", %{"echo" => fn args, _ -> {:ok, %{"echo" => args["msg"]}} end})
      session_id = start_session()

      env =
        json_rpc_eval(
          "session-metrics-1",
          session_id,
          ~S|(tool/call {:server "alpha" :tool "echo" :args {:msg "hi"}})|
        )

      refute Map.has_key?(env, "structuredContent")
      refute Map.has_key?(env, "__lisp_debug_structured")

      {:ok, record} = DebugBuffer.get("session-metrics-1")
      assert record.tool == "lisp_session_eval"
      assert is_map(record.ptc_metrics)
      assert record.ptc_metrics["schema_version"] == 1
      assert record.ptc_metrics["upstream_call_count"] == 1
      assert record.ptc_metrics["upstream_ok_count"] == 1
      assert is_integer(record.ptc_metrics["upstream_result_bytes"])
      assert is_integer(record.ptc_metrics["final_result_bytes"])

      [entry] = record.upstream_calls
      assert entry["server"] == "alpha"
      assert entry["tool"] == "echo"
      assert entry["status"] == "ok"
      assert is_integer(entry["result_bytes"])

      debug_get = call_debug("debug-get-1", %{"op" => "get", "request_id" => "session-metrics-1"})
      assert debug_get["record"]["ptc_metrics"]["upstream_call_count"] == 1
      [debug_entry] = debug_get["record"]["upstream_calls"]
      assert debug_entry["server"] == "alpha"
      assert debug_entry["tool"] == "echo"
    end

    test "debug recording keeps metrics for failed session eval after upstream call" do
      enable_debug()
      put_fake("alpha", %{"echo" => fn _, _ -> {:ok, "value"} end})
      session_id = start_session()

      env =
        json_rpc_eval(
          "session-metrics-2",
          session_id,
          ~S|(do (tool/call {:server "alpha" :tool "echo" :args {}}) (/ 1 0))|
        )

      assert env["isError"] == true
      refute inspect(env) =~ "ptc_metrics"

      {:ok, record} = DebugBuffer.get("session-metrics-2")
      assert record.ptc_metrics["upstream_call_count"] == 1
      assert record.ptc_metrics["final_result_bytes"] == 0
      assert record.ptc_metrics["payload_reduction_ratio"] == nil
      [entry] = record.upstream_calls
      assert entry["status"] == "ok"
    end

    test "failed session eval feedback includes compact upstream result summary" do
      ResponseProfile.set(:structured)

      put_fake("alpha", %{
        "echo" => fn _, _ -> {:ok, %{"structuredContent" => %{"content" => "hello"}}} end
      })

      session_id = start_session()

      envelope =
        eval_envelope(
          session_id,
          ~S|(do (tool/call {:server "alpha" :tool "echo" :args {}}) (+ 1 "x"))|
        )

      assert envelope["isError"] == true
      feedback = envelope["structuredContent"]["feedback"]
      assert feedback =~ "source=\"upstream-tool-results\""
      assert feedback =~ "Tool results before error"
      assert feedback =~ "alpha.echo ok"
      assert feedback =~ "map keys=[\"content\"]"
    end

    test "limit-exceeded public response omits metrics while debug record keeps them" do
      enable_debug()
      SessionsConfig.set(%{enabled: true, max_session_memory_bytes: 64})

      put_fake("alpha", %{
        "echo" => fn _, _ -> {:ok, String.duplicate("x", 512)} end
      })

      session_id = start_session()

      env =
        json_rpc_eval(
          "session-metrics-3",
          session_id,
          ~S|(def big (tool/call {:server "alpha" :tool "echo" :args {}}))|
        )

      assert env["isError"] == true
      assert get_in(env, ["content", Access.at(0), "text"]) =~ "session_limit_exceeded"
      refute inspect(env) =~ "ptc_metrics"

      {:ok, record} = DebugBuffer.get("session-metrics-3")
      assert record.ptc_metrics["upstream_call_count"] == 1
      assert record.ptc_metrics["upstream_ok_count"] == 1
    end
  end

  defp tools_config(tools) do
    %{
      tools:
        Map.new(tools, fn {name, fun} ->
          {name, {%{name: name, input_schema: %{}}, fun}}
        end)
    }
  end

  defp put_fake(name, tools) do
    :ok = UpstreamRegistry.put_fake(name, tools_config(tools), @registry_name)
  end

  defp enable_debug do
    DebugConfig.set(%{enabled: true, ring_size: 500, max_response_bytes: 65_536})
    {:ok, _pid} = DebugBuffer.start_link(ring_size: 500, name: DebugBuffer)
    :ok
  end

  defp start_session do
    call!("lisp_session_start", %{})["session_id"]
  end

  defp eval_envelope(session_id, program) do
    Tools.call(%{
      "name" => "lisp_session_eval",
      "arguments" => %{"session_id" => session_id, "program" => program}
    })
  end

  defp json_rpc_eval(id, session_id, program) do
    frame = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{
        "name" => "lisp_session_eval",
        "arguments" => %{"session_id" => session_id, "program" => program}
      }
    }

    {:async_call, ^id, work_fn, _on_busy, _on_discard, _} = JsonRpc.dispatch({:ok, frame})
    work_fn.()
  end

  defp call_debug(id, args) do
    frame = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => "lisp_debug", "arguments" => args}
    }

    {:reply, %{"result" => envelope}, _} = JsonRpc.dispatch({:ok, frame})
    envelope["structuredContent"]
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

  defp stop_buffer do
    case Process.whereis(DebugBuffer) do
      nil -> :ok
      pid -> if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end
end
