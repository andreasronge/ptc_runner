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
  # A failure is reported through the closed diagnostic catalog, never as a
  # doctor check row. Only the reason the shipped probe can produce is
  # translated:
  #
  #   * `:active_preflight` / `:connectivity_unavailable` —
  #     `llm_connectivity_unavailable`
  #
  # An exhausted budget reports `:active_preflight` / `:connectivity_timeout`
  # and carries no subject, because that budget belongs to the operation: it can
  # be spent before an occurrence is reached, and naming one would report a
  # provider as unreachable when nothing had reached it. As in phase 7, the
  # timeout is signalled out of band rather than through the `{:error, reason}`
  # table, so a callback returning the timeout reason itself cannot forge it.
  #
  # Anything else — an unknown reason, an unrecognised result shape, or a raise
  # — fails closed as an internal error. Translations are added with their
  # producers rather than in advance, so no branch here claims to classify a
  # failure nothing can currently return.

  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderRuntimeServices

  @unavailable_reasons [:llm_connectivity_unavailable]

  @doc """
  Probes every occurrence whose sealed descriptor declares `:probe`.

  Returns `:ok` when none does, which is the only outcome available to an
  operation whose selections all declare `:none` or `:acquisition`.
  """
  @spec run(
          PreparedRun.t(),
          InstallationCatalog.t(),
          ProviderRuntimeServices.t(),
          Deadline.t(),
          %{binary() => binary()}
        ) :: :ok | {:error, CommandDiagnostic.t()}
  def run(prepared, catalog, services, deadline, credentials) do
    with true <- bound?(prepared, catalog, services),
         true <- Deadline.valid?(deadline),
         true <- is_map(credentials) and not is_struct(credentials) do
      catalog
      |> applicable(prepared)
      |> probe_each(prepared, catalog, services, deadline, credentials)
    else
      _invalid -> {:error, internal_diagnostic()}
    end
  rescue
    _exception -> {:error, internal_diagnostic()}
  catch
    _kind, _reason -> {:error, internal_diagnostic()}
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

  defp probe_each([], _prepared, _catalog, _services, _deadline, _credentials), do: :ok

  defp probe_each(occurrences, prepared, catalog, services, deadline, credentials) do
    Enum.reduce_while(occurrences, :ok, fn occurrence, :ok ->
      case probe(occurrence, prepared, catalog, services, deadline, credentials) do
        :ok -> {:cont, :ok}
        {:error, _diagnostic} = error -> {:halt, error}
      end
    end)
  end

  defp probe(occurrence, prepared, catalog, services, deadline, credentials) do
    limits = prepared.request.package.limits

    context = %{
      destination: occurrence.destination,
      limits: limits,
      doctor_occurrence_deadline_ms: Deadline.expires_at(deadline),
      credentials: declared_credentials(catalog, occurrence.name, credentials)
    }

    with {:ok, callback} <- callback(catalog, occurrence.name),
         {:ok, timeout_ms} <- remaining(deadline) do
      case invoke(callback, occurrence.config, context, services, timeout_ms, limits) do
        :ok -> settled(deadline)
        :timed_out -> {:error, timeout_diagnostic()}
        {:error, reason} -> {:error, diagnostic(reason, occurrence)}
      end
    end
  end

  # The worker's bound is relative and starts after this process computed what
  # remained, so scheduling delay between the two can let a success arrive past
  # the anchored cutoff. Accepting it would let the step outrun the deadline it
  # promises to spend, so success is confirmed against the absolute deadline.
  defp settled(deadline) do
    if Deadline.expired?(deadline), do: {:error, timeout_diagnostic()}, else: :ok
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

  defp callback(catalog, name) do
    case Map.fetch(catalog.implementations, name) do
      {:ok, %{connectivity_probe: callback}} when is_function(callback, 3) -> {:ok, callback}
      _missing -> {:error, internal_diagnostic()}
    end
  end

  defp remaining(deadline) do
    case Deadline.remaining(deadline) do
      0 -> {:error, timeout_diagnostic()}
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

    BoundedWorker.classify_callback(result)
  end

  defp diagnostic(reason, occurrence) when reason in @unavailable_reasons do
    site = %{destination: occurrence.destination, index: occurrence.index}

    case CommandSubject.provider(occurrence.name, :connectivity, site) do
      {:ok, subject} ->
        CommandDiagnostic.new!(:active_preflight, :connectivity_unavailable,
          subject: subject,
          provider_activity: true
        )

      {:error, _reason} ->
        internal_diagnostic()
    end
  end

  defp diagnostic(_reason, _occurrence), do: internal_diagnostic()

  defp timeout_diagnostic,
    do: CommandDiagnostic.new!(:active_preflight, :connectivity_timeout, provider_activity: true)

  defp internal_diagnostic,
    do: CommandDiagnostic.new!(:internal, :internal_error, provider_activity: true)
end
