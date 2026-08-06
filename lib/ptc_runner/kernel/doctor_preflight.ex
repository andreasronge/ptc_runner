defmodule PtcRunner.Kernel.DoctorPreflight do
  @moduledoc false

  # Phase-7 audited-local execution.
  #
  # This is the only place a `:local_preflight` implementation callback runs. It
  # executes before the phase-8 marker and never enables provider activity: a
  # shipped audited-local check may inspect decoded configuration and loaded
  # adapter or executable availability, but may not resolve a credential, start
  # an application, process, or port, contact a provider, or perform network
  # work. Reaching the host is a process-free decrypt of the sealed payload, not
  # an activation.
  #
  # `DoctorPlan` renders one row per alias, but an audited-local check is a
  # property of an occurrence: its selection and destination decide what is
  # verified. Occurrences are therefore never collapsed before execution. Every
  # occurrence of a pending alias runs, in declaration order, and the alias row
  # is settled only once all of them pass.
  #
  # ## Failure translation
  #
  # A `local_preflight` failure is reported through the closed diagnostic
  # catalog, never as a check row — no provider row has a failure code in any
  # mode. This translation is the durable contract for that boundary:
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
  # local dependency. Anything else — an unknown reason, a callback that returns
  # a shape this does not recognise, one that raises, or one that outruns its
  # bound — fails closed as an internal error rather than being forced into the
  # nearest local code.

  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.DoctorPlan
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
  Runs every pending audited-local check and settles the rows it verifies.

  Returns the plan unchanged when nothing is pending, which is the whole
  no-application case: those rows are already settled as
  `skipped/application_required` and no callback can run without an occurrence.
  """
  @spec run(
          DoctorPlan.t(),
          PreparedRun.t() | nil,
          InstallationCatalog.t(),
          ProviderRuntimeServices.t(),
          pos_integer()
        ) :: {:ok, DoctorPlan.t()} | {:error, CommandDiagnostic.t()}
  def run(rows, prepared, catalog, services, timeout_ms)
      when is_list(rows) and is_integer(timeout_ms) and timeout_ms > 0 do
    case DoctorPlan.pending(rows) do
      [] -> {:ok, rows}
      pending -> run_pending(pending, rows, prepared, catalog, services, timeout_ms)
    end
  end

  def run(_rows, _prepared, _catalog, _services, _timeout_ms), do: {:error, internal_diagnostic()}

  defp run_pending(_pending, _rows, nil, _catalog, _services, _timeout_ms),
    do: {:error, internal_diagnostic()}

  defp run_pending(pending, rows, prepared, catalog, services, timeout_ms) do
    with true <- PreparedRun.valid?(prepared),
         true <- InstallationCatalog.valid?(catalog),
         true <- ProviderRuntimeServices.valid?(services) do
      Enum.reduce_while(pending, {:ok, rows}, fn row, {:ok, rows} ->
        case check_alias(row, prepared, catalog, services, timeout_ms) do
          :ok -> settle(rows, row)
          {:error, _diagnostic} = error -> {:halt, error}
        end
      end)
    else
      _invalid -> {:error, internal_diagnostic()}
    end
  rescue
    _exception -> {:error, internal_diagnostic()}
  catch
    _kind, _reason -> {:error, internal_diagnostic()}
  end

  defp settle(rows, row) do
    case DoctorPlan.settle(rows, row.name, {:pass, :available}) do
      {:ok, settled} -> {:cont, {:ok, settled}}
      {:error, _reason} -> {:halt, {:error, internal_diagnostic()}}
    end
  end

  # Every occurrence of the alias runs in declaration order and the first
  # failure stops the command, so a later occurrence never masks an earlier one
  # and no occurrence is skipped because a sibling already passed.
  defp check_alias(row, prepared, catalog, services, timeout_ms) do
    occurrences = Enum.filter(prepared.provider_declarations, &(&1.name == row.alias))

    case Map.fetch(catalog.implementations, row.alias) do
      {:ok, %{local_preflight: callback}} when is_function(callback, 3) ->
        check_occurrences(occurrences, row.alias, callback, prepared, services, timeout_ms)

      _missing ->
        {:error, internal_diagnostic()}
    end
  end

  defp check_occurrences([], _name, _callback, _prepared, _services, _timeout_ms),
    do: {:error, internal_diagnostic()}

  defp check_occurrences(occurrences, name, callback, prepared, services, timeout_ms) do
    Enum.reduce_while(occurrences, :ok, fn occurrence, :ok ->
      context = %{
        destination: occurrence.destination,
        limits: prepared.request.package.limits
      }

      case invoke(callback, occurrence.config, context, services, timeout_ms) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, diagnostic(reason, name, occurrence)}}
      end
    end)
  end

  # The callback is bounded so a shipped check that stats a filesystem or loads
  # an adapter cannot hold the command open. It is not deadline-cancellable
  # provider work, so the bound is the doctor's own, not a provider deadline.
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

  defp diagnostic(reason, name, occurrence)
       when reason in @environment_reasons,
       do: local_diagnostic(:environment_unavailable, name, occurrence)

  defp diagnostic(reason, name, occurrence) when reason in @launcher_reasons,
    do: local_diagnostic(:launcher_unavailable, name, occurrence)

  defp diagnostic(reason, name, occurrence) when reason in @adapter_reasons,
    do: local_diagnostic(:adapter_unavailable, name, occurrence)

  defp diagnostic(:provider_destination_denied, name, occurrence),
    do: declaration_diagnostic(:placement_denied, name, occurrence)

  defp diagnostic(reason, name, occurrence) when reason in @selection_reasons,
    do: declaration_diagnostic(:selection_invalid, name, occurrence)

  defp diagnostic(_reason, _name, _occurrence), do: internal_diagnostic()

  defp local_diagnostic(code, name, occurrence),
    do: subject_diagnostic(:local_preflight, code, name, :local, occurrence)

  defp declaration_diagnostic(code, name, occurrence),
    do: subject_diagnostic(:provider_declaration, code, name, :selection, occurrence)

  defp subject_diagnostic(phase, code, name, operation, occurrence) do
    occurrence = %{destination: occurrence.destination, index: occurrence.index}

    case CommandSubject.provider(name, operation, occurrence) do
      {:ok, subject} -> CommandDiagnostic.new!(phase, code, subject: subject)
      {:error, _reason} -> internal_diagnostic()
    end
  end

  defp internal_diagnostic, do: CommandDiagnostic.new!(:internal, :internal_error)
end
