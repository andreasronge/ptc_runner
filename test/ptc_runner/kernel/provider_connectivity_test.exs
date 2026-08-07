defmodule PtcRunner.Kernel.ProviderConnectivityTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.ConnectivityResult
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.ExecutionSessionOwner
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActiveSession
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.SelectionRules
  alias PtcRunner.TestSupport.HostBoundFixture

  test "a selection needing no connectivity completes without acquiring or evaluating" do
    # `RunBuilder.execute_built/1` can only answer with an execution outcome, so
    # a result shaped like this one is evidence the workflow was never
    # evaluated, and the untouched builder is evidence nothing was acquired.
    %{prepared: prepared, execution: execution} = fixture(%{"inert" => [destination: :workflow]})

    assert {:ok, result} = connect(prepared, execution)

    assert ConnectivityResult.entries(result) == [
             %{
               name: "inert",
               destination: :workflow,
               index: 0,
               mode: :none,
               outcome: :skipped
             }
           ]

    refute_received {:builder_invoked, _name}
    refute_received {:probe_invoked, _name}
  end

  test "a run over the same declaration does acquire it" do
    # The contrast is what makes the assertion above mean something: the builder
    # is reachable from this fixture, and connectivity is why it stays untouched.
    %{prepared: prepared, execution: execution} = fixture(%{"inert" => [destination: :workflow]})

    assert {:ok, _outcome} =
             RunCoordinator.execute(prepared, authority(), execution, fn _url ->
               flunk("ordinary execution must not notify authorization")
             end)

    assert_received {:builder_invoked, "inert"}
  end

  test "activity is marked before connectivity completes" do
    # Connectivity runs behind the phase-8 marker like a run, so anything that
    # fails inside the completion reports activity true. The marker itself is
    # not readable afterwards — the activity owner stops with the operation —
    # so the diagnostic is the observation, and it is also the contract-visible
    # one. Phase 7 failing false is asserted in the local-preflight regressions.
    %{prepared: prepared, execution: execution} =
      fixture(%{"reachable" => [destination: :workflow, connectivity_mode: :probe]})

    assert {:error, %CommandDiagnostic{} = diagnostic} = connect(prepared, execution)
    assert diagnostic.provider_activity
  end

  test "connectivity anchors its own clock instead of inheriting the run's" do
    # The manifest narrows the run to a second while the host keeps ten for
    # connectivity, so a connect that inherited the run clock would come out
    # shorter and a connect that merely took the smaller of the two would too.
    %{prepared: prepared, catalog: catalog} =
      fixture(%{"inert" => [destination: :workflow]}, run_duration_ms: 1_000)

    assert :ok = ProviderActivity.mark(prepared.provider_activity)
    limits = prepared.request.package.limits
    assert limits.run_duration_ms == 1_000
    assert limits.doctor_connectivity_timeout_ms == 10_000

    assert connect_remaining = begin_remaining(prepared, catalog, :connect)
    assert run_remaining = begin_remaining(prepared, catalog, :run)

    assert connect_remaining > limits.run_duration_ms
    assert connect_remaining <= limits.doctor_connectivity_timeout_ms
    assert run_remaining <= limits.run_duration_ms
  end

  test "the connectivity budget, not the run's, bounds work inside the operation" do
    # The installed connectivity budget is 100ms while the run clock keeps its
    # default, so a validator that burns 250ms survives a run and cannot survive
    # a connect. Its own `selection_validation_timeout_ms` is far larger, which
    # is what makes the operation clock the thing being observed here.
    {:ok, installed} = Limits.installed(%{doctor_connectivity_timeout_ms: 100})

    %{prepared: prepared, execution: execution} =
      fixture(
        %{"slow" => [destination: :workflow, selection_validation: :active]},
        installed_limits: installed
      )

    limits = prepared.request.package.limits
    assert limits.selection_validation_timeout_ms > 250
    assert limits.run_duration_ms > 250

    assert {:error, %CommandDiagnostic{} = diagnostic} = connect(prepared, execution)
    assert diagnostic.phase == :active_preflight
    assert diagnostic.code == :selection_validation_timeout
    assert diagnostic.provider_activity
  end

  test "a session anchors only the budgets its own limits sealed" do
    # The operation names its clock; it cannot supply one. A session sealed from
    # one limit set therefore cannot be claimed with another that widened either
    # budget behind its back.
    %{prepared: prepared} = fixture(%{"inert" => [destination: :workflow]})
    limits = prepared.request.package.limits
    {:ok, session} = ProviderSession.start_active(limits, prepared.attestation)
    on_exit(fn -> ProviderSession.close(session) end)

    assert ProviderSession.compatible_limits?(session, limits)

    widened = %{
      limits
      | doctor_connectivity_timeout_ms: limits.doctor_connectivity_timeout_ms + 1
    }

    refute ProviderSession.compatible_limits?(session, widened)

    assert {:error, :provider_session_unavailable} =
             ProviderSession.begin_operation(session, :invented)
  end

  test "the result keeps every selected occurrence rather than collapsing aliases" do
    # One alias may be selected once per destination, and each occurrence has
    # its own selection. A result that collapsed them could not say which
    # occurrence was reached, and the doctor plan that groups by alias would be
    # grouping something already lost.
    %{prepared: prepared, execution: execution, catalog: catalog} =
      fixture(%{"shared" => [destination: :both], "later" => [destination: :mission]})

    assert {:ok, result} = connect(prepared, execution)

    # Workflow before mission, then manifest order within a destination. The
    # same alias appears twice with different sites and is never merged.
    entries = ConnectivityResult.entries(result)

    assert Enum.map(entries, &{&1.name, &1.destination, &1.index}) == [
             {"shared", :workflow, 0},
             {"later", :mission, 0},
             {"shared", :mission, 1}
           ]

    assert ConnectivityResult.bound_to?(result, prepared, catalog)
    assert Enum.all?(entries, &(&1.outcome == :skipped))
  end

  test "an unimplemented connectivity mode fails closed without reaching a callback" do
    # `:probe` and `:acquisition` arrive in the next commit. Until then they must
    # refuse rather than report an occurrence nothing reached, and no declared
    # callback may become reachable by accident.
    for mode <- [:probe, :acquisition] do
      %{prepared: prepared, execution: execution} =
        fixture(%{"reachable" => [destination: :workflow, connectivity_mode: mode]})

      assert {:error, %CommandDiagnostic{phase: :internal, code: :internal_error}} =
               connect(prepared, execution)

      refute_received {:probe_invoked, _name}
      refute_received {:builder_invoked, _name}
    end
  end

  test "connectivity refuses an execution that asked for authorization" do
    # A health check must never open an interactive authorization or ask a
    # human for anything. Refusing is deliberate: silently running the
    # non-interactive path would report a check that skipped what was asked for.
    %{prepared: prepared, catalog: catalog} =
      fixture(%{"authorized" => [destination: :mission, authorization_mode: :oauth]})

    {:ok, services} = ProviderRuntimeServices.new()
    {:ok, interactive} = ProviderExecution.new(catalog, services, ["authorized"])

    refute ProviderExecution.non_interactive?(interactive)
    assert {:error, :invalid_provider_execution} = connect(prepared, interactive)

    # The refusal happens before the preparation is consumed, so it stays usable.
    assert PreparedRun.valid?(prepared)
    refute_received {:builder_invoked, _name}

    # A notifier is not merely unused by connectivity: there is nowhere to pass
    # one, and the owner refuses a connect that carries it.
    assert {:error, :provider_session_required} =
             ExecutionSessionOwner.start(
               prepared,
               authority(),
               self(),
               execution_for(catalog),
               fn _url -> flunk("connectivity must not notify authorization") end,
               :connect
             )

    assert PreparedRun.valid?(prepared)
  end

  test "a preparation from another catalog is refused before the session opens" do
    # Alias names are not identity: both catalogs install "inert", and only the
    # sealed attestation distinguishes the declarations behind it.
    %{prepared: prepared} = fixture(%{"inert" => [destination: :workflow]})

    %{execution: foreign} =
      fixture(%{"inert" => [destination: :workflow, revision: "foreign-v1"]})

    assert {:error, :invalid_provider_execution} = connect(prepared, foreign)
    assert PreparedRun.valid?(prepared)
    refute_received {:builder_invoked, _name}
  end

  test "a mismatched services binding cannot even build the operation" do
    # The trio is checked before an execution value exists, so connectivity
    # never has to defend against services from another host: there is no
    # `ProviderExecution` to run.
    %{catalog: catalog} = fixture(%{"inert" => [destination: :workflow]})

    assert {:error, :invalid_provider_execution} =
             ProviderExecution.new(catalog, HostBoundFixture.runtime_services(), [])
  end

  test "connectivity has no provider-free form" do
    # It answers for selected occurrences, so without any there is nothing to
    # answer. Refusing keeps it off the provider-free completion, which builds
    # the run config connectivity never wants.
    %{prepared: prepared} = fixture(%{})

    assert {:error, :provider_session_required} =
             ExecutionSessionOwner.start(prepared, authority(), self(), nil, nil, :connect)

    assert PreparedRun.valid?(prepared)
  end

  test "a completed connectivity operation leaves no session or activity behind" do
    %{prepared: prepared, execution: execution} = fixture(%{"inert" => [destination: :workflow]})
    activity_ref = Process.monitor(prepared.provider_activity.owner)

    assert {:ok, _result} = connect(prepared, execution)
    assert :ok = PreparedRun.close(prepared)
    assert_receive {:DOWN, ^activity_ref, :process, _pid, _reason}, 5_000
  end

  test "caller death leaves no owner, worker, or activity process" do
    %{prepared: prepared, execution: execution} = fixture(%{"inert" => [destination: :workflow]})
    parent = self()

    caller =
      spawn(fn ->
        assert {:ok, owner} =
                 ExecutionSessionOwner.start(
                   prepared,
                   authority(),
                   self(),
                   execution,
                   nil,
                   :connect
                 )

        send(parent, {:owner, owner})
        send(parent, {:result, ExecutionSessionOwner.await(owner)})
      end)

    caller_ref = Process.monitor(caller)
    assert_receive {:owner, owner}, 5_000
    owner_ref = Process.monitor(ExecutionSessionOwner.pid(owner))
    activity_ref = Process.monitor(prepared.provider_activity.owner)

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 5_000
    assert_receive {:DOWN, ^owner_ref, :process, _owner_pid, _owner_reason}, 5_000
    assert_receive {:DOWN, ^activity_ref, :process, _activity_pid, _activity_reason}, 5_000

    # The result belonged to the caller that died, so nothing may deliver it here.
    refute_received {:result, _result}
  end

  defp execution_for(catalog) do
    {:ok, services} = ProviderRuntimeServices.new()
    {:ok, execution} = ProviderExecution.new(catalog, services, [])
    execution
  end

  defp begin_remaining(prepared, catalog, operation) do
    limits = prepared.request.package.limits
    {:ok, session} = ProviderSession.start_active(limits, prepared.attestation)
    on_exit(fn -> ProviderSession.close(session) end)

    {:ok, session} =
      ProviderActiveSession.begin_owned_operation(session, prepared, catalog, operation)

    session |> ProviderSession.run_deadline() |> Deadline.remaining()
  end

  defp connect(prepared, execution),
    do: RunCoordinator.connect(prepared, authority(), execution)

  defp authority do
    {:ok, authority} = PublicationAuthority.new([])
    authority
  end

  # Custom declarations keep this file about the connectivity operation: they
  # need no host document, and their `:none` mode is the case this commit
  # implements. `:probe` and `:acquisition` fixtures exist only to prove their
  # callbacks stay unreachable.
  defp fixture(specifications, options \\ []) do
    parent = self()
    installed = Keyword.get(options, :installed_limits)
    limit_overrides = Keyword.delete(options, :installed_limits)
    {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

    registrations =
      Map.new(specifications, fn {name, options} ->
        mode = Keyword.get(options, :connectivity_mode, :none)
        authority = authority(Keyword.get(options, :authorization_mode, :none))

        {:ok, descriptor} =
          ProviderDescriptor.new(
            source: :custom,
            installation_revision: Keyword.get(options, :revision, "connect-v1"),
            credential_names: [],
            authorization_mode: Keyword.get(options, :authorization_mode, :none),
            data_class: :normal,
            accepts_data: [:normal],
            requires: [],
            provides: [],
            destinations: destinations(Keyword.fetch!(options, :destination)),
            workflow_llm?: false,
            connectivity_mode: mode,
            probe_effect: if(mode == :probe, do: :metadata),
            selection_validation: Keyword.get(options, :selection_validation, :declarative),
            selection_rules: rules,
            authority_fingerprint: authority && authority.fingerprint,
            local_preflight: :none
          )

        {name,
         %{
           descriptor: descriptor,
           implementation: implementation(parent, name, options, mode),
           authority: authority
         }}
      end)

    catalog_options = if installed, do: [installed_limits: installed], else: []
    {:ok, catalog} = InstallationCatalog.new(registrations, catalog_options)
    {:ok, services} = ProviderRuntimeServices.new()
    {:ok, execution} = ProviderExecution.new(catalog, services, [])

    prepared = prepared(catalog, specifications, limit_overrides, installed)
    on_exit(fn -> InstallationCatalog.close(catalog) end)

    %{prepared: prepared, catalog: catalog, execution: execution}
  end

  # The descriptor's fingerprint comes from the authority it is bound to, so an
  # OAuth fixture cannot drift from the binding the catalog seals.
  defp authority(:none), do: nil

  defp authority(:oauth) do
    {:ok, authority} =
      Authority.from_host(
        %{
          "installation_id" => "connect-primary",
          "issuer" => "https://auth.example",
          "scope_ceiling" => ["read"],
          "default_scopes" => ["read"],
          "client" => %{
            "registration" => "pre_registered",
            "client_id" => "connect-client",
            "token_endpoint_auth_method" => "none",
            "grant_types" => ["authorization_code"],
            "loopback_redirect" => %{"host" => "127.0.0.1", "path" => "/callback"}
          }
        },
        "https://mcp.example/mcp",
        MapSet.new()
      )

    authority
  end

  defp destinations(:both), do: [:workflow, :mission]
  defp destinations(destination), do: [destination]

  # Busy-waiting rather than sleeping: the subject of these tests is a clock, so
  # the fixture has to consume real time without a timer the suite forbids.
  defp burn_until(target_ms) do
    if System.monotonic_time(:millisecond) < target_ms, do: burn_until(target_ms), else: :ok
  end

  defp implementation(parent, name, options, mode) do
    {:ok, capability} =
      Capability.new(
        name: "fixture",
        input_schema: %{"type" => "object", "additionalProperties" => false},
        callback: fn _arguments -> {:ok, %{}} end
      )

    builder = fn _selection, _context ->
      send(parent, {:builder_invoked, name})

      {:ok,
       %{
         credential_names: [],
         preflight: fn -> {:ok, fn %{} -> {:ok, capability} end} end
       }}
    end

    implementation =
      if Keyword.get(options, :authorization_mode, :none) == :oauth do
        %{
          builder: builder,
          oauth_builder: fn _selection, _context, _runtime -> {:ok, %{credential_names: []}} end
        }
      else
        %{builder: builder}
      end

    implementation =
      if Keyword.get(options, :selection_validation, :declarative) == :active do
        Map.put(implementation, :selection_validator, fn _selection, _context ->
          burn_until(System.monotonic_time(:millisecond) + 250)
          :ok
        end)
      else
        implementation
      end

    if mode == :probe do
      Map.put(implementation, :connectivity_probe, fn _selection, _context, _services ->
        send(parent, {:probe_invoked, name})
        :ok
      end)
    else
      implementation
    end
  end

  defp prepared(catalog, specifications, limit_overrides, installed) do
    manifest = %{
      "version" => 1,
      "limits" => Map.new(limit_overrides, fn {name, value} -> {Atom.to_string(name), value} end),
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{
        "workflow" => selections(specifications, :workflow),
        "mission" => selections(specifications, :mission)
      }
    }

    documents = %{
      "ptc.json" => Jason.encode!(manifest),
      "main.clj" => "(ns app) (defn run [_input] (return {\"answer\" 42}))"
    }

    options =
      if installed,
        do: [result_projection: :json, installed_limits: installed],
        else: [result_projection: :json]

    {:ok, request} = ApplicationPackage.request_memory("ptc.json", documents, options)

    {:ok, prepared} = RunCoordinator.prepare(request, catalog)
    prepared
  end

  defp selections(specifications, destination) do
    specifications
    |> Enum.filter(fn {_name, options} ->
      Keyword.fetch!(options, :destination) in [destination, :both]
    end)
    |> Enum.sort_by(fn {name, _options} -> name end)
    |> Enum.map(fn {name, _options} -> %{"name" => name, "config" => %{}} end)
  end
end
