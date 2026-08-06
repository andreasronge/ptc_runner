defmodule PtcRunner.Kernel.LocalPreflight do
  @moduledoc false

  # Phase-7 audited-local execution, shared by every command that reaches it.
  #
  # This is the only place a `:local_preflight` implementation callback runs. It
  # executes before the phase-8 marker and enables no provider activity: a
  # shipped audited-local check may inspect decoded configuration and loaded
  # adapter or executable availability, but may not resolve a credential, start
  # an application, process, or port, contact a provider, or perform network
  # work. Reaching a host installation is a process-free decrypt of the sealed
  # payload, not an activation.
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
  # Only `:audited_local` runs here, and only a host-installed shipped
  # declaration may carry that value: `ProviderDescriptor` refuses it from a
  # custom source and `InstallationCatalog` refuses it without a runtime
  # binding. A catalog still holds the callbacks of its `:unverified`
  # declarations — parity requires one — but they are active work and this step
  # never invokes them.
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
  #   * `:provider_declaration` / `:placement_denied` —
  #     `provider_destination_denied`
  #   * `:provider_declaration` / `:selection_invalid` — the per-source
  #     `invalid_*_selection` reasons
  #
  # Destination and selection failures keep their own phases deliberately.
  # Folding them into a local code would report a manifest error as a missing
  # local dependency. Anything else — an unknown reason, an unrecognised result
  # shape, a raise, or a callback that outruns the remaining budget — fails
  # closed as an internal error rather than being forced into the nearest local
  # code. The catalog has no phase-7 timeout code, so an exhausted budget is
  # reported the same way.

  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderRuntimeServices

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
    with true <- bound?(prepared, catalog, services),
         true <- Deadline.valid?(deadline),
         occurrences = applicable(catalog, prepared),
         true <- trusted?(catalog, occurrences) do
      check_each(occurrences, prepared, catalog, services, deadline)
    else
      _invalid -> {:error, internal_diagnostic()}
    end
  rescue
    _exception -> {:error, internal_diagnostic()}
  catch
    _kind, _reason -> {:error, internal_diagnostic()}
  end

  # One trio, one catalog. This mirrors `ProviderExecution.bound_to_prepared?/2`
  # and its runtime-services binding, so a preparation cannot be reported or
  # checked against declarations it was never validated against.
  defp bound?(%PreparedRun{} = prepared, %InstallationCatalog{} = catalog, services) do
    PreparedRun.inactive_valid?(prepared) and InstallationCatalog.valid?(catalog) and
      ProviderRuntimeServices.valid?(services) and
      prepared.catalog_attestation == catalog.attestation and
      ProviderRuntimeServices.bound_to?(services, catalog.runtime_binding)
  end

  defp bound?(_prepared, _catalog, _services), do: false

  defp applicable(catalog, prepared) do
    Enum.filter(prepared.provider_declarations, fn declaration ->
      match?(%{local_preflight: :audited_local}, catalog.descriptors[declaration.name])
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

  defp check_each([], _prepared, _catalog, _services, _deadline), do: :ok

  defp check_each(occurrences, prepared, catalog, services, deadline) do
    Enum.reduce_while(occurrences, :ok, fn occurrence, :ok ->
      case check(occurrence, prepared, catalog, services, deadline) do
        :ok -> {:cont, :ok}
        {:error, _diagnostic} = error -> {:halt, error}
      end
    end)
  end

  defp check(occurrence, prepared, catalog, services, deadline) do
    context = %{
      destination: occurrence.destination,
      limits: prepared.request.package.limits
    }

    with {:ok, callback} <- callback(catalog, occurrence.name),
         {:ok, timeout_ms} <- remaining(deadline) do
      case invoke(callback, occurrence.config, context, services, timeout_ms) do
        :ok -> :ok
        {:error, reason} -> {:error, diagnostic(reason, occurrence)}
      end
    end
  end

  defp callback(catalog, name) do
    case Map.fetch(catalog.implementations, name) do
      {:ok, %{local_preflight: callback}} when is_function(callback, 3) -> {:ok, callback}
      _missing -> {:error, internal_diagnostic()}
    end
  end

  # Every occurrence spends the caller's one anchored budget, so the step is
  # bounded by that deadline no matter how many occurrences apply.
  defp remaining(deadline) do
    case Deadline.remaining(deadline) do
      0 -> {:error, internal_diagnostic()}
      timeout_ms -> {:ok, timeout_ms}
    end
  end

  defp invoke(callback, selection, context, services, timeout_ms) do
    result =
      BoundedWorker.run(fn -> callback.(selection, context, services) end,
        timeout_ms: timeout_ms,
        max_heap_words: @max_heap_words,
        cancel_with_caller: true
      )

    case result do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} when is_atom(reason) -> {:error, reason}
      _unrecognised -> {:error, :internal}
    end
  end

  defp diagnostic(reason, occurrence) when reason in @environment_reasons,
    do: local_diagnostic(:environment_unavailable, occurrence)

  defp diagnostic(reason, occurrence) when reason in @launcher_reasons,
    do: local_diagnostic(:launcher_unavailable, occurrence)

  defp diagnostic(reason, occurrence) when reason in @adapter_reasons,
    do: local_diagnostic(:adapter_unavailable, occurrence)

  defp diagnostic(:provider_destination_denied, occurrence),
    do: declaration_diagnostic(:placement_denied, occurrence)

  defp diagnostic(reason, occurrence) when reason in @selection_reasons,
    do: declaration_diagnostic(:selection_invalid, occurrence)

  defp diagnostic(_reason, _occurrence), do: internal_diagnostic()

  defp local_diagnostic(code, occurrence),
    do: subject_diagnostic(:local_preflight, code, :local, occurrence)

  defp declaration_diagnostic(code, occurrence),
    do: subject_diagnostic(:provider_declaration, code, :selection, occurrence)

  defp subject_diagnostic(phase, code, operation, occurrence) do
    site = %{destination: occurrence.destination, index: occurrence.index}

    case CommandSubject.provider(occurrence.name, operation, site) do
      {:ok, subject} -> CommandDiagnostic.new!(phase, code, subject: subject)
      {:error, _reason} -> internal_diagnostic()
    end
  end

  defp internal_diagnostic, do: CommandDiagnostic.new!(:internal, :internal_error)
end
