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

    assert {:ok, result} = ConnectivityResult.new(prepared, catalog, entries(), false, [])
    assert ConnectivityResult.valid?(result)
    assert ConnectivityResult.bound_to?(result, prepared, catalog)
    assert ConnectivityResult.entries(result) == entries()
  end

  test "false activity cannot contradict work proven by the sealed operation" do
    for options <- [
          [connectivity_mode: :probe],
          [connectivity_mode: :acquisition],
          [selection_validation: :active],
          [local_preflight: :unverified]
        ] do
      %{prepared: prepared, catalog: catalog} = fixture(options)
      mode = Keyword.get(options, :connectivity_mode, :none)
      outcome = if mode == :none, do: :skipped, else: :reachable

      assert {:error, :invalid_connectivity_result} =
               ConnectivityResult.new(
                 prepared,
                 catalog,
                 entries(mode, outcome),
                 false,
                 usage_for(mode)
               )

      assert {:ok, result} =
               ConnectivityResult.new(
                 prepared,
                 catalog,
                 entries(mode, outcome),
                 true,
                 usage_for(mode)
               )

      assert ConnectivityResult.bound_to?(result, prepared, catalog)
    end
  end

  test "a result cannot be reused against another catalog installing the same alias" do
    # Alias names are not identity. Occurrence identity alone would match here,
    # which is exactly why the binding is sealed into the value.
    %{prepared: prepared, catalog: catalog} = fixture()
    %{catalog: foreign} = fixture(revision: "foreign-v1")

    assert {:ok, result} = ConnectivityResult.new(prepared, catalog, entries(), false, [])
    assert catalog.attestation != foreign.attestation
    refute ConnectivityResult.bound_to?(result, prepared, foreign)

    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new(prepared, foreign, entries(), false, [])
  end

  test "every entry must report the mode its own sealed descriptor declares" do
    # A result claiming a mode the declaration never asked for would settle a
    # connectivity row for work nothing performed.
    %{prepared: prepared, catalog: catalog} = fixture()

    for mode <- [:probe, :acquisition] do
      assert {:error, :invalid_connectivity_result} =
               ConnectivityResult.new(
                 prepared,
                 catalog,
                 [
                   %{hd(entries()) | mode: mode, outcome: :reachable}
                 ],
                 false,
                 []
               )
    end
  end

  test "an outcome may not borrow another mode's meaning" do
    %{prepared: prepared, catalog: catalog} = fixture()

    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new(
               prepared,
               catalog,
               [
                 %{hd(entries()) | outcome: :reachable}
               ],
               false,
               []
             )

    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new(
               prepared,
               catalog,
               [%{hd(entries()) | outcome: :invented}],
               false,
               []
             )
  end

  test "the entries must be exactly the selected occurrences, in declaration order" do
    %{prepared: prepared, catalog: catalog} = fixture()

    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new(prepared, catalog, [], false, [])

    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new(prepared, catalog, entries() ++ entries(), false, [])

    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new(prepared, catalog, [%{hd(entries()) | index: 1}], false, [])

    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new(
               prepared,
               catalog,
               [%{hd(entries()) | destination: :mission}],
               false,
               []
             )

    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new(
               prepared,
               catalog,
               [%{hd(entries()) | name: "other"}],
               false,
               []
             )
  end

  test "an entry must carry exactly the occurrence identity fields" do
    %{prepared: prepared, catalog: catalog} = fixture()
    entry = hd(entries())

    for forged <- [Map.delete(entry, :index), Map.put(entry, :extra, true), :entry, nil] do
      assert {:error, :invalid_connectivity_result} =
               ConnectivityResult.new(prepared, catalog, [forged], false, [])
    end
  end

  test "a tampered result no longer validates" do
    %{prepared: prepared, catalog: catalog} = fixture()
    assert {:ok, result} = ConnectivityResult.new(prepared, catalog, entries(), false, [])

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
             ConnectivityResult.new(forged, catalog, entries(), false, [])

    assert {:ok, result} = ConnectivityResult.new(prepared, catalog, entries(), false, [])
    refute ConnectivityResult.bound_to?(result, forged, catalog)
  end

  test "usage accounts for exactly the probed occurrences" do
    %{prepared: prepared, catalog: catalog} = fixture(connectivity_mode: :probe)
    entries = entries(:probe, :reachable)
    account = %{name: "inert", destination: :workflow, index: 0, usage: nil}

    assert {:ok, result} = ConnectivityResult.new(prepared, catalog, entries, true, [account])
    assert ConnectivityResult.usage(result) == [account]

    # An account for an occurrence nothing probed, none for one that was, or two
    # for the same one would each attribute spend to the wrong declaration.
    for forged <- [[], [account, account], [%{account | name: "other"}], [%{account | index: 1}]] do
      assert {:error, :invalid_connectivity_result} =
               ConnectivityResult.new(prepared, catalog, entries, true, forged)
    end

    # A skipped occurrence is not billable, so it may carry no account at all.
    %{prepared: inert_prepared, catalog: inert_catalog} = fixture()

    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new(inert_prepared, inert_catalog, entries(), false, [account])
  end

  test "a usage account carries closed token values or nothing" do
    %{prepared: prepared, catalog: catalog} = fixture(connectivity_mode: :probe)
    entries = entries(:probe, :reachable)
    account = %{name: "inert", destination: :workflow, index: 0, usage: nil}

    assert {:ok, _result} =
             ConnectivityResult.new(prepared, catalog, entries, true, [
               %{
                 account
                 | usage: %{
                     "input" => 8,
                     "output" => 1,
                     "total_cost" => %{"currency" => "USD", "microunits" => 3}
                   }
               }
             ])

    # `LLMUsage` owns what a token record may say. A second, looser copy here
    # would let a fractional count or a value past the canonical ceiling be
    # attested and then reported as measured spend.
    for usage <- [
          %{"invented" => 1},
          %{"input" => -1},
          %{"input" => "8"},
          %{"input" => 0.5},
          %{"input" => 9_007_199_254_740_992},
          %{"total_cost" => 1.0e13},
          %{input: 8},
          :usage
        ] do
      assert {:error, :invalid_connectivity_result} =
               ConnectivityResult.new(prepared, catalog, entries, true, [
                 %{account | usage: usage}
               ])
    end

    for forged <- [Map.delete(account, :usage), Map.put(account, :extra, true), :account, nil] do
      assert {:error, :invalid_connectivity_result} =
               ConnectivityResult.new(prepared, catalog, entries, true, [forged])
    end
  end

  test "a tampered usage account no longer validates" do
    %{prepared: prepared, catalog: catalog} = fixture(connectivity_mode: :probe)
    entries = entries(:probe, :reachable)
    account = %{name: "inert", destination: :workflow, index: 0, usage: nil}

    assert {:ok, result} = ConnectivityResult.new(prepared, catalog, entries, true, [account])

    forged = %{result | usage: [%{account | usage: %{"total_cost" => 0}}]}
    refute ConnectivityResult.valid?(forged)
    refute ConnectivityResult.bound_to?(forged, prepared, catalog)
  end

  test "a value that is not a result at all is refused rather than inspected" do
    refute ConnectivityResult.valid?(:not_a_result)
    refute ConnectivityResult.bound_to?(:not_a_result, nil, nil)
  end

  defp entries(mode \\ :none, outcome \\ :skipped) do
    [%{name: "inert", destination: :workflow, index: 0, mode: mode, outcome: outcome}]
  end

  defp usage_for(:probe),
    do: [%{name: "inert", destination: :workflow, index: 0, usage: nil}]

  defp usage_for(_mode), do: []

  defp fixture(options \\ []) do
    {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

    selection_validation = Keyword.get(options, :selection_validation, :declarative)
    local_preflight = Keyword.get(options, :local_preflight, :none)

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
        connectivity_mode: Keyword.get(options, :connectivity_mode, :none),
        probe_effect:
          if(Keyword.get(options, :connectivity_mode, :none) == :probe,
            do: :metadata,
            else: nil
          ),
        selection_validation: selection_validation,
        selection_rules: rules,
        authority_fingerprint: nil,
        local_preflight: local_preflight
      )

    implementation = %{
      builder: fn _selection, _context -> {:ok, %{credential_names: []}} end
    }

    implementation =
      if selection_validation == :active,
        do: Map.put(implementation, :selection_validator, fn _selection, _context -> :ok end),
        else: implementation

    implementation =
      if local_preflight == :unverified,
        do:
          Map.put(
            implementation,
            :local_preflight,
            fn _selection, _context, _services -> :ok end
          ),
        else: implementation

    implementation =
      if Keyword.get(options, :connectivity_mode, :none) == :probe,
        do:
          Map.put(
            implementation,
            :connectivity_probe,
            fn _selection, _context, _services -> :ok end
          ),
        else: implementation

    registration = %{
      descriptor: descriptor,
      implementation: implementation,
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
