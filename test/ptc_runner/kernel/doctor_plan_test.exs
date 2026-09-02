defmodule PtcRunner.Kernel.DoctorPlanTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.ConnectivityResult
  alias PtcRunner.Kernel.DiagnosticCatalog
  alias PtcRunner.Kernel.DoctorPlan
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.SelectionRules
  alias PtcRunner.TestSupport.HostBoundFixture

  @environment %{runtime: :supported, viewer: :available}

  test "doctor failure codes exclude diagnostics that forbid attribution" do
    codes = DiagnosticCatalog.doctor_failure_codes_by_operation()

    assert :connectivity_unavailable in Map.fetch!(codes, :connectivity)
    assert :provider_unavailable in Map.fetch!(codes, :connectivity)
    refute :connectivity_timeout in Map.fetch!(codes, :connectivity)

    refute Enum.any?(codes, fn {_operation, values} ->
             :capability_requirement_missing in values
           end)

    refute CommandContract.diagnostic_allowed?(
             {:doctor, :connect},
             :provider_acquisition,
             :capability_requirement_missing
           )
  end

  test "the installed surface reports every alias without an application" do
    catalog = catalog(%{"beta" => [], "alpha" => []})

    assert {:ok, rows} = DoctorPlan.new(catalog, nil, @environment, :default)
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

  test "an application failure plan refuses a forged catalog" do
    catalog = catalog(%{"alpha" => []})
    forged = %{catalog | attestation: <<>>}
    diagnostic = CommandDiagnostic.new!(:application, :schema_violation)

    assert {:error, :invalid_doctor_plan} =
             DoctorPlan.application_failure(forged, diagnostic, @environment, :default)
  end

  test "an application narrows the plan to the aliases it selected" do
    catalog = catalog(%{"chosen" => [], "ignored" => []})
    prepared = prepared(catalog, ["chosen"])

    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment, :default)
    assert {:ok, checks} = DoctorPlan.checks(rows)

    names = Enum.map(checks, & &1["name"])
    assert "provider/chosen/local" in names
    refute Enum.any?(names, &String.starts_with?(&1, "provider/ignored/"))
    assert_contract(checks, false)
  end

  test "repeated occurrences of one alias collapse into one ordered group" do
    catalog = catalog(%{"repeated" => [destinations: [:workflow, :mission]]})
    prepared = prepared(catalog, ["repeated"], ["repeated"])

    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment, :default)
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

    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment, :default)
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

    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment, :default)

    # The plan cannot claim a local check passed without running one, so the row
    # is unsettled and no public check list can be projected yet.
    assert {:error, :invalid_doctor_plan} = DoctorPlan.checks(rows)

    assert {:ok, settled} = DoctorPlan.settle(rows, "provider/audited/local", {:pass, :available})
    assert {:ok, checks} = DoctorPlan.checks(settled)
    assert_contract(checks, false)
  end

  test "a settled row cannot carry an outcome the closed contract has no code for" do
    # The default settlement accepts only successful local outcomes. Connected
    # failures go through the separately bound failure settlement.
    catalog = catalog(%{"audited" => [local_preflight: :audited_local]})
    prepared = prepared(catalog, ["audited"])
    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment, :default)

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

    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment, :default)
    assert {:ok, checks} = DoctorPlan.checks(rows)

    assert %{"status" => "skipped", "code" => "active_check_required"} =
             fetch_check(checks, "provider/unverified/local")

    assert_contract(checks, false)
  end

  test "an active selection validator defers rather than validating declaratively" do
    catalog = catalog(%{"active" => [selection_validation: :active]})
    prepared = prepared(catalog, ["active"])

    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment, :default)
    assert {:ok, checks} = DoctorPlan.checks(rows)

    assert %{"status" => "skipped", "code" => "active_check_required"} =
             fetch_check(checks, "provider/active/selection")

    assert_contract(checks, false)
  end

  test "connect leaves pending exactly what default doctor settles inertly" do
    catalog =
      catalog(%{
        "bare" => [],
        "keyed" => [credential_names: ["token"]],
        "authorized" => [authorization_mode: :oauth],
        "reachable" => [connectivity_mode: :probe, probe_effect: :metadata],
        "validated" => [selection_validation: :active],
        "custom" => [local_preflight: :unverified],
        "audited" => [local_preflight: :audited_local]
      })

    selected = ["audited", "authorized", "bare", "custom", "keyed", "reachable", "validated"]
    prepared = prepared(catalog, selected)

    assert {:ok, default} = DoctorPlan.new(catalog, prepared, @environment, :default)
    assert {:ok, connect} = DoctorPlan.new(catalog, prepared, @environment, :connect)

    # The modes derive the same rows in the same order from the same sealed
    # declarations. Only whether a row arrives settled differs, and it differs
    # for exactly the rows default doctor settles without doing the work.
    assert Enum.map(default, & &1.name) == Enum.map(connect, & &1.name)

    deferred = [
      {:skipped, :requires_connect},
      {:skipped, :active_check_required},
      :audited_local
    ]

    for {default_row, connect_row} <- Enum.zip(default, connect) do
      if default_row.outcome in deferred do
        assert connect_row.outcome == :pending, "#{default_row.name} should be pending"
      else
        assert connect_row.outcome == default_row.outcome
      end
    end

    # Default doctor's one pending row settles from its phase-7 step. A connect
    # plan has no equivalent and stays unprojectable until its own operation
    # returned, which is what `settle_connect/4` needs and this one does not.
    assert {:ok, settled} =
             DoctorPlan.settle_local(default, [], prepared, catalog, @environment)

    assert {:ok, _checks} = DoctorPlan.checks(settled)
    assert {:error, :invalid_doctor_plan} = DoctorPlan.checks(connect)

    # Default doctor's settlement refuses a connect plan rather than using its
    # empty finding set as a shortcut through rows derived for another mode.
    assert {:error, :invalid_doctor_plan} =
             DoctorPlan.settle_local(connect, [], prepared, catalog, @environment)
  end

  test "connect has no application-free form" do
    # The closed contract admits a connect success only when the application row
    # is `pass/valid`, so a plan without one could never be projected.
    catalog = catalog(%{"alpha" => []})

    assert {:ok, _rows} = DoctorPlan.new(catalog, nil, @environment, :default)
    assert {:error, :invalid_doctor_plan} = DoctorPlan.new(catalog, nil, @environment, :connect)
  end

  test "a connect result settles every pending row it answers for" do
    catalog =
      catalog(%{
        "keyed" => [credential_names: ["token"]],
        "reachable" => [connectivity_mode: :probe, probe_effect: :metadata],
        "validated" => [selection_validation: :active],
        "custom" => [local_preflight: :unverified],
        "audited" => [local_preflight: :audited_local]
      })

    prepared = prepared(catalog, ["audited", "custom", "keyed", "reachable", "validated"])
    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment, :connect)

    assert {:ok, settled} =
             DoctorPlan.settle_connect(
               rows,
               connectivity_result(prepared, catalog),
               prepared,
               catalog
             )

    assert {:ok, checks} = DoctorPlan.checks(settled)

    # Connect's rule is stricter than default doctor's: every provider row must
    # pass, so the contract is what proves nothing was left behind.
    assert_contract(checks, true, "ready")

    assert %{"status" => "pass", "code" => "available"} =
             fetch_check(checks, "provider/custom/local")

    assert %{"status" => "pass", "code" => "available"} =
             fetch_check(checks, "provider/audited/local")

    assert %{"status" => "pass", "code" => "available"} =
             fetch_check(checks, "provider/validated/selection")

    assert %{"status" => "pass", "code" => "available"} =
             fetch_check(checks, "provider/keyed/credentials")

    assert %{"status" => "pass", "code" => "available"} =
             fetch_check(checks, "provider/reachable/connectivity")

    # A declarative selection was never pending and keeps its own code.
    assert %{"status" => "pass", "code" => "declarative"} =
             fetch_check(checks, "provider/keyed/selection")
  end

  test "an attributable failure settles one row and leaves other pending rows unverified" do
    catalog =
      catalog(%{
        "keyed" => [credential_names: ["token"]],
        "reachable" => [connectivity_mode: :probe, probe_effect: :metadata]
      })

    prepared = prepared(catalog, ["keyed", "reachable"])
    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment, :connect)

    diagnostic = diagnostic(:active_preflight, :credential_unavailable, "keyed", :credentials)

    assert {:ok, settled} =
             DoctorPlan.settle_failure(rows, diagnostic, prepared, catalog, @environment)

    assert {:ok, checks} = DoctorPlan.checks(settled)

    assert %{"status" => "fail", "code" => "credential_unavailable"} =
             fetch_check(checks, "provider/keyed/credentials")

    assert %{"status" => "skipped", "code" => "not_verified_due_to_failure"} =
             fetch_check(checks, "provider/reachable/connectivity")

    assert %{"status" => "pass", "code" => "declarative"} =
             fetch_check(checks, "provider/keyed/selection")
  end

  test "a rejected credential proves the same provider was reachable" do
    catalog =
      catalog(%{
        "model" => [
          credential_names: ["key"],
          connectivity_mode: :probe,
          probe_effect: :completion
        ]
      })

    prepared = prepared(catalog, ["model"])
    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment, :connect)
    diagnostic = diagnostic(:active_preflight, :authentication_rejected, "model", :credentials)

    assert {:ok, settled} =
             DoctorPlan.settle_failure(rows, diagnostic, prepared, catalog, @environment)

    assert {:ok, checks} = DoctorPlan.checks(settled)

    assert %{"status" => "fail", "code" => "authentication_rejected"} =
             fetch_check(checks, "provider/model/credentials")

    assert %{"status" => "pass", "code" => "available"} =
             fetch_check(checks, "provider/model/connectivity")
  end

  test "failure settlement reconstructs the exact sealed connect plan" do
    catalog = catalog(%{"shared" => [credential_names: ["token"]]})
    foreign = catalog(%{"shared" => [credential_names: ["token"], revision: "foreign-v1"]})
    prepared = prepared(catalog, ["shared"])
    foreign_prepared = prepared(foreign, ["shared"])

    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment, :connect)
    diagnostic = diagnostic(:active_preflight, :credential_unavailable, "shared", :credentials)

    tampered =
      Enum.map(rows, fn
        %{name: "provider/shared/credentials"} = row -> %{row | operation: :connectivity}
        row -> row
      end)

    for {candidate_rows, candidate_prepared, candidate_catalog, environment} <- [
          {tampered, prepared, catalog, @environment},
          {rows, foreign_prepared, foreign, @environment},
          {rows, prepared, catalog, %{runtime: :unsupported, viewer: :available}}
        ] do
      assert {:error, :invalid_doctor_plan} =
               DoctorPlan.settle_failure(
                 candidate_rows,
                 diagnostic,
                 candidate_prepared,
                 candidate_catalog,
                 environment
               )
    end
  end

  test "an acquisition diagnostic maps only an acquisition connectivity declaration" do
    acquiring = catalog(%{"provider" => [connectivity_mode: :acquisition]})
    probing = catalog(%{"provider" => [connectivity_mode: :probe, probe_effect: :metadata]})
    acquiring_prepared = prepared(acquiring, ["provider"])
    probing_prepared = prepared(probing, ["provider"])

    assert {:ok, acquiring_rows} =
             DoctorPlan.new(acquiring, acquiring_prepared, @environment, :connect)

    assert {:ok, probing_rows} =
             DoctorPlan.new(probing, probing_prepared, @environment, :connect)

    occurrence = %{destination: :workflow, index: 0}

    diagnostic =
      diagnostic(
        :provider_acquisition,
        :provider_unavailable,
        "provider",
        :acquisition,
        occurrence
      )

    assert {:ok, settled} =
             DoctorPlan.settle_failure(
               acquiring_rows,
               diagnostic,
               acquiring_prepared,
               acquiring,
               @environment
             )

    assert {:ok, checks} = DoctorPlan.checks(settled)

    assert %{"status" => "fail", "code" => "provider_unavailable"} =
             fetch_check(checks, "provider/provider/connectivity")

    assert {:error, :invalid_doctor_plan} =
             DoctorPlan.settle_failure(
               probing_rows,
               diagnostic,
               probing_prepared,
               probing,
               @environment
             )
  end

  test "endpoint connection diagnostics settle acquisition connectivity rows" do
    catalog = catalog(%{"provider" => [connectivity_mode: :acquisition]})
    prepared = prepared(catalog, ["provider"])
    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment, :connect)
    occurrence = %{destination: :workflow, index: 0}

    for code <- [
          :provider_endpoint_connection_refused,
          :provider_endpoint_name_unresolved,
          :provider_endpoint_tls_failed
        ] do
      failure = diagnostic(:provider_acquisition, code, "provider", :acquisition, occurrence)

      assert {:ok, settled} =
               DoctorPlan.settle_failure(rows, failure, prepared, catalog, @environment)

      assert {:ok, checks} = DoctorPlan.checks(settled)

      assert %{"status" => "fail", "code" => rendered} =
               fetch_check(checks, "provider/provider/connectivity")

      assert rendered == Atom.to_string(code)
    end
  end

  test "unattributable diagnostics cannot synthesize failed rows" do
    catalog = catalog(%{"reachable" => [connectivity_mode: :probe, probe_effect: :metadata]})
    prepared = prepared(catalog, ["reachable"])
    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment, :connect)

    {:ok, application_subject} = CommandSubject.provider("reachable", :application)

    application =
      CommandDiagnostic.new!(:active_preflight, :provider_application_unavailable,
        subject: application_subject,
        provider_activity: false
      )

    timeout =
      CommandDiagnostic.new!(:active_preflight, :connectivity_timeout, provider_activity: true)

    wrong_alias =
      diagnostic(
        :active_preflight,
        :connectivity_unavailable,
        "missing",
        :connectivity,
        %{destination: :workflow, index: 0}
      )

    for refused <- [application, timeout, wrong_alias] do
      assert {:error, :invalid_doctor_plan} =
               DoctorPlan.settle_failure(rows, refused, prepared, catalog, @environment)
    end
  end

  test "an authorization row is never settled, because V1 has no path that could" do
    # Its row demands `pass/available` while standalone OAuth execution is
    # disabled, and the execution refuses a selected OAuth occurrence before any
    # provider work. Reaching settlement with one pending means an operation
    # reported success for a selection that cannot succeed.
    catalog = catalog(%{"authorized" => [authorization_mode: :oauth]})
    prepared = prepared(catalog, ["authorized"])

    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment, :connect)
    assert Enum.any?(rows, &match?(%{operation: :authorization, outcome: :pending}, &1))

    assert {:error, :invalid_doctor_plan} =
             DoctorPlan.settle_connect(
               rows,
               connectivity_result(prepared, catalog),
               prepared,
               catalog
             )
  end

  test "resolving credentials without provider work permits a no-activity connect success" do
    catalog = catalog(%{"keyed" => [credential_names: ["token"]]})
    prepared = prepared(catalog, ["keyed"])
    assert {:ok, rows} = DoctorPlan.new(catalog, prepared, @environment, :connect)

    assert {:ok, settled} =
             DoctorPlan.settle_connect(
               rows,
               connectivity_result(prepared, catalog, false),
               prepared,
               catalog
             )

    assert {:ok, checks} = DoctorPlan.checks(settled)
    assert_contract(checks, false, "ready")
  end

  test "a connectivity row cannot be settled by a result that reached nothing" do
    # Alias names are not identity. Both catalogs install "shared", and only the
    # sealed descriptor says whether its connectivity row exists at all, so a
    # plan and a result derived from different catalogs must not settle each
    # other even though every name lines up.
    probing = catalog(%{"shared" => [connectivity_mode: :probe, probe_effect: :metadata]})
    inert = catalog(%{"shared" => []})

    probing_prepared = prepared(probing, ["shared"])
    inert_prepared = prepared(inert, ["shared"])

    assert {:ok, probing_rows} = DoctorPlan.new(probing, probing_prepared, @environment, :connect)
    assert {:ok, inert_rows} = DoctorPlan.new(inert, inert_prepared, @environment, :connect)

    # The dangerous direction: a plan holding a connectivity row settled from a
    # result whose occurrences were all skipped.
    assert {:error, :invalid_doctor_plan} =
             DoctorPlan.settle_connect(
               probing_rows,
               connectivity_result(inert_prepared, inert),
               inert_prepared,
               inert
             )

    # And its converse, where the result reached an alias the plan has no row
    # for, which means the plan was derived from declarations nothing answered.
    assert {:error, :invalid_doctor_plan} =
             DoctorPlan.settle_connect(
               inert_rows,
               connectivity_result(probing_prepared, probing),
               probing_prepared,
               probing
             )
  end

  test "connect settlement refuses a plan the result does not answer for" do
    catalog = catalog(%{"chosen" => [], "ignored" => []})
    both = prepared(catalog, ["chosen", "ignored"])
    one = prepared(catalog, ["chosen"])

    assert {:ok, rows} = DoctorPlan.new(catalog, both, @environment, :connect)

    # A result for a narrower selection cannot settle a plan derived from a
    # wider one, even against the same catalog.
    assert {:error, :invalid_doctor_plan} =
             DoctorPlan.settle_connect(rows, connectivity_result(one, catalog), one, catalog)

    # A result minted against another catalog cannot settle it either, and here
    # nothing else could tell: the aliases, the occurrences, and the
    # connectivity modes all line up, so only the sealed attestations separate
    # the two sets of declarations.
    foreign =
      catalog(%{"chosen" => [revision: "foreign-v1"], "ignored" => [revision: "foreign-v1"]})

    foreign_prepared = prepared(foreign, ["chosen", "ignored"])
    assert foreign.attestation != catalog.attestation

    assert {:error, :invalid_doctor_plan} =
             DoctorPlan.settle_connect(
               rows,
               connectivity_result(foreign_prepared, foreign),
               both,
               catalog
             )

    # Nor can an unbound value stand in for one.
    assert {:error, :invalid_doctor_plan} =
             DoctorPlan.settle_connect(rows, :not_a_result, both, catalog)
  end

  test "a default-mode plan cannot be settled as a connect one" do
    # Four row shapes only default doctor produces, each needing its own
    # fixture: a plan carrying more than one is refused for the first reason
    # reached and would leave the others unproven. Between them they are every
    # outcome `new/4` can construct that `:connect` cannot, which is what makes
    # the refusal total rather than a sample.
    #
    # A deferred connectivity row is not pending, so no result answers for it.
    deferred = catalog(%{"reachable" => [connectivity_mode: :probe, probe_effect: :metadata]})
    deferred_prepared = prepared(deferred, ["reachable"])
    assert {:ok, rows} = DoctorPlan.new(deferred, deferred_prepared, @environment, :default)

    assert {:error, :invalid_doctor_plan} =
             DoctorPlan.settle_connect(
               rows,
               connectivity_result(deferred_prepared, deferred),
               deferred_prepared,
               deferred
             )

    # A deferred code on any other operation has no connectivity row to be
    # caught by, so refusing the code itself is what keeps the mode check total.
    # Without it this settles, and the wrong mode is only discovered at the
    # closed result contract, as an internal error rather than as this refusal.
    keyed = catalog(%{"keyed" => [credential_names: ["token"]]})
    keyed_prepared = prepared(keyed, ["keyed"])
    assert {:ok, rows} = DoctorPlan.new(keyed, keyed_prepared, @environment, :default)
    refute Enum.any?(rows, &match?(%{operation: :connectivity}, &1))

    assert Enum.any?(
             rows,
             &match?(%{operation: :credentials, outcome: {:skipped, :requires_connect}}, &1)
           )

    assert {:error, :invalid_doctor_plan} =
             DoctorPlan.settle_connect(
               rows,
               connectivity_result(keyed_prepared, keyed),
               keyed_prepared,
               keyed
             )

    # And an audited-local row names a step that settles it under the other
    # mode, against evidence this settlement never saw. No shipped recipe pairs
    # an audited-local check with no connectivity — `llm` probes and stdio `mcp`
    # acquires — but the constructors admit that pairing from any shipped source
    # whose own rules leave `local_preflight` free, and `llm_replay` is one. It
    # is what leaves this plan no earlier reason to be refused for.
    audited =
      catalog(%{"replayed" => [source: :llm_replay, local_preflight: :audited_local]})

    audited_prepared = prepared(audited, ["replayed"])
    assert {:ok, rows} = DoctorPlan.new(audited, audited_prepared, @environment, :default)
    assert Enum.any?(rows, &match?(%{outcome: :audited_local}, &1))
    refute Enum.any?(rows, &match?(%{operation: :connectivity}, &1))

    assert {:error, :invalid_doctor_plan} =
             DoctorPlan.settle_connect(
               rows,
               connectivity_result(audited_prepared, audited),
               audited_prepared,
               audited
             )

    # Finally the application-less surface, whose two codes connect has no form
    # for at all. Its alias set can coincide with a real selection's, so nothing
    # earlier separates it — an inert alias leaves no connectivity row and the
    # preparation selects exactly the installed one.
    inert = catalog(%{"alpha" => []})
    inert_prepared = prepared(inert, ["alpha"])
    assert {:ok, rows} = DoctorPlan.new(inert, nil, @environment, :default)

    assert Enum.any?(rows, &match?(%{outcome: {:skipped, :not_requested}}, &1))
    assert Enum.any?(rows, &match?(%{outcome: {:skipped, :application_required}}, &1))

    assert {:error, :invalid_doctor_plan} =
             DoctorPlan.settle_connect(
               rows,
               connectivity_result(inert_prepared, inert),
               inert_prepared,
               inert
             )
  end

  test "an unsupported runtime and a missing viewer warn without failing the plan" do
    catalog = catalog(%{"alpha" => []})

    assert {:ok, rows} =
             DoctorPlan.new(
               catalog,
               nil,
               %{runtime: :unsupported, viewer: :unavailable},
               :default
             )

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

    assert {:error, :invalid_doctor_plan} =
             DoctorPlan.new(installed, prepared, @environment, :default)

    # The same preparation is fine against the catalog it was prepared from, so
    # the refusal is about binding rather than about the preparation itself.
    assert {:ok, rows} = DoctorPlan.new(foreign, prepared, @environment, :default)
    assert {:ok, _checks} = DoctorPlan.checks(rows)
  end

  test "projection refuses a row carrying an outcome the contract has no code for" do
    # Failure codes are operation-specific and closed. A caller cannot invent a
    # generic failure at the projection boundary.
    catalog = catalog(%{"alpha" => []})
    assert {:ok, rows} = DoctorPlan.new(catalog, nil, @environment, :default)
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
      assert {:error, :invalid_doctor_plan} = DoctorPlan.new(catalog, nil, environment, :default)
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

  defp diagnostic(phase, code, name, operation, occurrence \\ nil) do
    {:ok, subject} = CommandSubject.provider(name, operation, occurrence)

    CommandDiagnostic.new!(phase, code,
      subject: subject,
      provider_activity: phase == :provider_acquisition or code == :connectivity_unavailable
    )
  end

  # The success projection a completed connect operation seals: one entry per
  # selected occurrence, each reporting the mode its own sealed descriptor
  # declares. `ProviderConnectivityTest` drives the real operation end to end;
  # these cases are about what the plan does with the value it returns.
  defp connectivity_result(prepared, catalog, provider_activity \\ true) do
    entries =
      Enum.map(prepared.provider_declarations, fn declaration ->
        mode = catalog.descriptors[declaration.name].connectivity_mode

        %{
          name: declaration.name,
          destination: declaration.destination,
          index: declaration.index,
          mode: mode,
          outcome: if(mode == :none, do: :skipped, else: :reachable)
        }
      end)

    usage =
      entries
      |> Enum.filter(&(&1.mode == :probe))
      |> Enum.map(&%{name: &1.name, destination: &1.destination, index: &1.index, usage: nil})

    {:ok, result} =
      ConnectivityResult.new(prepared, catalog, entries, provider_activity, usage)

    result
  end

  # The contract, not this test, decides whether a row set is well formed: both
  # the generated schema and the ordering semantics it cannot express.
  defp assert_contract(checks, provider_activity, readiness \\ "unverified") do
    result = %{
      "checks" => checks,
      "model_aliases" => [],
      "provider_activity" => provider_activity,
      "readiness" => readiness,
      "usage" => %{"llm_usage_state" => "available", "llm_usage" => []}
    }

    assert CommandContract.valid_success_result?(:doctor, result)
    assert CommandContract.valid_success_semantics?(:doctor, result)
  end

  # Rows come from sealed declarations, so most fixtures are plain custom
  # registrations. `:audited_local` is the exception: it is a trust claim only a
  # shipped source in a host-bound catalog may make. `:llm` is the default such
  # source here and matches the shipped recipe; `:llm_replay` is one of the
  # sources whose own consistency rules leave `local_preflight` free, so the
  # constructors admit the claim from it without connectivity — a pairing no
  # shipped recipe combines. Each source pins its own consistent combination.
  defp catalog(specifications) do
    {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

    # An unbound catalog cannot carry an audited-local declaration at all, so a
    # fixture that declares one seals itself against a real host document — and
    # every registration in it then follows the host-bound rules.
    bound? =
      Enum.any?(specifications, fn {_name, options} ->
        Keyword.get(options, :local_preflight, :none) == :audited_local
      end)

    registrations =
      Map.new(specifications, fn {name, options} ->
        authority = authority(Keyword.get(options, :authorization_mode, :none))
        audited? = Keyword.get(options, :local_preflight, :none) == :audited_local
        source = Keyword.get(options, :source, if(audited?, do: :llm, else: :custom))

        {:ok, descriptor} =
          ProviderDescriptor.new(
            source: source,
            installation_revision: Keyword.get(options, :revision, "doctor-v1"),
            credential_names: Keyword.get(options, :credential_names, []),
            authorization_mode: Keyword.get(options, :authorization_mode, :none),
            data_class: :normal,
            accepts_data: [:normal],
            requires: [],
            provides: [],
            destinations: Keyword.get(options, :destinations, [:workflow]),
            workflow_llm?: source in [:llm, :llm_replay],
            connectivity_mode:
              Keyword.get(
                options,
                :connectivity_mode,
                if(source == :llm, do: :probe, else: :none)
              ),
            probe_effect: Keyword.get(options, :probe_effect, if(source == :llm, do: :metadata)),
            selection_validation: Keyword.get(options, :selection_validation, :declarative),
            selection_rules: rules,
            authority_fingerprint: authority && authority.fingerprint,
            local_preflight: Keyword.get(options, :local_preflight, :none)
          )

        {name,
         %{
           descriptor: descriptor,
           implementation: implementation(options, descriptor),
           # A host-bound catalog never holds an inline authority: the runtime
           # owns it and the registration only names it. The descriptor keeps
           # the fingerprint either way, so the binding cannot drift.
           authority: if(bound? and authority, do: :host_runtime, else: authority)
         }}
      end)

    {:ok, catalog} =
      InstallationCatalog.new(registrations,
        runtime_binding: if(bound?, do: HostBoundFixture.runtime_services().runtime_binding)
      )

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

  defp implementation(options, descriptor) do
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
      if descriptor.connectivity_mode == :probe do
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
