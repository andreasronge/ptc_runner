defmodule PtcRunner.Kernel.DoctorPreflightTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.DoctorPlan
  alias PtcRunner.Kernel.DoctorPreflight
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.SelectionRules

  @environment %{runtime: :supported, viewer: :available}
  @timeout_ms 5_000

  test "no application means no pending work and no callback at all" do
    # Every local row is already deferred as `application_required`, and there
    # is no occurrence to check against, so phase 7 must not reach a callback.
    parent = self()
    catalog = catalog(%{"audited" => audited(parent)})

    assert {:ok, rows} = DoctorPlan.new(catalog, nil, @environment)
    assert DoctorPlan.pending(rows) == []

    assert {:ok, ^rows} = DoctorPreflight.run(rows, nil, catalog, services(), @timeout_ms)
    refute_received {:audited_local, _destination, _selection, _limits}
    assert {:ok, checks} = DoctorPlan.checks(rows)
    assert_contract(checks)
  end

  test "every occurrence of one alias is checked, in declaration order" do
    # The plan renders one row per alias, but the check is a property of an
    # occurrence: each carries its own selection and destination.
    parent = self()

    catalog =
      catalog(%{"audited" => audited(parent, destinations: [:workflow, :mission])})

    prepared = prepared(catalog, ["audited"], ["audited"])

    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment)
    assert [%{name: "provider/audited/local"}] = DoctorPlan.pending(rows)

    assert {:ok, settled} =
             DoctorPreflight.run(rows, prepared, catalog, services(), @timeout_ms)

    assert_received {:audited_local, :workflow, %{}, true}
    assert_received {:audited_local, :mission, %{}, true}
    refute_received {:audited_local, _destination, _selection, _limits}

    assert DoctorPlan.pending(settled) == []
    assert {:ok, checks} = DoctorPlan.checks(settled)

    assert %{"status" => "pass", "code" => "available"} =
             fetch_check(checks, "provider/audited/local")

    assert_contract(checks)
  end

  test "one alias row settles only after every occurrence passes" do
    # The second occurrence fails, so the row must not be settled by the first.
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
    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment)

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             DoctorPreflight.run(rows, prepared, catalog, services(), @timeout_ms)

    assert diagnostic.phase == :local_preflight
    assert diagnostic.code == :adapter_unavailable
    assert diagnostic.subject.occurrence == %{destination: :mission, index: 0}

    # Both ran; the earlier pass did not settle the row on its own.
    assert_received {:audited_local, :workflow, _workflow_selection, true}
    assert_received {:audited_local, :mission, _mission_selection, true}
  end

  test "the first failing occurrence stops the command before later ones run" do
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
    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment)

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             DoctorPreflight.run(rows, prepared, catalog, services(), @timeout_ms)

    assert diagnostic.code == :environment_unavailable
    assert diagnostic.subject.occurrence == %{destination: :workflow, index: 0}
    assert_received {:audited_local, :workflow, _selection, true}
    refute_received {:audited_local, :mission, _other_selection, _limits}
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

  test "an unknown reason or unrecognised result fails closed" do
    for refused <- [:something_new, {:ok, :surprise}, :raise, :block] do
      assert %CommandDiagnostic{phase: :internal, code: :internal_error} = refuse(refused)
    end
  end

  test "a refused check never reports provider activity" do
    # Phase 7 runs before the marker, so no audited-local outcome may claim it.
    diagnostic = refuse(:invalid_llm_model)
    refute diagnostic.provider_activity
  end

  defp refuse(reason) do
    parent = self()
    catalog = catalog(%{"audited" => audited(parent, failing: %{workflow: reason})})
    prepared = prepared(catalog, ["audited"])
    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment)

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             DoctorPreflight.run(rows, prepared, catalog, services(), 500)

    diagnostic
  end

  defp fetch_check(checks, name), do: Enum.find(checks, &(&1["name"] == name))

  defp assert_contract(checks) do
    result = %{"checks" => checks, "provider_activity" => false}
    assert CommandContract.valid_success_result?(:doctor, result)
    assert CommandContract.valid_success_semantics?(:doctor, result)
  end

  # The callback reports every occurrence it sees, so a test can prove both that
  # each one ran and that none ran twice.
  defp audited(parent, options \\ []) do
    failing = Keyword.get(options, :failing, %{})

    callback = fn selection, context, _services ->
      send(
        parent,
        {:audited_local, context.destination, selection, Map.has_key?(context, :limits)}
      )

      case Map.get(failing, context.destination) do
        nil -> :ok
        :raise -> raise "the audited-local check refused"
        :block -> Process.sleep(:infinity)
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

  defp catalog(specifications) do
    {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

    registrations =
      Map.new(specifications, fn {name, options} ->
        {:ok, descriptor} =
          ProviderDescriptor.new(
            source: :custom,
            installation_revision: "doctor-v1",
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
            local_preflight: Keyword.get(options, :local_preflight, :none)
          )

        implementation = %{
          builder: fn _selection, _context -> {:ok, %{credential_names: []}} end,
          local_preflight: Keyword.fetch!(options, :callback)
        }

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
