defmodule PtcRunnerMcp.SessionsTest do
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.ConcurrencyGate
  alias PtcRunnerMcp.Credentials
  alias PtcRunnerMcp.Credentials.Binding
  alias PtcRunnerMcp.JsonRpc
  alias PtcRunnerMcp.Limits
  alias PtcRunnerMcp.PromptRegistry
  alias PtcRunnerMcp.Sessions
  alias PtcRunnerMcp.Sessions.Config, as: SessionsConfig
  alias PtcRunnerMcp.Sessions.Limits, as: SessionLimits
  alias PtcRunnerMcp.Sessions.Owner
  alias PtcRunnerMcp.Sessions.Registry
  alias PtcRunnerMcp.Stdio
  alias PtcRunnerMcp.Test.JsonRpcHarness
  alias PtcRunnerMcp.Tools

  setup do
    stop_sessions_processes()
    SessionsConfig.set(%{enabled: true})
    ConcurrencyGate.reset()
    assert :ok = Sessions.ensure_started()

    on_exit(fn ->
      stop_sessions_processes()
      SessionsConfig.reset()
      Limits.set(Limits.defaults())
      ConcurrencyGate.reset()
    end)

    :ok
  end

  test "session tools are hidden when disabled" do
    SessionsConfig.set(%{enabled: false})

    names = Tools.list()["tools"] |> Enum.map(& &1["name"])

    refute "ptc_session_start" in names
    refute "ptc_session_eval" in names
  end

  test "session tools advertise output schemas when enabled" do
    session_tools =
      Tools.list()["tools"]
      |> Enum.filter(&String.starts_with?(&1["name"], "ptc_session_"))

    assert Enum.map(session_tools, & &1["name"]) |> Enum.sort() == [
             "ptc_session_close",
             "ptc_session_eval",
             "ptc_session_forget",
             "ptc_session_inspect",
             "ptc_session_start"
           ]

    assert Enum.all?(
             session_tools,
             &match?(%{"type" => "object", "oneOf" => [_, _]}, &1["outputSchema"])
           )

    Enum.each(session_tools, fn tool ->
      [success, error] = tool["outputSchema"]["oneOf"]
      assert success["properties"]["status"] == %{"const" => "ok"}
      assert error["required"] == ["status", "reason", "message", "feedback"]
      assert error["properties"]["status"] == %{"const" => "error"}
      assert error["properties"]["reason"] == %{"type" => "string"}
    end)
  end

  test "session start and eval descriptions are rendered from prompt registry" do
    tools = Tools.list()["tools"]
    start = Enum.find(tools, &(&1["name"] == "ptc_session_start"))
    eval = Enum.find(tools, &(&1["name"] == "ptc_session_eval"))

    assert start["description"] == PromptRegistry.render(:mcp_session_start_description, [])
    assert eval["description"] == PromptRegistry.render(:mcp_session_eval_description, [])

    assert start["description"] =~ "# PTC-Lisp sessions"
    assert start["description"] =~ "Creates a new empty stateful PTC-Lisp session."

    assert eval["description"] =~ "Explicit definitions persist across calls"
    assert eval["description"] =~ "output_schema"
    assert eval["description"] =~ "signature"
    assert eval["description"] =~ "validation_error"
  end

  test "session start and eval descriptions preserve legacy assembly shape" do
    session_card =
      :ptc_runner_mcp
      |> :code.priv_dir()
      |> Path.join("mcp_session_authoring_card.md")
      |> File.read!()

    assert PromptRegistry.render(:mcp_session_start_description, []) ==
             session_card <> "\n\nCreates a new empty stateful PTC-Lisp session."

    assert PromptRegistry.render(:mcp_session_eval_description, []) ==
             session_card <>
               "\n\nEvaluates a PTC-Lisp program against committed session memory. Explicit definitions persist across calls; temporary tool caches do not." <>
               "\n\nOptionally validates the return value against a structured contract: pass `output_schema` (a JSON Schema describing the answer shape) or `signature` (PTC signature syntax — mutually exclusive with `output_schema`). On validation success, the response includes a `validated` field with the encoded structured value. On validation failure, the eval is REJECTED — session state is NOT committed and the response is a `validation_error`."
  end

  test "session prompt registry pins metadata order for start and eval descriptions" do
    assert [
             %{
               id: :mcp_session_authoring_card,
               surface: :mcp_session,
               audience: :mcp_tool_description,
               profile: :mcp_session,
               placement: :session_quick_contract,
               dynamic_boundary: :static_card,
               trust: :authoritative
             },
             %{
               id: :mcp_session_start_detail,
               placement: :after_session_quick_contract,
               dynamic_boundary: :static_card,
               trust: :authoritative
             }
           ] = PromptRegistry.profile_metadata(:mcp_session_start_description)

    assert [
             %{id: :mcp_session_authoring_card},
             %{
               id: :mcp_session_eval_detail,
               placement: :after_session_quick_contract,
               dynamic_boundary: :static_card,
               trust: :authoritative
             }
           ] = PromptRegistry.profile_metadata(:mcp_session_eval_description)
  end

  test "session eval persists explicit definitions and turn history" do
    session_id = start_session()

    eval1 = eval(session_id, "(def x 41)")
    assert eval1["status"] == "ok"
    assert eval1["memory"]["stored_keys"] == ["x"]

    eval2 = eval(session_id, "(+ x 1)")
    assert eval2["status"] == "ok"
    assert eval2["result"] == "user=> 42"

    eval3 = eval(session_id, "*1")
    assert eval3["status"] == "ok"
    assert eval3["result"] == "user=> 42"
  end

  test "failed eval does not commit candidate memory" do
    session_id = start_session()

    assert eval(session_id, "(def x 1)")["status"] == "ok"

    failed = eval(session_id, "(def x 2) missing-symbol")
    assert failed["status"] == "error"

    after_failure = eval(session_id, "x")
    assert after_failure["result"] == "user=> 1"
  end

  test "oversized history result stores reusable preview marker" do
    SessionsConfig.set(%{enabled: true, max_session_history_entry_bytes: 128})
    session_id = start_session()

    large = String.duplicate("x", 256)
    oversized = eval(session_id, inspect(large))

    assert oversized["status"] == "ok"
    assert [%{field: "*1"}] = oversized["history_notices"]

    history = call!("ptc_session_inspect", %{"session_id" => session_id, "view" => "history"})
    assert [%{"name" => "*1", "preview" => preview}] = history["history"]
    assert preview =~ ":ptc_session_preview true"

    marker = eval(session_id, "*1")
    assert marker["status"] == "ok"
    assert marker["result"] =~ ":ptc_session_preview true"
  end

  test "forget removes named bindings and clears prints" do
    session_id = start_session()

    assert eval(session_id, "(def x 1) (println \"hello\")")["status"] == "ok"

    forget =
      call!("ptc_session_forget", %{
        "session_id" => session_id,
        "bindings" => ["x"],
        "clear" => ["prints"]
      })

    assert forget["status"] == "ok"
    assert forget["stored_keys"] == []

    inspect = call!("ptc_session_inspect", %{"session_id" => session_id, "view" => "prints"})
    assert inspect["prints"] == []
  end

  test "inspect session summary does not expose advisory access mode" do
    session_id = start_session()

    inspect = call!("ptc_session_inspect", %{"session_id" => session_id, "view" => "overview"})

    refute Map.has_key?(inspect["session"], "mode")
  end

  test "persisted print and call histories are redacted before storage" do
    start_credentials!(%{"tok" => literal_binding("tok", "session-secret-abc123")})
    {:ok, _materialized} = Credentials.materialize("tok")

    limits = SessionsConfig.session_limits()

    assert SessionLimits.append_prints([], ["leaked session-secret-abc123"], limits) == [
             "leaked [REDACTED]"
           ]

    calls =
      SessionLimits.append_tool_calls(
        [],
        [
          %{
            name: "tool-session-secret-abc123",
            args: %{"token" => "session-secret-abc123"},
            status: "error",
            error: "bad session-secret-abc123"
          }
        ],
        limits
      )

    assert calls == [
             %{
               name: "tool-[REDACTED]",
               args: %{"token" => "[REDACTED]"},
               status: "error",
               error: "bad [REDACTED]"
             }
           ]
  end

  test "session start rejects non-object arguments without allocating a session" do
    envelope = Tools.call(%{"name" => "ptc_session_start", "arguments" => []})

    assert envelope["isError"]
    assert envelope["structuredContent"]["reason"] == "session_args_error"
  end

  test "session eval applies context validation limits" do
    Limits.set(%{Limits.defaults() | max_context_bytes: 8})

    envelope =
      Tools.call(%{
        "name" => "ptc_session_eval",
        "arguments" => %{
          "session_id" => "missing",
          "program" => "1",
          "context" => %{"large" => "value"}
        }
      })

    assert envelope["isError"]
    assert envelope["structuredContent"]["reason"] == "session_args_error"
    assert envelope["structuredContent"]["message"] == "context exceeds max_context_bytes"
  end

  test "history trimming terminates when byte cap is smaller than empty history encoding" do
    limits = %{SessionsConfig.session_limits() | max_print_bytes: 1}

    assert SessionLimits.append_prints([], [], limits) == []
  end

  test "idle expiration does not close a session while eval is in flight" do
    SessionsConfig.set(%{enabled: true, session_idle_timeout_ms: 100})
    session_id = start_session()
    {:ok, owner} = Owner.from_context(nil)
    request_id = make_ref()

    assert {:ok, snapshot} = Sessions.begin_eval(session_id, owner, request_id, %{program: "1"})
    Process.sleep(150)

    result = Sessions.run_snapshot(snapshot, "1", %{profile: :mcp_no_tools})

    assert {:ok, response} = Sessions.commit_eval(session_id, owner, request_id, result, %{})
    assert response["status"] == "ok"
  end

  test "ttl expiration kills an in-flight eval worker" do
    SessionsConfig.set(%{
      enabled: true,
      session_ttl_ms: 5_000,
      session_idle_timeout_ms: 1_000
    })

    session_id = start_session()
    {:ok, %{pid: session_pid}} = Registry.lookup(session_id)
    test_pid = self()
    request_id = make_ref()

    worker =
      spawn(fn ->
        {:ok, owner} = Owner.from_context(nil)
        result = Sessions.begin_eval(session_id, owner, request_id, %{program: "1"})
        send(test_pid, {:begin_eval_result, self(), result})

        receive do
          :release -> :ok
        end
      end)

    ref = Process.monitor(worker)

    assert_receive {:begin_eval_result, ^worker, {:ok, _snapshot}}, 1_000
    send(session_pid, :ttl_expired)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1_000
  end

  test "json-rpc preflight returns session_busy before global gate work" do
    session_id = start_session()
    {:ok, owner} = Owner.from_context(nil)
    request_id = make_ref()

    assert {:ok, snapshot} = Sessions.begin_eval(session_id, owner, request_id, %{program: "1"})

    frame = %{
      "jsonrpc" => "2.0",
      "id" => "busy-1",
      "method" => "tools/call",
      "params" => %{
        "name" => "ptc_session_eval",
        "arguments" => %{"session_id" => session_id, "program" => "2"}
      }
    }

    assert {:reply, reply, :continue} = JsonRpc.dispatch({:ok, frame})
    assert reply["result"]["isError"]
    assert reply["result"]["structuredContent"]["reason"] == "session_busy"

    result = Sessions.run_snapshot(snapshot, "1", %{profile: :mcp_no_tools})
    assert {:ok, _response} = Sessions.commit_eval(session_id, owner, request_id, result, %{})
  end

  test "json-rpc session eval reserves before async worker starts" do
    session_id = start_session()

    first = session_eval_frame("reserve-1", session_id, "1")
    second = session_eval_frame("reserve-2", session_id, "2")

    assert {:async_call, "reserve-1", _work_fn, on_busy, _on_discard, :continue} =
             JsonRpc.dispatch({:ok, first})

    assert {:reply, reply, :continue} = JsonRpc.dispatch({:ok, second})
    assert reply["result"]["isError"]
    assert reply["result"]["structuredContent"]["reason"] == "session_busy"

    on_busy.(%{"isError" => true, "structuredContent" => %{"reason" => "busy"}})
  end

  test "stdio concurrent eval on same session returns session_busy and does not hang" do
    {:ok, harness} = JsonRpcHarness.start()
    on_exit(fn -> JsonRpcHarness.stop(harness) end)

    session_id = start_session()
    _ = JsonRpcHarness.drain_replied_messages()

    :ok =
      Stdio.feed(harness.stdio, session_eval_line("long-1", session_id, long_running_program()))

    wait_until(fn -> Stdio.in_flight_count(harness.stdio) == 1 end, 500)

    :ok = Stdio.feed(harness.stdio, session_eval_line("busy-1", session_id, "(+ 1 2)"))

    replies = read_replies(harness)

    assert Enum.any?(replies, fn reply ->
             reply["id"] == "busy-1" and
               reply["result"]["structuredContent"]["reason"] == "session_busy"
           end)

    :ok = Stdio.feed(harness.stdio, cancelled_line("long-1"))
    wait_until(fn -> Stdio.in_flight_count(harness.stdio) == 0 end, 1_500)
  end

  test "stdio cancelled session eval does not commit candidate memory and clears busy state" do
    {:ok, harness} = JsonRpcHarness.start()
    on_exit(fn -> JsonRpcHarness.stop(harness) end)

    session_id = start_session()
    assert eval(session_id, "(def x 41)")["status"] == "ok"
    _ = JsonRpcHarness.drain_replied_messages()

    program = "(def x 99) " <> long_running_program()

    :ok = Stdio.feed(harness.stdio, session_eval_line("cancel-1", session_id, program))
    wait_until(fn -> Stdio.in_flight_count(harness.stdio) == 1 end, 500)

    :ok = Stdio.feed(harness.stdio, cancelled_line("cancel-1"))
    wait_until(fn -> Stdio.in_flight_count(harness.stdio) == 0 end, 1_500)

    assert read_replies(harness) == []
    assert eval(session_id, "x")["result"] == "user=> 41"

    inspect = call!("ptc_session_inspect", %{"session_id" => session_id, "view" => "overview"})
    assert inspect["session"]["eval_status"] == "idle"
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

  defp session_eval_frame(id, session_id, program) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{
        "name" => "ptc_session_eval",
        "arguments" => %{"session_id" => session_id, "program" => program}
      }
    }
  end

  defp session_eval_line(id, session_id, program) do
    Jason.encode!(session_eval_frame(id, session_id, program)) <> "\n"
  end

  defp cancelled_line(id) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => id}
    }) <> "\n"
  end

  defp read_replies(%{io: io}) do
    io
    |> StringIO.flush()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp long_running_program do
    "((fn ack [m n] " <>
      "(cond (= m 0) (+ n 1) " <>
      "(= n 0) (ack (- m 1) 1) " <>
      ":else (ack (- m 1) (ack m (- n 1))))) 3 8)"
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("wait_until timed out")
      else
        receive do
        after
          10 -> :ok
        end

        do_wait_until(fun, deadline)
      end
    end
  end

  defp stop_sessions_processes do
    stop_if_alive(Registry)
    stop_if_alive(PtcRunnerMcp.Sessions.Supervisor)
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

  defp start_credentials!(bindings) do
    case Process.whereis(Credentials) do
      nil -> :ok
      pid -> stop_credentials(pid)
    end

    {:ok, pid} = Credentials.start_link(bindings: bindings, name: Credentials)
    on_exit(fn -> stop_credentials(pid) end)
    pid
  end

  defp stop_credentials(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal, 5_000)
    end
  catch
    :exit, _ -> :ok
  end

  defp literal_binding(name, value) do
    %Binding{name: name, source: :literal, scheme_hint: :raw, spec: %{value: value}}
  end
end
