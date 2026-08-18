defmodule PtcRunner.Kernel.LocalPreflight do
  @moduledoc false

  # Local declaration checks, on both sides of the phase-8 marker.
  #
  # `run/4` and `collect/4` are the only places an `:audited_local` callback
  # runs. Both execute before the marker and enable no provider activity: a
  # shipped audited-local check may inspect decoded configuration and loaded
  # adapter, executable, or fixture availability, but may not resolve a
  # credential, start an application, process, or port, contact a provider, or
  # perform network work. Reaching a host installation is a process-free
  # decrypt of the sealed payload, not an activation.
  #
  # `run_unverified/5` is the only place an `:unverified` callback runs, and it
  # is past the marker where none of those limits apply. The two steps are
  # described together under "The two steps" below.
  #
  # Applicability is derived here rather than supplied. Every selected
  # occurrence whose sealed descriptor declares `:audited_local` is checked, in
  # declaration order, so no caller can narrow the work by handing over a
  # shortened list. An audited-local check is a property of an occurrence — its
  # selection and destination decide what is verified — so occurrences are never
  # collapsed by alias before execution.
  #
  # ## Trust
  #
  # Only `:audited_local` runs here, and the two constructors bound which
  # declarations may carry that value: `ProviderDescriptor` refuses it from a
  # custom source, and `InstallationCatalog` refuses it without a host runtime
  # binding. That is a bound on what may be *declared*. It is not an attestation
  # that the implementation behind an admitted declaration came from a shipped
  # recipe: whoever assembles a catalog in-process supplies its callbacks, and
  # that code is already trusted — same-VM containment is an explicit non-goal.
  # What the rules do guarantee is that manifest input, which can only select
  # installed aliases and never register an implementation, can introduce
  # nothing into this step.
  #
  # A catalog still holds the callbacks of its `:unverified` declarations —
  # parity requires one — but they are active work, so `run/4` never invokes
  # them and `run_unverified/5` is their only entry.
  #
  # ## The two steps
  #
  # `run/4` and `collect/4` are phase 7: audited-local only, before the marker,
  # and the trust rules below bound what may declare it. `run_unverified/5` is phase 8:
  # `:unverified` only, after the marker, under the operation deadline its
  # caller anchored. Nothing bounds what an unverified callback may do, which is
  # exactly why it cannot run in phase 7 and why default doctor reports
  # `active_check_required` rather than calling it.
  #
  # They share the local half of the translation below, because those are the
  # same conditions found at different times, and they differ in two ways. Every
  # outcome of `run_unverified/5` carries cumulative `provider_activity`.
  # Invoking an unverified callback sets it; a budget exhausted before dispatch
  # preserves only evidence from earlier work. The flag is supplied to the
  # shared translator rather than inferred from the marker. And the declaration
  # half of the table does not survive the marker: see it for why.
  #
  # The prepared run, catalog, and runtime services must belong together. Alias
  # names are not identity: two catalogs can install the same alias over
  # different sealed descriptors, and accepting a mismatched trio would run one
  # catalog's callback against another's normalized occurrence.
  #
  # How much that binding proves differs by catalog. A host-bound catalog
  # carries a runtime binding, so its services are checked against it. An
  # unbound catalog has no binding for services to carry, so any services
  # constructed without one satisfy the check — the same limit
  # `ProviderExecution` has, because the identity simply does not exist. The
  # prepared-run attestation is exact in both cases.
  #
  # ## Deadline
  #
  # The caller anchors one deadline for the whole step and every occurrence
  # spends what remains of it. Nested work never resets it, so a run with many
  # audited-local occurrences cannot multiply the phase-7 bound. An exhausted
  # budget fails closed rather than continuing unbounded.
  #
  # ## Failure translation
  #
  # Runtime and active failures are reported through the closed diagnostic
  # catalog. Default doctor retains attributable failures and projects them as
  # check rows. This translation is the durable contract for those boundaries:
  #
  #   * `:local_preflight` / `:environment_unavailable` —
  #     `invalid_compatibility_environment`, `invalid_mcp_working_directory`,
  #     `mcp_command_not_found`, `invalid_mcp_executable`, and every
  #     replay-fixture reason `PtcRunner.Kernel.LLMReplayFixtureDiagnostic`
  #     renders, whether file-level or `{reason, line}`
  #   * `:local_preflight` / `:launcher_unavailable` —
  #     `mcp_stdio_launcher_unavailable`, `unsupported_mcp_stdio_platform`
  #   * `:local_preflight` / `:adapter_unavailable` — `invalid_llm_model`
  #
  # Doctor refines `mcp_command_not_found` to `command_not_found`, an existing
  # but unusable executable to `executable_unavailable`, and every replay-fixture
  # reason to `fixtures_unreadable`, so its local rows name the actionable input
  # rather than collapsing all three into environment availability. Either code
  # carries the fixture reason's own message, so the row states which rule the
  # file broke rather than only that a local check failed.
  # The declaration-class reasons differ by side of the marker:
  #
  #   * before it — `:provider_declaration` / `:placement_denied` for
  #     `provider_destination_denied`, and `:provider_declaration` /
  #     `:selection_invalid` for the per-source `invalid_*_selection` reasons.
  #     They keep their own phase deliberately: folding them into a local code
  #     would report a manifest error as a missing local dependency; and
  #   * after it — `:active_preflight` / `:selection_rejected` for both.
  #     `:provider_declaration` is a pre-classification phase pinned to
  #     `provider_activity: false`, so a post-marker run could not render it at
  #     all. What a callback reports there is a provider refusing its own
  #     selection, which is what that code already means for active selection
  #     validation, and the `:selection` subject and occurrence are unchanged.
  #     The placement/selection distinction is a phase-7 refinement and does not
  #     cross the marker, because past it the command has stopped checking
  #     declarations.
  #
  # Anything else — an unknown reason, an unrecognised result shape, or a raise
  # — fails closed as an internal error rather than being forced into the
  # nearest local code.
  #
  # An exhausted budget is the exception, because it is an expected operational
  # outcome rather than a defect: a slow filesystem or adapter load reports
  # `:local_preflight` / `:local_check_timeout`, whether the budget ran out
  # before an occurrence started or while one was running.

  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.LLMReplayFixtureDiagnostic
  alias PtcRunner.Kernel.MissionReplTarget
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.ResourceRegistrar

  @environment_reasons [
    :invalid_compatibility_environment,
    :invalid_mcp_working_directory,
    :mcp_command_not_found,
    :invalid_mcp_executable,
    :replay_owner_unavailable
  ]
  @fixture_file_reasons [
    :replay_fixtures_unreadable,
    :replay_fixtures_empty,
    :replay_fixtures_too_large
  ]
  # A replay installation's fixture file is named by the declaration, so it is
  # checked by every command that verifies declarations, not only by those that
  # acquire providers.
  @input_sources [:llm_replay]

  @launcher_reasons [:mcp_stdio_launcher_unavailable, :unsupported_mcp_stdio_platform]
  @adapter_reasons [:invalid_llm_model]
  @selection_reasons [
    :invalid_mcp_selection,
    :invalid_llm_selection,
    :invalid_llm_replay_selection,
    :invalid_trace_snapshot_selection,
    :invalid_inspection_snapshot_selection
  ]

  # The audited callback code is shipped, but replay probes admit up to an 8 MB
  # fixture and parse one response up to the installed 1 MB result ceiling.
  # Five million words matches the installed provider-work ceiling and leaves
  # room for the raw fixture, detached decoded values, and the retained entry
  # map to coexist without making phase 7 depend on an application-narrowable
  # limit.
  @max_heap_words 5_000_000

  @doc """
  Runs every applicable audited-local check for one prepared run.

  Returns `:ok` when no occurrence declares an audited-local check, which is
  also the only outcome available to a command that prepared no application.
  """
  @spec run(
          PreparedRun.t(),
          InstallationCatalog.t(),
          ProviderRuntimeServices.t(),
          Deadline.t()
        ) :: :ok | {:error, CommandDiagnostic.t()}
  def run(prepared, catalog, services, deadline) do
    run_scoped(prepared, catalog, services, deadline, :all)
  end

  @doc false
  @spec run(
          PreparedRun.t(),
          InstallationCatalog.t(),
          ProviderRuntimeServices.t(),
          Deadline.t(),
          MissionReplTarget.t()
        ) :: :ok | {:error, CommandDiagnostic.t()}
  def run(prepared, catalog, services, deadline, %MissionReplTarget{} = target) do
    run_scoped(prepared, catalog, services, deadline, target)
  end

  @doc """
  Runs the audited-local checks that read a document the declaration itself
  names, for a command that verifies declarations without acquiring providers.

  `validate` reports whether this manifest and host document can run. A replay
  installation names a fixture file the same way the manifest names a
  component: the file is part of the declaration, so a fixture that cannot load
  is a broken declaration rather than a missing local dependency, and reporting
  it here keeps `validate` from passing a configuration `run` immediately
  refuses. The environment-dependency checks — an LLM adapter, an MCP
  executable — stay out, because whether they are present says nothing about
  whether the documents are well formed.
  """
  @spec run_declared_inputs(
          PreparedRun.t(),
          InstallationCatalog.t(),
          ProviderRuntimeServices.t(),
          Deadline.t()
        ) :: :ok | {:error, CommandDiagnostic.t()}
  def run_declared_inputs(prepared, catalog, services, deadline) do
    with true <- bound?(prepared, catalog, services, :inactive),
         true <- Deadline.valid?(deadline),
         occurrences =
           applicable(catalog, prepared.provider_declarations, :audited_local, @input_sources),
         true <- trusted?(catalog, occurrences) do
      check_each(occurrences, prepared, catalog, services, deadline, audited_step(:runtime))
    else
      _invalid -> {:error, internal_diagnostic(false)}
    end
  rescue
    _exception -> {:error, internal_diagnostic(false)}
  catch
    _kind, _reason -> {:error, internal_diagnostic(false)}
  end

  defp run_scoped(prepared, catalog, services, deadline, target) do
    with true <- bound?(prepared, catalog, services, :inactive),
         {:ok, declarations} <- MissionReplTarget.declarations_for(prepared, catalog, target),
         true <- Deadline.valid?(deadline),
         occurrences = applicable(catalog, declarations, :audited_local),
         true <- trusted?(catalog, occurrences) do
      check_each(occurrences, prepared, catalog, services, deadline, audited_step(:runtime))
    else
      _invalid -> {:error, internal_diagnostic(false)}
    end
  rescue
    _exception -> {:error, internal_diagnostic(false)}
  catch
    _kind, _reason -> {:error, internal_diagnostic(false)}
  end

  @doc """
  Runs every applicable audited-local check and retains attributable failures.

  Unlike `run/4`, this doctor-only boundary does not stop after the first
  ordinary local failure. Every selected occurrence spends the same absolute
  phase deadline, and the returned diagnostics remain in declaration order.
  Invalid bindings or an unclassifiable callback result still fail closed.
  """
  @spec collect(
          PreparedRun.t(),
          InstallationCatalog.t(),
          ProviderRuntimeServices.t(),
          Deadline.t()
        ) :: {:ok, [CommandDiagnostic.t()]} | {:error, CommandDiagnostic.t()}
  def collect(prepared, catalog, services, deadline) do
    with true <- bound?(prepared, catalog, services, :inactive),
         true <- Deadline.valid?(deadline),
         occurrences = applicable(catalog, prepared.provider_declarations, :audited_local),
         true <- trusted?(catalog, occurrences) do
      occurrences
      |> collect_each(
        prepared,
        catalog,
        services,
        deadline,
        audited_step(:doctor)
      )
      |> classified_findings()
    else
      _invalid -> {:error, internal_diagnostic(false)}
    end
  rescue
    _exception -> {:error, internal_diagnostic(false)}
  catch
    _kind, _reason -> {:error, internal_diagnostic(false)}
  end

  @doc """
  Runs every applicable unverified local check for one prepared run.

  This is the only entry to an `:unverified` callback, and it is reachable only
  after the phase-8 marker: nothing bounds what such a callback may do, so it
  cannot be trusted with the pre-activity window that `run/4` occupies. Default
  doctor reports `active_check_required` rather than calling this; runs and
  `doctor --connect` call it under the operation deadline their session anchored.

  The final argument states whether an earlier step already attempted provider
  work. It is preserved when the budget expires before the first callback and
  becomes true as soon as an unverified callback is dispatched.

  There is no trust gate here, unlike `run/4`. `:unverified` is precisely the
  declaration that makes no trust claim, so there is nothing to verify — the
  marker, not the declaration, is what makes the call admissible.
  """
  @spec run_unverified(
          PreparedRun.t(),
          InstallationCatalog.t(),
          ProviderRuntimeServices.t(),
          ProviderSession.t(),
          boolean()
        ) :: :ok | {:error, CommandDiagnostic.t()}
  def run_unverified(prepared, catalog, services, session, provider_activity) do
    run_unverified_scoped(prepared, catalog, services, session, provider_activity, :all)
  end

  @doc false
  @spec run_unverified(
          PreparedRun.t(),
          InstallationCatalog.t(),
          ProviderRuntimeServices.t(),
          ProviderSession.t(),
          boolean(),
          MissionReplTarget.t()
        ) :: :ok | {:error, CommandDiagnostic.t()}
  def run_unverified(
        prepared,
        catalog,
        services,
        session,
        provider_activity,
        %MissionReplTarget{} = target
      ) do
    run_unverified_scoped(prepared, catalog, services, session, provider_activity, target)
  end

  defp run_unverified_scoped(
         prepared,
         catalog,
         services,
         session,
         provider_activity,
         target
       ) do
    deadline = ProviderSession.run_deadline(session)

    with true <- bound?(prepared, catalog, services, :active),
         {:ok, declarations} <- MissionReplTarget.declarations_for(prepared, catalog, target),
         true <- owns_operation?(session, prepared),
         true <- Deadline.valid?(deadline),
         true <- is_boolean(provider_activity) do
      catalog
      |> applicable(declarations, :unverified)
      |> check_each(
        prepared,
        catalog,
        services,
        deadline,
        active_step(prepared, session, provider_activity)
      )
    else
      _invalid -> {:error, internal_diagnostic(true)}
    end
  rescue
    _exception -> {:error, internal_diagnostic(true)}
  catch
    _kind, _reason -> {:error, internal_diagnostic(true)}
  end

  # Phase 7 needs no scope — its callbacks may not start anything — and spends a
  # fixed ceiling, because the code it runs is shipped and the step precedes the
  # limits an application can narrow. A post-marker callback is unrestricted
  # active work, so it gets the session that can own what it starts and the
  # sealed `provider_heap_words` the rest of the operation is held to.
  defp audited_step(diagnostic_mode),
    do: %{
      activity: false,
      session: nil,
      max_heap_words: @max_heap_words,
      diagnostic_mode: diagnostic_mode
    }

  defp active_step(prepared, session, provider_activity),
    do: %{
      activity: true,
      prior_activity: provider_activity,
      session: session,
      max_heap_words: prepared.request.package.limits.provider_heap_words,
      diagnostic_mode: :runtime
    }

  # One trio, one catalog. This mirrors `ProviderExecution.bound_to_prepared?/2`
  # and its runtime-services binding, so a preparation cannot be reported or
  # checked against declarations it was never validated against.
  #
  # The lifecycle half differs by step and cannot be shared: phase 7 runs before
  # the execution owner consumes the preparation, and the post-marker step runs
  # while it is consumed. Checking the wrong one would reject every valid call.
  defp bound?(%PreparedRun{} = prepared, %InstallationCatalog{} = catalog, services, lifecycle) do
    lifecycle_valid?(prepared, lifecycle) and InstallationCatalog.valid?(catalog) and
      ProviderRuntimeServices.valid?(services) and
      prepared.catalog_attestation == catalog.attestation and
      ProviderRuntimeServices.bound_to?(services, catalog.runtime_binding)
  end

  defp bound?(_prepared, _catalog, _services, _lifecycle), do: false

  defp lifecycle_valid?(prepared, :inactive), do: PreparedRun.inactive_valid?(prepared)
  defp lifecycle_valid?(prepared, :active), do: PreparedRun.active_valid?(prepared)

  # The session is a fourth thing that must belong to the same operation, on the
  # same terms as the trio. A valid session opened for another preparation, or
  # one built by hand with wider limits, would otherwise supply the deadline the
  # callback spends and the scope its resources are owned by — so the check
  # would run outside the sealed budget and lifecycle of the run it answers for.
  # The caller checks this too; the step does not depend on that, because a
  # boundary that revalidates its trio has no reason to trust its session.
  defp owns_operation?(session, prepared) do
    ProviderSession.bound_to_operation?(session, prepared.attestation) and
      ProviderSession.compatible_limits?(session, prepared.request.package.limits)
  end

  defp applicable(catalog, declarations, mode) do
    Enum.filter(declarations, fn declaration ->
      match?(%{local_preflight: ^mode}, catalog.descriptors[declaration.name])
    end)
  end

  defp applicable(catalog, declarations, mode, sources) do
    catalog
    |> applicable(declarations, mode)
    |> Enum.filter(fn declaration ->
      case catalog.descriptors[declaration.name] do
        %{source: source} -> source in sources
        _absent -> false
      end
    end)
  end

  # Fail-closed defense in depth. `ProviderDescriptor` refuses `:audited_local`
  # from a custom source and `InstallationCatalog` refuses it without a runtime
  # binding, and `bound?/3` above revalidates both seals, so a trio that reaches
  # here failing this check crossed a constructor that should not have admitted
  # it. Refusing the whole step is deliberate: skipping the untrusted occurrence
  # instead would report a passing local check nothing verified.
  defp trusted?(_catalog, []), do: true

  defp trusted?(%{runtime_binding: binding} = catalog, occurrences) when is_binary(binding) do
    Enum.all?(occurrences, fn occurrence ->
      match?(%{source: source} when source != :custom, catalog.descriptors[occurrence.name])
    end)
  end

  defp trusted?(_catalog, _occurrences), do: false

  defp check_each([], _prepared, _catalog, _services, _deadline, _step), do: :ok

  defp check_each(occurrences, prepared, catalog, services, deadline, step) do
    occurrences
    |> Enum.reduce_while({:ok, Map.get(step, :prior_activity, false)}, fn occurrence,
                                                                          {:ok, activity} ->
      case check(occurrence, prepared, catalog, services, deadline, step, activity) do
        {:ok, activity} -> {:cont, {:ok, activity}}
        {:error, _diagnostic} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _activity} -> :ok
      {:error, _diagnostic} = error -> error
    end
  end

  defp collect_each(occurrences, prepared, catalog, services, deadline, step) do
    Enum.reduce(occurrences, [], fn occurrence, findings ->
      case check(occurrence, prepared, catalog, services, deadline, step, false) do
        {:ok, false} -> findings
        {:error, %CommandDiagnostic{} = diagnostic} -> [diagnostic | findings]
      end
    end)
    |> Enum.reverse()
  end

  defp classified_findings(findings) do
    case Enum.find(findings, &(&1.phase not in [:local_preflight])) do
      nil -> {:ok, findings}
      diagnostic -> {:error, diagnostic}
    end
  end

  defp check(occurrence, prepared, catalog, services, deadline, step, prior_activity) do
    with {:ok, callback} <- callback(catalog, occurrence.name, prior_activity),
         {:ok, result} <-
           scoped(step, prepared, occurrence, deadline, prior_activity, fn context ->
             # The budget is measured after the scope is open, not before.
             # Opening and activating a registrar is a call into the session and
             # spends real time, so a timeout computed first can outlive the
             # deadline that backed it and let a callback start work the
             # operation is no longer entitled to. Confirming afterwards, as
             # `settled/3` does, changes only the reported result — it cannot
             # undo what the callback already did.
             case Deadline.remaining(deadline) do
               0 ->
                 {:timed_out, prior_activity}

               timeout_ms ->
                 activity = prior_activity or step.activity

                 {:attempted, activity,
                  invoke(callback, occurrence.config, context, services, timeout_ms, step)}
             end
           end) do
      case result do
        {:attempted, activity, :ok} ->
          settled(deadline, occurrence, activity)

        {:attempted, activity, :timed_out} ->
          {:error, local_diagnostic(:local_check_timeout, occurrence, activity)}

        {:attempted, activity, {:error, reason}} ->
          {:error, diagnostic(reason, occurrence, activity, step.diagnostic_mode)}

        {:timed_out, activity} ->
          {:error, local_diagnostic(:local_check_timeout, occurrence, activity)}
      end
    end
  end

  # An active callback receives the session's scoped registrar and its signal
  # owner, and the scope is aborted afterwards, so a process or port it starts
  # cannot outlive the check: killing the bounded worker alone would leave an
  # unlinked root that `ProviderSession.close/1` never learned about. This
  # mirrors what active selection validation does with its own validators.
  #
  # Phase 7 opens no scope because it has no session to open one from and its
  # callbacks may not start anything in the first place.
  defp scoped(%{session: nil} = step, prepared, occurrence, _deadline, _activity, run),
    do: {:ok, run.(context(prepared, occurrence, step, nil))}

  defp scoped(step, prepared, occurrence, deadline, prior_activity, run) do
    # Opening a scope is itself operation work and the session refuses to open
    # one past the deadline, so a budget already spent stops the step here
    # rather than surfacing that refusal as an internal error.
    if Deadline.expired?(deadline) do
      {:ok, {:timed_out, prior_activity}}
    else
      case ProviderSession.open_registrar(step.session) do
        {:ok, registrar} ->
          run_in_scope(
            registrar,
            step,
            prepared,
            occurrence,
            deadline,
            prior_activity,
            run
          )

        {:error, _reason} ->
          {:ok, setup_failure(deadline, prior_activity)}
      end
    end
  end

  # The session refuses scope work past the operation deadline, so a setup that
  # was live at the precheck and expired while waiting on a busy session comes
  # back as an unavailable handle. That is the budget running out, not a defect,
  # and the module contract says an exhausted budget reports the timeout.
  defp setup_failure(deadline, prior_activity) do
    if Deadline.expired?(deadline),
      do: {:timed_out, prior_activity},
      else: {:attempted, prior_activity, {:error, :internal}}
  end

  defp run_in_scope(registrar, step, prepared, occurrence, deadline, prior_activity, run) do
    result =
      case ResourceRegistrar.activate(registrar) do
        :ok -> {:ok, run.(context(prepared, occurrence, step, registrar))}
        {:error, _reason} -> {:ok, setup_failure(deadline, prior_activity)}
      end

    case ResourceRegistrar.abort(registrar) do
      :ok -> result
      {:error, _reason} -> {:error, cleanup_diagnostic()}
    end
  end

  defp context(prepared, occurrence, _step, nil),
    do: %{destination: occurrence.destination, limits: prepared.request.package.limits}

  defp context(prepared, occurrence, step, registrar) do
    prepared
    |> context(occurrence, step, nil)
    |> Map.merge(%{owner: ResourceRegistrar.owner(registrar), resource_registrar: registrar})
  end

  # The worker's bound is relative and starts after this process computed what
  # remained, so scheduling delay between the two can let a success arrive past
  # the anchored cutoff. Accepting it would let the step outrun the deadline it
  # promises to spend, so success is confirmed against the absolute deadline.
  # A failure keeps its own diagnostic: it is more informative than the budget
  # having been spent, and reporting it does not extend the step.
  defp settled(deadline, occurrence, activity) do
    if Deadline.expired?(deadline),
      do: {:error, local_diagnostic(:local_check_timeout, occurrence, activity)},
      else: {:ok, activity}
  end

  defp callback(catalog, name, activity) do
    case Map.fetch(catalog.implementations, name) do
      {:ok, %{local_preflight: callback}} when is_function(callback, 3) -> {:ok, callback}
      _missing -> {:error, internal_diagnostic(activity)}
    end
  end

  defp invoke(callback, selection, context, services, timeout_ms, step) do
    result =
      BoundedWorker.run(fn -> callback.(selection, context, services) end,
        timeout_ms: timeout_ms,
        max_heap_words: step.max_heap_words,
        cancel_with_caller: true,
        # Linking to the caller alone is not enough for active work. The
        # executor can outlive the session, so a callback blocked in network or
        # process work would keep running until the deadline even though the
        # session that owns it is gone. Phase 7 has no session and supplies no
        # target, which is what `nil` means here.
        cancel_with: ProviderSession.worker_cancel_target(step.session)
      )

    BoundedWorker.classify_callback(result)
  end

  # A refused fixture file states the rule it broke, and a line-level rejection
  # states which line. Both are part of the published fixture contract, so
  # neither leaks anything the file holds.
  defp diagnostic({entry_reason, line}, occurrence, activity, mode)
       when is_atom(entry_reason) and is_integer(line) and line > 0,
       do: fixture_diagnostic({entry_reason, line}, occurrence, activity, mode)

  defp diagnostic(reason, occurrence, activity, mode) when reason in @fixture_file_reasons,
    do: fixture_diagnostic(reason, occurrence, activity, mode)

  defp diagnostic(:mcp_command_not_found, occurrence, activity, :doctor),
    do: local_diagnostic(:command_not_found, occurrence, activity)

  defp diagnostic(:invalid_mcp_executable, occurrence, activity, :doctor),
    do: local_diagnostic(:executable_unavailable, occurrence, activity)

  defp diagnostic(reason, occurrence, activity, _mode) when reason in @environment_reasons,
    do: local_diagnostic(:environment_unavailable, occurrence, activity)

  defp diagnostic(reason, occurrence, activity, _mode) when reason in @launcher_reasons,
    do: local_diagnostic(:launcher_unavailable, occurrence, activity)

  defp diagnostic(reason, occurrence, activity, _mode) when reason in @adapter_reasons,
    do: local_diagnostic(:adapter_unavailable, occurrence, activity)

  defp diagnostic(:provider_destination_denied, occurrence, activity, _mode),
    do: declaration_diagnostic(:placement_denied, occurrence, activity)

  defp diagnostic(reason, occurrence, activity, _mode) when reason in @selection_reasons,
    do: declaration_diagnostic(:selection_invalid, occurrence, activity)

  defp diagnostic(_reason, _occurrence, activity, _mode), do: internal_diagnostic(activity)

  defp fixture_diagnostic(reason, occurrence, activity, mode) do
    case LLMReplayFixtureDiagnostic.message(reason) do
      {:ok, message} ->
        subject_diagnostic(
          :local_preflight,
          fixture_code(mode),
          :local,
          occurrence,
          activity,
          message
        )

      :error ->
        internal_diagnostic(activity)
    end
  end

  defp fixture_code(:doctor), do: :fixtures_unreadable
  defp fixture_code(_mode), do: :environment_unavailable

  defp local_diagnostic(code, occurrence, activity),
    do: subject_diagnostic(:local_preflight, code, :local, occurrence, activity)

  # Before the marker a declaration-class reason is a manifest error and keeps
  # its own phase, which is why phase 7 does not fold these into a local code.
  #
  # After the marker that phase is unreachable rather than merely unattractive:
  # `provider_declaration` is a pre-classification phase pinned to
  # `provider_activity: false`, so a post-marker run could not render it at all.
  # What an unverified callback reports there is a provider refusing its own
  # selection, which is exactly `active_preflight/selection_rejected` — the code
  # active selection validation already uses for that, carrying the same
  # `:selection` subject and occurrence. The placement/selection distinction is
  # a phase-7 refinement and is deliberately not carried across the marker,
  # because past it the command has stopped checking declarations.
  defp declaration_diagnostic(code, occurrence, false),
    do: subject_diagnostic(:provider_declaration, code, :selection, occurrence, false)

  defp declaration_diagnostic(_code, occurrence, true),
    do: subject_diagnostic(:active_preflight, :selection_rejected, :selection, occurrence, true)

  # Activity is cumulative attempted-work evidence supplied by the step that
  # knows what preceded this check. The same condition can therefore differ
  # before and after callback dispatch without borrowing the lifecycle marker.
  defp subject_diagnostic(phase, code, operation, occurrence, activity, message \\ nil) do
    site = %{destination: occurrence.destination, index: occurrence.index}

    case CommandSubject.provider(occurrence.name, operation, site) do
      {:ok, subject} ->
        opts = [subject: subject, provider_activity: activity]
        opts = if is_binary(message), do: Keyword.put(opts, :message, message), else: opts
        CommandDiagnostic.new!(phase, code, opts)

      {:error, _reason} ->
        internal_diagnostic(activity)
    end
  end

  defp internal_diagnostic(activity),
    do: CommandDiagnostic.new!(:internal, :internal_error, provider_activity: activity)

  # Only the post-marker step opens a scope, so an abort failure always reports
  # activity: there is no pre-marker path that can reach this.
  defp cleanup_diagnostic,
    do: CommandDiagnostic.new!(:result_cleanup, :provider_cleanup_failed, provider_activity: true)
end
