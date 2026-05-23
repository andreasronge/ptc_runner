defmodule PtcRunnerMcp.SessionsTest do
  use ExUnit.Case, async: false
  import PtcRunnerMcp.McpTestHelpers, only: [stop_existing_registry: 1]
  import PtcRunnerMcp.TestSupport.WaitHelpers

  alias PtcRunnerMcp.CatalogConfig
  alias PtcRunnerMcp.CatalogDescription
  alias PtcRunnerMcp.ConcurrencyGate
  alias PtcRunnerMcp.Credentials
  alias PtcRunnerMcp.Credentials.Binding
  alias PtcRunnerMcp.JsonRpc
  alias PtcRunnerMcp.Limits
  alias PtcRunnerMcp.PromptRegistry
  alias PtcRunnerMcp.ResponseProfile
  alias PtcRunnerMcp.Sessions
  alias PtcRunnerMcp.Sessions.Config, as: SessionsConfig
  alias PtcRunnerMcp.Sessions.Limits, as: SessionLimits
  alias PtcRunnerMcp.Sessions.Owner
  alias PtcRunnerMcp.Sessions.Registry
  alias PtcRunnerMcp.Sessions.Session
  alias PtcRunnerMcp.Stdio
  alias PtcRunnerMcp.Test.JsonRpcHarness
  alias PtcRunnerMcp.Tools
  alias PtcRunnerMcp.Upstream.Catalog, as: UpstreamCatalog
  alias PtcRunnerMcp.Upstream.Registry, as: UpstreamRegistry

  setup do
    old_profile = ResponseProfile.current()
    stop_sessions_processes()
    SessionsConfig.set(%{enabled: true})
    ResponseProfile.set(:structured)
    ConcurrencyGate.reset()
    assert :ok = Sessions.ensure_started()

    on_exit(fn ->
      stop_sessions_processes()
      SessionsConfig.reset()
      ResponseProfile.set(old_profile)
      Limits.set(Limits.defaults())
      ConcurrencyGate.reset()
    end)

    :ok
  end

  test "session tools are hidden when disabled" do
    SessionsConfig.set(%{enabled: false})

    names = Tools.list()["tools"] |> Enum.map(& &1["name"])

    assert "lisp_eval" in names
    refute "lisp_session_start" in names
    refute "lisp_session_eval" in names
  end

  test "session mode hides and rejects stateless lisp_eval" do
    names = Tools.list()["tools"] |> Enum.map(& &1["name"])

    refute "lisp_eval" in names
    assert "lisp_session_eval" in names

    direct =
      Tools.call(%{
        "name" => "lisp_eval",
        "arguments" => %{"program" => "(+ 1 2)"}
      })

    assert direct["isError"] == true
    assert direct["structuredContent"]["reason"] == "unknown_tool"

    frame = %{
      "jsonrpc" => "2.0",
      "id" => "no-stateless",
      "method" => "tools/call",
      "params" => %{"name" => "lisp_eval", "arguments" => %{"program" => "(+ 1 2)"}}
    }

    assert {:reply, reply, :continue} = JsonRpc.dispatch({:ok, frame})
    assert reply["result"]["isError"] == true
    assert reply["result"]["structuredContent"]["reason"] == "unknown_tool"
  end

  test "session Lisp opts preserve the aggregate parallel memory budget" do
    snapshot = %{memory: %{}, turn_history: []}
    opts = Session.lisp_opts(snapshot, "(+ 1 2)", %{max_heap: 1_250_000})

    assert opts[:max_parallel_workers] == 8
    assert opts[:worker_max_heap] * opts[:max_parallel_workers] <= opts[:max_heap]
  end

  test "session Lisp opts forward discovery executor" do
    snapshot = %{memory: %{}, turn_history: []}
    discovery_exec = fn _op, _args -> {:ok, []} end

    opts = Session.lisp_opts(snapshot, "(mcp/servers)", %{discovery_exec: discovery_exec})

    assert opts[:discovery_exec] == discovery_exec
  end

  test "session tools advertise output schemas when enabled" do
    session_tools =
      Tools.list()["tools"]
      |> Enum.filter(&String.starts_with?(&1["name"], "lisp_session_"))

    assert Enum.map(session_tools, & &1["name"]) |> Enum.sort() == [
             "lisp_session_close",
             "lisp_session_eval",
             "lisp_session_forget",
             "lisp_session_inspect",
             "lisp_session_list",
             "lisp_session_start"
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

  test "session eval omits outputSchema in slim profile" do
    ResponseProfile.set(:slim)

    eval =
      Tools.list()["tools"]
      |> Enum.find(&(&1["name"] == "lisp_session_eval"))

    refute Map.has_key?(eval, "outputSchema")
  end

  test "session start and eval descriptions are rendered from prompt registry" do
    tools = Tools.list()["tools"]
    start = Enum.find(tools, &(&1["name"] == "lisp_session_start"))
    eval = Enum.find(tools, &(&1["name"] == "lisp_session_eval"))

    assert start["description"] == PromptRegistry.render(:mcp_session_start_description, [])
    assert eval["description"] == PromptRegistry.render(:mcp_session_eval_description, [])
  end

  test "session eval description mentions upstream calls only when upstreams are configured" do
    stop_existing_registry(UpstreamRegistry)

    on_exit(fn ->
      stop_existing_registry(UpstreamRegistry)
      CatalogConfig.set(CatalogConfig.defaults())
      UpstreamCatalog.clear_frozen()
    end)

    tools = Tools.list()["tools"]
    default_eval = Enum.find(tools, &(&1["name"] == "lisp_session_eval"))

    refute default_eval["description"] =~ "tool/mcp-call"
    refute default_eval["description"] =~ "apropos"

    {:ok, _pid} = UpstreamRegistry.start_link(name: UpstreamRegistry)
    :ok = UpstreamRegistry.put_fake("alpha", %{tools: %{}}, UpstreamRegistry)
    CatalogConfig.set(%{catalog_mode: :lazy})
    UpstreamCatalog.freeze_snapshot([%{name: "alpha", tools: [], metadata: %{}}])

    tools = Tools.list()["tools"]
    eval = Enum.find(tools, &(&1["name"] == "lisp_session_eval"))

    assert eval["description"] ==
             PromptRegistry.render(:mcp_session_eval_with_upstreams_description,
               catalog: CatalogDescription.render()
             )

    assert eval["description"] =~ "tool/mcp-call"
    assert eval["description"] =~ "apropos"
  end

  test "session utility descriptions are rendered from prompt registry" do
    tools = Tools.list()["tools"]

    assert tool_description(tools, "lisp_session_inspect") ==
             PromptRegistry.render(:mcp_session_inspect_description, [])

    assert tool_description(tools, "lisp_session_list") ==
             PromptRegistry.render(:mcp_session_list_description, [])

    assert tool_description(tools, "lisp_session_forget") ==
             PromptRegistry.render(:mcp_session_forget_description, [])

    assert tool_description(tools, "lisp_session_close") ==
             PromptRegistry.render(:mcp_session_close_description, [])
  end

  test "session descriptions are rendered from registered prompt profiles" do
    assert PromptRegistry.render(:mcp_session_start_description, []) |> is_binary()
    assert PromptRegistry.render(:mcp_session_eval_description, []) |> is_binary()

    assert PromptRegistry.profile_parts!(:mcp_session_start_description) != []
    assert PromptRegistry.profile_parts!(:mcp_session_eval_description) != []
  end

  test "session utility prompt cards pin metadata" do
    for key <- [
          :mcp_session_inspect_description,
          :mcp_session_list_description,
          :mcp_session_forget_description,
          :mcp_session_close_description
        ] do
      assert %{
               dynamic_boundary: :static_card,
               trust: :authoritative
             } = PromptRegistry.card_metadata(key)
    end
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

    history = call!("lisp_session_inspect", %{"session_id" => session_id, "view" => "history"})
    assert [%{"name" => "*1", "preview" => preview}] = history["history"]
    assert preview =~ ":lisp_session_preview true"

    marker = eval(session_id, "*1")
    assert marker["status"] == "ok"
    assert marker["result"] =~ ":lisp_session_preview true"
  end

  test "forget removes named bindings and clears prints" do
    session_id = start_session()

    assert eval(session_id, "(def x 1) (println \"hello\")")["status"] == "ok"

    forget =
      call!("lisp_session_forget", %{
        "session_id" => session_id,
        "bindings" => ["x"],
        "clear" => ["prints"]
      })

    assert forget["status"] == "ok"
    assert forget["stored_keys"] == []

    inspect = call!("lisp_session_inspect", %{"session_id" => session_id, "view" => "prints"})
    assert inspect["prints"] == []
  end

  test "inspect session summary does not expose advisory access mode" do
    session_id = start_session()

    inspect = call!("lisp_session_inspect", %{"session_id" => session_id, "view" => "overview"})

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
    envelope = Tools.call(%{"name" => "lisp_session_start", "arguments" => []})

    assert envelope["isError"]
    assert envelope["structuredContent"]["reason"] == "session_args_error"
  end

  test "session start rejects advisory mode argument" do
    envelope =
      Tools.call(%{"name" => "lisp_session_start", "arguments" => %{"mode" => "read_only"}})

    assert envelope["isError"]
    assert envelope["structuredContent"]["reason"] == "session_args_error"
    assert envelope["structuredContent"]["message"] =~ "unexpected lisp_session_start argument"
  end

  test "session list returns metadata-only summaries for current owner" do
    owner_a = %{"transport" => "stdio", "instance_id" => "owner-a"}
    owner_b = %{"transport" => "stdio", "instance_id" => "owner-b"}

    a_session =
      call!("lisp_session_start", %{"title" => "A", "owner" => owner_a})["session_id"]

    _b_session =
      call!("lisp_session_start", %{"title" => "B", "owner" => owner_b})["session_id"]

    assert call!(
             "lisp_session_eval",
             %{"session_id" => a_session, "program" => "(def secret 42)", "owner" => owner_a}
           )["status"] == "ok"

    assert call!("lisp_session_list", %{"owner" => owner_a})["reason"] == "session_args_error"

    listed = list_for_owner!(owner_a)

    assert listed["status"] == "ok"
    assert listed["count"] == 1

    assert [
             %{
               "session_id" => ^a_session,
               "title" => "A",
               "turn" => 1,
               "eval_status" => "idle",
               "memory_bytes" => memory_bytes,
               "binding_count" => 1
             } = summary
           ] = listed["sessions"]

    assert is_integer(memory_bytes) and memory_bytes > 0
    refute Map.has_key?(summary, "text")
    refute Map.has_key?(summary, "stored_keys")
    refute inspect(summary) =~ "secret"
  end

  test "session list sorts by live updated_at descending" do
    first = start_session()
    second = start_session()

    assert eval(first, "(def newer 1)")["status"] == "ok"

    listed = call!("lisp_session_list", %{})["sessions"]
    assert [%{"session_id" => ^first}, %{"session_id" => ^second}] = Enum.take(listed, 2)
  end

  test "session list shows running status without acquiring rendered state" do
    session_id = start_session()
    {:ok, owner} = Owner.from_context(nil)
    request_id = make_ref()

    assert {:ok, snapshot} = Sessions.begin_eval(session_id, owner, request_id, %{program: "1"})

    listed = call!("lisp_session_list", %{})

    assert Enum.find_value(listed["sessions"], fn
             %{"session_id" => ^session_id, "eval_status" => "running"} -> true
             _summary -> false
           end)

    result = Sessions.run_snapshot(snapshot, "1", %{profile: :mcp_no_tools})
    assert {:ok, _response} = Sessions.commit_eval(session_id, owner, request_id, result, %{})
  end

  test "session list does not refresh idle timer" do
    SessionsConfig.set(%{enabled: true, session_idle_timeout_ms: 250})
    session_id = start_session()

    Process.sleep(180)
    assert call!("lisp_session_list", %{})["count"] == 1
    Process.sleep(120)

    wait_until(
      fn ->
        case Registry.lookup(session_id) do
          {:ok, _meta} -> false
          {:error, _reason} -> true
        end
      end,
      300
    )
  end

  test "live lookup does not use the central registry mailbox" do
    session_id = start_session()
    registry_pid = Process.whereis(Registry)

    :sys.suspend(registry_pid)

    try do
      assert {:ok, %{pid: session_pid}} = Registry.lookup(session_id)
      assert Process.alive?(session_pid)

      {:ok, owner} = Owner.from_context(nil)
      request_id = make_ref()
      assert {:ok, snapshot} = Sessions.begin_eval(session_id, owner, request_id, %{program: "1"})
      result = Sessions.run_snapshot(snapshot, "1", %{profile: :mcp_no_tools})
      assert {:ok, response} = Sessions.commit_eval(session_id, owner, request_id, result, %{})
      assert response["status"] == "ok"
    after
      :sys.resume(registry_pid)
    end
  end

  test "custom registries keep explicit session ids isolated from default live lookup" do
    {:ok, owner} = Owner.from_context(nil)
    session_id = "shared-session-id"

    {:ok, supervisor_a} = start_named_session_supervisor(:a)
    {:ok, supervisor_b} = start_named_session_supervisor(:b)
    {:ok, registry_a} = start_named_session_registry(:a, supervisor_a)
    {:ok, registry_b} = start_named_session_registry(:b, supervisor_b)

    on_exit(fn ->
      stop_process(registry_a)
      stop_process(registry_b)
      stop_process(supervisor_a)
      stop_process(supervisor_b)
    end)

    assert {:ok, %{pid: pid_a}} =
             Registry.start_session(owner, %{session_id: session_id}, registry_a)

    assert {:ok, %{pid: pid_b}} =
             Registry.start_session(owner, %{session_id: session_id}, registry_b)

    assert pid_a != pid_b

    assert {:ok, %{pid: ^pid_a}} = Registry.lookup(session_id, registry_a)
    assert {:ok, %{pid: ^pid_b}} = Registry.lookup(session_id, registry_b)
    assert {:error, :session_not_found} = Registry.lookup(session_id)
    assert [] = live_name_lookup(session_id)
  end

  test "live lookup ignores sessions owned by a previous default registry process" do
    session_id = start_session()
    {:ok, %{pid: session_pid}} = Registry.lookup(session_id)
    assert [_entry] = live_name_lookup(session_id)

    Registry
    |> Process.whereis()
    |> GenServer.stop(:normal, 5_000)

    assert Process.alive?(session_pid)
    assert :ok = Sessions.ensure_started()
    assert {:error, :session_not_found} = Registry.lookup(session_id)
  end

  test "closed sessions are removed from the live name registry" do
    session_id = start_session()

    assert [_entry] = Elixir.Registry.lookup(PtcRunnerMcp.Sessions.Names, session_id)
    assert call!("lisp_session_close", %{"session_id" => session_id})["status"] == "ok"

    wait_until(
      fn ->
        live_name_lookup(session_id) == [] and
          match?({:error, :session_closed}, Registry.lookup(session_id))
      end,
      300
    )
  end

  test "crashed sessions are removed from the live name registry" do
    session_id = start_session()
    {:ok, %{pid: session_pid}} = Registry.lookup(session_id)

    Process.exit(session_pid, :kill)

    wait_until(
      fn ->
        live_name_lookup(session_id) == [] and
          match?({:error, :session_not_found}, Registry.lookup(session_id))
      end,
      300
    )
  end

  test "session eval applies context validation limits" do
    Limits.set(%{Limits.defaults() | max_context_bytes: 8})

    envelope =
      Tools.call(%{
        "name" => "lisp_session_eval",
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
        "name" => "lisp_session_eval",
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

    inspect = call!("lisp_session_inspect", %{"session_id" => session_id, "view" => "overview"})
    assert inspect["session"]["eval_status"] == "idle"
  end

  defp start_session do
    call!("lisp_session_start", %{})["session_id"]
  end

  defp eval(session_id, program) do
    call!("lisp_session_eval", %{"session_id" => session_id, "program" => program})
  end

  defp list_for_owner!(owner_context) do
    {:ok, response} = Sessions.list(owner_context)
    response
  end

  defp tool_description(tools, name) do
    tools
    |> Enum.find(&(&1["name"] == name))
    |> Map.fetch!("description")
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
        "name" => "lisp_session_eval",
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

  defp stop_sessions_processes do
    stop_if_alive(Registry)
    stop_if_alive(PtcRunnerMcp.Sessions.Supervisor)
    stop_if_alive(PtcRunnerMcp.Sessions.Names)
  end

  defp start_named_session_supervisor(label) do
    PtcRunnerMcp.Sessions.Supervisor.start_link(name: global_test_name(:supervisor, label))
  end

  defp start_named_session_registry(label, supervisor) do
    Registry.start_link(name: global_test_name(:registry, label), session_supervisor: supervisor)
  end

  defp global_test_name(kind, label) do
    {:global, {__MODULE__, kind, label, make_ref()}}
  end

  defp live_name_lookup(session_id) do
    case Process.whereis(PtcRunnerMcp.Sessions.Names) do
      nil -> []
      _pid -> Elixir.Registry.lookup(PtcRunnerMcp.Sessions.Names, session_id)
    end
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
