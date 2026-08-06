defmodule PtcRunner.Kernel.ProviderActiveSession do
  @moduledoc """
  Opens the active provider boundary through selection validation.

  The opener first verifies the exact sealed `PreparedRun` and
  `InstallationCatalog` pair — already consumed by the execution-session owner
  that opens the sinks — and monotonically marks provider activity. It then opens the command's `ProviderSession` and
  admits selected optional provider applications according to the sealed
  runtime services before invoking active selection validators in declaration
  order. `open_consumed_setup/5` and `begin_owned_operation/4` expose that boundary in
  two steps for the Mix-only explicit OAuth interaction: setup admission occurs
  first, while the ordinary run clock and active validators begin only after
  interaction. Both halves belong to the execution-session owner, which owns the
  prepared run; a failure here closes only the session it opened.

  Each validator runs in a heap- and time-bounded worker with its own
  provisional `ResourceRegistrar`. The callback receives only the normalized
  selection, the safe prepared context, the absolute validation deadline, and
  the scoped resource owners. Its scope is always aborted after the callback,
  so a validator cannot retain a process or port root. Caller death kills the
  linked worker while the session owner drains its provisional scope.

  Cleanup responsibility is fixed: `open_consumed_setup/5` receives a
  preparation the execution owner already consumed and a lifecycle owner that
  receives the session, so a failed open closes only the session it opened. The
  execution owner remains responsible for the prepared run's activity marker.
  """

  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.ProviderApplicationGate
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.ResourceRegistrar

  @doc false
  @spec open_consumed_setup(
          PreparedRun.t(),
          InstallationCatalog.t(),
          ProviderRuntimeServices.t(),
          pid(),
          (ProviderSession.t() -> :ok | {:error, term()})
        ) :: {:ok, ProviderSession.t()} | {:error, CommandDiagnostic.t()}
  def open_consumed_setup(
        %PreparedRun{} = prepared,
        %InstallationCatalog{} = catalog,
        %ProviderRuntimeServices{} = services,
        lifecycle_owner,
        handoff
      )
      when is_pid(lifecycle_owner) and is_function(handoff, 1) do
    with true <- PreparedRun.consumed_valid?(prepared),
         true <- InstallationCatalog.valid?(catalog),
         true <- prepared.catalog_attestation == catalog.attestation,
         true <- ProviderRuntimeServices.bound_to?(services, catalog.runtime_binding),
         true <- prepared.provider_declarations != [] do
      open_consumed(prepared, catalog, services, {:owned, lifecycle_owner, handoff})
    else
      _invalid -> {:error, internal_diagnostic(false)}
    end
  end

  def open_consumed_setup(
        _prepared,
        _catalog,
        _services,
        _lifecycle_owner,
        _handoff
      ),
      do: {:error, internal_diagnostic(false)}

  @doc """
  Anchors the operation clock this operation is entitled to and validates
  selections behind it.

  The duration is chosen by operation rather than read from the session: a run
  spends `run_duration_ms`, while `doctor --connect` spends the much shorter
  `doctor_connectivity_timeout_ms`. Sharing this boundary without choosing the
  duration would let connectivity silently inherit a run's clock.
  """
  @spec begin_owned_operation(
          ProviderSession.t(),
          PreparedRun.t(),
          InstallationCatalog.t(),
          :run | :check | :connect
        ) :: {:ok, ProviderSession.t()} | {:error, CommandDiagnostic.t()}
  def begin_owned_operation(
        session,
        %PreparedRun{} = prepared,
        %InstallationCatalog{} = catalog,
        operation
      )
      when operation in [:run, :check, :connect] do
    if PreparedRun.active_valid?(prepared) and InstallationCatalog.valid?(catalog) and
         prepared.catalog_attestation == catalog.attestation and
         ProviderSession.bound_to_operation?(session, prepared.attestation) do
      do_begin_run(session, prepared, catalog, operation_duration(prepared, operation))
    else
      reject_begin_run(session, prepared)
    end
  end

  def begin_owned_operation(_session, _prepared, _catalog, _operation),
    do: {:error, internal_diagnostic(false)}

  defp operation_duration(prepared, :connect),
    do: prepared.request.package.limits.doctor_connectivity_timeout_ms

  defp operation_duration(prepared, _operation),
    do: prepared.request.package.limits.run_duration_ms

  defp open_consumed(prepared, catalog, services, ownership) do
    case ProviderActivity.mark(prepared.provider_activity) do
      :ok -> open_marked(prepared, catalog, services, ownership)
      {:error, _reason} -> {:error, internal_diagnostic(false)}
    end
  end

  defp open_marked(prepared, catalog, services, ownership) do
    case start_session(prepared, ownership) do
      {:ok, session} -> admit_open_session(session, prepared, catalog, services)
      {:error, _reason} -> {:error, internal_diagnostic(true)}
    end
  end

  defp start_session(prepared, {:owned, lifecycle_owner, handoff}),
    do:
      ProviderSession.start_active_owned(
        prepared.request.package.limits,
        prepared.attestation,
        lifecycle_owner,
        handoff
      )

  defp admit_open_session(session, prepared, catalog, services) do
    case ProviderApplicationGate.admit(prepared, catalog, services) do
      :ok ->
        {:ok, session}

      {:error, %CommandDiagnostic{} = diagnostic} ->
        fail_with_session(session, diagnostic)
    end
  end

  defp do_begin_run(session, prepared, catalog, duration_ms) do
    case ProviderSession.begin_operation(session, duration_ms) do
      {:ok, session} ->
        validate_open_session(session, prepared, catalog)

      # `ProviderSession.begin_operation/2` queues token-authenticated cleanup when its
      # bounded call becomes unavailable. Do not follow that timeout with an
      # unbounded synchronous close against the same unavailable process.
      {:error, _reason} ->
        {:error, internal_diagnostic(true)}
    end
  end

  defp validate_open_session(session, prepared, catalog) do
    case validate_active_selections(session, prepared, catalog) do
      :ok ->
        {:ok, session}

      {:error, %CommandDiagnostic{} = diagnostic} ->
        fail_with_session(session, diagnostic)
    end
  rescue
    _exception -> fail_with_session(session, internal_diagnostic(true))
  catch
    _kind, _reason -> fail_with_session(session, internal_diagnostic(true))
  end

  defp validate_active_selections(session, prepared, catalog) do
    Enum.reduce_while(prepared.provider_declarations, :ok, fn declaration, :ok ->
      if declaration.validation_state == :active_required do
        case validate_selection(session, prepared, catalog, declaration) do
          :ok -> {:cont, :ok}
          {:error, %CommandDiagnostic{} = diagnostic} -> {:halt, {:error, diagnostic}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp validate_selection(session, prepared, catalog, declaration) do
    case ProviderSession.open_registrar(session) do
      {:ok, registrar} ->
        validate_in_scope(
          registrar,
          ProviderSession.run_deadline(session),
          prepared,
          catalog,
          declaration
        )

      {:error, _reason} ->
        {:error, internal_diagnostic(true)}
    end
  end

  defp validate_in_scope(registrar, run_deadline, prepared, catalog, declaration) do
    result =
      case ResourceRegistrar.activate(registrar) do
        :ok -> run_validator(registrar, run_deadline, prepared, catalog, declaration)
        {:error, _reason} -> {:error, internal_diagnostic(true)}
      end

    case ResourceRegistrar.abort(registrar) do
      :ok -> result
      {:error, _reason} -> {:error, cleanup_diagnostic()}
    end
  end

  defp run_validator(registrar, run_deadline, prepared, catalog, declaration) do
    deadline =
      Deadline.earliest(
        run_deadline,
        Deadline.new(prepared.request.package.limits.selection_validation_timeout_ms)
      )

    callback =
      catalog.implementations |> Map.fetch!(declaration.name) |> Map.fetch!(:selection_validator)

    context =
      Map.merge(declaration.selection_context, %{
        deadline: deadline,
        deadline_ms: Deadline.expires_at(deadline),
        installed_limits: catalog.installed_limits,
        owner: ResourceRegistrar.owner(registrar),
        resource_registrar: registrar
      })

    result =
      case Deadline.remaining(deadline) do
        0 ->
          {:error, :timeout}

        timeout_ms ->
          BoundedWorker.run(fn -> callback.(declaration.config, context) end,
            timeout_ms: timeout_ms,
            max_heap_words: prepared.request.package.limits.provider_heap_words,
            cancel_with_caller: true
          )
      end

    classify_validator_result(result, deadline, declaration)
  end

  defp classify_validator_result(result, deadline, declaration) do
    if Deadline.expired?(deadline) do
      {:error, selection_diagnostic(declaration, :selection_validation_timeout)}
    else
      do_classify_validator_result(result, declaration)
    end
  end

  defp do_classify_validator_result(result, declaration) do
    case result do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, :selection_rejected}} ->
        {:error, selection_diagnostic(declaration, :selection_rejected)}

      {:error, :timeout} ->
        {:error, selection_diagnostic(declaration, :selection_validation_timeout)}

      _failure ->
        {:error, selection_diagnostic(declaration, :selection_validation_failed)}
    end
  end

  # The prepared run belongs to the execution owner, so a failure here closes
  # only the session it opened and leaves that run for its owner to release.
  defp fail_with_session(session, diagnostic) do
    cleanup = ProviderSession.close(session)

    if cleanup == :ok,
      do: {:error, diagnostic},
      else: {:error, cleanup_diagnostic()}
  end

  defp reject_begin_run(session, prepared) do
    diagnostic = internal_diagnostic(ProviderSession.alive?(session))

    if PreparedRun.active_valid?(prepared) and
         ProviderSession.bound_to_operation?(session, prepared.attestation) do
      fail_with_session(session, diagnostic)
    else
      {:error, diagnostic}
    end
  end

  defp selection_diagnostic(declaration, code) do
    occurrence = %{destination: declaration.destination, index: declaration.index}
    {:ok, subject} = CommandSubject.provider(declaration.name, :selection, occurrence)

    CommandDiagnostic.new!(:active_preflight, code,
      subject: subject,
      provider_activity: true
    )
  end

  defp cleanup_diagnostic,
    do: CommandDiagnostic.new!(:result_cleanup, :provider_cleanup_failed, provider_activity: true)

  defp internal_diagnostic(activity),
    do: CommandDiagnostic.new!(:internal, :internal_error, provider_activity: activity)
end
