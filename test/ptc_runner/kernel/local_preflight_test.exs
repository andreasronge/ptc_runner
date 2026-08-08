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
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.ResourceRegistrar
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
             LocalPreflight.run_unverified(prepared, catalog, services(), session(prepared))

    assert refusal.provider_activity
    refute_received {:audited_local, _step, _name, _destination, _selection, _limits}

    assert :ok = ProviderActivity.mark(prepared.provider_activity)
    assert :ok = LocalPreflight.run_unverified(prepared, catalog, services(), session(prepared))
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

    assert :ok = LocalPreflight.run_unverified(prepared, catalog, services(), session(prepared))
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

  test "every unverified outcome reports its own phase and code, with activity" do
    # Asserting activity alone would pass on `internal_error`, which also
    # reports activity here — so each case pins the phase and code it must not
    # collapse into.
    for {reason, phase, code} <- [
          {:invalid_llm_model, :local_preflight, :adapter_unavailable},
          {:invalid_mcp_executable, :local_preflight, :environment_unavailable},
          {:mcp_stdio_launcher_unavailable, :local_preflight, :launcher_unavailable},
          {:provider_destination_denied, :active_preflight, :selection_rejected},
          {:invalid_mcp_selection, :active_preflight, :selection_rejected}
        ] do
      diagnostic = refuse_unverified(reason)

      assert diagnostic.phase == phase, "#{reason} reported #{diagnostic.phase}"
      assert diagnostic.code == code, "#{reason} reported #{diagnostic.code}"
      assert diagnostic.provider_activity
      assert diagnostic.subject.occurrence == %{destination: :workflow, index: 0}
    end

    # An unknown reason still fails closed, and that outcome also carries
    # activity — which is exactly why the cases above pin their codes.
    assert %CommandDiagnostic{phase: :internal, code: :internal_error} =
             refuse_unverified(:something_new)
  end

  test "an unverified callback gets a scope its resources are owned by" do
    # Unrestricted active work needs somewhere to put a process root. Without a
    # registrar the callback has nowhere to register one, killing the bounded
    # worker would not reach it, and `ProviderSession.close/1` would never learn
    # it existed. Phase 7 gets neither, because its callbacks may start nothing.
    catalog =
      catalog(%{
        "audited" => [destination: :workflow],
        "custom" => [destination: :mission, source: :custom, local_preflight: :unverified]
      })

    prepared = prepared(catalog, ["audited"], ["custom"])

    assert :ok = LocalPreflight.run(prepared, catalog, services(), deadline())
    assert_received {:scope, "audited", nil, nil}

    assert :ok = ProviderActivity.mark(prepared.provider_activity)
    assert :ok = LocalPreflight.run_unverified(prepared, catalog, services(), session(prepared))
    assert_received {:scope, "custom", owner, registrar}

    assert is_pid(owner)
    assert ResourceRegistrar.valid?(registrar)
  end

  test "a root a callback registers does not outlive its check" do
    # The scope is aborted after every occurrence, so a root registered inside
    # it is gone by the time the step returns rather than waiting for session
    # close — which is what makes an unlinked process safe to allow at all.
    catalog = catalog(%{"custom" => [source: :custom, local_preflight: :unverified, root: true]})
    prepared = prepared(catalog, ["custom"])
    assert :ok = ProviderActivity.mark(prepared.provider_activity)

    assert :ok = LocalPreflight.run_unverified(prepared, catalog, services(), session(prepared))
    assert_received {:root, root}

    ref = Process.monitor(root)
    assert_receive {:DOWN, ^ref, :process, ^root, _reason}, 5_000
  end

  test "an unverified callback spends the sealed provider heap, not the audited cap" do
    # Phase 7 holds shipped code to a fixed 200k words. An unverified callback is
    # held to the `provider_heap_words` the operation itself is held to, so a
    # custom check between the two is valid work rather than an internal error.
    catalog = catalog(%{"custom" => [source: :custom, local_preflight: :unverified, heap: true]})
    prepared = prepared(catalog, ["custom"])
    assert prepared.request.package.limits.provider_heap_words > 1_000_000
    assert :ok = ProviderActivity.mark(prepared.provider_activity)

    assert :ok = LocalPreflight.run_unverified(prepared, catalog, services(), session(prepared))
    assert_received {:allocated, words} when words > 200_000
  end

  test "a blocked callback dies with the session that owns it" do
    # The bounded worker is linked to its caller, and the executor can outlive
    # the session. Without a cancel target a callback blocked in network or
    # process work would keep running after the session that owns it is gone,
    # until a run deadline that may be minutes away.
    #
    # The session is opened inside the runner because a session belongs to the
    # process that created it: opening it here and using it there would be
    # refused by the very binding check this module makes.
    catalog =
      catalog(%{"custom" => [source: :custom, local_preflight: :unverified, failing: :block]})

    prepared = prepared(catalog, ["custom"])
    assert :ok = ProviderActivity.mark(prepared.provider_activity)
    parent = self()
    limits = prepared.request.package.limits
    services = services()

    runner =
      spawn(fn ->
        {:ok, session} = ProviderSession.start_active(limits, prepared.attestation)
        {:ok, session} = ProviderSession.begin_operation(session, :run)
        send(parent, {:session, ProviderSession.worker_cancel_target(session)})

        send(
          parent,
          {:result, LocalPreflight.run_unverified(prepared, catalog, services, session)}
        )
      end)

    on_exit(fn -> Process.exit(runner, :kill) end)

    assert_receive {:session, session_pid}, 5_000
    assert_receive {:worker, worker}, 5_000
    reference = Process.monitor(worker)

    Process.exit(session_pid, :kill)
    assert_receive {:DOWN, ^reference, :process, ^worker, _reason}, 5_000
  end

  test "a session from another preparation cannot supply the scope or the clock" do
    # The session is a fourth thing that must belong to this operation. One
    # opened for a different preparation would otherwise hand over the deadline
    # the callback spends and the scope its resources are owned by.
    catalog = catalog(%{"custom" => [source: :custom, local_preflight: :unverified]})
    prepared = prepared(catalog, ["custom"])
    foreign = prepared(catalog, ["custom"])

    assert :ok = ProviderActivity.mark(prepared.provider_activity)
    assert :ok = ProviderActivity.mark(foreign.provider_activity)
    assert prepared.attestation != foreign.attestation

    assert {:error, %CommandDiagnostic{phase: :internal, code: :internal_error}} =
             LocalPreflight.run_unverified(prepared, catalog, services(), session(foreign))

    refute_received {:audited_local, _step, _name, _destination, _selection, _limits}

    # The same preparation is fine with its own session, so the refusal is about
    # the binding rather than the preparation.
    assert :ok = LocalPreflight.run_unverified(prepared, catalog, services(), session(prepared))
    assert_received {:audited_local, _step, "custom", :workflow, %{}, true}
  end

  test "a callback does not start once scope setup has spent the budget" do
    # Opening and activating the scope is a call into the session and spends
    # real time, so the budget is measured after it. A deadline that expires
    # during setup must stop the callback starting, not merely change how its
    # result is reported afterwards.
    catalog = catalog(%{"custom" => [source: :custom, local_preflight: :unverified]})
    prepared = prepared(catalog, ["custom"], [], %{"run_duration_ms" => 100})
    assert :ok = ProviderActivity.mark(prepared.provider_activity)

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             LocalPreflight.run_unverified(
               prepared,
               catalog,
               services(),
               expired_session(prepared)
             )

    assert diagnostic.phase == :local_preflight
    assert diagnostic.code == :local_check_timeout
    assert diagnostic.provider_activity
    refute_received {:audited_local, _step, _name, _destination, _selection, _limits}
  end

  test "a declaration reason keeps its own phase before the marker and not after" do
    # Phase 7 refuses to fold a manifest error into a local code. Past the
    # marker that phase is unreachable rather than unattractive: it is
    # pre-classification and pinned to no activity, so a run could not render
    # it. The occurrence and subject operation survive the change of phase.
    before = refuse(:provider_destination_denied)
    assert before.phase == :provider_declaration
    assert before.code == :placement_denied
    refute before.provider_activity

    refute CommandContract.unclassified_diagnostic_phase?(:local_preflight)
    assert CommandContract.unclassified_diagnostic_phase?(:provider_declaration)

    after_marker = refuse_unverified(:provider_destination_denied)
    assert after_marker.phase == :active_preflight
    assert after_marker.subject.operation == before.subject.operation
    assert after_marker.subject.occurrence == before.subject.occurrence
  end

  test "the local-preflight codes are admitted wherever a local check can run" do
    # A run admits every catalogued pair and renders a post-marker failure
    # through the classified branch, which is why `local_preflight` must not be
    # a pre-classification phase. `validate` and `models` open no session and
    # invoke no callback, so admitting these codes there would let them report a
    # check they cannot run.
    for code <- [
          :environment_unavailable,
          :adapter_unavailable,
          :launcher_unavailable,
          :local_check_timeout
        ] do
      for mode <- [:run, :doctor, {:doctor, :connect}] do
        assert CommandContract.diagnostic_allowed?(mode, :local_preflight, code),
               "#{inspect(mode)} must admit local_preflight/#{code}"
      end

      for mode <- [:validate, :models, :run_unclassified] do
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
             LocalPreflight.run_unverified(prepared, catalog, services(), session(prepared))

    diagnostic
  end

  defp deadline, do: Deadline.new(@deadline_ms)

  # A session whose operation clock is already spent. The step must refuse to
  # start a callback under it rather than report the timeout after the fact.
  #
  # Setting up that state is itself racy, and no budget removes the race. The
  # operation budget has to outlast `begin_operation/2`: it seals the deadline
  # before the call and the session re-checks it on arrival, so a budget the
  # round-trip outruns is already expired when the server reads it and the
  # session is refused as `:provider_session_unavailable`. But the budget is
  # also what the caller then waits out, so raising it only trades wall clock
  # for a wider margin -- 1ms lost that race often enough to fail CI, and 100ms
  # would still lose it under a long enough stall.
  #
  # So the margin is sized from measurement and the residue is retried rather
  # than hoped away: the round-trip is 6us at the median and ~1ms at its worst
  # under scheduler pressure, 100ms clears that by two orders of magnitude, and
  # a setup that loses anyway starts over instead of failing the test. Only
  # setup retries; the assertion runs once, against a session whose clock is
  # genuinely spent.
  @setup_attempts 5

  defp expired_session(prepared, attempt \\ 1) do
    limits = prepared.request.package.limits
    {:ok, session} = ProviderSession.start_active(limits, prepared.attestation)
    on_exit(fn -> ProviderSession.close(session) end)

    case ProviderSession.begin_operation(session, :run) do
      {:ok, begun} ->
        wait_until(Deadline.expires_at(ProviderSession.run_deadline(begun)) + 5)
        begun

      {:error, :provider_session_unavailable} when attempt < @setup_attempts ->
        expired_session(prepared, attempt + 1)

      {:error, reason} ->
        flunk("could not open an operation in #{@setup_attempts} attempts: #{inspect(reason)}")
    end
  end

  # Yields rather than spinning. `max_cases` is capped at the scheduler count
  # precisely because sandbox children starve under load, so burning a core to
  # watch a clock steals runtime from the tests running beside this one.
  defp wait_until(target_ms) do
    remaining_ms = target_ms - System.monotonic_time(:millisecond)

    if remaining_ms > 0 do
      receive do
      after
        remaining_ms -> wait_until(target_ms)
      end
    else
      :ok
    end
  end

  # A root registers itself from inside the callback's scope, which is the
  # protocol a real adapter follows, so aborting that scope is what must end it.
  defp register_root(parent, context) do
    registrar = Map.fetch!(context, :resource_registrar)
    owner = Map.fetch!(context, :owner)
    caller = self()

    root =
      spawn(fn ->
        reference = Process.monitor(owner)
        :ok = ResourceRegistrar.register_root(registrar)
        send(caller, :registered)
        receive do: ({:DOWN, ^reference, :process, _pid, _reason} -> :ok)
      end)

    # Registration has to be observed before the callback returns, or the scope
    # could abort before the root joined it and the test would prove nothing.
    receive do
      :registered -> send(parent, {:root, root})
    after
      5_000 -> send(parent, {:root, :never_registered})
    end
  end

  # Comfortably past the fixed audited-local ceiling and far below the sealed
  # provider heap, so only the wrong ceiling can kill it.
  defp allocate(parent) do
    words = length(Enum.to_list(1..400_000)) * 2
    send(parent, {:allocated, words})
  end

  # The post-marker step takes the session rather than a bare deadline, because
  # an unverified callback is active work that needs a scope its resources can
  # be owned by. Building a real one is the point: a fake would not abort.
  defp session(prepared) do
    limits = prepared.request.package.limits
    {:ok, session} = ProviderSession.start_active(limits, prepared.attestation)
    on_exit(fn -> ProviderSession.close(session) end)
    {:ok, session} = ProviderSession.begin_operation(session, :run)
    session
  end

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

      send(
        parent,
        {:scope, name, Map.get(context, :owner), Map.get(context, :resource_registrar)}
      )

      if Keyword.get(options, :root), do: register_root(parent, context)
      if Keyword.get(options, :heap), do: allocate(parent)

      case failing do
        nil ->
          :ok

        :block ->
          send(parent, {:worker, self()})
          receive do: (:never -> :ok)

        :raise ->
          raise "the audited-local check refused"

        {:ok, _value} = unrecognised ->
          unrecognised

        reason ->
          {:error, reason}
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

  defp prepared(catalog, workflow, mission \\ [], limits \\ %{}) do
    manifest = %{
      "version" => 1,
      "limits" => limits,
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
