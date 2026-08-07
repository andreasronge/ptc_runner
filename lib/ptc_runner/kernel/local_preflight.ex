defmodule PtcRunner.Kernel.LocalPreflight do
  @moduledoc false

  # Local declaration checks, on both sides of the phase-8 marker.
  #
  # `run/4` is the only place an `:audited_local` callback runs. It executes
  # before the marker and enables no provider activity: a shipped audited-local
  # check may inspect decoded configuration and loaded adapter or executable
  # availability, but may not resolve a credential, start an application,
  # process, or port, contact a provider, or perform network work. Reaching a
  # host installation is a process-free decrypt of the sealed payload, not an
  # activation.
  #
  # `run_unverified/4` is the only place an `:unverified` callback runs, and it
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
  # them and `run_unverified/4` is their only entry.
  #
  # ## The two steps
  #
  # `run/4` is phase 7: audited-local only, before the marker, and the trust
  # rules below bound what may declare it. `run_unverified/4` is phase 8:
  # `:unverified` only, after the marker, under the operation deadline its
  # caller anchored. Nothing bounds what an unverified callback may do, which is
  # exactly why it cannot run in phase 7 and why default doctor reports
  # `active_check_required` rather than calling it.
  #
  # They share the local half of the translation below, because those are the
  # same conditions found at different times, and they differ in two ways. Every
  # outcome of `run_unverified/4` carries `provider_activity`, which is a fact
  # about the marker rather than about the check, so the flag is supplied rather
  # than assumed. And the declaration half of the table does not survive the
  # marker: see it for why.
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
  # A failure is reported through the closed diagnostic catalog, never as a
  # doctor check row — no provider row has a failure code in any mode. This
  # translation is the durable contract for that boundary:
  #
  #   * `:local_preflight` / `:environment_unavailable` —
  #     `invalid_compatibility_environment`, `invalid_mcp_working_directory`,
  #     `invalid_mcp_executable`
  #   * `:local_preflight` / `:launcher_unavailable` —
  #     `mcp_stdio_launcher_unavailable`, `unsupported_mcp_stdio_platform`
  #   * `:local_preflight` / `:adapter_unavailable` — `invalid_llm_model`
  #
  # Those three are identical in both steps. The declaration-class reasons are
  # not, because their phase is reachable from only one side of the marker:
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
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.ResourceRegistrar

  @environment_reasons [
    :invalid_compatibility_environment,
    :invalid_mcp_working_directory,
    :invalid_mcp_executable
  ]
  @launcher_reasons [:mcp_stdio_launcher_unavailable, :unsupported_mcp_stdio_platform]
  @adapter_reasons [:invalid_llm_model]
  @selection_reasons [
    :invalid_mcp_selection,
    :invalid_llm_selection,
    :invalid_llm_replay_selection,
    :invalid_trace_snapshot_selection,
    :invalid_inspection_snapshot_selection
  ]

  @max_heap_words 200_000

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
    with true <- bound?(prepared, catalog, services, :inactive),
         true <- Deadline.valid?(deadline),
         occurrences = applicable(catalog, prepared, :audited_local),
         true <- trusted?(catalog, occurrences) do
      check_each(occurrences, prepared, catalog, services, deadline, audited_step())
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
  doctor reports `active_check_required` rather than calling this; run, check,
  and `doctor --connect` call it under the operation deadline their session
  anchored.

  There is no trust gate here, unlike `run/4`. `:unverified` is precisely the
  declaration that makes no trust claim, so there is nothing to verify — the
  marker, not the declaration, is what makes the call admissible.
  """
  @spec run_unverified(
          PreparedRun.t(),
          InstallationCatalog.t(),
          ProviderRuntimeServices.t(),
          ProviderSession.t()
        ) :: :ok | {:error, CommandDiagnostic.t()}
  def run_unverified(prepared, catalog, services, session) do
    deadline = ProviderSession.run_deadline(session)

    with true <- bound?(prepared, catalog, services, :active),
         true <- Deadline.valid?(deadline) do
      catalog
      |> applicable(prepared, :unverified)
      |> check_each(prepared, catalog, services, deadline, active_step(prepared, session))
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
  defp audited_step, do: %{activity: false, session: nil, max_heap_words: @max_heap_words}

  defp active_step(prepared, session),
    do: %{
      activity: true,
      session: session,
      max_heap_words: prepared.request.package.limits.provider_heap_words
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

  defp applicable(catalog, prepared, mode) do
    Enum.filter(prepared.provider_declarations, fn declaration ->
      match?(%{local_preflight: ^mode}, catalog.descriptors[declaration.name])
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
    Enum.reduce_while(occurrences, :ok, fn occurrence, :ok ->
      case check(occurrence, prepared, catalog, services, deadline, step) do
        :ok -> {:cont, :ok}
        {:error, _diagnostic} = error -> {:halt, error}
      end
    end)
  end

  defp check(occurrence, prepared, catalog, services, deadline, step) do
    with {:ok, callback} <- callback(catalog, occurrence.name, step.activity),
         {:ok, timeout_ms} <- remaining(deadline, occurrence, step.activity),
         {:ok, result} <-
           scoped(step, prepared, occurrence, fn context ->
             invoke(
               callback,
               occurrence.config,
               context,
               services,
               timeout_ms,
               step.max_heap_words
             )
           end) do
      case result do
        :ok -> settled(deadline, occurrence, step.activity)
        :timed_out -> {:error, local_diagnostic(:local_check_timeout, occurrence, step.activity)}
        {:error, reason} -> {:error, diagnostic(reason, occurrence, step.activity)}
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
  defp scoped(%{session: nil} = step, prepared, occurrence, run),
    do: {:ok, run.(context(prepared, occurrence, step, nil))}

  defp scoped(step, prepared, occurrence, run) do
    case ProviderSession.open_registrar(step.session) do
      {:ok, registrar} -> run_in_scope(registrar, step, prepared, occurrence, run)
      {:error, _reason} -> {:error, internal_diagnostic(step.activity)}
    end
  end

  defp run_in_scope(registrar, step, prepared, occurrence, run) do
    result =
      case ResourceRegistrar.activate(registrar) do
        :ok -> {:ok, run.(context(prepared, occurrence, step, registrar))}
        {:error, _reason} -> {:error, internal_diagnostic(step.activity)}
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
      else: :ok
  end

  defp callback(catalog, name, activity) do
    case Map.fetch(catalog.implementations, name) do
      {:ok, %{local_preflight: callback}} when is_function(callback, 3) -> {:ok, callback}
      _missing -> {:error, internal_diagnostic(activity)}
    end
  end

  # Every occurrence spends the caller's one anchored budget, so the step is
  # bounded by that deadline no matter how many occurrences apply. An exhausted
  # budget is the same operational outcome whether it runs out before an
  # occurrence starts or while one is running, so both report the same code.
  defp remaining(deadline, occurrence, activity) do
    case Deadline.remaining(deadline) do
      0 -> {:error, local_diagnostic(:local_check_timeout, occurrence, activity)}
      timeout_ms -> {:ok, timeout_ms}
    end
  end

  defp invoke(callback, selection, context, services, timeout_ms, max_heap_words) do
    result =
      BoundedWorker.run(fn -> callback.(selection, context, services) end,
        timeout_ms: timeout_ms,
        max_heap_words: max_heap_words,
        cancel_with_caller: true
      )

    # The exhausted budget is reported as a bare atom rather than through the
    # `{:error, reason}` translation, so a callback returning the timeout reason
    # itself cannot forge the code: an unrecognised result still fails closed.
    case result do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} when is_atom(reason) -> {:error, reason}
      {:error, :timeout} -> :timed_out
      _unrecognised -> {:error, :internal}
    end
  end

  defp diagnostic(reason, occurrence, activity) when reason in @environment_reasons,
    do: local_diagnostic(:environment_unavailable, occurrence, activity)

  defp diagnostic(reason, occurrence, activity) when reason in @launcher_reasons,
    do: local_diagnostic(:launcher_unavailable, occurrence, activity)

  defp diagnostic(reason, occurrence, activity) when reason in @adapter_reasons,
    do: local_diagnostic(:adapter_unavailable, occurrence, activity)

  defp diagnostic(:provider_destination_denied, occurrence, activity),
    do: declaration_diagnostic(:placement_denied, occurrence, activity)

  defp diagnostic(reason, occurrence, activity) when reason in @selection_reasons,
    do: declaration_diagnostic(:selection_invalid, occurrence, activity)

  defp diagnostic(_reason, _occurrence, activity), do: internal_diagnostic(activity)

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

  # Activity is a fact about the marker rather than about the check, so it is
  # supplied by the step that knows which side of the marker it runs on. The
  # same condition reported before and after the marker differs only here.
  defp subject_diagnostic(phase, code, operation, occurrence, activity) do
    site = %{destination: occurrence.destination, index: occurrence.index}

    case CommandSubject.provider(occurrence.name, operation, site) do
      {:ok, subject} ->
        CommandDiagnostic.new!(phase, code, subject: subject, provider_activity: activity)

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
