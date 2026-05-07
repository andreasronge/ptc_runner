defmodule PtcRunnerMcp.JsonRpcTest do
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.JsonRpc

  describe "initialize" do
    test "echoes 2025-11-25 when client requests it" do
      frame = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"protocolVersion" => "2025-11-25"}
      }

      {:reply, reply, :continue} = JsonRpc.dispatch({:ok, frame})

      assert reply["jsonrpc"] == "2.0"
      assert reply["id"] == 1
      result = reply["result"]
      assert result["protocolVersion"] == "2025-11-25"
      assert result["serverInfo"]["name"] == "ptc_runner_mcp"
      assert result["serverInfo"]["version"] =~ ~r/^\d+\.\d+\.\d+/
      assert result["capabilities"]["tools"]["listChanged"] == false
    end

    test "echoes 2025-06-18 when client requests it" do
      frame = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"protocolVersion" => "2025-06-18"}
      }

      {:reply, reply, _} = JsonRpc.dispatch({:ok, frame})
      assert reply["result"]["protocolVersion"] == "2025-06-18"
    end

    test "falls back to 2025-11-25 for unrecognized versions" do
      frame = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"protocolVersion" => "1999-01-01"}
      }

      {:reply, reply, _} = JsonRpc.dispatch({:ok, frame})
      assert reply["result"]["protocolVersion"] == "2025-11-25"
    end

    test "result has no resources/prompts/experimental/elicitation/sampling keys" do
      frame = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"protocolVersion" => "2025-11-25"}
      }

      {:reply, reply, _} = JsonRpc.dispatch({:ok, frame})
      result = reply["result"]

      refute Map.has_key?(result["capabilities"], "resources")
      refute Map.has_key?(result["capabilities"], "prompts")
      refute Map.has_key?(result["capabilities"], "experimental")
      refute Map.has_key?(result["capabilities"], "elicitation")
      refute Map.has_key?(result["capabilities"], "sampling")
    end
  end

  describe "notifications/initialized" do
    test "is silently accepted (no reply)" do
      frame = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      assert {:noreply, :continue} = JsonRpc.dispatch({:ok, frame})
    end
  end

  describe "tools/list" do
    test "returns the single advertised tool" do
      frame = %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}
      {:reply, reply, :continue} = JsonRpc.dispatch({:ok, frame})

      assert reply["id"] == 2
      assert [%{"name" => "ptc_lisp_execute"}] = reply["result"]["tools"]
    end
  end

  describe "tools/call" do
    test "ptc_lisp_execute (+ 1 2) returns success envelope (isError=false)" do
      # Phase 4: tools/call dispatch is async. JsonRpc returns an
      # `{:async_call, id, work_fn, lifecycle}` outcome; the work_fn
      # is the body that Stdio runs in a per-call worker. We invoke
      # it inline here to assert the envelope shape end-to-end.
      frame = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{"name" => "ptc_lisp_execute", "arguments" => %{"program" => "(+ 1 2)"}}
      }

      assert {:async_call, 3, work_fn, :continue} = JsonRpc.dispatch({:ok, frame})

      env = work_fn.()
      assert env["isError"] == false
      assert env["structuredContent"]["status"] == "ok"
      assert env["structuredContent"]["result"] == "user=> 3"
    end

    test "ptc_lisp_execute with malformed args returns args_error synchronously" do
      # Validation errors short-circuit before the async path: JsonRpc
      # returns {:reply, ..., :continue} with the rendered envelope,
      # so no worker is spawned and no permit is acquired.
      frame = %{
        "jsonrpc" => "2.0",
        "id" => 33,
        "method" => "tools/call",
        "params" => %{"name" => "ptc_lisp_execute", "arguments" => %{}}
      }

      {:reply, reply, :continue} = JsonRpc.dispatch({:ok, frame})
      env = reply["result"]
      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "args_error"
    end

    test "unknown tool name returns unknown_tool tool result, NOT -32601 (D1 deviation)" do
      frame = %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/call",
        "params" => %{"name" => "nope", "arguments" => %{}}
      }

      {:reply, reply, :continue} = JsonRpc.dispatch({:ok, frame})

      # Crucially: result.isError is true; there is NO `error` key.
      refute Map.has_key?(reply, "error")
      env = reply["result"]
      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "unknown_tool"
    end
  end

  describe "shutdown / exit" do
    test "shutdown replies null and transitions to drain" do
      frame = %{"jsonrpc" => "2.0", "id" => 5, "method" => "shutdown"}
      {:reply, reply, lifecycle} = JsonRpc.dispatch({:ok, frame})
      assert reply["result"] == nil
      assert lifecycle == :drain
    end

    test "exit is a notification that signals process termination" do
      frame = %{"jsonrpc" => "2.0", "method" => "exit"}
      {:noreply, :exit} = JsonRpc.dispatch({:ok, frame})
    end
  end

  describe "notifications/cancelled" do
    test "with requestId returns {:cancel, id, :continue} for Stdio to act on" do
      # Phase 4: JsonRpc surfaces the cancellation; Stdio decides
      # whether the id is in flight (kill) or unknown (silent no-op).
      # § 6.4 row 4 (silent ignore for unknown ids) is enforced in
      # Stdio.cancel_request/2, NOT here.
      frame = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => 999}
      }

      assert {:cancel, 999, :continue} = JsonRpc.dispatch({:ok, frame})
    end

    test "without requestId is silently ignored at the dispatch layer" do
      frame = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled"
      }

      assert {:noreply, :continue} = JsonRpc.dispatch({:ok, frame})
    end
  end

  describe "notification semantics (no `id` member)" do
    test "tools/list sent without id is treated as notification → no reply" do
      frame = %{"jsonrpc" => "2.0", "method" => "tools/list"}
      assert {:noreply, :continue} = JsonRpc.dispatch({:ok, frame})
    end

    test "unknown method without id is treated as notification → no reply" do
      frame = %{"jsonrpc" => "2.0", "method" => "no/such/method"}
      assert {:noreply, :continue} = JsonRpc.dispatch({:ok, frame})
    end

    test "tools/call without id is treated as notification → no reply" do
      frame = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{"name" => "ptc_lisp_execute", "arguments" => %{"program" => "(+ 1 2)"}}
      }

      assert {:noreply, :continue} = JsonRpc.dispatch({:ok, frame})
    end
  end

  describe "unknown methods and protocol errors" do
    test "foo/bar returns -32601 Method not found" do
      frame = %{"jsonrpc" => "2.0", "id" => 6, "method" => "foo/bar"}
      {:reply, reply, :continue} = JsonRpc.dispatch({:ok, frame})

      assert reply["error"]["code"] == -32_601
      assert reply["error"]["message"] == "Method not found"
    end

    test "parse error tag returns -32700" do
      {:reply, reply, :continue} = JsonRpc.dispatch({:error, :parse_error})
      assert reply["error"]["code"] == -32_700
      assert reply["error"]["message"] == "Parse error"
      assert reply["id"] == nil
    end

    test "non-object frame returns -32600 Invalid Request" do
      {:reply, reply, :continue} = JsonRpc.dispatch({:ok, ["not", "a", "map"]})
      assert reply["error"]["code"] == -32_600
    end
  end
end
