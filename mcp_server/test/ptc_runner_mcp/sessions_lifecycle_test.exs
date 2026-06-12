defmodule PtcRunnerMcp.SessionsLifecycleTest do
  @moduledoc """
  Deterministic branch coverage for the stateful-sessions surface that the
  `:soak`-tagged churn test otherwise exercises only under load.

  These tests drive the REAL production paths:

    * `PtcRunnerMcp.Tools.call/1` for the public MCP lifecycle
      (`lisp_session_start` -> `_eval` -> `_inspect` -> `_forget` ->
      `_list` -> `_close`).
    * The `PtcRunnerMcp.Sessions` facade for the authorization boundary,
      the `session_busy` rejection, deterministic ttl/idle eviction, and
      the registry quota / tombstone / disabled branches.

  Pure-table assertions cover `Sessions.Config`, `Sessions.Limits`,
  `Sessions.Projection`, and `Sessions.Owner` derivation — the branches
  reachable only with direct input, not the dead `Owner.same?/2` and
  `Owner.hash/1` helpers.
  """
  use ExUnit.Case, async: false

  alias PtcRunner.Lisp
  alias PtcRunner.TraceLog.{Analyzer, Collector, Introspection}
  alias PtcRunnerMcp.{ResponseProfile, Sessions, Tools}
  alias PtcRunnerMcp.Sessions.{Config, Limits, Owner, Projection, Session}
  alias PtcRunnerMcp.Sessions.Registry, as: SessionsRegistry
  alias PtcRunnerMcp.TestSupport.SoakHelpers
  alias PtcRunnerMcp.{TurnLogCollector, TurnLogConfig}

  # A second stdio owner with a *different* instance id. Because the
  # session is created under the process-wide stdio owner, this map is a
  # forged caller that should fail every authorization check.
  @forged_owner %{transport: :stdio, instance_id: "forged_other_instance"}

  setup do
    old_profile = ResponseProfile.current()
    # SoakHelpers.setup_sessions/1 stops stale session procs, installs the
    # config, resets the gate, starts the registry/supervisor, and
    # registers an on_exit that tears it all back down + resets config.
    SoakHelpers.setup_sessions(%{enabled: true})
    ResponseProfile.set(:structured)
    old_turn_log_config = TurnLogConfig.get()

    on_exit(fn ->
      ResponseProfile.set(old_profile)
      TurnLogConfig.set(old_turn_log_config)
      TurnLogConfig.put_collector(nil)
    end)

    :ok
  end

  describe "full lifecycle via Tools.call" do
    test "start -> eval -> inspect(all views) -> forget -> list -> close" do
      sid = SoakHelpers.start_session()

      eval =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => "(do (println \"hello\") (def x 41) (def y 2) (+ x y))"
        })

      assert eval["isError"] == false
      sc = eval["structuredContent"]
      assert sc["status"] == "ok"
      assert sc["memory"]["changed_keys"] == ["x", "y"]
      assert sc["memory"]["stored_keys"] == ["x", "y"]
      assert sc["session"]["turn"] == 1
      refute Map.has_key?(sc, "feedback")

      # Every inspect view must shape distinctly and stay authorized.
      for view <- ~w(overview memory prints tool_calls history limits) do
        r = call("lisp_session_inspect", %{"session_id" => sid, "view" => view})
        assert r["isError"] == false
        vsc = r["structuredContent"]
        assert vsc["status"] == "ok"
        assert vsc["view"] == view
        assert vsc["session_id"] == sid
        # Each view carries its committed metadata summary.
        assert vsc["session"]["binding_count"] == 2
      end

      # View-specific shaping branches.
      mem = inspect_view(sid, "memory")
      assert mem["stored_keys"] == ["x", "y"]
      assert mem["text"] =~ "x"

      prints = inspect_view(sid, "prints")
      assert prints["prints"] == ["hello"]

      limits = inspect_view(sid, "limits")
      assert is_map(limits["limits"])
      assert is_list(limits["top_bindings"])

      # forget a single binding
      forget =
        call("lisp_session_forget", %{"session_id" => sid, "bindings" => ["x"]})

      fsc = forget["structuredContent"]
      assert fsc["status"] == "ok"
      assert fsc["removed_bindings"] == ["x"]
      assert fsc["stored_keys"] == ["y"]

      # list shows the single live session
      list = call("lisp_session_list", %{})
      lsc = list["structuredContent"]
      assert lsc["status"] == "ok"
      assert lsc["count"] == 1
      assert [session] = lsc["sessions"]
      assert session["session_id"] == sid

      # close
      close = call("lisp_session_close", %{"session_id" => sid})
      csc = close["structuredContent"]
      assert csc["status"] == "ok"
      assert csc["closed"] == true
      assert csc["session_id"] == sid
    end

    test "clear directive empties a history bucket but preserves memory" do
      sid = SoakHelpers.start_session()
      SoakHelpers.eval_ok!(sid, "(do (println \"a\") (def keep 1) keep)")

      forget =
        call("lisp_session_forget", %{"session_id" => sid, "clear" => ["prints"]})

      assert forget["structuredContent"]["status"] == "ok"
      assert forget["structuredContent"]["cleared"] == ["prints"]

      prints = inspect_view(sid, "prints")
      assert prints["prints"] == []
      # memory binding survives the prints clear
      assert inspect_view(sid, "memory")["stored_keys"] == ["keep"]
    end

    test "an invalid clear target is a session_args_error" do
      sid = SoakHelpers.start_session()

      env =
        call("lisp_session_forget", %{"session_id" => sid, "clear" => ["not_a_bucket"]})

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "session_args_error"
    end
  end

  describe "registry lookup error branches via Tools.call" do
    test "unknown session id reports session_not_found" do
      env =
        call("lisp_session_inspect", %{
          "session_id" => "ptcs_does_not_exist",
          "view" => "overview"
        })

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "session_not_found"
    end

    test "operating on a closed session reports the session_closed tombstone" do
      {:ok, %{"session_id" => sid}} = Sessions.start_session(nil, %{})
      {:ok, meta} = SessionsRegistry.lookup(sid)
      ref = Process.monitor(meta.pid)

      call("lisp_session_close", %{"session_id" => sid})

      # Drive the real public inspect path only after the session pid is
      # down AND the `Sessions.Names` fast-path entry is pruned, so the
      # production tombstone — not a transient noproc — is what we assert.
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 1_000
      await_names_pruned(sid)
      drain_registry()

      env =
        call("lisp_session_inspect", %{"session_id" => sid, "view" => "overview"})

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "session_closed"
    end

    test "lisp_session_list rejects any argument" do
      env = call("lisp_session_list", %{"session_id" => "x"})
      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "session_args_error"
    end

    test "lisp_session_start rejects unexpected arguments" do
      env = call("lisp_session_start", %{"bogus" => 1})
      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "session_args_error"
      assert env["structuredContent"]["message"] =~ "bogus"
    end
  end

  describe "authorization boundary (forged owner)" do
    setup do
      {:ok, %{"session_id" => sid}} = Sessions.start_session(nil, %{})
      %{sid: sid}
    end

    test "inspect by a non-owner is rejected", %{sid: sid} do
      assert {:error, response} = Sessions.inspect(sid, %{owner: @forged_owner}, "overview")
      assert response["reason"] == "session_owner_mismatch"
      assert response["message"] =~ "does not own"
    end

    test "forget by a non-owner is rejected", %{sid: sid} do
      assert {:error, response} = Sessions.forget(sid, %{owner: @forged_owner}, %{})
      assert response["reason"] == "session_owner_mismatch"
    end

    test "close by a non-owner is rejected and the session stays live", %{sid: sid} do
      assert {:error, response} = Sessions.close(sid, %{owner: @forged_owner}, "x")
      assert response["reason"] == "session_owner_mismatch"

      # The rightful owner can still reach it: authorization failed closed.
      assert {:ok, _summary} = Sessions.inspect(sid, nil, "overview")
    end

    test "forged owner also blocked through the Tools.call transport seam", %{sid: sid} do
      env =
        call("lisp_session_inspect", %{
          "session_id" => sid,
          "view" => "overview",
          "owner" => %{"transport" => "stdio", "instance_id" => "forged_via_tools"}
        })

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "session_owner_mismatch"
    end
  end

  describe "session_busy rejection" do
    test "forget while an eval is reserved is rejected as session_busy" do
      {:ok, %{"session_id" => sid}} = Sessions.start_session(nil, %{})
      owner = Owner.stdio()
      {:ok, meta} = SessionsRegistry.lookup(sid)

      # Reserve the session for an eval but never commit it: the session is
      # now busy from the GenServer's point of view.
      {:ok, _snapshot} =
        Session.begin_eval(meta.pid, owner, make_ref(), %{program: "(+ 1 1)"})

      assert {:error, response} = Sessions.forget(sid, nil, %{})
      assert response["reason"] == "session_busy"
      assert response["session_id"] == sid
    end
  end

  describe "turn log recording" do
    @tag :tmp_dir
    test "records accepted MCP session eval attempts as canonical turn events", %{tmp_dir: dir} do
      TurnLogConfig.set(%{turn_log_dir: dir})
      start_supervised!({TurnLogCollector, [dir: dir]})
      path = TurnLogCollector.path()

      {:ok, %{"session_id" => sid}} = Sessions.start_session(nil, %{})
      assert String.starts_with?(sid, "ptcs_")

      commit_tool_eval!(sid)

      assert {:error, sandbox_error} = Sessions.eval(sid, "(no-such-fn 1)")
      assert sandbox_error["reason"] == "unbound_var"

      validation_error =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => "\"not-an-integer\"",
          "output_schema" => %{"type" => "integer"}
        })

      assert validation_error["isError"] == true
      assert validation_error["structuredContent"]["reason"] == "validation_error"

      stop_turn_log!()

      events = Analyzer.load(path)
      turns = Analyzer.session_turns(events, sid)

      assert length(turns) == 3
      assert Enum.map(turns, & &1["session_id"]) == [sid, sid, sid]
      assert Enum.map(turns, & &1["driver"]) == ["session", "session", "session"]
      assert Enum.map(turns, & &1["attempt"]) == [1, 2, 3]
      assert Enum.map(turns, & &1["turn"]) == [1, 1, 1]
      assert Enum.map(turns, & &1["committed"]) == [true, false, false]
      assert Enum.map(turns, & &1["status"]) == ["ok", "error", "error"]

      [[tool_call], [], []] = Enum.map(turns, &get_in(&1, ["data", "tool_calls"]))
      assert tool_call["tool"] == "fetch"
      assert is_binary(tool_call["args_hash"])
      assert byte_size(tool_call["args_hash"]) > 0

      sandbox_turn = Enum.at(turns, 1)
      assert get_in(sandbox_turn, ["data", "fail", "reason"]) == "unbound_var"

      validation_turn = Enum.at(turns, 2)
      assert get_in(validation_turn, ["data", "fail", "reason"]) == "validation_failed"
      assert get_in(validation_turn, ["data", "result_preview"]) =~ "not-an-integer"

      assert [summary] = Analyzer.sessions(events)
      assert summary.correlation_id == sid
      assert summary.turns == 3
      assert summary.committed == 1
      assert summary.failed == 2
      assert summary.tool_calls == 1

      log_program = ~s|[(count (log/turns "#{sid}")) (log/programs "#{sid}")]|

      assert {:ok,
              %{return: [3, ["(tool/fetch {:id 1})", "(no-such-fn 1)", "\"not-an-integer\""]]}} =
               Lisp.run(
                 log_program,
                 prelude: Introspection.prelude_source(),
                 tools: Introspection.tools(path)
               )
    end

    @tag :tmp_dir
    test "records upstream-style tool/call entries once with real tool identity", %{tmp_dir: dir} do
      TurnLogConfig.set(%{turn_log_dir: dir})
      start_supervised!({TurnLogCollector, [dir: dir]})
      path = TurnLogCollector.path()

      {:ok, %{"session_id" => sid}} = Sessions.start_session(nil, %{})

      commit_call_tool_eval!(
        sid,
        ~S|(tool/call {:server "observatory" :tool "list_traces" :args {:org_id "acme"}})|
      )

      commit_call_tool_eval!(
        sid,
        ~S|(tool/call {:server "observatory" :tool "fail_trace" :args {:id "missing"}})|
      )

      stop_turn_log!()

      turns = path |> Analyzer.load() |> Analyzer.session_turns(sid)
      assert length(turns) == 2

      assert [ok_call] = get_in(Enum.at(turns, 0), ["data", "tool_calls"])
      assert ok_call["server"] == "observatory"
      assert ok_call["tool"] == "list_traces"
      assert ok_call["outcome"] == "ok"
      assert is_binary(ok_call["args_hash"])

      assert [error_call] = get_in(Enum.at(turns, 1), ["data", "tool_calls"])
      assert error_call["server"] == "observatory"
      assert error_call["tool"] == "fail_trace"
      assert error_call["outcome"] == "error"
      assert is_binary(error_call["args_hash"])
      assert ok_call["args_hash"] != error_call["args_hash"]
    end
  end

  describe "deterministic eviction (no Process.sleep)" do
    test "idle timeout evicts the session and leaves a tombstone" do
      Config.set(%{enabled: true, session_idle_timeout_ms: 5, session_ttl_ms: 60_000})

      {:ok, %{"session_id" => sid}} = Sessions.start_session(nil, %{})
      {:ok, meta} = SessionsRegistry.lookup(sid)
      ref = Process.monitor(meta.pid)

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 1_000

      assert tombstone_lookup(sid) == {:error, :session_closed}
    end

    test "ttl expiry evicts the session even while idle timer is long" do
      Config.set(%{enabled: true, session_ttl_ms: 5, session_idle_timeout_ms: 60_000})

      {:ok, %{"session_id" => sid}} = Sessions.start_session(nil, %{})
      {:ok, meta} = SessionsRegistry.lookup(sid)
      ref = Process.monitor(meta.pid)

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 1_000

      assert tombstone_lookup(sid) == {:error, :session_closed}
    end
  end

  describe "registry quota branches" do
    test "max_sessions cap rejects the next start as session_limit_exceeded" do
      SoakHelpers.setup_sessions(%{enabled: true, max_sessions: 1})

      assert {:ok, _} = Sessions.start_session(nil, %{})
      assert {:error, response} = Sessions.start_session(nil, %{})
      assert response["reason"] == "session_limit_exceeded"
      assert response["message"] =~ "maximum number of sessions"
    end

    test "per-owner cap rejects an over-quota owner while leaving global room" do
      SoakHelpers.setup_sessions(%{
        enabled: true,
        max_sessions: 100,
        max_sessions_per_owner: 1
      })

      assert {:ok, _} = Sessions.start_session(nil, %{})
      assert {:error, response} = Sessions.start_session(nil, %{})
      assert response["reason"] == "session_limit_exceeded"
      assert response["message"] =~ "for this owner"
    end

    test "a distinct owner is unaffected by another owner's per-owner cap" do
      SoakHelpers.setup_sessions(%{
        enabled: true,
        max_sessions: 100,
        max_sessions_per_owner: 1
      })

      other = %{owner: %{transport: :http, mcp_session_id: "other-owner-1"}}

      assert {:ok, _} = Sessions.start_session(nil, %{})
      assert {:error, _} = Sessions.start_session(nil, %{})
      # Different owner still has its own quota headroom.
      assert {:ok, _} = Sessions.start_session(other, %{})
    end

    test "DOWN of a session frees a per-owner quota slot" do
      SoakHelpers.setup_sessions(%{
        enabled: true,
        max_sessions: 100,
        max_sessions_per_owner: 1
      })

      {:ok, %{"session_id" => sid}} = Sessions.start_session(nil, %{})
      assert {:error, _} = Sessions.start_session(nil, %{})

      assert {:ok, _} = Sessions.close(sid, nil, "done")
      await_session_removed(sid)

      # The owner index slot was reclaimed on :DOWN, so a new start succeeds.
      assert {:ok, _} = Sessions.start_session(nil, %{})
    end

    test "inspect on a closed session with an unpruned Names entry returns the tombstone" do
      SoakHelpers.setup_sessions(%{enabled: true})

      {:ok, %{"session_id" => sid}} = Sessions.start_session(nil, %{})
      {:ok, meta} = SessionsRegistry.lookup(sid)
      pid = meta.pid

      # Freeze the partitioned `Sessions.Names` registry so it cannot prune the
      # dead-pid entry — deterministically recreating the post-`:DOWN` /
      # pre-prune window where `lookup/1`'s fast path still resolves `sid` to
      # the dead session pid. Registry reads hit ETS directly, so lookups still
      # work while the partition processes are suspended.
      names_partitions =
        for {_, p, _, _} <- Supervisor.which_children(PtcRunnerMcp.Sessions.Names),
            is_pid(p),
            do: p

      Enum.each(names_partitions, &:sys.suspend/1)

      try do
        ref = Process.monitor(pid)
        assert {:ok, _} = Sessions.close(sid, nil, "done")
        assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 1_000
        await_session_removed(sid)

        # The Names fast path still hands back the now-dead pid; `lookup/1` must
        # not return it, so `inspect` resolves to the session_closed tombstone
        # instead of crashing the caller with a `:noproc` exit.
        assert {:error, %{"reason" => "session_closed"}} =
                 Sessions.inspect(sid, nil, "overview")
      after
        Enum.each(names_partitions, &:sys.resume/1)
      end
    end
  end

  describe "disabled surface" do
    test "every session tool reports sessions_disabled when the feature is off" do
      Config.set(%{enabled: false})
      SoakHelpers.stop_sessions_processes()

      for name <- ~w(lisp_session_start lisp_session_list) do
        env = call(name, %{})
        assert env["isError"] == true
        assert env["structuredContent"]["reason"] == "sessions_disabled"
      end
    end
  end

  describe "Sessions.Config table behavior" do
    test "resolve/1 returns disabled defaults from an empty args map" do
      assert {:ok, d} = Config.resolve(%{})
      assert d.enabled == false
      assert d.max_sessions == 64
      assert d.max_sessions_per_owner == 16
    end

    test "resolve/1 honors CLI keys and parses integer strings" do
      assert {:ok, resolved} =
               Config.resolve(%{
                 sessions: true,
                 max_sessions: 7,
                 session_ttl_ms: "1234"
               })

      assert resolved.enabled == true
      assert resolved.max_sessions == 7
      assert resolved.session_ttl_ms == 1234
    end

    test "resolve/1 rejects invalid explicit integer config" do
      assert {:error, message} = Config.resolve(%{max_sessions_per_owner: "not-a-number"})

      assert message =~ "--max-sessions-per-owner"
      assert message =~ "PTC_RUNNER_MCP_MAX_SESSIONS_PER_OWNER"
      assert message =~ "must be a positive integer"
    end

    test "resolve/1 rejects numeric-prefix garbage" do
      assert {:error, message} = Config.resolve(%{max_sessions_per_owner: "64mb"})

      assert message =~ "--max-sessions-per-owner"
      assert message =~ "must be a positive integer"
    end

    test "set/1 normalizes non-positive integers back to defaults" do
      Config.set(%{enabled: true, max_sessions: -5, max_sessions_per_owner: 3})
      config = Config.get()
      assert config.max_sessions == 64
      assert config.max_sessions_per_owner == 3
    after
      Config.reset()
    end

    test "clamp_ttl_ms/1 caps requested ttl at the configured maximum" do
      Config.set(%{enabled: true, session_ttl_ms: 1_000})
      assert Config.clamp_ttl_ms(nil) == 1_000
      assert Config.clamp_ttl_ms(500) == 500
      assert Config.clamp_ttl_ms(5_000) == 1_000
      assert Config.clamp_ttl_ms("garbage") == 1_000
    after
      Config.reset()
    end

    test "session_limits/0 projects only the per-session caps" do
      Config.set(%{enabled: true, session_idle_timeout_ms: 4_242})
      limits = Config.session_limits()
      assert limits.max_idle_ms == 4_242
      assert Map.has_key?(limits, :max_memory_bytes)
      refute Map.has_key?(limits, :max_sessions)
    after
      Config.reset()
    end
  end

  describe "Sessions.Limits table behavior" do
    setup do
      Config.set(%{enabled: true})
      on_exit(&Config.reset/0)
      %{limits: Config.session_limits()}
    end

    test "usage/5 summarizes committed state counts and bytes" do
      usage = Limits.usage(%{a: 1, b: 2}, [1, 2], ["p"], [], [])
      assert usage.binding_count == 2
      assert usage.history_count == 2
      assert usage.print_entries == 1
      assert usage.memory_bytes > 0
    end

    test "validate_memory/2 rejects too many bindings", %{limits: limits} do
      tight = Map.put(limits, :max_bindings, 0)
      assert {:error, detail} = Limits.validate_memory(%{a: 1}, tight)
      assert detail.limit == "max_bindings"
    end

    test "validate_memory/2 rejects an oversized single binding", %{limits: limits} do
      tight = Map.put(limits, :max_binding_bytes, 1)
      assert {:error, detail} = Limits.validate_memory(%{big: String.duplicate("x", 64)}, tight)
      assert detail.limit == "max_binding_bytes"
      assert detail.name == "big"
    end

    test "validate_memory/2 accepts state within limits", %{limits: limits} do
      assert Limits.validate_memory(%{a: 1}, limits) == :ok
    end

    test "stored_keys/1 returns sorted string keys" do
      assert Limits.stored_keys(%{b: 1, a: 2}) == ["a", "b"]
    end

    test "drop_bindings/2 removes named keys without atom creation" do
      assert Limits.drop_bindings(%{"a" => 1, "b" => 2}, ["a"]) == %{"b" => 2}
    end

    test "top_bindings/2 ranks by approximate external size" do
      assert [%{name: "b"}] = Limits.top_bindings(%{a: 1, b: String.duplicate("x", 64)}, 1)
    end

    test "cap_turn_history/3 keeps small values verbatim with no notices", %{limits: limits} do
      {history, notices} = Limits.cap_turn_history([], 42, limits)
      assert history == [42]
      assert notices == []
    end

    test "cap_turn_history/3 replaces an oversized entry with a preview marker", %{limits: limits} do
      tight = Map.put(limits, :max_history_entry_bytes, 8)
      big = String.duplicate("z", 256)
      {[entry], [notice]} = Limits.cap_turn_history([], big, tight)
      assert entry.lisp_session_preview == true
      assert notice.reason == "max_history_entry_bytes"
    end

    test "append_prints/3 trims to the most recent entries under the count cap", %{limits: limits} do
      tight = Map.put(limits, :max_print_entries, 2)
      result = Limits.append_prints(["old"], ["a", "b", "c"], tight)
      assert result == ["b", "c"]
    end
  end

  describe "Sessions.Projection table behavior" do
    test "error/3 stringifies the reason and merges extra fields" do
      response = Projection.error(:custom_reason, "boom", %{detail: 7})
      assert response["status"] == "error"
      assert response["reason"] == "custom_reason"
      assert response["message"] == "boom"
      assert response["feedback"] == "boom"
      assert response["detail"] == 7
    end

    test "list/1 of no sessions reports an empty, zero-count payload" do
      assert Projection.list([]) == %{
               "status" => "ok",
               "count" => 0,
               "sessions" => []
             }
    end

    test "list/1 reports the count of provided summaries" do
      payload = Projection.list([%{"session_id" => "a"}, %{"session_id" => "b"}])
      assert payload["count"] == 2
    end

    test "eval_success uses configured session preview chars" do
      Config.set(%{Config.get() | max_session_preview_chars: 20})

      previous = %{memory: %{}}

      committed = %{
        id: "sess-preview",
        turn: 1,
        memory: %{},
        turn_history: [],
        prints: [],
        tool_calls: [],
        upstream_calls: []
      }

      step = %{
        return: String.duplicate("a", 200),
        memory: %{},
        prints: [],
        tool_calls: [],
        upstream_calls: []
      }

      payload = Projection.eval_success(previous, committed, step, [])

      assert payload["truncated"] == true
      assert String.length(payload["result"]) < 120
      assert payload["feedback"] =~ "truncated"
      assert payload["feedback"] =~ "(describe *1)"
      assert payload["feedback"] =~ "(describe *1 {:paths true :depth 2})"
      assert length(String.split(payload["feedback"], "(describe *1)")) == 2
    end

    test "lisp_session_eval envelope surfaces result truncation describe hint" do
      Config.set(%{Config.get() | max_session_preview_chars: 20})
      sid = SoakHelpers.start_session()

      envelope =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => ~s("#{String.duplicate("a", 200)}")
        })

      assert envelope["structuredContent"]["truncated"] == true
      assert envelope["structuredContent"]["feedback"] =~ "(describe *1)"

      refute envelope["structuredContent"]["feedback"] =~ "<untrusted_ptc_output"

      text = get_in(envelope, ["content", Access.at(0), "text"])

      assert text =~ "(describe *1)"
      assert length(String.split(text, "user=>")) == 2
      refute text =~ "<untrusted_ptc_output"
    end

    test "slim lisp_session_eval non-truncated success does not duplicate feedback" do
      ResponseProfile.set(:slim)
      sid = SoakHelpers.start_session()

      envelope =
        call("lisp_session_eval", %{
          "session_id" => sid,
          "program" => "(+ 1 2)"
        })

      text = get_in(envelope, ["content", Access.at(0), "text"])

      refute Map.has_key?(envelope, "structuredContent")
      assert text =~ "user=> 3"
      assert length(String.split(text, "user=> 3")) == 2
      refute text =~ "<result>"
    end

    test "eval_success does not add describe hint without truncation" do
      previous = %{memory: %{}}

      committed = %{
        id: "sess-preview",
        turn: 1,
        memory: %{},
        turn_history: [],
        prints: [],
        tool_calls: [],
        upstream_calls: []
      }

      step = %{
        return: "short",
        memory: %{},
        prints: [],
        tool_calls: [],
        upstream_calls: []
      }

      payload = Projection.eval_success(previous, committed, step, [])

      assert payload["truncated"] == false
      refute payload["feedback"] =~ "(describe *1)"
    end

    test "eval_success does not add result describe hint for print-only truncation" do
      previous = %{memory: %{}}

      committed = %{
        id: "sess-preview",
        turn: 1,
        memory: %{},
        turn_history: [],
        prints: [],
        tool_calls: [],
        upstream_calls: []
      }

      step = %{
        return: "short",
        memory: %{},
        prints: [String.duplicate("p", 3_000)],
        tool_calls: [],
        upstream_calls: []
      }

      payload = Projection.eval_success(previous, committed, step, [])

      assert payload["truncated"] == true
      assert payload["feedback"] =~ "truncated"
      refute payload["feedback"] =~ "(describe *1)"
    end

    test "eval_success does not add result describe hint when history stores a preview marker" do
      Config.set(%{Config.get() | max_session_preview_chars: 20})
      previous = %{memory: %{}}

      committed = %{
        id: "sess-preview",
        turn: 1,
        memory: %{},
        turn_history: [],
        prints: [],
        tool_calls: [],
        upstream_calls: []
      }

      step = %{
        return: String.duplicate("a", 200),
        memory: %{},
        prints: [],
        tool_calls: [],
        upstream_calls: []
      }

      history_notices = [
        %{reason: "max_history_entry_bytes", message: "*1 stored as preview"}
      ]

      payload = Projection.eval_success(previous, committed, step, history_notices)

      assert payload["truncated"] == true
      refute payload["feedback"] =~ "(describe *1)"
      assert payload["feedback"] =~ "*1 stored as preview"
    end
  end

  describe "Sessions.Owner derivation" do
    test "from_context/1 maps nil and empty map to the process stdio owner" do
      {:ok, a} = Owner.from_context(nil)
      {:ok, b} = Owner.from_context(%{})
      assert a.transport == :stdio
      assert a == b
    end

    test "from_context/1 derives an http owner from string keys" do
      assert {:ok, owner} =
               Owner.from_context(%{"transport" => "http", "mcp_session_id" => "sess-1"})

      assert owner.transport == :http
      assert owner.mcp_session_id == "sess-1"
    end

    test "from_context/1 normalizes an explicit owner override" do
      assert {:ok, owner} =
               Owner.from_context(%{owner: %{transport: :stdio, instance_id: "abc"}})

      assert owner == %{transport: :stdio, instance_id: "abc"}
    end

    test "from_context/1 rejects an unknown transport" do
      assert Owner.from_context(%{transport: :carrier_pigeon}) == {:error, :session_args_error}
    end

    test "from_context/1 rejects a non-map, non-list context" do
      assert Owner.from_context(123) == {:error, :session_args_error}
    end

    test "normalize/1 rejects an http owner with a blank session id" do
      assert Owner.normalize(%{transport: :http, mcp_session_id: ""}) ==
               {:error, :session_args_error}
    end

    test "check/2 authorizes equal owners and rejects mismatches" do
      owner = Owner.stdio()
      assert Owner.check(owner, owner) == :ok
      assert Owner.check(owner, @forged_owner) == {:error, :session_owner_mismatch}
    end

    test "fingerprint/1 is stable and distinguishes distinct owners" do
      owner = Owner.stdio()
      assert Owner.fingerprint(owner) == Owner.fingerprint(owner)
      refute Owner.fingerprint(owner) == Owner.fingerprint(@forged_owner)
    end
  end

  describe "Session.lisp_opts setup ceiling" do
    # Heap re-baseline (docs/plans/sandbox-heap-rebaseline.md): every eval
    # passes a setup ceiling sized for the program budget plus the session
    # memory copied in at spawn, at the pinned 5x refc amplification.
    test "derives setup_max_heap from max_heap and the session memory limit" do
      snapshot = %{
        memory: %{},
        turn_history: [],
        limits: %{Config.session_limits() | max_memory_bytes: 8_000_000}
      }

      opts = Session.lisp_opts(snapshot, "(+ 1 2)", %{})
      max_heap = Keyword.fetch!(opts, :max_heap)

      assert Keyword.fetch!(opts, :setup_max_heap) ==
               4 * max_heap + 5 * div(8_000_000, 8)
    end

    test "an explicit :setup_max_heap override wins" do
      snapshot = %{memory: %{}, turn_history: [], limits: Config.session_limits()}

      opts = Session.lisp_opts(snapshot, "(+ 1 2)", %{setup_max_heap: 123_456})
      assert Keyword.fetch!(opts, :setup_max_heap) == 123_456
    end
  end

  defp call(name, args) do
    Tools.call(%{"name" => name, "arguments" => args})
  end

  defp inspect_view(sid, view) do
    call("lisp_session_inspect", %{"session_id" => sid, "view" => view})["structuredContent"]
  end

  defp commit_tool_eval!(sid) do
    owner = Owner.stdio()
    {:ok, meta} = SessionsRegistry.lookup(sid)
    request_id = make_ref()
    program = "(tool/fetch {:id 1})"

    {:ok, snapshot} =
      Session.begin_eval(meta.pid, owner, request_id, %{program: program})

    tools = %{"fetch" => fn %{"id" => id} -> %{"id" => id} end}
    result = Sessions.run_snapshot(snapshot, program, %{tools: tools})

    assert {:ok, response} =
             Session.commit_eval(meta.pid, owner, request_id, result, %{})

    assert response["status"] == "ok"
  end

  defp commit_call_tool_eval!(sid, program) do
    owner = Owner.stdio()
    {:ok, meta} = SessionsRegistry.lookup(sid)
    request_id = make_ref()

    {:ok, snapshot} =
      Session.begin_eval(meta.pid, owner, request_id, %{program: program})

    result = Sessions.run_snapshot(snapshot, program, %{tools: %{"call" => &call_tool_stub/1}})

    response = Session.commit_eval(meta.pid, owner, request_id, result, %{})
    assert match?({:ok, _}, response) or match?({:error, _}, response)
    response
  end

  defp call_tool_stub(%{"tool" => "fail_trace"}), do: raise("upstream failed")

  defp call_tool_stub(%{"server" => server, "tool" => tool, "args" => args}) do
    %{"server" => server, "tool" => tool, "args" => args}
  end

  defp stop_turn_log! do
    case TurnLogConfig.collector() do
      nil -> :ok
      collector -> assert {:ok, _path, 0} = Collector.stop(collector)
    end

    TurnLogConfig.put_collector(nil)
  end

  # `lisp_session_close` / eviction makes the Session GenServer reply (or
  # stop) and then `cast`s `mark_closed` to the Registry. A synchronous
  # `:sys.get_state` drains all preceding casts so the tombstone is
  # observable — no `Process.sleep` poll loop.
  defp drain_registry do
    case Process.whereis(SessionsRegistry) do
      nil -> :ok
      pid -> _ = :sys.get_state(pid, 5_000)
    end

    :ok
  end

  # `Sessions.close/3` stops the session process; the Registry frees the
  # per-owner quota slot only when it handles that process's monitor `:DOWN`
  # (registry.ex `handle_info({:DOWN, ...})` removes the session from
  # `sessions` and releases the owner index together). `:sys.get_state` orders
  # only messages already enqueued, so it cannot wait for that async `:DOWN`.
  # Poll the Registry's authoritative state until the session is gone —
  # deterministic, yields the scheduler between checks, no `Process.sleep`.
  defp await_session_removed(sid, attempts \\ 5_000) do
    pid = Process.whereis(SessionsRegistry)

    cond do
      is_nil(pid) ->
        :ok

      not Map.has_key?(:sys.get_state(pid, 5_000).sessions, sid) ->
        :ok

      attempts > 0 ->
        :erlang.yield()
        await_session_removed(sid, attempts - 1)

      true ->
        flunk("Sessions.Registry did not process :DOWN for session #{sid}")
    end
  end

  # The public `lookup/1` first consults the partitioned `Sessions.Names`
  # `Registry`, whose dead-pid pruning is asynchronous and can briefly
  # return a stale live entry after a `:DOWN`. For a deterministic
  # tombstone assertion, drain the `Sessions.Registry` GenServer (so its
  # own `:DOWN` handler has run) and query it authoritatively by pid,
  # which skips the racy fast-path.
  defp tombstone_lookup(sid) do
    pid = Process.whereis(SessionsRegistry)
    _ = :sys.get_state(pid, 5_000)
    SessionsRegistry.lookup(sid, pid)
  end

  @names_registry PtcRunnerMcp.Sessions.Names

  # Deterministically wait for the partitioned `Sessions.Names` registry to
  # prune a dead session's entry. The session pid is already confirmed down
  # by a `:DOWN` assertion at the call site; here we only yield the
  # scheduler (never `Process.sleep`) on a bounded budget until the
  # registry's own monitor has cleaned up.
  defp await_names_pruned(sid, attempts \\ 1_000)

  defp await_names_pruned(_sid, 0), do: :ok

  defp await_names_pruned(sid, attempts) do
    case Elixir.Registry.lookup(@names_registry, sid) do
      [] ->
        :ok

      _live ->
        :erlang.yield()
        await_names_pruned(sid, attempts - 1)
    end
  end
end
