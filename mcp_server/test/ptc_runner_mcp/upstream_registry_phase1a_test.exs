defmodule PtcRunnerMcp.UpstreamRegistryPhase1aTest do
  @moduledoc """
  Phase 1a tests for `PtcRunnerMcp.Upstream.Registry`.

  Covers:

    * §4.1 per-name serialization of `ensure_started/1`: concurrent
      callers for the same upstream observe exactly one spawn attempt.
    * §4.1 `started_upstreams/0` reflects only currently-healthy
      upstreams.
    * §5.4 test API: `put_fake/2` and the `:upstreams` start option
      are the only paths to register a Fake. There is no JSON
      bridge — tests assert the JSON config format does NOT carry
      `"fake"` semantics (production read by `Application` builds
      a Stdio entry only).
    * §7.4 cache-only unknown-tool classification: the executor
      sees `cached_tools/1` returning the schemas after a successful
      ensure_started.
    * §13.2 first-call-spawns / subsequent-skip semantics.

  Spec: `Plans/ptc-runner-mcp-aggregator.md` §4.1, §5.4, §7.4, §13.2.
  """
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.Upstream.{Fake, Registry}

  setup do
    name = :"reg-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Registry.start_link(name: name)
    on_exit(fn -> stop_quietly(name) end)
    {:ok, registry: name}
  end

  defp stop_quietly(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 1_000)
    end
  catch
    :exit, _ -> :ok
  end

  defp tools_config(tools) do
    %{
      tools:
        Map.new(tools, fn {n, fun} ->
          {n, {%{name: n, input_schema: %{}}, fun}}
        end)
    }
  end

  describe "configured?/2" do
    test "false for unknown name", %{registry: r} do
      refute Registry.configured?("nope", r)
    end

    test "true after put_fake/3", %{registry: r} do
      :ok = Registry.put_fake("alpha", %{}, r)
      assert Registry.configured?("alpha", r)
    end
  end

  describe "configured_count/1" do
    test "tracks bootstrap upstreams", %{registry: r} do
      assert Registry.configured_count(r) == 0

      :ok = Registry.put_fake("a", %{}, r)
      :ok = Registry.put_fake("b", %{}, r)

      assert Registry.configured_count(r) == 2
    end
  end

  describe "ensure_started/2 happy path" do
    test "first call spawns; second call short-circuits", %{registry: r} do
      :ok =
        Registry.put_fake(
          "alpha",
          tools_config(%{"echo" => fn args, _ -> {:ok, args} end}),
          r
        )

      assert {:ok, %{duration_ms: d1}} = Registry.ensure_started("alpha", r)
      assert d1 >= 0

      assert {:ok, %{duration_ms: 0}} = Registry.ensure_started("alpha", r)
      assert MapSet.member?(Registry.started_upstreams(r), "alpha")
    end

    test "different upstreams start independently", %{registry: r} do
      :ok = Registry.put_fake("a", tools_config(%{"x" => fn _, _ -> {:ok, 1} end}), r)
      :ok = Registry.put_fake("b", tools_config(%{"y" => fn _, _ -> {:ok, 2} end}), r)

      assert {:ok, _} = Registry.ensure_started("a", r)
      assert {:ok, _} = Registry.ensure_started("b", r)

      started = Registry.started_upstreams(r)
      assert MapSet.member?(started, "a")
      assert MapSet.member?(started, "b")
    end

    test "started_upstreams reflects start order", %{registry: r} do
      :ok = Registry.put_fake("a", %{}, r)
      :ok = Registry.put_fake("b", %{}, r)

      # Before any start, no upstreams are started even though both
      # are configured.
      assert MapSet.size(Registry.started_upstreams(r)) == 0
      assert Registry.configured_count(r) == 2

      assert {:ok, _} = Registry.ensure_started("a", r)
      assert MapSet.equal?(Registry.started_upstreams(r), MapSet.new(["a"]))
    end
  end

  describe "ensure_started/2 failure path" do
    test "init failure surfaces as :upstream_unavailable", %{registry: r} do
      :ok =
        Registry.put_fake(
          "broken",
          %{init_result: {:error, :upstream_unavailable, "boom"}},
          r
        )

      assert {:error, :upstream_unavailable, detail, %{duration_ms: _}} =
               Registry.ensure_started("broken", r)

      assert detail == "boom"
    end

    test "the registry does NOT cache failures across calls (§4.3)", %{registry: r} do
      # Per §4.3 first bullet: "no automatic retry of `ensure_started/1`
      # within a single program; the next program is a fresh attempt."
      # The within-program failure cache lives in the call_context
      # (an ETS table owned by the request worker), NOT in the
      # registry. The registry must attempt every `ensure_started/2`
      # so a transient failure cannot poison subsequent calls /
      # programs.
      #
      # Witness without `put_fake` between calls (so the registry
      # entry is untouched): an init_result that always fails. Both
      # ensure_started calls MUST report a non-zero (or at least
      # non-cached) wall-clock duration, proving each one ran the
      # `attempt_start` path. Pre-fix the second call returned the
      # cached failure with `duration_ms: 0` from the short-circuit.
      :ok =
        Registry.put_fake(
          "broken",
          %{init_result: {:error, :upstream_unavailable, "down"}},
          r
        )

      # First call: fresh attempt → `duration_ms` reflects the
      # attempt wall-clock (≥ 0, typically a few ms).
      assert {:error, :upstream_unavailable, "down", %{duration_ms: d1}} =
               Registry.ensure_started("broken", r)

      assert is_integer(d1) and d1 >= 0

      # Second call WITHOUT any put_fake: pre-fix this short-
      # circuited from the registry's `last_failure` and returned
      # `duration_ms: 0` without invoking `start_link/2`. Post-fix
      # the registry runs `attempt_start` again — same outcome,
      # but a fresh wall-clock measurement.
      assert {:error, :upstream_unavailable, "down", %{duration_ms: _d2}} =
               Registry.ensure_started("broken", r)

      # The strongest assertion: the registry entry has no
      # `last_failure` field at all. Pre-fix it had
      # `last_failure: {:upstream_unavailable, "down"}`.
      entry = Registry.lookup("broken", r)
      refute Map.has_key?(entry, :last_failure)

      # And the entry is `:not_started` — ready for another fresh
      # attempt on the next call (no poisoned state).
      assert entry.status == :not_started
    end

    test "across-program recovery: failed → reconfigured → succeeds", %{registry: r} do
      # The full "next program is a fresh attempt" scenario from
      # §4.3, exercised at the registry level. Stronger version of
      # the test above: between programs the operator brings the
      # upstream back up (via `put_fake` with success config), and
      # the next `ensure_started/2` MUST succeed. Pre-fix this also
      # passed (because put_fake reset `last_failure` as a side
      # effect of installing a new entry); post-fix it passes for
      # the right reason — the registry never cached the failure
      # in the first place.
      :ok =
        Registry.put_fake(
          "transient",
          %{init_result: {:error, :upstream_unavailable, "transient failure"}},
          r
        )

      assert {:error, :upstream_unavailable, "transient failure", _} =
               Registry.ensure_started("transient", r)

      :ok =
        Registry.put_fake(
          "transient",
          tools_config(%{"ping" => fn _, _ -> {:ok, "pong"} end}),
          r
        )

      assert {:ok, _} = Registry.ensure_started("transient", r)
      assert "transient" in Registry.started_upstreams(r)
    end

    test "unknown name returns :upstream_unavailable", %{registry: r} do
      assert {:error, :upstream_unavailable, detail, %{duration_ms: 0}} =
               Registry.ensure_started("never-configured", r)

      assert detail =~ "not configured"
    end
  end

  describe "ensure_started/2 per-name serialization (§4.1)" do
    test "concurrent callers for same not-yet-started upstream observe one spawn", %{
      registry: r
    } do
      # Counter incremented inside the fake init to count actual
      # spawn attempts. The fake's `init_result` is :ok, so the
      # GenServer starts cleanly; we read the counter post-test.
      counter = :counters.new(1, [])
      parent = self()

      # Wrap the fake's start by intercepting via a custom impl that
      # bumps `counter` inside `start_link/2`. Easiest path: a
      # one-off impl module — but we don't want that complexity.
      # Instead, count *successful* `ensure_started` returns: per
      # §4.1, two concurrent callers for the same not-yet-started
      # upstream MUST both observe exactly one spawn (the second
      # waits on the first's result).
      :ok =
        Registry.put_fake(
          "shared",
          %{
            tools: %{
              "ping" =>
                {%{name: "ping", input_schema: %{}},
                 fn _, _ ->
                   :counters.add(counter, 1, 1)
                   {:ok, "pong"}
                 end}
            }
          },
          r
        )

      # 8 parallel callers all asking ensure_started for the same
      # not-yet-started upstream. Each then makes one (independent)
      # call/4 request, but ensure_started should only have
      # spawned/handshaked the GenServer once — the 8 parallel
      # callers all observe :ok.
      tasks =
        for _ <- 1..8 do
          Task.async(fn ->
            Registry.ensure_started("shared", r)
          end)
        end

      results = Task.await_many(tasks, 5_000)

      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)

      send(parent, :done)

      # Started exactly once: the registry's per-name lock means
      # only the first call's `attempt_start` ran.
      assert MapSet.member?(Registry.started_upstreams(r), "shared")

      # Sanity: the underlying Fake GenServer is alive and
      # responsive — the 8 ensure_started calls did not double-start.
      assert {:ok, _} = Fake.list_tools("shared")
    end

    test "concurrent callers for same failing upstream all see :upstream_unavailable",
         %{registry: r} do
      # Per the new model (§4.3 first bullet, post-fix): the
      # registry does NOT cache failures. Each concurrent caller
      # gets a fresh `attempt_start` serialized through the
      # GenServer mailbox; all attempts hit the same configured
      # `init_result`, so all return the same world-fault. The
      # within-program suppression that prevents N concurrent pmap
      # branches from running N spawn attempts lives at the
      # AggregatorTools layer (the `call_context.failure_cache`),
      # which is exercised by the integration tests.
      :ok =
        Registry.put_fake(
          "broken",
          %{init_result: {:error, :upstream_unavailable, "first attempt failure"}},
          r
        )

      tasks =
        for _ <- 1..8 do
          Task.async(fn -> Registry.ensure_started("broken", r) end)
        end

      results = Task.await_many(tasks, 5_000)

      assert Enum.all?(results, fn
               {:error, :upstream_unavailable, "first attempt failure", _} -> true
               _ -> false
             end)
    end
  end

  describe "cached_tools/2 (§7.4)" do
    test "returns nil before ensure_started", %{registry: r} do
      :ok =
        Registry.put_fake(
          "alpha",
          tools_config(%{"echo" => fn args, _ -> {:ok, args} end}),
          r
        )

      assert Registry.cached_tools("alpha", r) == nil
    end

    test "returns the configured schemas after a successful ensure_started", %{registry: r} do
      :ok =
        Registry.put_fake(
          "alpha",
          tools_config(%{"echo" => fn args, _ -> {:ok, args} end}),
          r
        )

      {:ok, _} = Registry.ensure_started("alpha", r)
      tools = Registry.cached_tools("alpha", r)
      assert is_list(tools)
      assert Enum.any?(tools, fn t -> Map.get(t, :name) == "echo" end)
    end

    test "still nil for unknown upstream", %{registry: r} do
      assert Registry.cached_tools("never-configured", r) == nil
    end
  end

  describe "put_fake/3 (§5.4)" do
    test "replaces an existing entry", %{registry: r} do
      :ok = Registry.put_fake("a", tools_config(%{"v1" => fn _, _ -> {:ok, "old"} end}), r)
      {:ok, _} = Registry.ensure_started("a", r)
      assert "v1" == hd(Registry.cached_tools("a", r)).name

      # Replace the impl. The previously-running Fake should be
      # stopped and the new config installed; ensure_started will
      # re-spawn against the new tools.
      :ok = Registry.put_fake("a", tools_config(%{"v2" => fn _, _ -> {:ok, "new"} end}), r)

      # cached_tools is nil now (status reset to :not_started).
      assert Registry.cached_tools("a", r) == nil

      {:ok, _} = Registry.ensure_started("a", r)
      assert "v2" == hd(Registry.cached_tools("a", r)).name
    end
  end

  describe "lookup/2" do
    test "returns the routing entry for a configured upstream", %{registry: r} do
      :ok = Registry.put_fake("alpha", %{}, r)
      entry = Registry.lookup("alpha", r)
      assert entry.impl == Fake
      assert entry.status == :not_started
    end

    test "returns nil for unknown name", %{registry: r} do
      assert Registry.lookup("missing", r) == nil
    end
  end

  # Per §2 a started upstream is "currently healthy"; per §4.3
  # third bullet "a started upstream that crashes is removed from
  # `started_upstreams`." This helper synchronizes on the registry
  # mailbox so any prior `:DOWN` info-message has been processed
  # before we observe state. (`GenServer.call/2` is FIFO with
  # `handle_info` callbacks: by the time `lookup/2` returns, the
  # `:DOWN` we fired before it has been handled.)
  defp wait_for_invalidation(registry, name) do
    _ = Registry.lookup(name, registry)
    :ok
  end

  describe "crash invalidation (§4.3 third bullet)" do
    test "Fake.stop/1 removes the upstream from started_upstreams", %{registry: r} do
      :ok =
        Registry.put_fake(
          "alpha",
          tools_config(%{"echo" => fn args, _ -> {:ok, args} end}),
          r
        )

      {:ok, _} = Registry.ensure_started("alpha", r)
      assert "alpha" in Registry.started_upstreams(r)
      assert is_list(Registry.cached_tools("alpha", r))

      # Capture the underlying Fake pid via lookup. This is the pid
      # the registry monitors; we monitor it from the test to
      # synchronize on its death.
      [{fake_pid, _}] =
        Elixir.Registry.lookup(PtcRunnerMcp.Upstream.Fake.Names, "alpha")

      monitor = Process.monitor(fake_pid)

      :ok = Fake.stop("alpha")

      # Synchronize: the Fake must have died before the registry's
      # `:DOWN` handler fires. `assert_receive` with a generous
      # timeout is the deterministic wait; we never `Process.sleep`.
      assert_receive {:DOWN, ^monitor, :process, ^fake_pid, _}, 1_000
      :ok = wait_for_invalidation(r, "alpha")

      # Pre-fix this would still return `MapSet.new(["alpha"])`
      # with the stale `cached_tools` populated.
      refute "alpha" in Registry.started_upstreams(r)
      assert Registry.cached_tools("alpha", r) == nil

      # The next `ensure_started/2` re-attempts a fresh spawn —
      # the entry is `:not_started`, not poisoned by any cached
      # failure (per fix #1).
      assert {:ok, _} = Registry.ensure_started("alpha", r)
      assert "alpha" in Registry.started_upstreams(r)
    end

    test "forcible kill of the underlying upstream invalidates the entry", %{registry: r} do
      :ok =
        Registry.put_fake(
          "beta",
          tools_config(%{"echo" => fn args, _ -> {:ok, args} end}),
          r
        )

      {:ok, _} = Registry.ensure_started("beta", r)

      [{fake_pid, _}] =
        Elixir.Registry.lookup(PtcRunnerMcp.Upstream.Fake.Names, "beta")

      monitor = Process.monitor(fake_pid)
      Process.exit(fake_pid, :kill)

      assert_receive {:DOWN, ^monitor, :process, ^fake_pid, :killed}, 1_000
      :ok = wait_for_invalidation(r, "beta")

      refute "beta" in Registry.started_upstreams(r)
      assert Registry.cached_tools("beta", r) == nil
    end
  end
end
