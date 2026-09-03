defmodule PtcRunner.Kernel.ConnectivityProbe do
  @moduledoc false

  # The `:probe` half of the connectivity operation.
  #
  # A probe answers whether a declared provider is reachable without building
  # it, so this step selects the sealed `connectivity_probe` callback directly
  # instead of routing through the runtime registry. Direct means *which
  # callback*, and nothing more: the trio is still checked, the call still runs
  # after the phase-8 marker inside a heap- and time-bounded worker it can be
  # cancelled with, and it still spends the operation's own budget.
  #
  # Applicability is derived here rather than supplied, on the same terms as
  # `PtcRunner.Kernel.LocalPreflight`: every selected occurrence whose sealed
  # descriptor declares `:probe` is probed, in declaration order, so no caller
  # can narrow the work by handing over a shortened list. Occurrences are never
  # collapsed by alias, because a probe answers for one selection at one
  # destination.
  #
  # ## Deadline
  #
  # The caller anchors one deadline for the whole step and every occurrence
  # spends what remains of it, so many probes cannot multiply the connectivity
  # bound. That deadline is also handed to the callback as
  # `:doctor_occurrence_deadline_ms`, which is how a shipped probe intersects
  # its own intrinsic budget with the operation's. Whichever of the two is
  # smaller — including an exact tie — the outcome stays a connectivity-class
  # diagnostic, because this step never consults another operation's clock.
  #
  # ## Credentials
  #
  # A probe is handed the credentials phase-8 step 5 already resolved and never
  # resolves its own, so one command reads a credential once no matter how many
  # occurrences need it. Each occurrence receives only the names its own sealed
  # descriptor declares, on the same least-privilege terms acquisition uses.
  #
  # ## Failure translation
  #
  # A failure is reported authoritatively through the closed diagnostic catalog.
  # The doctor command may additionally project an attributable diagnostic into
  # its corresponding failed check row; subjectless operation timeouts remain
  # diagnostic-only. Only reasons the shipped probe can produce are translated:
  #
  #   * `:active_preflight` / `:connectivity_unavailable` —
  #     `llm_connectivity_unavailable` or a normalized non-authentication LLM
  #     provider failure
  #   * `:local_preflight` / `:model_contract_unsupported` — the sealed
  #     `ModelContractPricingCause` produced only from the adapter's exact,
  #     payload-free uncataloged-pricing sentinel.
  #   * `:active_preflight` / `:authentication_rejected` — a normalized LLM
  #     `authentication_failed` or `denied` response. The endpoint answered, so
  #     the diagnostic names credentials and proves connectivity.
  #
  # An exhausted budget reports `:active_preflight` / `:connectivity_timeout`
  # and carries no subject, because that budget belongs to the operation: it can
  # be spent before an occurrence is reached, and naming one would report a
  # provider as unreachable when nothing had reached it. Its activity value is
  # cumulative evidence from earlier work until a probe callback is actually
  # dispatched. As in phase 7, the timeout is signalled out of band rather than
  # through the `{:error, reason}` table, so a callback returning the timeout
  # reason itself cannot forge it.
  #
  # Anything else — an unknown reason, an unrecognised result shape, or a raise
  # — fails closed as an internal error. Translations are added with their
  # producers rather than in advance, so no branch here claims to classify a
  # failure nothing can currently return.
  #
  # ## Usage
  #
  # A probe that reached a metered provider may report what its request spent.
  # The payload is the callback's own and is closed here through
  # `LLMUsage.normalize/1` before it becomes evidence, so an unrecognised shape
  # fails the occurrence rather than travelling on: a probe whose account cannot
  # be read is not a probe whose account is zero. One entry is produced per
  # probed occurrence, in the order the occurrences were probed, and a callback
  # answering a bare `:ok` produces an entry whose usage is absent.

  alias PtcRunner.Kernel.AcquisitionReason
  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.LLMUsage
  alias PtcRunner.Kernel.ModelContractPricingCause
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.ProviderRuntimeServices

  @unavailable_reasons [:llm_connectivity_unavailable]
  @llm_authentication_kinds [:authentication_failed, :denied]

  @type usage_entry :: %{
          name: binary(),
          destination: :workflow | :mission,
          index: non_neg_integer(),
          usage: map() | nil
        }

  @doc """
  Probes every occurrence whose sealed descriptor declares `:probe`.

  Returns the cumulative activity value and one usage entry per probed
  occurrence when every applicable probe succeeds. When none applies, the
  supplied earlier activity is returned unchanged beside no entries.
  """
  @spec run(
          PreparedRun.t(),
          InstallationCatalog.t(),
          ProviderRuntimeServices.t(),
          Deadline.t(),
          %{binary() => binary()},
          boolean()
        ) :: {:ok, boolean(), [usage_entry()]} | {:error, CommandDiagnostic.t()}
  def run(prepared, catalog, services, deadline, credentials, provider_activity) do
    with true <- bound?(prepared, catalog, services),
         true <- Deadline.valid?(deadline),
         true <- is_map(credentials) and not is_struct(credentials),
         true <- is_boolean(provider_activity) do
      catalog
      |> applicable(prepared)
      |> probe_each(prepared, catalog, services, deadline, credentials, provider_activity)
    else
      _invalid -> {:error, internal_diagnostic(true)}
    end
  rescue
    _exception -> {:error, internal_diagnostic(true)}
  catch
    _kind, _reason -> {:error, internal_diagnostic(true)}
  end

  # One trio, one catalog. The preparation is consumed while its operation runs,
  # so its seal is checked rather than its lifecycle state — the same check
  # `ConnectivityResult` makes of the pair it binds itself to.
  defp bound?(%PreparedRun{} = prepared, %InstallationCatalog{} = catalog, services) do
    PreparedRun.sealed?(prepared) and InstallationCatalog.valid?(catalog) and
      ProviderRuntimeServices.valid?(services) and
      prepared.catalog_attestation == catalog.attestation and
      ProviderRuntimeServices.bound_to?(services, catalog.runtime_binding)
  end

  defp bound?(_prepared, _catalog, _services), do: false

  defp applicable(catalog, prepared) do
    Enum.filter(prepared.provider_declarations, fn declaration ->
      match?(%{connectivity_mode: :probe}, catalog.descriptors[declaration.name])
    end)
  end

  defp probe_each(
         [],
         _prepared,
         _catalog,
         _services,
         _deadline,
         _credentials,
         provider_activity
       ),
       do: {:ok, provider_activity, []}

  defp probe_each(
         occurrences,
         prepared,
         catalog,
         services,
         deadline,
         credentials,
         provider_activity
       ) do
    occurrences
    |> Enum.reduce_while({:ok, provider_activity, []}, fn occurrence, {:ok, activity, entries} ->
      case probe(occurrence, prepared, catalog, services, deadline, credentials, activity) do
        {:ok, activity, usage} ->
          {:cont, {:ok, activity, [usage_entry(occurrence, usage) | entries]}}

        {:error, _diagnostic} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, activity, entries} -> {:ok, activity, Enum.reverse(entries)}
      {:error, _diagnostic} = error -> error
    end
  end

  defp usage_entry(occurrence, usage),
    do: %{
      name: occurrence.name,
      destination: occurrence.destination,
      index: occurrence.index,
      usage: usage
    }

  defp probe(
         occurrence,
         prepared,
         catalog,
         services,
         deadline,
         credentials,
         provider_activity
       ) do
    limits = prepared.request.package.limits

    context = %{
      destination: occurrence.destination,
      limits: limits,
      doctor_occurrence_deadline_ms: Deadline.expires_at(deadline),
      credentials: declared_credentials(catalog, occurrence.name, credentials)
    }

    with {:ok, callback} <- callback(catalog, occurrence.name, provider_activity),
         {:ok, timeout_ms} <- remaining(deadline, provider_activity) do
      case invoke(callback, occurrence.config, context, services, timeout_ms, limits) do
        :ok ->
          settled(deadline, nil)

        {:ok, payload} ->
          settled_with_usage(deadline, payload)

        :timed_out ->
          {:error, timeout_diagnostic(true)}

        {:error, reason} ->
          descriptor = Map.get(catalog.descriptors, occurrence.name)
          {:error, diagnostic(reason, occurrence, descriptor)}
      end
    end
  end

  # The payload is whatever the callback handed back. A shape this module cannot
  # close is not admitted as an account of what was spent, and the probe fails
  # closed rather than reporting an occurrence as reached with no usable record.
  defp settled_with_usage(deadline, payload) do
    case LLMUsage.normalize(payload) do
      {:ok, usage} -> settled(deadline, usage)
      {:error, :invalid_llm_usage} -> {:error, internal_diagnostic(true)}
    end
  end

  # The worker's bound is relative and starts after this process computed what
  # remained, so scheduling delay between the two can let a success arrive past
  # the anchored cutoff. Accepting it would let the step outrun the deadline it
  # promises to spend, so success is confirmed against the absolute deadline.
  defp settled(deadline, usage) do
    if Deadline.expired?(deadline),
      do: {:error, timeout_diagnostic(true)},
      else: {:ok, true, usage}
  end

  # Least privilege, and a fail-closed empty map rather than the whole union if
  # the descriptor is somehow missing: an occurrence that cannot be looked up
  # here is refused a moment later by `callback/2` anyway.
  defp declared_credentials(catalog, name, credentials) do
    case Map.fetch(catalog.descriptors, name) do
      {:ok, descriptor} -> Map.take(credentials, descriptor.credential_names)
      :error -> %{}
    end
  end

  defp callback(catalog, name, provider_activity) do
    case Map.fetch(catalog.implementations, name) do
      {:ok, %{connectivity_probe: callback}} when is_function(callback, 3) -> {:ok, callback}
      _missing -> {:error, internal_diagnostic(provider_activity)}
    end
  end

  defp remaining(deadline, provider_activity) do
    case Deadline.remaining(deadline) do
      0 -> {:error, timeout_diagnostic(provider_activity)}
      timeout_ms -> {:ok, timeout_ms}
    end
  end

  defp invoke(callback, selection, context, services, timeout_ms, limits) do
    result =
      BoundedWorker.run(fn -> callback.(selection, context, services) end,
        timeout_ms: timeout_ms,
        max_heap_words: limits.provider_heap_words,
        cancel_with_caller: true
      )

    case result do
      {:ok, {:error, %ProviderError{} = error}} ->
        if ProviderError.valid?(error), do: {:error, error}, else: {:error, :internal}

      other ->
        BoundedWorker.classify_payload_callback(other)
    end
  end

  defp diagnostic(%ModelContractPricingCause{} = reason, occurrence, _descriptor),
    do:
      AcquisitionReason.diagnostic(reason, %{
        provider: occurrence.name,
        destination: occurrence.destination,
        index: occurrence.index
      })

  defp diagnostic(reason, occurrence, _descriptor) when reason in @unavailable_reasons do
    connectivity_diagnostic(occurrence)
  end

  defp diagnostic(
         %ProviderError{kind: kind, dispatch_provenance: :dispatched},
         occurrence,
         %{source: :llm}
       )
       when kind in @llm_authentication_kinds do
    case CommandSubject.provider(occurrence.name, :credentials) do
      {:ok, subject} ->
        CommandDiagnostic.new!(:active_preflight, :authentication_rejected,
          subject: subject,
          provider_activity: true
        )

      {:error, _reason} ->
        internal_diagnostic(true)
    end
  end

  defp diagnostic(%ProviderError{}, occurrence, _descriptor) do
    connectivity_diagnostic(occurrence)
  end

  defp diagnostic(_reason, _occurrence, _descriptor), do: internal_diagnostic(true)

  defp connectivity_diagnostic(occurrence) do
    site = %{destination: occurrence.destination, index: occurrence.index}

    case CommandSubject.provider(occurrence.name, :connectivity, site) do
      {:ok, subject} ->
        CommandDiagnostic.new!(:active_preflight, :connectivity_unavailable,
          subject: subject,
          provider_activity: true
        )

      {:error, _reason} ->
        internal_diagnostic(true)
    end
  end

  defp timeout_diagnostic(provider_activity),
    do:
      CommandDiagnostic.new!(:active_preflight, :connectivity_timeout,
        provider_activity: provider_activity
      )

  defp internal_diagnostic(provider_activity),
    do: CommandDiagnostic.new!(:internal, :internal_error, provider_activity: provider_activity)
end
