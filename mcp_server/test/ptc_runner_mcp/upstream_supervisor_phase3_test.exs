defmodule PtcRunnerMcp.UpstreamSupervisorPhase3Test do
  @moduledoc """
  Phase 3 eager-start-at-boot tests for `Upstream.Supervisor`.

  Spec: `Plans/ptc-runner-mcp-aggregator.md` §12.5.1.

  ## Scope

    * Configured upstreams reach `:started` BEFORE control returns
      from the eager-start step that runs after
      `Upstream.Supervisor.start_link/1`. The catalog rendered from
      `Connection.cached_tools/1` immediately after the eager-start
      pass reflects the configured tools.
    * A failed eager-start is non-fatal: the offending upstream
      renders as "(unavailable at startup)" in the catalog, and a
      fresh `ensure_started/1` after boot succeeds (per §4.3 backoff).

  ## Test shape

  We do NOT spin up the full `Upstream.Supervisor` tree because
  `test_helper.exs` already started the global `Fake.Names`,
  `Stdio.Names`, `Connection.Names` Registries and the shared
  `Upstream.DynamicSupervisor`. Booting another `Upstream.Supervisor`
  on top would collide on those globally-registered names. Instead
  each test:

    1. Starts an isolated `Upstream.Registry` GenServer under a
       per-test name (the `:upstreams` option triggers Connection
       creation via the shared DynamicSupervisor).
    2. Calls `Upstream.Supervisor.eager_start_upstreams/1` against
       that Registry — the same kernel the production supervisor
       runs after its own `start_link/1`.
    3. Asserts the post-eager-start state of each Connection.

  This is the same `:upstreams`-bootstrap → eager-start sequence
  production runs; the `Supervisor.start_link/1` wrapping is just
  the supervision-tree layout, which `tools_phase0_test.exs` and
  `upstream_supervisor_phase21_test.exs` already cover.
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Agentic.CapabilitySummary
  alias PtcRunnerMcp.AgenticConfig
  alias PtcRunnerMcp.Log
  alias PtcRunnerMcp.Upstream.Catalog
  alias PtcRunnerMcp.Upstream.Connection
  alias PtcRunnerMcp.Upstream.Fake
  alias PtcRunnerMcp.Upstream.Registry, as: UpstreamRegistry
  alias PtcRunnerMcp.Upstream.Supervisor, as: UpstreamSupervisor

  setup do
    reg_name = :"phase3-reg-#{System.unique_integer([:positive])}"
    original_agentic = AgenticConfig.get()
    original_log_level = Log.level()
    Catalog.clear_frozen()

    on_exit(fn ->
      stop_registry(reg_name)
      Catalog.clear_frozen()
      AgenticConfig.set(original_agentic)
      Log.set_level(original_log_level)
    end)

    {:ok, reg_name: reg_name}
  end

  describe "eager-start at boot (§12.5.1)" do
    test "configured Fakes reach :started after eager-start", %{reg_name: reg_name} do
      a = unique_name("alpha")
      b = unique_name("beta")

      upstreams = [
        %{name: a, impl: Fake, config: fake_config()},
        %{name: b, impl: Fake, config: fake_config()}
      ]

      {:ok, _pid} = UpstreamRegistry.start_link(name: reg_name, upstreams: upstreams)

      :ok =
        UpstreamSupervisor.eager_start_upstreams(
          upstreams: upstreams,
          registry_name: reg_name
        )

      pid_a = UpstreamRegistry.connection_for(a, reg_name)
      pid_b = UpstreamRegistry.connection_for(b, reg_name)

      assert is_pid(pid_a)
      assert is_pid(pid_b)
      assert Connection.started?(pid_a)
      assert Connection.started?(pid_b)
      assert is_list(Connection.cached_tools(pid_a))
      assert is_list(Connection.cached_tools(pid_b))
    end

    test "catalog rendered immediately after eager-start includes all upstreams' tools", %{
      reg_name: reg_name
    } do
      a = unique_name("alpha")
      b = unique_name("beta")

      upstreams = [
        %{name: a, impl: Fake, config: fake_config()},
        %{name: b, impl: Fake, config: fake_config()}
      ]

      {:ok, _pid} = UpstreamRegistry.start_link(name: reg_name, upstreams: upstreams)

      :ok =
        UpstreamSupervisor.eager_start_upstreams(
          upstreams: upstreams,
          registry_name: reg_name
        )

      catalog = Catalog.render(reg_name)

      assert catalog =~ "#{a}:"
      assert catalog =~ "#{b}:"
      assert catalog =~ "ping(msg: string)"
    end

    test "failed eager-start renders '(unavailable at startup)' but proceeds", %{
      reg_name: reg_name
    } do
      good_name = unique_name("good")
      bad_name = unique_name("bad")

      upstreams = [
        %{name: good_name, impl: Fake, config: fake_config()},
        %{
          name: bad_name,
          impl: Fake,
          config: %{init_result: {:error, :upstream_unavailable, "boot failure injected"}}
        }
      ]

      {:ok, _pid} = UpstreamRegistry.start_link(name: reg_name, upstreams: upstreams)

      # Eager-start MUST complete despite one upstream's start_link
      # failing — the spec requires non-fatal degradation.
      :ok =
        UpstreamSupervisor.eager_start_upstreams(
          upstreams: upstreams,
          registry_name: reg_name
        )

      good_pid = UpstreamRegistry.connection_for(good_name, reg_name)
      bad_pid = UpstreamRegistry.connection_for(bad_name, reg_name)

      assert is_pid(good_pid)
      assert is_pid(bad_pid)
      assert Connection.started?(good_pid)
      refute Connection.started?(bad_pid)

      catalog = Catalog.render(reg_name)
      assert catalog =~ "#{good_name}:\n  ping(msg: string)"
      assert catalog =~ "#{bad_name}:\n  (unavailable at startup)"
    end

    test "failed-at-boot upstream is re-attempted after boot (§4.3 first bullet)", %{
      reg_name: reg_name
    } do
      bad_name = unique_name("transient")

      upstreams = [
        %{
          name: bad_name,
          impl: Fake,
          config: %{init_result: {:error, :upstream_unavailable, "transient at boot"}}
        }
      ]

      {:ok, _pid} = UpstreamRegistry.start_link(name: reg_name, upstreams: upstreams)

      :ok =
        UpstreamSupervisor.eager_start_upstreams(
          upstreams: upstreams,
          registry_name: reg_name
        )

      pid = UpstreamRegistry.connection_for(bad_name, reg_name)
      refute Connection.started?(pid)

      # Phase 3's eager-start does NOT arm the recovery-backoff window
      # for init-time failures (§4.3 third bullet covers crashes only),
      # so the next `ensure_started/1` retries fresh. Operator fixes
      # the upstream — model that with put_fake replacing the broken
      # config with a healthy one.
      :ok = UpstreamRegistry.put_fake(bad_name, fake_config(), reg_name)

      new_pid = UpstreamRegistry.connection_for(bad_name, reg_name)
      assert is_pid(new_pid)
      assert {:ok, _} = Connection.ensure_started(new_pid)
      assert Connection.started?(new_pid)
    end

    test "no-upstreams config → eager-start is a no-op", %{reg_name: reg_name} do
      {:ok, _pid} = UpstreamRegistry.start_link(name: reg_name, upstreams: [])

      assert :ok =
               UpstreamSupervisor.eager_start_upstreams(
                 upstreams: [],
                 registry_name: reg_name
               )

      assert UpstreamRegistry.configured_count(reg_name) == 0
      assert Catalog.render(reg_name) == ""
    end
  end

  describe "freeze_catalog/1 (§12.5 'rebuilt only on PtcRunner restart')" do
    test "freezes the catalog after eager_start; frozen content matches a fresh render at the same moment",
         %{reg_name: reg_name} do
      a = unique_name("alpha")
      b = unique_name("beta")

      upstreams = [
        %{name: a, impl: Fake, config: fake_config()},
        %{name: b, impl: Fake, config: fake_config()}
      ]

      {:ok, _pid} = UpstreamRegistry.start_link(name: reg_name, upstreams: upstreams)
      assert Catalog.frozen() == ""

      :ok =
        UpstreamSupervisor.eager_start_upstreams(
          upstreams: upstreams,
          registry_name: reg_name
        )

      :ok =
        UpstreamSupervisor.freeze_catalog(
          upstreams: upstreams,
          registry_name: reg_name
        )

      # The frozen string MUST be byte-equal to a fresh render
      # against the same routing Registry at the same moment —
      # this is the contract `Tools.tool_entry/0` relies on.
      assert Catalog.frozen() == Catalog.render(reg_name)
      assert Catalog.frozen() =~ "#{a}:"
      assert Catalog.frozen() =~ "#{b}:"
    end

    test "logs generated agentic capability summary metadata after catalog freeze", %{
      reg_name: reg_name
    } do
      a = unique_name("alpha")

      upstreams = [
        %{name: a, impl: Fake, config: fake_config()}
      ]

      Log.set_level(:info)

      :ok =
        AgenticConfig.set(%{
          AgenticConfig.defaults()
          | enabled: true,
            capability_summary: nil
        })

      {:ok, _pid} = UpstreamRegistry.start_link(name: reg_name, upstreams: upstreams)

      :ok =
        UpstreamSupervisor.eager_start_upstreams(
          upstreams: upstreams,
          registry_name: reg_name
        )

      log =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          :ok =
            UpstreamSupervisor.freeze_catalog(
              upstreams: upstreams,
              registry_name: reg_name
            )
        end)

      summary = CapabilitySummary.from_frozen()
      decoded = Jason.decode!(String.trim(log))

      assert decoded["event"] == "agentic_capability_summary"
      assert decoded["fields"]["source"] == "auto"
      assert decoded["fields"]["bytes"] == byte_size(summary)

      assert decoded["fields"]["hash"] ==
               :crypto.hash(:sha256, summary) |> Base.encode16(case: :lower)

      refute log =~ "ping"
    end

    test "does not log generated capability summary metadata when override is configured", %{
      reg_name: reg_name
    } do
      a = unique_name("alpha")

      upstreams = [
        %{name: a, impl: Fake, config: fake_config()}
      ]

      Log.set_level(:info)

      :ok =
        AgenticConfig.set(%{
          AgenticConfig.defaults()
          | enabled: true,
            capability_summary: "operator summary"
        })

      {:ok, _pid} = UpstreamRegistry.start_link(name: reg_name, upstreams: upstreams)

      :ok =
        UpstreamSupervisor.eager_start_upstreams(
          upstreams: upstreams,
          registry_name: reg_name
        )

      log =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          :ok =
            UpstreamSupervisor.freeze_catalog(
              upstreams: upstreams,
              registry_name: reg_name
            )
        end)

      refute log =~ "agentic_capability_summary"
    end

    test "freezes empty string for no-upstreams config", %{reg_name: reg_name} do
      {:ok, _pid} = UpstreamRegistry.start_link(name: reg_name, upstreams: [])

      :ok =
        UpstreamSupervisor.freeze_catalog(
          upstreams: [],
          registry_name: reg_name
        )

      assert Catalog.frozen() == ""
    end

    test "freeze captures (unavailable at startup) for upstreams that failed eager-start",
         %{reg_name: reg_name} do
      good_name = unique_name("good")
      bad_name = unique_name("bad")

      upstreams = [
        %{name: good_name, impl: Fake, config: fake_config()},
        %{
          name: bad_name,
          impl: Fake,
          config: %{init_result: {:error, :upstream_unavailable, "boot failure"}}
        }
      ]

      {:ok, _pid} = UpstreamRegistry.start_link(name: reg_name, upstreams: upstreams)

      :ok =
        UpstreamSupervisor.eager_start_upstreams(
          upstreams: upstreams,
          registry_name: reg_name
        )

      :ok =
        UpstreamSupervisor.freeze_catalog(
          upstreams: upstreams,
          registry_name: reg_name
        )

      frozen = Catalog.frozen()
      assert frozen =~ "#{good_name}:\n  ping(msg: string)"
      assert frozen =~ "#{bad_name}:\n  (unavailable at startup)"
    end
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp fake_config do
    %{
      tools: %{
        "ping" =>
          {%{
             name: "ping",
             input_schema: %{
               "type" => "object",
               "properties" => %{"msg" => %{"type" => "string"}},
               "required" => ["msg"]
             },
             description: "Ping"
           }, fn _, _ -> {:ok, "pong"} end}
      }
    }
  end

  defp stop_registry(reg_name) do
    case Process.whereis(reg_name) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :shutdown)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          2_000 -> :ok
        end
    end
  end
end
