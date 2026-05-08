defmodule PtcRunnerMcp.UpstreamRegistryPhase21Test do
  @moduledoc """
  Phase 2.1 regression test for `Upstream.Registry`'s standalone-test
  fallback path.

  Spec: `Plans/ptc-runner-mcp-aggregator.md` §12.4.1 finding #3, §5.4.

  ## Bug

  `Registry.put_fake/3` (and `start_link/1`'s bootstrap) calls
  `DynamicSupervisor.start_child/2`. The fallback in
  `start_connection/6` was written assuming an `{:error, _}` return
  when the supervisor is missing, but `DynamicSupervisor.start_child/2`
  actually exits with `:noproc`. The documented standalone-Registry
  test path (start a Registry alone, no surrounding `Upstream.Supervisor`)
  therefore crashes mid-`put_fake/2`.

  ## Discriminating signal

  Start an `Upstream.Registry` GenServer wired to a NON-EXISTENT
  DynamicSupervisor name. Call `put_fake/3` and require it to return
  `:ok` while the upstream is observable via `connection_for/2` and
  `started_upstreams/0`. Pre-fix: `DynamicSupervisor.start_child/2`
  exits `:noproc`, the Registry's `handle_call` crashes, and
  `put_fake/3` raises `:exit`.
  """
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.Upstream.Registry, as: UpstreamRegistry

  defp unique_atom(prefix), do: :"#{prefix}-#{System.unique_integer([:positive])}"

  defp start_isolated_registry!(supervisor_name) do
    name = unique_atom("phase21-reg")

    {:ok, pid} =
      UpstreamRegistry.start_link(
        name: name,
        connection_supervisor: supervisor_name,
        upstreams: []
      )

    on_exit(fn ->
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)

    name
  end

  describe "standalone Registry without surrounding Upstream.Supervisor (codex #3)" do
    test "put_fake/3 succeeds when DynamicSupervisor is absent" do
      # Wire the Registry to a DynamicSupervisor name that has NEVER
      # been started. Pre-fix: `DynamicSupervisor.start_child/2`
      # exits with `:noproc` — the Registry's `handle_call({:put_fake,
      # ...})` crashes and `put_fake/3` raises an EXIT.
      missing_sup = unique_atom("phase21-missing-dynsup")
      registry = start_isolated_registry!(missing_sup)

      # Sanity: the supervisor really is missing.
      assert Process.whereis(missing_sup) == nil

      # Discriminator 1: put_fake/3 returns :ok (does NOT exit).
      assert :ok = UpstreamRegistry.put_fake("alpha", %{}, registry)
    end

    test "after put_fake/3 the upstream is observable end-to-end" do
      # Even via the fallback, the upstream must be fully registered:
      # `connection_for/2` returns a live pid, `started_upstreams/0`
      # picks it up after a successful `ensure_started/1`, and the
      # Connection mailbox actually serves calls. This guards against
      # a "fix" that swallows the :noproc but leaves the routing
      # table inconsistent.
      missing_sup = unique_atom("phase21-missing-dynsup")
      registry = start_isolated_registry!(missing_sup)

      :ok = UpstreamRegistry.put_fake("beta", %{}, registry)

      # Connection pid is live and reachable through the routing layer.
      conn_pid = UpstreamRegistry.connection_for("beta", registry)
      assert is_pid(conn_pid)
      assert Process.alive?(conn_pid)

      # configured?/2 sees it.
      assert UpstreamRegistry.configured?("beta", registry)
      assert UpstreamRegistry.configured_count(registry) == 1

      # ensure_started/2 succeeds — the Fake impl spins up under
      # the fallback-spawned Connection.
      assert {:ok, %{duration_ms: _}} =
               UpstreamRegistry.ensure_started("beta", registry)

      # And the Registry's view of the live set picks it up.
      started = UpstreamRegistry.started_upstreams(registry)
      assert MapSet.member?(started, "beta")
    end

    test "bootstrap via :upstreams option also tolerates missing supervisor" do
      # The same fallback runs at `init/1` time when bootstrapping
      # configured upstreams. Pre-fix: `DynamicSupervisor.start_child/2`
      # exits `:noproc` from inside `init/1`, the Registry never
      # starts, and `start_link/1` returns an error.
      missing_sup = unique_atom("phase21-missing-dynsup-boot")
      name = unique_atom("phase21-reg-boot")
      assert Process.whereis(missing_sup) == nil

      assert {:ok, pid} =
               UpstreamRegistry.start_link(
                 name: name,
                 connection_supervisor: missing_sup,
                 upstreams: [
                   %{name: "gamma", impl: PtcRunnerMcp.Upstream.Fake, config: %{}}
                 ]
               )

      on_exit(fn ->
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end)

      assert UpstreamRegistry.configured?("gamma", name)
      assert is_pid(UpstreamRegistry.connection_for("gamma", name))
    end
  end
end
