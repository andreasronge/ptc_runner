defmodule PtcRunner.Kernel.DoctorPlanTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.DoctorPlan
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.SelectionRules

  @environment %{runtime: :supported, viewer: :available}

  test "the installed surface reports every alias without an application" do
    catalog = catalog(%{"beta" => [], "alpha" => []})

    assert {:ok, rows} = DoctorPlan.new(catalog, nil, @environment)
    assert {:ok, checks} = DoctorPlan.checks(rows)

    assert Enum.map(checks, & &1["name"]) == [
             "runtime",
             "application",
             "viewer",
             "provider/alpha/local",
             "provider/beta/local"
           ]

    assert_contract(checks, false)
  end

  test "an application narrows the plan to the aliases it selected" do
    catalog = catalog(%{"chosen" => [], "ignored" => []})
    prepared = prepared(catalog, ["chosen"])

    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment)
    assert {:ok, checks} = DoctorPlan.checks(rows)

    names = Enum.map(checks, & &1["name"])
    assert "provider/chosen/local" in names
    refute Enum.any?(names, &String.starts_with?(&1, "provider/ignored/"))
    assert_contract(checks, false)
  end

  test "repeated occurrences of one alias collapse into one ordered group" do
    catalog = catalog(%{"repeated" => [destinations: [:workflow, :mission]]})
    prepared = prepared(catalog, ["repeated"], ["repeated"])

    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment)
    assert {:ok, checks} = DoctorPlan.checks(rows)

    assert Enum.map(checks, & &1["name"]) == [
             "runtime",
             "application",
             "viewer",
             "provider/repeated/local",
             "provider/repeated/selection"
           ]

    assert_contract(checks, false)
  end

  test "each operation appears only when the sealed declaration says it applies" do
    catalog =
      catalog(%{
        "bare" => [],
        "keyed" => [credential_names: ["token"]],
        "authorized" => [authorization_mode: :oauth],
        "reachable" => [connectivity_mode: :probe, probe_effect: :metadata]
      })

    prepared = prepared(catalog, ["authorized", "bare", "keyed", "reachable"])

    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment)
    assert {:ok, checks} = DoctorPlan.checks(rows)

    assert operations(checks, "bare") == ["local", "selection"]
    assert operations(checks, "keyed") == ["local", "selection", "credentials"]
    assert operations(checks, "authorized") == ["local", "selection", "authorization"]
    assert operations(checks, "reachable") == ["local", "selection", "connectivity"]
    assert_contract(checks, false)
  end

  test "an audited-local declaration stays pending until a phase-7 check settles it" do
    catalog = catalog(%{"audited" => [local_preflight: :audited_local]})
    prepared = prepared(catalog, ["audited"])

    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment)

    # The plan cannot claim a local check passed without running one, so the row
    # is unsettled and no public check list can be projected yet.
    assert [%{name: "provider/audited/local"}] = DoctorPlan.pending(rows)
    assert {:error, :invalid_doctor_plan} = DoctorPlan.checks(rows)

    assert {:ok, settled} = DoctorPlan.settle(rows, "provider/audited/local", {:pass, :available})
    assert DoctorPlan.pending(settled) == []
    assert {:ok, checks} = DoctorPlan.checks(settled)
    assert_contract(checks, false)
  end

  test "a settled row cannot carry an outcome the closed contract has no code for" do
    # There is no failing provider row in any mode, so a failing audited-local
    # check has to fail the command rather than be reported as a row.
    catalog = catalog(%{"audited" => [local_preflight: :audited_local]})
    prepared = prepared(catalog, ["audited"])
    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment)

    for refused <- [{:fail, :unavailable}, {:warn, :available}, {:pass, :declarative}] do
      assert {:error, :invalid_doctor_plan} =
               DoctorPlan.settle(rows, "provider/audited/local", refused)
    end

    assert {:error, :invalid_doctor_plan} =
             DoctorPlan.settle(rows, "provider/audited/selection", {:pass, :available})
  end

  test "an unverified declaration defers to an active check without one running" do
    catalog = catalog(%{"unverified" => [local_preflight: :unverified]})
    prepared = prepared(catalog, ["unverified"])

    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment)
    assert DoctorPlan.pending(rows) == []
    assert {:ok, checks} = DoctorPlan.checks(rows)

    assert %{"status" => "skipped", "code" => "active_check_required"} =
             fetch_check(checks, "provider/unverified/local")

    assert_contract(checks, false)
  end

  test "an active selection validator defers rather than validating declaratively" do
    catalog = catalog(%{"active" => [selection_validation: :active]})
    prepared = prepared(catalog, ["active"])

    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment)
    assert {:ok, checks} = DoctorPlan.checks(rows)

    assert %{"status" => "skipped", "code" => "active_check_required"} =
             fetch_check(checks, "provider/active/selection")

    assert_contract(checks, false)
  end

  test "an unsupported runtime and a missing viewer warn without failing the plan" do
    catalog = catalog(%{"alpha" => []})

    assert {:ok, rows} =
             DoctorPlan.new(catalog, nil, %{runtime: :unsupported, viewer: :unavailable})

    assert {:ok, checks} = DoctorPlan.checks(rows)
    assert %{"status" => "warn", "code" => "unsupported"} = fetch_check(checks, "runtime")

    assert %{"status" => "warn", "code" => "optional_unavailable"} =
             fetch_check(checks, "viewer")

    assert_contract(checks, false)
  end

  test "a preparation from another catalog is refused even when the aliases match" do
    # Alias names are not identity. Both catalogs install "shared", but only one
    # declares it audited-local, so accepting the foreign preparation would
    # report rows derived from declarations it was never validated against.
    installed = catalog(%{"shared" => [local_preflight: :audited_local]})
    foreign = catalog(%{"shared" => []})

    assert installed.attestation != foreign.attestation
    prepared = prepared(foreign, ["shared"])

    assert {:error, :invalid_doctor_plan} = DoctorPlan.new(installed, prepared, @environment)

    # The same preparation is fine against the catalog it was prepared from, so
    # the refusal is about binding rather than about the preparation itself.
    assert {:ok, rows} = DoctorPlan.new(foreign, prepared, @environment)
    assert {:ok, _checks} = DoctorPlan.checks(rows)
  end

  test "projection refuses a row carrying an outcome the contract has no code for" do
    # The rule that no provider row can express a failure has to hold at the
    # boundary that renders rows, not only at the producers that build them.
    catalog = catalog(%{"alpha" => []})
    assert {:ok, rows} = DoctorPlan.new(catalog, nil, @environment)
    assert {:ok, _checks} = DoctorPlan.checks(rows)

    for forged <- [{:fail, :unavailable}, {:pass, :invented}, {:warn, :requires_connect}] do
      tampered =
        Enum.map(rows, fn
          %{name: "provider/alpha/local"} = row -> %{row | outcome: forged}
          row -> row
        end)

      assert {:error, :invalid_doctor_plan} = DoctorPlan.checks(tampered)
    end
  end

  test "an unknown environment fact is refused rather than defaulted" do
    catalog = catalog(%{"alpha" => []})

    for environment <- [%{}, %{runtime: :supported}, %{runtime: :maybe, viewer: :available}] do
      assert {:error, :invalid_doctor_plan} = DoctorPlan.new(catalog, nil, environment)
    end
  end

  defp operations(checks, alias_name) do
    prefix = "provider/#{alias_name}/"

    checks
    |> Enum.map(& &1["name"])
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(&String.replace_prefix(&1, prefix, ""))
  end

  defp fetch_check(checks, name), do: Enum.find(checks, &(&1["name"] == name))

  # The contract, not this test, decides whether a row set is well formed: both
  # the generated schema and the ordering semantics it cannot express.
  defp assert_contract(checks, provider_activity) do
    result = %{"checks" => checks, "provider_activity" => provider_activity}
    assert CommandContract.valid_success_result?(:doctor, result)
    assert CommandContract.valid_success_semantics?(:doctor, result)
  end

  defp catalog(specifications) do
    {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

    registrations =
      Map.new(specifications, fn {name, options} ->
        authority = authority(Keyword.get(options, :authorization_mode, :none))

        {:ok, descriptor} =
          ProviderDescriptor.new(
            source: :custom,
            installation_revision: "doctor-v1",
            credential_names: Keyword.get(options, :credential_names, []),
            authorization_mode: Keyword.get(options, :authorization_mode, :none),
            data_class: :normal,
            accepts_data: [:normal],
            requires: [],
            provides: [],
            destinations: Keyword.get(options, :destinations, [:workflow]),
            workflow_llm?: false,
            connectivity_mode: Keyword.get(options, :connectivity_mode, :none),
            probe_effect: Keyword.get(options, :probe_effect),
            selection_validation: Keyword.get(options, :selection_validation, :declarative),
            selection_rules: rules,
            authority_fingerprint: authority && authority.fingerprint,
            local_preflight: Keyword.get(options, :local_preflight, :none)
          )

        {name,
         %{
           descriptor: descriptor,
           implementation: implementation(options),
           authority: authority
         }}
      end)

    {:ok, catalog} = InstallationCatalog.new(registrations)
    on_exit(fn -> InstallationCatalog.close(catalog) end)
    catalog
  end

  # The descriptor's fingerprint is taken from the authority it is bound to, so
  # the fixture cannot drift from the binding the catalog seals.
  defp authority(:none), do: nil

  defp authority(:oauth) do
    {:ok, authority} =
      Authority.from_host(
        %{
          "installation_id" => "doctor-primary",
          "issuer" => "https://auth.example",
          "scope_ceiling" => ["read"],
          "default_scopes" => ["read"],
          "client" => %{
            "registration" => "pre_registered",
            "client_id" => "doctor-client",
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

  defp implementation(options) do
    builder = fn _selection, _context -> {:ok, %{credential_names: []}} end

    implementation =
      case Keyword.get(options, :local_preflight, :none) do
        :none ->
          %{builder: builder}

        _mode ->
          %{builder: builder, local_preflight: fn _selection, _context, _services -> :ok end}
      end

    case Keyword.get(options, :selection_validation, :declarative) do
      :active ->
        Map.put(implementation, :selection_validator, fn _selection, _context -> :ok end)

      :declarative ->
        implementation
    end
    |> then(fn implementation ->
      if Keyword.get(options, :authorization_mode) == :oauth do
        Map.put(implementation, :oauth_builder, fn _selection, _context, _runtime ->
          {:ok, %{credential_names: []}}
        end)
      else
        implementation
      end
    end)
    |> then(fn implementation ->
      if Keyword.get(options, :connectivity_mode, :none) == :probe do
        Map.put(implementation, :connectivity_probe, fn _selection, _context, _services -> :ok end)
      else
        implementation
      end
    end)
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
