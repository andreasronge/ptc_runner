defmodule PtcRunner.Kernel.ServingCall do
  @moduledoc """
  Owns the opaque reservation used by `PtcRunner.Kernel.ServingTemplate`.

  Hosts use ServingTemplate for reserve, activation and close. This module owns
  the internal reservation representation; it does not authorize transport
  commitment or add per-call policy overrides.
  """
  alias PtcRunner.Kernel.ArtifactPublisher
  alias PtcRunner.Kernel.ExecutionInput
  alias PtcRunner.Kernel.ExecutionOutcome
  alias PtcRunner.Kernel.ExecutionPolicy
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.OwnerFailure
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.ProviderPlan
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunAdmission
  alias PtcRunner.Kernel.RunRequest
  alias PtcRunner.Kernel.ServingOutcome
  alias PtcRunner.Kernel.ServingTemplate
  alias PtcRunner.Kernel.StrictJSON
  alias PtcRunner.Kernel.ValueContract

  @opaque reservation ::
            {__MODULE__, ServingTemplate.t(), map(), RunAdmission.reservation(), integer(), pid()}

  @spec reserve(ServingTemplate.t(), term(), pid(), integer() | :infinity) ::
          {:ok, reservation()} | ServingOutcome.t()
  def reserve(template, input, admission, caller_deadline) do
    with {:ok, input} <- StrictJSON.admit(input),
         true <- is_map(input) and not is_struct(input),
         true <- ValueContract.valid?(template.package.contracts.input, input) do
      reserve_valid(template, input, admission, caller_deadline)
    else
      _ -> outcome(template, :invalid_input, false)
    end
  rescue
    _ -> outcome(template, :internal_error, false)
  end

  defp reserve_valid(template, input, admission, caller_deadline) do
    now = System.monotonic_time(:millisecond)
    limit = now + ServingTemplate.limits(template).run_duration_ms
    deadline = if caller_deadline == :infinity, do: limit, else: caller_deadline

    cond do
      not is_integer(deadline) ->
        outcome(template, :internal_error, false)

      deadline <= now ->
        outcome(template, :cancelled, false)

      true ->
        deadline = min(deadline, limit)

        case RunAdmission.reserve(admission, deadline) do
          {:ok, lease} -> {:ok, {__MODULE__, template, input, lease, deadline, self()}}
          {:error, :run_capacity_exhausted} -> outcome(template, :busy, false)
          _ -> outcome(template, :admission_unavailable, false)
        end
    end
  end

  @spec close(reservation()) :: :ok | {:error, :run_admission_unavailable}
  def close({__MODULE__, _, _, lease, _, caller}) when caller == self(),
    do: RunAdmission.close(lease)

  def close(_), do: {:error, :run_admission_unavailable}

  @spec activate(reservation()) :: ServingOutcome.t()
  def activate(reservation), do: activate(reservation, %{})

  @doc false
  def activate({__MODULE__, template, input, lease, deadline, caller}, hooks)
      when caller == self() do
    case RunAdmission.retain_publication(lease) do
      :ok -> activate_owned(template, input, lease, deadline, hooks)
      _ -> outcome(template, expired_code(deadline, :admission_unavailable), false)
    end
  end

  def activate(_, _), do: ServingOutcome.new(:internal_error, false, :write)

  defp activate_owned(template, input, lease, deadline, hooks) do
    case prepare(template, input) do
      {:ok, prepared} ->
        try do
          case PublicationAuthority.new([]) do
            {:ok, authority} ->
              execute(template, prepared, authority, lease, deadline, hooks)

            _ ->
              clean? = PreparedRun.close(prepared) == :ok
              RunAdmission.finish_publication(lease, clean?)
              outcome(template, if(clean?, do: :publication_failed, else: :cleanup_failed), false)
          end
        after
          PreparedRun.close(prepared)
        end

      _ ->
        RunAdmission.finish_publication(lease, false)
        outcome(template, :cleanup_failed, false)
    end
  rescue
    _ ->
      RunAdmission.finish_publication(lease, false)
      outcome(template, :cleanup_failed, false)
  catch
    _, _ ->
      RunAdmission.finish_publication(lease, false)
      outcome(template, :cleanup_failed, false)
  end

  defp prepare(template, input) do
    bundle = template.workflow.bundle
    bundles = Map.new(template.missions, fn {name, mission} -> {name, mission.bundle} end)

    with {:ok, input} <- ExecutionInput.new(input, :normal, template.package.contracts.input),
         {:ok, policy} <-
           ExecutionPolicy.new(
             run_id: identity(),
             trace_id: identity(),
             result_projection: :json,
             inspection_capture: false,
             event_policy: :normal
           ),
         {:ok, request} <- RunRequest.new(template.package, input, policy),
         {:ok, catalog} <-
           InstallationCatalog.new(%{}, installed_limits: template.package.installed_limits),
         {:ok, metadata} <- ProviderPlan.derive(request, bundle, bundles, []) do
      ProviderActivity.start_owned(fn activity ->
        PreparedRun.new(
          request,
          bundle,
          bundles,
          "(#{template.package.entry} data/input)",
          activity,
          catalog,
          Map.merge(metadata, %{provider_declarations: [], installation_config_digests: %{}})
        )
      end)
    end
  end

  defp execute(template, prepared, authority, lease, deadline, hooks) do
    result =
      try do
        case RunAdmission.activate(lease, prepared, authority) do
          {:ok, execution} -> collect(template, RunAdmission.await(execution), authority, hooks)
          {:error, reason} -> failure(template, reason)
        end
      rescue
        _ -> outcome(template, :internal_error, :unknown)
      catch
        _, _ -> outcome(template, :internal_error, :unknown)
      end

    prepared_clean? = PreparedRun.close(prepared) == :ok
    clean? = cleanup(authority, hooks) == :ok and prepared_clean?

    case RunAdmission.finish_publication(lease, clean?) do
      :ok when clean? ->
        replace_expired(template, result, deadline)

      {:error, :call_cancelled} when clean? ->
        outcome(template, :cancelled, ServingOutcome.metadata(result).dispatched)

      _ ->
        RunAdmission.close(lease)

        case admission_status(lease) do
          :unavailable ->
            outcome(template, :cleanup_failed, ServingOutcome.metadata(result).dispatched)

          _ when not clean? ->
            outcome(template, :cleanup_failed, ServingOutcome.metadata(result).dispatched)

          _ ->
            replace_expired(template, result, deadline)
        end
    end
  end

  defp admission_status(lease) do
    case RunAdmission.reservation_snapshot(lease) do
      {:ok, %{status: status}} -> status
      _ -> :unavailable
    end
  end

  defp cleanup(authority, hooks) do
    case Map.get(hooks, :cleanup) do
      nil -> PublicationAuthority.abort(authority)
      hook -> hook.(authority)
    end
  rescue
    _ -> {:error, :cleanup_failed}
  catch
    _, _ -> {:error, :cleanup_failed}
  end

  defp collect(template, {:ok, sealed}, authority, hooks) do
    if hook = Map.get(hooks, :before_publication), do: hook.(authority)

    case ExecutionOutcome.open(sealed, authority) do
      {:ok, evidence} ->
        published =
          ArtifactPublisher.publish(evidence, authority, Map.get(hooks, :publication, %{}))

        classify(template, evidence, published)

      _ ->
        outcome(template, :publication_failed, :unknown)
    end
  end

  defp collect(template, {:error, reason}, _authority, _hooks), do: failure(template, reason)

  defp classify(template, evidence, published) do
    cond do
      match?({:error, %{kind: :provider_cleanup_error}}, evidence.result) ->
        outcome(template, :cleanup_failed, true)

      match?({:error, _}, evidence.terminal_batch) or
          match?({:error, %{kind: :event_sink_error}}, evidence.result) ->
        outcome(template, :publication_failed, true)

      publication_failed?(published) ->
        outcome(template, :publication_failed, true)

      evidence.result_contract != :ok ->
        outcome(template, :invalid_result, true)

      match?({:error, %{reason: :terminal_result_exceeded}}, evidence.result) ->
        outcome(template, :invalid_result, true)

      match?(
        {:error, %{reason: reason}}
        when reason in [
               :invalid_result_projection,
               :public_projection_collision,
               :java_projection_error,
               :projection_error,
               :invalid_keyword,
               :invalid_lisp_list,
               :invalid_symbol_ref,
               :symbol_ref_collision
             ],
        evidence.result
      ) ->
        outcome(template, :invalid_result, true)

      match?({:error, %{reason: :timeout}}, evidence.result) ->
        outcome(template, :cancelled, true)

      match?({:error, _}, published) and match?({:ok, _}, evidence.result) ->
        outcome(template, :publication_failed, true)

      match?({:error, _}, evidence.result) ->
        outcome(template, :execution_failed, true)

      true ->
        {:ok, value} = ValueContract.json_value(elem(evidence.result, 1).value)
        outcome(template, :success, true, value)
    end
  end

  defp publication_failed?({:error, report}),
    do: report.failed != [] or report.error == :invalid_execution_outcome

  defp publication_failed?(_), do: false

  defp failure(template, :run_admission_unavailable),
    do: outcome(template, :admission_unavailable, false)

  defp failure(template, %{code: :provider_cleanup_failed}),
    do: outcome(template, :cleanup_failed, :unknown)

  defp failure(template, reason) do
    case OwnerFailure.evidence(reason) do
      {:ok, :event_sink_error, _, :not_started} -> outcome(template, :publication_failed, false)
      {:ok, _, _, :not_started} -> outcome(template, :internal_error, false)
      _ -> outcome(template, :internal_error, :unknown)
    end
  end

  defp replace_expired(template, result, deadline) do
    if ServingOutcome.code(result) != :cleanup_failed and
         expired_code(deadline, :live) == :cancelled,
       do: outcome(template, :cancelled, ServingOutcome.metadata(result).dispatched),
       else: result
  end

  defp expired_code(deadline, fallback),
    do: if(System.monotonic_time(:millisecond) >= deadline, do: :cancelled, else: fallback)

  defp outcome(template, code, dispatched, value \\ nil),
    do: ServingOutcome.new(code, dispatched, template.effect, value)

  defp identity, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
end
