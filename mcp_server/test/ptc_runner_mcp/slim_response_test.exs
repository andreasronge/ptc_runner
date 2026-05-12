defmodule PtcRunnerMcp.SlimResponseTest do
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.{
    AggregatorConfig,
    DebugBuffer,
    DebugConfig,
    JsonRpc,
    Limits,
    ResponseProfile,
    Tools
  }

  alias PtcRunnerMcp.Upstream.Registry

  @registry_name PtcRunnerMcp.Upstream.Registry

  setup do
    old_profile = ResponseProfile.current()
    old_debug = DebugConfig.get()
    stop_registry()
    stop_buffer()
    Limits.set(Limits.defaults())
    AggregatorConfig.set(AggregatorConfig.defaults())
    DebugConfig.set(DebugConfig.defaults())
    ResponseProfile.set(:slim)

    on_exit(fn ->
      stop_registry()
      stop_buffer()
      Limits.set(Limits.defaults())
      AggregatorConfig.set(AggregatorConfig.defaults())
      DebugConfig.set(old_debug)
      ResponseProfile.set(old_profile)
    end)

    :ok
  end

  test "slim success emits text only" do
    env =
      Tools.call(%{
        "name" => "ptc_lisp_execute",
        "arguments" => %{"program" => "(+ 1 2)"}
      })

    assert env == %{
             "isError" => false,
             "content" => [%{"type" => "text", "text" => "user=> 3"}]
           }

    refute Map.has_key?(env, "structuredContent")
  end

  test "slim success renders prints compactly and omits empty/default fields" do
    env =
      Tools.call(%{
        "name" => "ptc_lisp_execute",
        "arguments" => %{"program" => ~S|(do (println "line 1") (+ 1 2))|}
      })

    [block] = env["content"]
    assert block["text"] == "<prints>\nline 1\n\n<result>\nuser=> 3"
    refute Map.has_key?(env, "structuredContent")
    refute inspect(env) =~ "ptc_metrics"
    refute inspect(env) =~ "upstream_calls"
    refute inspect(env) =~ "truncated"
  end

  test "slim error emits useful repair text and no structuredContent" do
    env =
      Tools.call(%{
        "name" => "ptc_lisp_execute",
        "arguments" => %{"program" => "(missing-fn 1)"}
      })

    assert env["isError"] == true
    [block] = env["content"]
    assert block["text"] =~ "runtime_error:"
    refute Map.has_key?(env, "structuredContent")
  end

  test "slim tools/list omits outputSchema" do
    %{"tools" => [tool]} = Tools.list()

    refute Map.has_key?(tool, "outputSchema")
    assert tool["description"] =~ "Response profile: slim"
  end

  test "structured profile emits compact structuredContent and concise text" do
    ResponseProfile.set(:structured)

    env =
      Tools.call(%{
        "name" => "ptc_lisp_execute",
        "arguments" => %{"program" => "(+ 1 2)"}
      })

    assert env["isError"] == false
    assert env["structuredContent"] == %{"status" => "ok", "result" => "user=> 3"}
    assert env["content"] == [%{"type" => "text", "text" => "user=> 3"}]
  end

  test "debug profile preserves the verbose envelope" do
    ResponseProfile.set(:debug)

    env =
      Tools.call(%{
        "name" => "ptc_lisp_execute",
        "arguments" => %{"program" => "(+ 1 2)"}
      })

    assert env["structuredContent"]["status"] == "ok"
    assert Jason.decode!(hd(env["content"])["text"]) == env["structuredContent"]
  end

  test "slim aggregator success omits observability even with upstream calls" do
    {:ok, _pid} = Registry.start_link(name: @registry_name)

    :ok =
      Registry.put_fake(
        "alpha",
        %{tools: %{"echo" => {%{name: "echo", input_schema: %{}}, fn _, _ -> {:ok, "ok"} end}}},
        @registry_name
      )

    env =
      Tools.call_with_gate(%{
        "program" => ~S|(tool/mcp-call {:server "alpha" :tool "echo" :args {}})|
      })

    assert env["isError"] == false
    refute Map.has_key?(env, "structuredContent")
    refute inspect(env) =~ "upstream_calls"
    refute inspect(env) =~ "ptc_metrics"
  end

  test "explicit slim with debug enabled records pre-slim upstream diagnostics internally" do
    DebugConfig.set(%{enabled: true, ring_size: 500, max_response_bytes: 65_536})
    {:ok, _pid} = DebugBuffer.start_link(ring_size: 500, name: DebugBuffer)
    {:ok, _pid} = Registry.start_link(name: @registry_name)

    :ok =
      Registry.put_fake(
        "alpha",
        %{tools: %{"echo" => {%{name: "echo", input_schema: %{}}, fn _, _ -> {:ok, "ok"} end}}},
        @registry_name
      )

    frame = %{
      "jsonrpc" => "2.0",
      "id" => 123,
      "method" => "tools/call",
      "params" => %{
        "name" => "ptc_lisp_execute",
        "arguments" => %{
          "program" => ~S|(tool/mcp-call {:server "alpha" :tool "echo" :args {}})|
        }
      }
    }

    {:async_call, 123, work_fn, _on_busy, _} = JsonRpc.dispatch({:ok, frame})
    env = work_fn.()

    refute Map.has_key?(env, "structuredContent")
    refute Map.has_key?(env, "__ptc_debug_structured")

    {:ok, rec} = DebugBuffer.get("123")
    [entry] = rec.upstream_calls
    assert entry["server"] == "alpha"
    assert entry["tool"] == "echo"
    assert entry["status"] == "ok"
    assert is_map(rec.ptc_metrics)
  end

  defp stop_registry do
    case Process.whereis(@registry_name) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> :ok
        end
    end
  end

  defp stop_buffer do
    case Process.whereis(DebugBuffer) do
      nil -> :ok
      pid -> if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end
end
