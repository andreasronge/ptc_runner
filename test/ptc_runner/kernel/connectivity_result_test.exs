defmodule PtcRunner.Kernel.ConnectivityResultTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.ConnectivityResult
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.SelectionRules

  test "a result is bound to the exact preparation and catalog it answers for" do
    %{prepared: prepared, catalog: catalog} = fixture()

    assert {:ok, result} = ConnectivityResult.new(prepared, catalog, entries())
    assert ConnectivityResult.valid?(result)
    assert ConnectivityResult.bound_to?(result, prepared, catalog)
    assert ConnectivityResult.entries(result) == entries()
  end

  test "a result cannot be reused against another catalog installing the same alias" do
    # Alias names are not identity. Occurrence identity alone would match here,
    # which is exactly why the binding is sealed into the value.
    %{prepared: prepared, catalog: catalog} = fixture()
    %{catalog: foreign} = fixture(revision: "foreign-v1")

    assert {:ok, result} = ConnectivityResult.new(prepared, catalog, entries())
    assert catalog.attestation != foreign.attestation
    refute ConnectivityResult.bound_to?(result, prepared, foreign)

    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new(prepared, foreign, entries())
  end

  test "every entry must report the mode its own sealed descriptor declares" do
    # A result claiming a mode the declaration never asked for would settle a
    # connectivity row for work nothing performed.
    %{prepared: prepared, catalog: catalog} = fixture()

    for mode <- [:probe, :acquisition] do
      assert {:error, :invalid_connectivity_result} =
               ConnectivityResult.new(prepared, catalog, [
                 %{hd(entries()) | mode: mode, outcome: :reachable}
               ])
    end
  end

  test "an outcome may not borrow another mode's meaning" do
    %{prepared: prepared, catalog: catalog} = fixture()

    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new(prepared, catalog, [
               %{hd(entries()) | outcome: :reachable}
             ])

    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new(prepared, catalog, [%{hd(entries()) | outcome: :invented}])
  end

  test "the entries must be exactly the selected occurrences, in declaration order" do
    %{prepared: prepared, catalog: catalog} = fixture()

    assert {:error, :invalid_connectivity_result} = ConnectivityResult.new(prepared, catalog, [])

    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new(prepared, catalog, entries() ++ entries())

    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new(prepared, catalog, [%{hd(entries()) | index: 1}])

    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new(prepared, catalog, [%{hd(entries()) | destination: :mission}])

    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new(prepared, catalog, [%{hd(entries()) | name: "other"}])
  end

  test "an entry must carry exactly the occurrence identity fields" do
    %{prepared: prepared, catalog: catalog} = fixture()
    entry = hd(entries())

    for forged <- [Map.delete(entry, :index), Map.put(entry, :extra, true), :entry, nil] do
      assert {:error, :invalid_connectivity_result} =
               ConnectivityResult.new(prepared, catalog, [forged])
    end
  end

  test "a tampered result no longer validates" do
    %{prepared: prepared, catalog: catalog} = fixture()
    assert {:ok, result} = ConnectivityResult.new(prepared, catalog, entries())

    forged = %{result | entries: [%{hd(entries()) | outcome: :reachable}]}
    refute ConnectivityResult.valid?(forged)
    refute ConnectivityResult.bound_to?(forged, prepared, catalog)

    rebound = %{result | catalog_attestation: "v1:" <> String.duplicate("0", 64)}
    refute ConnectivityResult.valid?(rebound)
  end

  test "a caller-authored preparation cannot have its declarations attested" do
    # Keeping a stale attestation while editing declarations would otherwise get
    # those edited declarations sealed into a result, which is the one thing the
    # binding exists to prevent.
    %{prepared: prepared, catalog: catalog} = fixture()

    forged = %{
      prepared
      | provider_declarations:
          Enum.map(prepared.provider_declarations, &Map.put(&1, :name, "other"))
    }

    assert forged.attestation == prepared.attestation

    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new(forged, catalog, entries())

    assert {:ok, result} = ConnectivityResult.new(prepared, catalog, entries())
    refute ConnectivityResult.bound_to?(result, forged, catalog)
  end

  test "a value that is not a result at all is refused rather than inspected" do
    refute ConnectivityResult.valid?(:not_a_result)
    refute ConnectivityResult.bound_to?(:not_a_result, nil, nil)
  end

  defp entries do
    [%{name: "inert", destination: :workflow, index: 0, mode: :none, outcome: :skipped}]
  end

  defp fixture(options \\ []) do
    {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

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
        destinations: [:workflow],
        workflow_llm?: false,
        connectivity_mode: :none,
        probe_effect: nil,
        selection_validation: :declarative,
        selection_rules: rules,
        authority_fingerprint: nil,
        local_preflight: :none
      )

    registration = %{
      descriptor: descriptor,
      implementation: %{builder: fn _selection, _context -> {:ok, %{credential_names: []}} end},
      authority: nil
    }

    {:ok, catalog} = InstallationCatalog.new(%{"inert" => registration})

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{
        "workflow" => [%{"name" => "inert", "config" => %{}}],
        "mission" => []
      }
    }

    documents = %{
      "ptc.json" => Jason.encode!(manifest),
      "main.clj" => "(ns app) (defn run [_input] (return {\"answer\" 42}))"
    }

    {:ok, request} =
      ApplicationPackage.request_memory("ptc.json", documents, result_projection: :json)

    {:ok, prepared} = RunCoordinator.prepare(request, catalog)

    on_exit(fn ->
      PreparedRun.close(prepared)
      InstallationCatalog.close(catalog)
    end)

    %{prepared: prepared, catalog: catalog}
  end
end
