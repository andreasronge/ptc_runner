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

  alias PtcRunnerMcp.{ResponseProfile, Sessions, Tools}
  alias PtcRunnerMcp.Sessions.{Config, Limits, Owner, Projection, Session}
  alias PtcRunnerMcp.Sessions.Registry, as: SessionsRegistry
  alias PtcRunnerMcp.TestSupport.SoakHelpers

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
    on_exit(fn -> ResponseProfile.set(old_profile) end)
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
      drain_registry()

      # The owner index slot was reclaimed on :DOWN, so a new start succeeds.
      assert {:ok, _} = Sessions.start_session(nil, %{})
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
      d = Config.resolve(%{})
      assert d.enabled == false
      assert d.max_sessions == 64
      assert d.max_sessions_per_owner == 16
    end

    test "resolve/1 honors CLI keys and parses integer strings" do
      resolved =
        Config.resolve(%{
          sessions: true,
          max_sessions: 7,
          session_ttl_ms: "1234"
        })

      assert resolved.enabled == true
      assert resolved.max_sessions == 7
      assert resolved.session_ttl_ms == 1234
    end

    test "resolve/1 falls back to the default for an unparseable integer" do
      resolved = Config.resolve(%{max_sessions_per_owner: "not-a-number"})
      assert resolved.max_sessions_per_owner == 16
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

  defp call(name, args) do
    Tools.call(%{"name" => name, "arguments" => args})
  end

  defp inspect_view(sid, view) do
    call("lisp_session_inspect", %{"session_id" => sid, "view" => view})["structuredContent"]
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
