defmodule PtcRunner.Kernel.LocalPreflightTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.LocalPreflight
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.SelectionRules
  alias PtcRunner.TestSupport.HostBoundFixture

  @deadline_ms 5_000

  test "a run declaring no audited-local check invokes nothing" do
    catalog = catalog(%{"inert" => [local_preflight: :none]})
    prepared = prepared(catalog, ["inert"])

    assert :ok = LocalPreflight.run(prepared, catalog, services(), deadline())
    refute_received {:audited_local, _step, _name, _destination, _selection, _limits}
  end

  test "an unverified check is never invoked before provider activity" do
    # Catalog parity requires an `:unverified` declaration to register its
    # callback, so the callback is present here. Invoking it would run active
    # work in a phase whose whole contract is that no provider work has begun.
    catalog = catalog(%{"custom" => [source: :custom, local_preflight: :unverified]})
    prepared = prepared(catalog, ["custom"])

    assert is_function(catalog.implementations["custom"].local_preflight, 3)
    assert :ok = LocalPreflight.run(prepared, catalog, services(), deadline())
    refute_received {:audited_local, _step, _name, _destination, _selection, _limits}
  end

  test "every applicable occurrence is checked, in declaration order" do
    # The check is a property of an occurrence: each carries its own selection
    # and destination, so occurrences are never collapsed by alias. Traversal
    # runs workflow before mission and follows declaration order within a
    # destination.
    sequence = counter()

    catalog =
      catalog(%{
        "model" => [destination: :workflow, sequence: sequence],
        "tools-a" => [destination: :mission, sequence: sequence],
        "tools-b" => [destination: :mission, sequence: sequence]
      })

    prepared = prepared(catalog, ["model"], ["tools-a", "tools-b"])

    assert :ok = LocalPreflight.run(prepared, catalog, services(), deadline())

    assert_received {:audited_local, 1, "model", :workflow, %{}, true}
    assert_received {:audited_local, 2, "tools-a", :mission, %{}, true}
    assert_received {:audited_local, 3, "tools-b", :mission, %{}, true}
    refute_received {:audited_local, _step, _name, _destination, _selection, _limits}
  end

  test "the first failing occurrence stops the step before later ones run" do
    catalog =
      catalog(%{
        "model" => [destination: :workflow, failing: :invalid_mcp_executable],
        "tools" => [destination: :mission]
      })

    prepared = prepared(catalog, ["model"], ["tools"])

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             LocalPreflight.run(prepared, catalog, services(), deadline())

    assert diagnostic.code == :environment_unavailable
    assert diagnostic.subject.occurrence == %{destination: :workflow, index: 0}
    assert_received {:audited_local, _step, "model", :workflow, _selection, true}
    refute_received {:audited_local, _later, "tools", :mission, _other, _limits}
  end

  test "a later occurrence still fails the step after an earlier one passed" do
    catalog =
      catalog(%{
        "model" => [destination: :workflow],
        "tools" => [destination: :mission, failing: :invalid_llm_model]
      })

    prepared = prepared(catalog, ["model"], ["tools"])

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             LocalPreflight.run(prepared, catalog, services(), deadline())

    assert diagnostic.phase == :local_preflight
    assert diagnostic.code == :adapter_unavailable
    assert diagnostic.subject.occurrence == %{destination: :mission, index: 0}
    assert_received {:audited_local, _first, "model", :workflow, _workflow_selection, true}
    assert_received {:audited_local, _second, "tools", :mission, _mission_selection, true}
  end

  test "an exhausted budget stops the step before any callback runs" do
    # Every occurrence spends the caller's one anchored deadline, so a step that
    # begins with nothing left never reaches a callback. A spent budget is an
    # expected operational outcome, not an internal defect.
    catalog = catalog(%{"model" => []})
    prepared = prepared(catalog, ["model"])
    expired = Deadline.new(1, System.monotonic_time(:millisecond) - 10_000)

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             LocalPreflight.run(prepared, catalog, services(), expired)

    assert diagnostic.phase == :local_preflight
    assert diagnostic.code == :local_check_timeout
    assert diagnostic.subject.occurrence == %{destination: :workflow, index: 0}
    refute diagnostic.provider_activity
    refute_received {:audited_local, _step, _name, _destination, _selection, _limits}
  end

  test "a callback that outruns the remaining budget reports the same timeout" do
    catalog = catalog(%{"model" => [failing: :block]})
    prepared = prepared(catalog, ["model"])

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             LocalPreflight.run(prepared, catalog, services(), Deadline.new(200))

    assert diagnostic.phase == :local_preflight
    assert diagnostic.code == :local_check_timeout
    assert diagnostic.subject.occurrence == %{destination: :workflow, index: 0}
    refute diagnostic.provider_activity
  end

  test "a callback cannot report the timeout code itself" do
    # The step reports an exhausted budget outside the reason translation, so a
    # callback claiming that reason is an unrecognised result and fails closed
    # rather than passing off a defect as an expected operational outcome.
    assert %CommandDiagnostic{phase: :internal, code: :internal_error} =
             refuse(:local_check_timeout)
  end

  test "a preparation and catalog that do not belong together are refused" do
    # Alias names are not identity: running one catalog's callback against
    # another's normalized occurrence checks declarations it never validated.
    installed = catalog(%{"shared" => [installation_revision: "installed-v1"]})
    foreign = catalog(%{"shared" => [installation_revision: "foreign-v1"]})
    prepared = prepared(foreign, ["shared"])

    assert installed.attestation != foreign.attestation

    assert {:error, %CommandDiagnostic{phase: :internal, code: :internal_error}} =
             LocalPreflight.run(prepared, installed, services(), deadline())

    refute_received {:audited_local, _step, _name, _destination, _selection, _limits}

    # The same preparation is fine against the catalog it came from, so the
    # refusal is about binding rather than the preparation itself.
    assert :ok = LocalPreflight.run(prepared, foreign, services(), deadline())
    assert_received {:audited_local, _workflow_step, "shared", :workflow, _selection, true}
  end

  test "services sealed from another host cannot check this catalog" do
    # The trio has to agree on all three sides. A host-bound catalog is checked
    # only by services its own host document sealed, and generic services carry
    # no host payload to compare at all.
    catalog = catalog(%{"model" => []})
    prepared = prepared(catalog, ["model"])

    for foreign <- [HostBoundFixture.runtime_services("other-v1"), generic_services()] do
      assert {:error, %CommandDiagnostic{phase: :internal, code: :internal_error}} =
               LocalPreflight.run(prepared, catalog, foreign, deadline())
    end

    refute_received {:audited_local, _step, _name, _destination, _selection, _limits}
  end

  test "an untrusted declaration is refused before any callback runs" do
    # `ProviderDescriptor` refuses `:audited_local` from a custom source and
    # `InstallationCatalog` refuses it without a runtime binding, so neither
    # trio below can be built through a constructor. Phase 7 revalidates what it
    # is handed rather than trusting it, and refuses the whole step: skipping
    # the untrusted occurrence would report a local check nothing verified.
    catalog = catalog(%{"model" => []})
    prepared = prepared(catalog, ["model"])

    untrusted = [
      %{catalog | descriptors: %{"model" => %{catalog.descriptors["model"] | source: :custom}}},
      %{catalog | runtime_binding: nil}
    ]

    for forged <- untrusted do
      assert {:error, %CommandDiagnostic{phase: :internal, code: :internal_error}} =
               LocalPreflight.run(prepared, forged, services(), deadline())
    end

    refute_received {:audited_local, _step, _name, _destination, _selection, _limits}
  end

  test "each local failure reason translates to its exact closed code" do
    for {reason, code} <- [
          {:invalid_compatibility_environment, :environment_unavailable},
          {:invalid_mcp_working_directory, :environment_unavailable},
          {:invalid_mcp_executable, :environment_unavailable},
          {:mcp_stdio_launcher_unavailable, :launcher_unavailable},
          {:unsupported_mcp_stdio_platform, :launcher_unavailable},
          {:invalid_llm_model, :adapter_unavailable}
        ] do
      assert %CommandDiagnostic{phase: :local_preflight, code: ^code} = refuse(reason)
    end
  end

  test "destination and selection failures keep their own declaration phase" do
    # Folding these into a local code would report a manifest error as a
    # missing local dependency.
    assert %CommandDiagnostic{phase: :provider_declaration, code: :placement_denied} =
             refuse(:provider_destination_denied)

    for reason <- [
          :invalid_mcp_selection,
          :invalid_llm_selection,
          :invalid_llm_replay_selection,
          :invalid_trace_snapshot_selection,
          :invalid_inspection_snapshot_selection
        ] do
      assert %CommandDiagnostic{phase: :provider_declaration, code: :selection_invalid} =
               refuse(reason)
    end
  end

  test "an unknown reason, unrecognised result, or raise fails closed" do
    for refused <- [:something_new, {:ok, :surprise}, :raise] do
      assert %CommandDiagnostic{phase: :internal, code: :internal_error} = refuse(refused)
    end
  end

  test "no audited-local outcome ever reports provider activity" do
    # Phase 7 runs before the marker, so nothing here may claim activity.
    refute refuse(:invalid_llm_model).provider_activity
    refute refuse(:provider_destination_denied).provider_activity
    refute refuse(:something_new).provider_activity
  end

  test "an unverified check is refused until the marker is set, then runs" do
    # The same trio, the same callback, and the marker is the only thing that
    # changes between the refusal and the call.
    catalog = catalog(%{"custom" => [source: :custom, local_preflight: :unverified]})
    prepared = prepared(catalog, ["custom"])

    assert {:error, %CommandDiagnostic{phase: :internal, code: :internal_error} = refusal} =
             LocalPreflight.run_unverified(prepared, catalog, services(), deadline())

    assert refusal.provider_activity
    refute_received {:audited_local, _step, _name, _destination, _selection, _limits}

    assert :ok = ProviderActivity.mark(prepared.provider_activity)
    assert :ok = LocalPreflight.run_unverified(prepared, catalog, services(), deadline())
    assert_received {:audited_local, _step, "custom", :workflow, %{}, true}
  end

  test "the post-marker step runs unverified checks and never audited-local ones" do
    # Applicability is derived per step, so neither can reach the other's
    # declarations however the catalog mixes them.
    catalog =
      catalog(%{
        "audited" => [destination: :workflow],
        "custom" => [destination: :mission, source: :custom, local_preflight: :unverified]
      })

    prepared = prepared(catalog, ["audited"], ["custom"])
    assert :ok = ProviderActivity.mark(prepared.provider_activity)

    assert :ok = LocalPreflight.run_unverified(prepared, catalog, services(), deadline())
    assert_received {:audited_local, _step, "custom", :mission, %{}, true}
    refute_received {:audited_local, _step, "audited", _destination, _selection, _limits}
  end

  test "an unverified failure names its exact occurrence and keeps the closed code" do
    diagnostic = refuse_unverified(:invalid_llm_model)

    assert diagnostic.phase == :local_preflight
    assert diagnostic.code == :adapter_unavailable
    assert diagnostic.subject.name == "custom"
    assert diagnostic.subject.operation == :local
    assert diagnostic.subject.occurrence == %{destination: :workflow, index: 0}
  end

  test "every unverified outcome reports provider activity" do
    # The mirror of the phase-7 assertion above. Same conditions and same codes;
    # activity is the one rendered field that must differ, because it is a fact
    # about the marker rather than about the check.
    assert refuse_unverified(:invalid_llm_model).provider_activity
    assert refuse_unverified(:provider_destination_denied).provider_activity
    assert refuse_unverified(:something_new).provider_activity
  end

  test "the local-preflight codes are admitted wherever a local check can run" do
    # Run and check render through the same unclassified run mode — `run --check`
    # is not a separate command surface — and both doctor modes reach a local
    # check of one kind or another. `validate` and `models` open no session and
    # invoke no callback, so admitting these codes there would let them report a
    # check they cannot run.
    for code <- [
          :environment_unavailable,
          :adapter_unavailable,
          :launcher_unavailable,
          :local_check_timeout
        ] do
      for mode <- [:run_unclassified, :doctor, {:doctor, :connect}] do
        assert CommandContract.diagnostic_allowed?(mode, :local_preflight, code),
               "#{inspect(mode)} must admit local_preflight/#{code}"
      end

      for mode <- [:validate, :models] do
        refute CommandContract.diagnostic_allowed?(mode, :local_preflight, code),
               "#{inspect(mode)} must not admit local_preflight/#{code}"
      end
    end
  end

  defp refuse(reason) do
    catalog = catalog(%{"model" => [failing: reason]})
    prepared = prepared(catalog, ["model"])

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             LocalPreflight.run(prepared, catalog, services(), deadline())

    diagnostic
  end

  defp refuse_unverified(reason) do
    catalog =
      catalog(%{"custom" => [source: :custom, local_preflight: :unverified, failing: reason]})

    prepared = prepared(catalog, ["custom"])
    assert :ok = ProviderActivity.mark(prepared.provider_activity)

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             LocalPreflight.run_unverified(prepared, catalog, services(), deadline())

    diagnostic
  end

  defp deadline, do: Deadline.new(@deadline_ms)

  # Each occurrence runs in its own bounded worker, so their messages have no
  # inter-sender ordering. A shared counter makes the executor's sequential
  # traversal observable instead of assumed.
  defp counter, do: :atomics.new(1, signed: false)

  defp step(nil), do: 0
  defp step(sequence), do: :atomics.add_get(sequence, 1, 1)

  # The callback reports every occurrence it sees, so a test can prove both that
  # each one ran and that none ran twice. The phase-7 context carries the
  # occurrence rather than the alias, so the name is closed over from the
  # registration instead.
  defp callback(parent, name, options) do
    failing = Keyword.get(options, :failing)
    sequence = Keyword.get(options, :sequence)

    fn selection, context, _services ->
      send(
        parent,
        {:audited_local, step(sequence), name, context.destination, selection,
         Map.has_key?(context, :limits)}
      )

      case failing do
        nil -> :ok
        :raise -> raise "the audited-local check refused"
        :block -> receive do: (:never -> :ok)
        {:ok, _value} = unrecognised -> unrecognised
        reason -> {:error, reason}
      end
    end
  end

  # The binding is a pure function of the host document, so services sealed from
  # the same document are interchangeable and one sealed elsewhere is not.
  defp services, do: HostBoundFixture.runtime_services()

  defp generic_services do
    {:ok, services} =
      ProviderRuntimeServices.new(credential_resolver: fn _names -> {:ok, %{}} end)

    services
  end

  # Phase 7 runs only host-installed audited-local checks, so every fixture is a
  # shipped source in a host-bound catalog. `:llm` and `:mcp` are the two
  # sources the shipped recipes declare audited-local, and they are also the
  # workflow and mission sides of an occurrence list. An alias declares one
  # destination and a manifest may name it once per destination, so an
  # audited-local alias has exactly one occurrence.
  defp catalog(specifications) do
    parent = self()
    {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

    registrations =
      Map.new(specifications, fn {name, options} ->
        mode = Keyword.get(options, :local_preflight, :audited_local)

        {:ok, descriptor} =
          rules
          |> descriptor_options(
            Keyword.get(options, :destination, :workflow),
            Keyword.get(options, :source, :shipped)
          )
          |> Keyword.merge(
            installation_revision: Keyword.get(options, :installation_revision, "doctor-v1"),
            local_preflight: mode
          )
          |> ProviderDescriptor.new()

        builder = fn _selection, _context -> {:ok, %{credential_names: []}} end
        probe = fn _selection, _context, _services -> :ok end

        implementation =
          %{builder: builder}
          |> maybe_put(mode != :none, :local_preflight, callback(parent, name, options))
          |> maybe_put(descriptor.connectivity_mode == :probe, :connectivity_probe, probe)

        {name, %{descriptor: descriptor, implementation: implementation, authority: nil}}
      end)

    {:ok, catalog} =
      InstallationCatalog.new(registrations, runtime_binding: services().runtime_binding)

    on_exit(fn -> InstallationCatalog.close(catalog) end)
    catalog
  end

  defp maybe_put(implementation, false, _key, _value), do: implementation
  defp maybe_put(implementation, true, key, value), do: Map.put(implementation, key, value)

  defp descriptor_options(rules, destination, source) do
    base = [
      credential_names: [],
      authorization_mode: :none,
      data_class: :normal,
      accepts_data: [:normal],
      requires: [],
      provides: [],
      selection_validation: :declarative,
      selection_rules: rules,
      authority_fingerprint: nil
    ]

    Keyword.merge(base, shape(destination, source))
  end

  defp shape(:workflow, :shipped),
    do: [
      source: :llm,
      destinations: [:workflow],
      workflow_llm?: true,
      connectivity_mode: :probe,
      probe_effect: :metadata
    ]

  defp shape(:mission, :shipped),
    do: [
      source: :mcp,
      destinations: [:mission],
      workflow_llm?: false,
      connectivity_mode: :acquisition,
      probe_effect: nil
    ]

  defp shape(destination, :custom),
    do:
      destination
      |> shape(:shipped)
      |> Keyword.merge(source: :custom, connectivity_mode: :none, probe_effect: nil)

  defp prepared(catalog, workflow, mission \\ []) do
    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{
        "workflow" => Enum.map(workflow, &%{"name" => &1, "config" => %{}}),
        "mission" => Enum.map(mission, &%{"name" => &1, "config" => %{}})
      }
    }

    documents = %{
      "ptc.json" => Jason.encode!(manifest),
      "main.clj" => "(ns app) (defn run [_input] (return {\"answer\" 42}))"
    }

    {:ok, request} =
      ApplicationPackage.request_memory("ptc.json", documents, result_projection: :json)

    {:ok, prepared} = RunCoordinator.prepare(request, catalog)
    on_exit(fn -> PreparedRun.close(prepared) end)
    prepared
  end
end
