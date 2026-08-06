defmodule PtcRunner.Kernel.ProviderConnectivityTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.ConnectivityResult
  alias PtcRunner.Kernel.ExecutionSessionOwner
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.ProviderRuntimeServices
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

    assert result == [
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

  test "the result keeps every selected occurrence rather than collapsing aliases" do
    # One alias may be selected once per destination, and each occurrence has
    # its own selection. A result that collapsed them could not say which
    # occurrence was reached, and the doctor plan that groups by alias would be
    # grouping something already lost.
    %{prepared: prepared, execution: execution} =
      fixture(%{"shared" => [destination: :both], "later" => [destination: :mission]})

    assert {:ok, result} = connect(prepared, execution)

    # Workflow before mission, then manifest order within a destination. The
    # same alias appears twice with different sites and is never merged.
    assert Enum.map(result, &{&1.name, &1.destination, &1.index}) == [
             {"shared", :workflow, 0},
             {"later", :mission, 0},
             {"shared", :mission, 1}
           ]

    assert ConnectivityResult.covers?(result, prepared)
    assert Enum.all?(result, &(&1.outcome == :skipped))
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
                   &notifier/1,
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

  defp connect(prepared, execution),
    do: RunCoordinator.connect(prepared, authority(), execution, &notifier/1)

  defp notifier(_url), do: flunk("connectivity must not notify authorization")

  defp authority do
    {:ok, authority} = PublicationAuthority.new([])
    authority
  end

  # Custom declarations keep this file about the connectivity operation: they
  # need no host document, and their `:none` mode is the case this commit
  # implements. `:probe` and `:acquisition` fixtures exist only to prove their
  # callbacks stay unreachable.
  defp fixture(specifications) do
    parent = self()
    {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

    registrations =
      Map.new(specifications, fn {name, options} ->
        mode = Keyword.get(options, :connectivity_mode, :none)

        {:ok, descriptor} =
          ProviderDescriptor.new(
            source: :custom,
            installation_revision: Keyword.get(options, :revision, "connect-v1"),
            credential_names: [],
            authorization_mode: :none,
            data_class: :normal,
            accepts_data: [:normal],
            requires: [],
            provides: [],
            destinations: destinations(Keyword.fetch!(options, :destination)),
            workflow_llm?: false,
            connectivity_mode: mode,
            probe_effect: if(mode == :probe, do: :metadata),
            selection_validation: :declarative,
            selection_rules: rules,
            authority_fingerprint: nil,
            local_preflight: :none
          )

        {name,
         %{
           descriptor: descriptor,
           implementation: implementation(parent, name, mode),
           authority: nil
         }}
      end)

    {:ok, catalog} = InstallationCatalog.new(registrations)
    {:ok, services} = ProviderRuntimeServices.new()
    {:ok, execution} = ProviderExecution.new(catalog, services, [])

    prepared = prepared(catalog, specifications)
    on_exit(fn -> InstallationCatalog.close(catalog) end)

    %{prepared: prepared, catalog: catalog, execution: execution}
  end

  defp destinations(:both), do: [:workflow, :mission]
  defp destinations(destination), do: [destination]

  defp implementation(parent, name, mode) do
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

    implementation = %{builder: builder}

    if mode == :probe do
      Map.put(implementation, :connectivity_probe, fn _selection, _context, _services ->
        send(parent, {:probe_invoked, name})
        :ok
      end)
    else
      implementation
    end
  end

  defp prepared(catalog, specifications) do
    manifest = %{
      "version" => 1,
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

    {:ok, request} =
      ApplicationPackage.request_memory("ptc.json", documents, result_projection: :json)

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
