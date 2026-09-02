defmodule PtcRunner.Kernel.ProviderCredentials do
  @moduledoc false

  # Phase-8 step 5: the one place an active command resolves ordinary
  # credentials.
  #
  # Every active command — a run and `doctor --connect` — crosses
  # this step once, after the registry and OAuth context exist and before any
  # provider prepare, preflight, acquisition, or execution callback runs.
  # Active selection checks, unverified local checks, command-owned provider
  # application startup, or OAuth authorization may already have run, so the
  # caller supplies that activity evidence. Resolving here rather than inside
  # acquisition is what makes one credential model serve all three: acquisition
  # answers for the closure it acquires, and a `:none` occurrence that declares
  # a credential is inside no closure at all, so a connect that resolved only
  # the remainder its closure missed would need a credential path of its own.
  #
  # ## Required names
  #
  # The union comes from the sealed descriptor of every selected declaration,
  # never from what a prepare callback reported. Deriving the requirement from
  # callback reports would make the authority to read a credential depend on
  # invoking the code that reads it, which is the same rule that decides the
  # acquisition closure and holds here for the same reason.
  #
  # Consumers receive the resolved map and take their own declared subset from
  # it. A provider that reports a name this union does not contain is drift and
  # fails closed at the consumer, because the map cannot cover it.
  #
  # ## Attribution
  #
  # `DiagnosticCatalog.subject_occurrence_policy/3` forbids an occurrence on
  # `active_preflight`/`credential_unavailable`, so a failure is attributed per
  # alias and not per occurrence. The resolver reports no name either — it
  # answers for the batch — so the alias cannot be the one that actually failed.
  # It is instead the first alias in manifest order that declares a credential:
  # deterministic, independent of resolver behaviour, and stable against the
  # order providers happen to be prepared in.
  #
  # ## Deadline
  #
  # Resolution spends the operation deadline the session anchored, and an
  # exhausted budget keeps the credential-class diagnostic rather than the
  # operation's own, which is what the deadline contract specifies for this
  # class of work. A command declaring no credential does no work here and
  # reports nothing: the next step checks the same deadline and reports it with
  # the operation class it belongs to.

  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.MissionReplTarget
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderSession

  @doc """
  Resolves every credential the sealed selected declarations require.

  Returns `{:ok, %{}}` without calling the resolver when nothing declares one.
  `provider_activity` states whether earlier work in this operation already
  crossed a provider-facing boundary; a failure preserves that fact.
  """
  @spec resolve(
          PreparedRun.t(),
          InstallationCatalog.t(),
          ProviderRegistry.t(),
          ProviderSession.t(),
          boolean()
        ) :: {:ok, %{binary() => binary()}} | {:error, CommandDiagnostic.t()}
  def resolve(prepared, catalog, registry, session, provider_activity) do
    resolve_scoped(prepared, catalog, registry, session, provider_activity, :all)
  end

  @doc false
  def resolve(
        prepared,
        catalog,
        registry,
        session,
        provider_activity,
        %MissionReplTarget{} = target
      ) do
    resolve_scoped(prepared, catalog, registry, session, provider_activity, target)
  end

  defp resolve_scoped(prepared, catalog, registry, session, provider_activity, target) do
    with true <- is_boolean(provider_activity),
         true <- bound?(prepared, catalog, registry),
         {:ok, declarations} <- MissionReplTarget.declarations_for(prepared, catalog, target),
         {:ok, deadline} when not is_nil(deadline) <-
           ProviderSession.execution_deadline(session) do
      declarations
      |> required_names(catalog)
      |> resolve_required(
        prepared,
        catalog,
        registry,
        session,
        deadline,
        provider_activity,
        declarations
      )
    else
      _invalid -> {:error, internal_diagnostic()}
    end
  rescue
    _exception -> {:error, internal_diagnostic()}
  catch
    _kind, _reason -> {:error, internal_diagnostic()}
  end

  @doc false
  @spec required_names([map()], InstallationCatalog.t()) :: [binary()]
  def required_names(declarations, %InstallationCatalog{} = catalog) do
    declarations
    |> Enum.flat_map(&Map.fetch!(catalog.descriptors, &1.name).credential_names)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # One trio, one catalog. The preparation is consumed while its operation runs,
  # so its seal is checked rather than its lifecycle state, as in the phase-7
  # and probe steps that read the same sealed declarations.
  defp bound?(%PreparedRun{} = prepared, %InstallationCatalog{} = catalog, registry) do
    PreparedRun.sealed?(prepared) and InstallationCatalog.valid?(catalog) and
      prepared.catalog_attestation == catalog.attestation and
      ProviderRegistry.valid?(registry)
  end

  defp bound?(_prepared, _catalog, _registry), do: false

  defp resolve_required(
         [],
         _prepared,
         _catalog,
         _registry,
         _session,
         _deadline,
         _provider_activity,
         _declarations
       ),
       do: {:ok, %{}}

  defp resolve_required(
         names,
         prepared,
         catalog,
         registry,
         session,
         deadline,
         provider_activity,
         declarations
       ) do
    max_heap_words = prepared.request.package.limits.provider_heap_words

    result =
      case Deadline.remaining(deadline) do
        0 ->
          {:error, :timeout}

        timeout_ms ->
          BoundedWorker.run(fn -> ProviderRegistry.resolve_credentials(registry, names) end,
            timeout_ms: timeout_ms,
            max_heap_words: max_heap_words,
            cancel_with_caller: true,
            cancel_with: ProviderSession.worker_cancel_target(session)
          )
      end

    # The worker's bound is relative and starts after this process computed what
    # remained, so a success can arrive past the absolute cutoff. Accepting it
    # would let the step hand a credential to work the operation may no longer
    # do, so the deadline decides rather than the worker.
    if Deadline.expired?(deadline) do
      unavailable(prepared, catalog, provider_activity, declarations)
    else
      case result do
        {:ok, {:ok, credentials}} -> {:ok, credentials}
        _failure -> unavailable(prepared, catalog, provider_activity, declarations)
      end
    end
  end

  defp unavailable(_prepared, catalog, provider_activity, declarations) do
    with name when is_binary(name) <- attributed_alias(declarations, catalog),
         {:ok, subject} <- CommandSubject.provider(name, :credentials) do
      {:error,
       CommandDiagnostic.new!(:active_preflight, :credential_unavailable,
         subject: subject,
         provider_activity: provider_activity
       )}
    else
      _invalid -> {:error, internal_diagnostic()}
    end
  end

  # Reachable only with a non-empty union, so a declaration bearing credentials
  # always exists. The fail-closed `nil` is what the caller turns into an
  # internal error rather than an unattributed credential failure.
  defp attributed_alias(declarations, catalog) do
    Enum.find_value(declarations, fn declaration ->
      descriptor = Map.fetch!(catalog.descriptors, declaration.name)
      if descriptor.credential_names != [], do: declaration.name
    end)
  end

  defp internal_diagnostic,
    do: CommandDiagnostic.new!(:internal, :internal_error, provider_activity: true)
end
