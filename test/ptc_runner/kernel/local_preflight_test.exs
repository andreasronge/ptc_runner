defmodule PtcRunner.Kernel.LocalPreflightTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.LocalPreflight
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.SelectionRules

  @deadline_ms 5_000

  test "a run declaring no audited-local check invokes nothing" do
    parent = self()
    catalog = catalog(%{"inert" => [local_preflight: :none, callback: reporter(parent)]})
    prepared = prepared(catalog, ["inert"])

    assert :ok = LocalPreflight.run(prepared, catalog, services(), deadline())
    refute_received {:audited_local, _step, _destination, _selection, _limits}
  end

  test "every occurrence of one alias is checked, in declaration order" do
    # The check is a property of an occurrence: each carries its own selection
    # and destination, so occurrences are never collapsed by alias.
    parent = self()

    catalog =
      catalog(%{
        "audited" => audited(parent, destinations: [:workflow, :mission], sequence: counter())
      })

    prepared = prepared(catalog, ["audited"], ["audited"])

    assert :ok = LocalPreflight.run(prepared, catalog, services(), deadline())

    assert_received {:audited_local, 1, :workflow, %{}, true}
    assert_received {:audited_local, 2, :mission, %{}, true}
    refute_received {:audited_local, _step, _destination, _selection, _limits}
  end

  test "the first failing occurrence stops the step before later ones run" do
    parent = self()

    catalog =
      catalog(%{
        "audited" =>
          audited(parent,
            destinations: [:workflow, :mission],
            failing: %{workflow: :invalid_mcp_executable}
          )
      })

    prepared = prepared(catalog, ["audited"], ["audited"])

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             LocalPreflight.run(prepared, catalog, services(), deadline())

    assert diagnostic.code == :environment_unavailable
    assert diagnostic.subject.occurrence == %{destination: :workflow, index: 0}
    assert_received {:audited_local, _workflow_step, :workflow, _selection, true}
    refute_received {:audited_local, _mission_step, :mission, _other, _limits}
  end

  test "a later occurrence still fails the step after an earlier one passed" do
    parent = self()

    catalog =
      catalog(%{
        "audited" =>
          audited(parent,
            destinations: [:workflow, :mission],
            failing: %{mission: :invalid_llm_model}
          )
      })

    prepared = prepared(catalog, ["audited"], ["audited"])

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             LocalPreflight.run(prepared, catalog, services(), deadline())

    assert diagnostic.phase == :local_preflight
    assert diagnostic.code == :adapter_unavailable
    assert diagnostic.subject.occurrence == %{destination: :mission, index: 0}
    assert_received {:audited_local, _first, :workflow, _workflow_selection, true}
    assert_received {:audited_local, _second, :mission, _mission_selection, true}
  end

  test "an exhausted budget stops the step before any callback runs" do
    # Every occurrence spends the caller's one anchored deadline, so a step that
    # begins with nothing left never reaches a callback.
    parent = self()
    catalog = catalog(%{"audited" => audited(parent)})
    prepared = prepared(catalog, ["audited"])
    expired = Deadline.new(1, System.monotonic_time(:millisecond) - 10_000)

    assert {:error, %CommandDiagnostic{phase: :internal, code: :internal_error}} =
             LocalPreflight.run(prepared, catalog, services(), expired)

    refute_received {:audited_local, _step, _destination, _selection, _limits}
  end

  test "a callback that outruns the remaining budget fails closed" do
    parent = self()
    catalog = catalog(%{"audited" => audited(parent, failing: %{workflow: :block})})
    prepared = prepared(catalog, ["audited"])

    assert {:error, %CommandDiagnostic{phase: :internal, code: :internal_error}} =
             LocalPreflight.run(prepared, catalog, services(), Deadline.new(200))
  end

  test "a preparation and catalog that do not belong together are refused" do
    # Alias names are not identity: running one catalog's callback against
    # another's normalized occurrence checks declarations it never validated.
    parent = self()
    installed = catalog(%{"shared" => audited(parent, installation_revision: "installed-v1")})
    foreign = catalog(%{"shared" => audited(parent, installation_revision: "foreign-v1")})
    prepared = prepared(foreign, ["shared"])

    assert installed.attestation != foreign.attestation

    assert {:error, %CommandDiagnostic{phase: :internal, code: :internal_error}} =
             LocalPreflight.run(prepared, installed, services(), deadline())

    refute_received {:audited_local, _step, _destination, _selection, _limits}

    # The same preparation is fine against the catalog it came from, so the
    # refusal is about binding rather than the preparation itself.
    assert :ok = LocalPreflight.run(prepared, foreign, services(), deadline())
    assert_received {:audited_local, _workflow_step, :workflow, _selection, true}
  end

  test "runtime services bound to a host cannot check an unbound catalog" do
    # The trio has to agree on all three sides: services carrying a host binding
    # belong to that host's catalog, not to a custom one that never had it.
    parent = self()
    catalog = catalog(%{"audited" => audited(parent)})
    prepared = prepared(catalog, ["audited"])

    assert {:error, %CommandDiagnostic{phase: :internal, code: :internal_error}} =
             LocalPreflight.run(prepared, catalog, host_bound_services(), deadline())

    refute_received {:audited_local, _step, _destination, _selection, _limits}
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

  defp refuse(reason) do
    parent = self()
    catalog = catalog(%{"audited" => audited(parent, failing: %{workflow: reason})})
    prepared = prepared(catalog, ["audited"])

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             LocalPreflight.run(prepared, catalog, services(), deadline())

    diagnostic
  end

  defp deadline, do: Deadline.new(@deadline_ms)

  defp reporter(parent) do
    fn selection, context, _services ->
      send(
        parent,
        {:audited_local, 0, context.destination, selection, Map.has_key?(context, :limits)}
      )

      :ok
    end
  end

  # Each occurrence runs in its own bounded worker, so their messages have no
  # inter-sender ordering. A shared counter makes the executor's sequential
  # traversal observable instead of assumed.
  defp counter, do: :atomics.new(1, signed: false)

  defp step(nil), do: 0
  defp step(sequence), do: :atomics.add_get(sequence, 1, 1)

  # The callback reports every occurrence it sees, so a test can prove both that
  # each one ran and that none ran twice.
  defp audited(parent, options \\ []) do
    failing = Keyword.get(options, :failing, %{})

    sequence = Keyword.get(options, :sequence)

    callback = fn selection, context, _services ->
      send(
        parent,
        {:audited_local, step(sequence), context.destination, selection,
         Map.has_key?(context, :limits)}
      )

      case Map.get(failing, context.destination) do
        nil -> :ok
        :raise -> raise "the audited-local check refused"
        :block -> receive do: (:never -> :ok)
        {:ok, _value} = unrecognised -> unrecognised
        reason -> {:error, reason}
      end
    end

    Keyword.merge(options, local_preflight: :audited_local, callback: callback)
  end

  defp services do
    {:ok, services} =
      ProviderRuntimeServices.new(credential_resolver: fn _names -> {:ok, %{}} end)

    services
  end

  defp host_bound_services do
    document = %{
      "install" => %{
        "history" => %{
          "source" => "ptc_trace_snapshot",
          "installation_revision" => "history-v1",
          "directory" => "traces"
        }
      }
    }

    {:ok, decoded} = HostConfig.decode(document, "/tmp")

    host =
      struct!(HostConfig,
        path: "/tmp/ptc-host.json",
        directory: "/tmp",
        runtime: decoded.runtime,
        limits: decoded.limits,
        credentials: decoded.credentials,
        install: decoded.install
      )

    {:ok, services} = HostInstallation.runtime_services(host)
    services
  end

  defp catalog(specifications) do
    {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

    registrations =
      Map.new(specifications, fn {name, options} ->
        mode = Keyword.get(options, :local_preflight, :audited_local)

        {:ok, descriptor} =
          ProviderDescriptor.new(
            source: :custom,
            installation_revision: Keyword.get(options, :installation_revision, "doctor-v1"),
            credential_names: [],
            authorization_mode: :none,
            data_class: :normal,
            accepts_data: [:normal],
            requires: [],
            provides: [],
            destinations: Keyword.get(options, :destinations, [:workflow]),
            workflow_llm?: false,
            connectivity_mode: :none,
            probe_effect: nil,
            selection_validation: :declarative,
            selection_rules: rules,
            authority_fingerprint: nil,
            local_preflight: mode
          )

        builder = fn _selection, _context -> {:ok, %{credential_names: []}} end

        implementation =
          if mode == :none,
            do: %{builder: builder},
            else: %{builder: builder, local_preflight: Keyword.fetch!(options, :callback)}

        {name, %{descriptor: descriptor, implementation: implementation, authority: nil}}
      end)

    {:ok, catalog} = InstallationCatalog.new(registrations)
    on_exit(fn -> InstallationCatalog.close(catalog) end)
    catalog
  end

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
