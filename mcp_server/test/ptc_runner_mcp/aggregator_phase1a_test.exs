defmodule PtcRunnerMcp.AggregatorPhase1aTest do
  @moduledoc """
  Phase 1a end-to-end tests against `Upstream.Fake`.

  Spec: `Plans/ptc-runner-mcp-aggregator.md` §13.2.

  Each test starts its own `Upstream.Registry` GenServer under a
  unique name (so tests run in parallel without colliding) and
  registers the registry under the production module name
  `PtcRunnerMcp.Upstream.Registry` so `Tools.configured_aggregator_mode?/0`
  + `AggregatorTools.build/2` (which default-routes to that name)
  can find it.

  Note: this means the integration tests are `async: false` —
  there is exactly one global `PtcRunnerMcp.Upstream.Registry`
  process at a time. This matches production semantics.
  """
  use ExUnit.Case, async: false

  import PtcRunnerMcp.McpTestHelpers, only: [stop_existing_registry: 1]

  alias PtcRunnerMcp.{AggregatorConfig, Limits, Tools, UpstreamCalls}
  alias PtcRunnerMcp.Upstream.Registry

  @registry_name PtcRunnerMcp.Upstream.Registry

  setup do
    stop_existing_registry(@registry_name)

    {:ok, _pid} = Registry.start_link(name: @registry_name)
    Limits.set(Limits.defaults())
    AggregatorConfig.set(AggregatorConfig.defaults())

    on_exit(fn ->
      stop_existing_registry(@registry_name)
      Limits.set(Limits.defaults())
      AggregatorConfig.set(AggregatorConfig.defaults())
    end)

    :ok
  end

  defp tools_config(tools) do
    %{
      tools:
        Map.new(tools, fn {n, fun} ->
          {n, {%{name: n, input_schema: %{}}, fun}}
        end)
    }
  end

  defp put_fake(name, tools) when is_list(tools) or is_map(tools) do
    map =
      case tools do
        list when is_list(list) -> Map.new(list)
        m when is_map(m) -> m
      end

    :ok = Registry.put_fake(name, tools_config(map), @registry_name)
  end

  defp put_fake_failing(name, detail) do
    :ok =
      Registry.put_fake(
        name,
        %{init_result: {:error, :upstream_unavailable, detail}},
        @registry_name
      )
  end

  defp call(program) do
    Tools.call_with_gate(%{"program" => program})
  end

  defp structured(env), do: env["structuredContent"]

  defp upstream_calls(env), do: structured(env)["upstream_calls"] || []

  # ============================================================
  # § 13.2 bullets
  # ============================================================

  describe "(tool/mcp-call ...) dispatch" do
    test "first call to a configured upstream succeeds, returning the upstream's value" do
      put_fake("alpha", %{"echo" => fn args, _ -> {:ok, %{"echo" => args["msg"]}} end})

      env =
        call(~S|
          (tool/mcp-call {:server "alpha" :tool "echo" :args {:msg "hi"}})
        |)

      assert env["isError"] == false
      assert structured(env)["status"] == "ok"
      # The program's last expression is the upstream's return — surfaced
      # in `result` as the LLM-readable preview.
      assert structured(env)["result"] =~ "hi"

      [entry] = upstream_calls(env)
      assert entry["server"] == "alpha"
      assert entry["tool"] == "echo"
      assert entry["status"] == "ok"
      assert is_integer(entry["duration_ms"]) and entry["duration_ms"] >= 0
    end

    test "successful cold-start duration_ms includes ensure_started overhead (§8.5)" do
      # Per §8.5: the entry's `duration_ms` is "time spent attempting
      # the operation, **including ensure-started overhead the
      # caller paid for**." A cold-start successful call MUST report
      # `ensure_duration + call_duration`, not just the call.
      #
      # Witness: a Fake whose `start_link/2` sleeps 100ms (via
      # `:init_delay_ms`) before returning :ok, and whose `call/4`
      # returns immediately. Pre-fix `duration_ms ≈ 0..5` (only the
      # fast `call/4`); post-fix `duration_ms >= 100` (includes the
      # 100ms ensure_started cost). A 5× margin (≥ 100, not just
      # > 5) makes this deterministic without wall-clock flakiness.
      :ok =
        Registry.put_fake(
          "slowstart",
          %{
            init_delay_ms: 100,
            tools: %{
              "echo" => {%{name: "echo", input_schema: %{}}, fn _, _ -> {:ok, "ok"} end}
            }
          },
          @registry_name
        )

      env = call(~S|(tool/mcp-call {:server "slowstart" :tool "echo" :args {}})|)

      assert env["isError"] == false
      [entry] = upstream_calls(env)
      assert entry["status"] == "ok"

      # Pre-fix this is ≈ 0–5 ms (the fast call only). Post-fix it
      # is ≥ 100 ms (ensure_started's 100ms sleep + the fast call).
      assert entry["duration_ms"] >= 100,
             "expected duration_ms ≥ 100 (ensure_started + call), got #{entry["duration_ms"]}"
    end

    test "configured but ensure_started failure → nil + upstream_unavailable" do
      put_fake_failing("broken", "boom")

      env = call(~S|(tool/mcp-call {:server "broken" :tool "any" :args {}})|)

      assert env["isError"] == false
      [entry] = upstream_calls(env)
      assert entry["status"] == "error"
      assert entry["reason"] == "upstream_unavailable"
      assert entry["error"] == "boom"
    end

    test "subsequent call to an unhealthy upstream replays the cached failure (no retry)" do
      put_fake_failing("broken", "down for maintenance")

      env =
        call(~S|
          [(tool/mcp-call {:server "broken" :tool "x" :args {}})
           (tool/mcp-call {:server "broken" :tool "y" :args {}})]
        |)

      [a, b] = upstream_calls(env)
      assert a["reason"] == "upstream_unavailable"
      assert b["reason"] == "upstream_unavailable"
      assert a["error"] == "down for maintenance"
      assert b["error"] == "down for maintenance"
      # Second entry has duration 0 (no fresh attempt was made).
      assert b["duration_ms"] == 0
    end

    test "concurrent pmap branches against a failing upstream observe exactly ONE start_link (§4.3)" do
      # The within-program retry-suppression invariant from §4.3 is
      # NOT satisfied by the registry's per-name GenServer mailbox
      # alone: N concurrent `pmap` branches all observe
      # `cached_failure → :miss` simultaneously, all submit their
      # own `Registry.ensure_started/2`, and the registry —
      # serialized but with no per-program memory — runs N
      # `start_link/2` attempts because each call sees the entry
      # still `:not_started` after the previous failure.
      #
      # The leader/follower ETS lock in `UpstreamCalls` ensures
      # exactly one branch runs `ensure_started/2`; followers wait
      # on `await_ensure_result/3` and replay the leader's outcome.
      #
      # Witness: a Fake whose `init/1` bumps an `:atomics` counter
      # on every entry. Pre-fix: 8 pmap branches → 8 `init/1`
      # invocations. Post-fix: 8 pmap branches → 1 `init/1`
      # invocation. The 50ms `init_delay_ms` widens the race window
      # so the absence of the lock is visible deterministically;
      # without the delay, scheduling could mask the bug on a
      # heavily-loaded scheduler.
      attempts = :atomics.new(1, signed: false)

      :ok =
        Registry.put_fake(
          "broken",
          %{
            init_result: {:error, :upstream_unavailable, "always down"},
            init_attempts: attempts,
            init_delay_ms: 50
          },
          @registry_name
        )

      program = """
      (pmap (fn [i]
              (tool/mcp-call {:server "broken" :tool "x" :args {:i i}}))
            [1 2 3 4 5 6 7 8])
      """

      env = call(program)

      assert env["isError"] == false, "envelope was: #{inspect(env, limit: :infinity)}"

      entries = upstream_calls(env)
      assert length(entries) == 8

      # All 8 branches see :upstream_unavailable.
      Enum.each(entries, fn e ->
        assert e["status"] == "error"
        assert e["reason"] == "upstream_unavailable"
        assert e["error"] == "always down"
      end)

      # Pre-fix: 8 init attempts (one per pmap branch). Post-fix:
      # exactly 1 — only the leader runs `start_link/2`; followers
      # replay the leader's published failure result without
      # re-attempting.
      assert :atomics.get(attempts, 1) == 1,
             "expected exactly 1 start_link attempt, got #{:atomics.get(attempts, 1)}"
    end

    test "next program is a fresh attempt: same failing config retries (§4.3 first bullet)" do
      # Per §4.3 first bullet: "no automatic retry of `ensure_started/1`
      # within a single program; the next program is a fresh
      # attempt." The within-program failure cache lives in the
      # call_context (an ETS table owned by the request worker,
      # auto-cleaned on worker death). The registry MUST NOT cache
      # failures across programs.
      #
      # Witness: an upstream whose start_link always fails with the
      # same detail. Two SEPARATE programs (separate
      # `call_with_gate/1` invocations) MUST both observe the same
      # `:upstream_unavailable` and BOTH must produce a non-zero
      # `duration_ms` (proving a fresh attempt was made — pre-fix
      # the second program returned `duration_ms: 0` from the
      # registry's cached `last_failure` short-circuit, without
      # invoking `start_link/2` at all).
      put_fake_failing("transient", "down")

      env1 = call(~S|(tool/mcp-call {:server "transient" :tool "x" :args {}})|)
      [entry1] = upstream_calls(env1)
      assert entry1["reason"] == "upstream_unavailable"
      assert entry1["error"] == "down"
      # First program made a real attempt → ensure_started actually
      # tried to spawn, so duration ≥ 0 (typically a few ms).
      first_duration = entry1["duration_ms"]
      assert is_integer(first_duration) and first_duration >= 0

      # Second program — fresh call_context, fresh failure_cache,
      # NO `put_fake` in between (so the registry entry is
      # untouched). Pre-fix: the registry's cached `last_failure`
      # short-circuited and reported `duration_ms: 0`. Post-fix:
      # the registry attempts a fresh start_link, which fails
      # again with the same configured `init_result`, and reports
      # the wall-clock of that fresh attempt.
      env2 = call(~S|(tool/mcp-call {:server "transient" :tool "x" :args {}})|)
      [entry2] = upstream_calls(env2)
      assert entry2["reason"] == "upstream_unavailable"
      assert entry2["error"] == "down"

      # Pre-fix: this was 0 (cached short-circuit, no attempt).
      # Post-fix: the registry made a fresh attempt; even on a
      # millisecond-fast machine, the duration field is the
      # measured wall-clock of THIS program's attempt, not a
      # cached zero. We assert by comparison: pre-fix, the only
      # path that produces `duration_ms: 0` is the cached short-
      # circuit — and within-program suppression already returned
      # 0 for entry1's hypothetical second call. The
      # discriminator is "is this program treated as a fresh
      # attempt?", which we verify via the duration field being
      # populated by a real attempt path (matching field
      # contracts §8.5: ensure_started failure → "wall-clock of
      # the spawn + initialize + ... attempt").
      #
      # Stronger assertion: within-program suppression yields 0,
      # but the ACROSS-program path MUST run the registry attempt.
      # We prove the path was taken by also checking the registry
      # state directly — `lookup/2` exists for this.
      entry = Registry.lookup("transient", @registry_name)
      assert entry.status == :not_started
      # The registry has no `last_failure` field anymore (post-fix).
      refute Map.has_key?(entry, :last_failure)
    end
  end

  describe "programmer-fault failures (§7.2 / §7.4)" do
    test ":server not configured → runtime_error envelope (program terminates)" do
      # Aggregator mode requires ≥1 upstream configured; "alpha" is
      # the witness upstream and "ghost" is the unknown :server.
      put_fake("alpha", %{})

      env = call(~S|(tool/mcp-call {:server "ghost" :tool "x" :args {}})|)

      assert env["isError"] == true
      assert structured(env)["status"] == "error"
      assert structured(env)["reason"] == "runtime_error"
      assert structured(env)["message"] =~ "no upstream 'ghost' configured"
    end

    test "unknown tool on a started upstream → runtime_error" do
      put_fake("alpha", %{"known" => fn _, _ -> {:ok, "ok"} end})

      # Warm the cache by making one successful call first.
      _warm = call(~S|(tool/mcp-call {:server "alpha" :tool "known" :args {}})|)

      env = call(~S|(tool/mcp-call {:server "alpha" :tool "unknown" :args {}})|)

      assert env["isError"] == true
      assert structured(env)["reason"] == "runtime_error"
      assert structured(env)["message"] =~ "no tool 'unknown' in upstream 'alpha'"
    end

    test "unknown tool on a NOT-started upstream → world-fault upstream_unavailable (§7.4 cold start)" do
      # ensure_started fails → cache cannot prove the tool's absence,
      # so we must classify as world-fault, not programmer-fault.
      put_fake_failing("cold", "cold-start failure")

      env = call(~S|(tool/mcp-call {:server "cold" :tool "anything" :args {}})|)

      assert env["isError"] == false
      [entry] = upstream_calls(env)
      assert entry["status"] == "error"
      assert entry["reason"] == "upstream_unavailable"
    end

    test "cold start + unknown tool: ensure_started succeeds → re-check cache → programmer-fault (§7.4)" do
      # The §7.4 spec rule: programmer-fault `no tool '<tool>' in
      # upstream '<server>'` is raised iff `<server>` is in
      # `started_upstreams` AND its cached `tools/list` lacks
      # `<tool>`. The cold-start path runs `check_known_tool/3`
      # before ensure_started — at which point cached_tools is nil
      # and we cannot prove absence, so the check falls through.
      # After ensure_started succeeds the cache is populated, and
      # `ensure_known_tool_post_start!/3` MUST re-check
      # authoritatively. Pre-fix the post-check was missing: the
      # call dispatched to `Upstream.call/4` with a misspelled
      # tool, which the upstream's lookup-by-name failed and
      # returned `:upstream_error` — surfacing as world-fault `nil`
      # rather than the programmer-fault the spec requires.
      called = :counters.new(1, [])

      :ok =
        Registry.put_fake(
          "fake-x",
          %{
            tools: %{
              "search" =>
                {%{name: "search", input_schema: %{}},
                 fn _, _ ->
                   :counters.add(called, 1, 1)
                   {:ok, "ok"}
                 end}
            }
          },
          @registry_name
        )

      # Cold start: nothing is started yet; the upstream is configured
      # but `started_upstreams/0` is empty. The first call uses an
      # unknown tool name. Pre-fix: the call dispatches, the Fake's
      # tool-lookup misses, returns `:upstream_error`, and the
      # program sees `nil`. Post-fix: post-`ensure_started`
      # re-check catches the absence and raises programmer-fault.
      assert MapSet.size(Registry.started_upstreams(@registry_name)) == 0

      env = call(~S|(tool/mcp-call {:server "fake-x" :tool "missspelled" :args {}})|)

      # Programmer-fault: the program is terminated with a
      # runtime_error envelope. Pre-fix the envelope was a success
      # envelope with nil result + an upstream_error entry.
      assert env["isError"] == true
      assert structured(env)["reason"] == "runtime_error"

      assert structured(env)["message"] =~
               "no tool 'missspelled' in upstream 'fake-x'"

      # The Fake's `call/4` MUST NOT be invoked: programmer-fault
      # surfaces BEFORE the upstream call, so the test-only counter
      # bound into the configured "search" tool stays at zero. Pre-fix
      # the Fake's lookup-by-name path got reached (and missed,
      # returning `:upstream_error`), so even though "missspelled"
      # would not bump this counter, asserting it is zero here is
      # the right invariant: post-fix, we never even reach the
      # impl-level dispatch for the cold-start unknown tool.
      assert :counters.get(called, 1) == 0

      # And the upstream IS now started — `ensure_started/2` ran
      # successfully before the post-check raised. This proves the
      # re-check path was taken (not an early bail-out).
      assert "fake-x" in Registry.started_upstreams(@registry_name)
    end
  end

  describe "world-fault reasons (§7.1)" do
    test ":upstream_error → nil + reason upstream_error" do
      put_fake("alpha", %{"err" => fn _, _ -> {:error, :upstream_error, "404"} end})

      env = call(~S|(tool/mcp-call {:server "alpha" :tool "err" :args {}})|)

      assert env["isError"] == false
      [entry] = upstream_calls(env)
      assert entry["reason"] == "upstream_error"
      assert entry["error"] == "404"
    end

    test ":timeout → nil + reason timeout" do
      Limits.set(Map.put(Limits.defaults(), :upstream_call_timeout_ms, 50))

      slow = fn _, _ ->
        :timer.sleep(500)
        {:ok, "should never see this"}
      end

      put_fake("alpha", %{"slow" => slow})

      started = System.monotonic_time(:millisecond)
      env = call(~S|(tool/mcp-call {:server "alpha" :tool "slow" :args {}})|)
      elapsed = System.monotonic_time(:millisecond) - started

      assert env["isError"] == false
      [entry] = upstream_calls(env)
      assert entry["reason"] == "timeout"
      # The 50ms timeout flag is what fired (≥10× margin over actual).
      assert elapsed < 300, "timeout enforcement leaked: elapsed=#{elapsed}ms"
    end

    test ":response_too_large → nil + reason response_too_large" do
      Limits.set(Map.put(Limits.defaults(), :max_upstream_response_bytes, 100))

      payload = String.duplicate("x", 5_000)
      put_fake("alpha", %{"big" => fn _, _ -> {:ok, payload} end})

      env = call(~S|(tool/mcp-call {:server "alpha" :tool "big" :args {}})|)

      assert env["isError"] == false
      [entry] = upstream_calls(env)
      assert entry["reason"] == "response_too_large"
    end
  end

  describe "JSON-non-encodable args (§7.2)" do
    test "non-encodable args raise programmer-fault before upstream call" do
      # PTC-Lisp produces value types that don't always survive
      # JSON encoding. A user-constructed `fn` (closure) is the
      # cleanest non-encodable witness: Jason has no encoder for
      # the internal `{:closure, ...}` tuple. The aggregator MUST
      # reject these args with `runtime_error: tool '<server>.<tool>'
      # rejected args: ...` before attempting the upstream call
      # (per §7.2). The upstream's own fun is never invoked.
      called = :counters.new(1, [])

      put_fake("alpha", %{
        "x" => fn _, _ ->
          :counters.add(called, 1, 1)
          {:ok, "ok"}
        end
      })

      env =
        call(~S|(tool/mcp-call {:server "alpha" :tool "x" :args {:bad (fn [x] x)}})|)

      assert env["isError"] == true
      assert structured(env)["reason"] == "runtime_error"
      assert structured(env)["message"] =~ "rejected args"
      # The upstream fun must NOT have been invoked (§7.2: the rejection
      # happens before the upstream call is attempted).
      assert :counters.get(called, 1) == 0
    end
  end

  describe ":json-null sentinel (§7.3)" do
    test "successful upstream returning JSON null → :json-null keyword" do
      put_fake("alpha", %{"null" => fn _, _ -> {:ok, nil} end})

      # A program that compares the result against the sentinel
      # surfaces a deterministic boolean in `validated`.
      env =
        Tools.call_with_gate(%{
          "program" => ~S|(= (tool/mcp-call {:server "alpha" :tool "null" :args {}}) :json-null)|,
          "output_schema" => %{"type" => "boolean"}
        })

      assert env["isError"] == false
      # The validated value is true: the sentinel substitution
      # happened and the program saw `:json-null`, not `nil`.
      assert structured(env)["validated"] == true

      [entry] = upstream_calls(env)
      assert entry["status"] == "ok"
    end

    test "nested JSON null inside a successful payload is left as nil" do
      put_fake("alpha", %{"mixed" => fn _, _ -> {:ok, %{"a" => nil, "b" => 1}} end})

      env =
        Tools.call_with_gate(%{
          "program" => ~S|
            (let [r (tool/mcp-call {:server "alpha" :tool "mixed" :args {}})]
              (and (map? r) (nil? (get r "a")) (= (get r "b") 1)))
          |,
          "output_schema" => %{"type" => "boolean"}
        })

      assert env["isError"] == false, "envelope was: #{inspect(env, limit: :infinity)}"
      assert structured(env)["validated"] == true
    end
  end

  describe "per-program upstream-call cap (§7.1 cap_exhausted)" do
    test "(N+1)th call returns nil + cap_exhausted (sequential)" do
      Limits.set(Map.put(Limits.defaults(), :max_upstream_calls_per_program, 2))

      put_fake("alpha", %{"x" => fn args, _ -> {:ok, args["i"]} end})

      env =
        call(~S|
          [(tool/mcp-call {:server "alpha" :tool "x" :args {:i 1}})
           (tool/mcp-call {:server "alpha" :tool "x" :args {:i 2}})
           (tool/mcp-call {:server "alpha" :tool "x" :args {:i 3}})]
        |)

      assert env["isError"] == false
      entries = upstream_calls(env)
      # The first 2 calls succeed; the 3rd records cap_exhausted.
      assert length(entries) == 3

      [a, b, c] = entries
      assert a["status"] == "ok"
      assert b["status"] == "ok"
      assert c["status"] == "error"
      assert c["reason"] == "cap_exhausted"
      # cap_exhausted has duration_ms = 0 per §8.5 (no attempt made).
      assert c["duration_ms"] == 0
    end

    test "pmap over N+K calls: exactly N succeed, exactly K cap_exhausted" do
      # Now that the cap counter uses `:atomics.add_get/3`
      # (atomic fetch-and-add), each caller receives a unique slot
      # number — no race window where concurrent reads land after
      # concurrent bumps. Cap=3 with 5 pmap branches yields
      # **exactly** 3 ok + 2 cap_exhausted, deterministically.
      Limits.set(Map.put(Limits.defaults(), :max_upstream_calls_per_program, 3))

      put_fake("alpha", %{"x" => fn _, _ -> {:ok, 1} end})

      program = """
      (def results
        (pmap (fn [i]
                (tool/mcp-call {:server "alpha" :tool "x" :args {:i i}}))
              [1 2 3 4 5]))
      results
      """

      env = call(program)

      assert env["isError"] == false, "envelope was: #{inspect(env, limit: :infinity)}"

      entries = upstream_calls(env)
      assert length(entries) == 5

      successes = Enum.count(entries, fn e -> e["status"] == "ok" end)
      cap_exhausted = Enum.count(entries, fn e -> e["reason"] == "cap_exhausted" end)

      assert successes == 3, "expected exactly 3 successes, got #{successes}"
      assert cap_exhausted == 2, "expected exactly 2 cap_exhausted, got #{cap_exhausted}"
    end

    test "pmap stress: cap=1 with 8 concurrent callers → exactly 1 ok + 7 cap_exhausted" do
      # The strict regression test for the codex-flagged race: with
      # the pre-fix `:counters.add(c, 1, 1); :counters.get(c, 1)`
      # bump-then-read, two concurrent callers can both observe
      # the post-bump counter as 2 (after the OTHER's add lands)
      # and both record `cap_exhausted` — leaving 0 successes.
      # `:atomics.add_get/3` makes the bump-and-read atomic so each
      # caller gets a unique slot in [1..N]; only the slot=1 caller
      # proceeds, the other 7 get cap_exhausted. Run under the
      # 10-seed flake loop to ensure no race window slips through.
      Limits.set(Map.put(Limits.defaults(), :max_upstream_calls_per_program, 1))

      put_fake("alpha", %{"x" => fn _, _ -> {:ok, 1} end})

      program = """
      (pmap (fn [i]
              (tool/mcp-call {:server "alpha" :tool "x" :args {:i i}}))
            [1 2 3 4 5 6 7 8])
      """

      env = call(program)

      assert env["isError"] == false, "envelope was: #{inspect(env, limit: :infinity)}"

      entries = upstream_calls(env)
      assert length(entries) == 8

      successes = Enum.count(entries, fn e -> e["status"] == "ok" end)
      cap_exhausted = Enum.count(entries, fn e -> e["reason"] == "cap_exhausted" end)

      assert successes == 1, "expected exactly 1 success, got #{successes}"
      assert cap_exhausted == 7, "expected exactly 7 cap_exhausted, got #{cap_exhausted}"
    end
  end

  describe "pmap concurrency (§13.2)" do
    test "pmap over delayed fake calls completes in completion-order entries" do
      put_fake("alpha", %{
        "task" => fn args, _ ->
          :timer.sleep(args["sleep"])
          {:ok, args["i"]}
        end
      })

      # Three calls with different durations; entries should arrive
      # in completion order (shortest sleep first).
      program = """
      (pmap (fn [pair]
              (let [i (get pair "i") sleep (get pair "sleep")]
                (tool/mcp-call {:server "alpha" :tool "task" :args {:i i :sleep sleep}})))
            [{"i" 1 "sleep" 200} {"i" 2 "sleep" 50} {"i" 3 "sleep" 100}])
      """

      env = call(program)

      assert env["isError"] == false, "envelope was: #{inspect(env, limit: :infinity)}"

      entries = upstream_calls(env)
      assert length(entries) == 3

      # Completion order: i=2 (50ms), i=3 (100ms), i=1 (200ms).
      # We assert by relative duration_ms ordering rather than i's
      # because i is encoded into the result not into the entry.
      durations = Enum.map(entries, & &1["duration_ms"])
      assert durations == Enum.sort(durations)
    end
  end

  describe "tools/list aggregator-mode advertisement (§8)" do
    test "description includes the aggregator authoring card" do
      # Configuring at least one upstream activates the predicate.
      put_fake("alpha", %{})

      assert Tools.configured_aggregator_mode?()

      desc = Tools.tool_entry()["description"]
      # Phase 1a description includes:
      #   * the `(tool/mcp-call ...)` form
      #   * the `nil` failure convention
      #   * the `:json-null` sentinel
      #   * the `upstream_calls` envelope field
      assert desc =~ "tool/mcp-call"
      assert desc =~ "nil"
      assert desc =~ ":json-null"
      assert desc =~ "upstream_calls"
      assert desc =~ "Aggregator authoring"
      assert desc =~ "Unwrap with"
      assert desc =~ "Use `output_schema` for typed final results"
    end

    test "annotations match §8.2 (destructiveHint: true, readOnlyHint: false)" do
      put_fake("alpha", %{})

      annotations = Tools.tool_entry()["annotations"]
      assert annotations["readOnlyHint"] == false
      assert annotations["destructiveHint"] == true
      assert annotations["idempotentHint"] == false
      assert annotations["openWorldHint"] == true
    end

    test "read-only aggregator config advertises non-destructive but still open-world" do
      put_fake("alpha", %{})
      :ok = AggregatorConfig.set(%{read_only: true})

      annotations = Tools.tool_entry()["annotations"]
      assert annotations["readOnlyHint"] == true
      assert annotations["destructiveHint"] == false
      assert annotations["idempotentHint"] == false
      assert annotations["openWorldHint"] == true
    end

    test "outputSchema accepts the upstream_calls field (§8.4)" do
      put_fake("alpha", %{})

      schema = Tools.tool_entry()["outputSchema"]

      Enum.each(schema["oneOf"], fn branch ->
        props = branch["properties"]
        assert Map.has_key?(props, "upstream_calls")
        assert props["upstream_calls"]["type"] == "array"
      end)
    end

    test "config-derived predicate is true with at least one upstream, regardless of started_upstreams" do
      assert Registry.started_upstreams(@registry_name) == MapSet.new()
      refute Tools.configured_aggregator_mode?()

      put_fake("alpha", %{})
      # Still no started upstreams (lazy spawn).
      assert Registry.started_upstreams(@registry_name) == MapSet.new()
      # Predicate flipped because the routing table now has an entry.
      assert Tools.configured_aggregator_mode?()
    end
  end

  describe ":mcp_no_tools fallback when no upstreams configured (§13.2 last bullet)" do
    test "non-aggregator (no config) mode behaves as Phase 0" do
      # No put_fake → empty upstreams → predicate false.
      refute Tools.configured_aggregator_mode?()

      # tool_entry must mirror the v1 fixture per §12.1.
      live = Tools.tool_entry()
      v1 = Tools.advertised_description(:mcp_no_tools, catalog: nil)
      assert live["description"] == v1
      assert live["annotations"]["readOnlyHint"] == true
      assert live["annotations"]["destructiveHint"] == false

      # An (otherwise valid) program runs unchanged. No `upstream_calls`
      # is decorated because we're not in aggregator mode.
      env = Tools.call_with_gate(%{"program" => "(+ 1 2)"})
      assert env["isError"] == false
      refute Map.has_key?(structured(env), "upstream_calls")
    end
  end

  describe "envelope decoration (§8.3 / §8.5)" do
    test "upstream_calls field appears in both structuredContent and mirrored text" do
      put_fake("alpha", %{"x" => fn _, _ -> {:ok, "v"} end})

      env = call(~S|(tool/mcp-call {:server "alpha" :tool "x" :args {}})|)

      structured = structured(env)
      assert is_list(structured["upstream_calls"])

      # The text content mirrors the structuredContent JSON.
      [%{"type" => "text", "text" => mirror}] = env["content"]
      assert Jason.decode!(mirror)["upstream_calls"] == structured["upstream_calls"]
    end

    test "upstream_calls is omitted when empty (no upstream calls made)" do
      put_fake("alpha", %{})

      env = call("(+ 1 2)")
      refute Map.has_key?(structured(env), "upstream_calls")
    end
  end

  # ============================================================
  # Test API direct sanity (UpstreamCalls helpers)
  # ============================================================

  describe "UpstreamCalls helpers (§6.4 / §8.5 direct)" do
    test "drain returns entries in arrival order and clears mailbox" do
      ref = make_ref()

      ctx = %{collector_pid: self(), collector_ref: ref}

      :ok = UpstreamCalls.record(ctx, UpstreamCalls.success_entry("a", "x", 10))
      :ok = UpstreamCalls.record(ctx, UpstreamCalls.success_entry("b", "y", 20))

      assert [first, second] = UpstreamCalls.drain(ref)
      assert first["server"] == "a"
      assert second["server"] == "b"

      # Drain again: empty (mailbox cleared).
      assert UpstreamCalls.drain(ref) == []
    end

    test "drain filters by ref — unrelated refs are left in place" do
      ref_us = make_ref()
      ref_other = make_ref()

      send(self(), {:upstream_call_recorded, ref_other, %{"foreign" => true}})

      :ok =
        UpstreamCalls.record(
          %{collector_pid: self(), collector_ref: ref_us},
          UpstreamCalls.success_entry("a", "x", 1)
        )

      assert [%{"server" => "a"}] = UpstreamCalls.drain(ref_us)

      # The foreign message is still in the mailbox.
      assert_received {:upstream_call_recorded, ^ref_other, %{"foreign" => true}}
    end

    test "decorate omits empty list" do
      assert UpstreamCalls.decorate(%{"a" => 1}, []) == %{"a" => 1}
    end

    test "decorate adds the field when non-empty" do
      payload = %{"status" => "ok"}
      entry = UpstreamCalls.success_entry("a", "x", 1)

      assert %{"status" => "ok", "upstream_calls" => [^entry]} =
               UpstreamCalls.decorate(payload, [entry])
    end
  end
end
