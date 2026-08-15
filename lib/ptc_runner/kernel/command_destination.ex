defmodule PtcRunner.Kernel.CommandDestination do
  @moduledoc false

  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandPreparation
  alias PtcRunner.Kernel.CommandRejection
  alias PtcRunner.Kernel.CommandRunRef
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.ProjectArtifactRoot
  alias PtcRunner.Kernel.PublicationAuthority

  @artifact_names ["trace", "inspection", "result"]
  @option_keys [:trace_dir, :inspect, :output, :private_output]

  @spec capture(map()) :: {map(), [atom()]}
  def capture(options) when is_map(options) do
    destinations = Map.take(options, @option_keys)

    case first_relative_destination(destinations) do
      nil ->
        {destinations, []}

      _relative_key ->
        case File.cwd() do
          {:ok, cwd} -> anchor(destinations, cwd)
          {:error, _reason} -> split_unanchored(destinations)
        end
    end
  end

  def capture(_options), do: {%{}, @option_keys}

  @spec preflight(CommandPreparation.t()) ::
          {:ok, PublicationAuthority.t()} | {:error, CommandOutcome.t()}
  def preflight(%CommandPreparation{} = preparation) do
    case preflight_with_context(preparation, nil) do
      {:ok, authority, nil} -> {:ok, authority}
      {:error, outcome, _rejection} -> {:error, outcome}
    end
  rescue
    _exception -> {:error, internal_outcome(preparation)}
  catch
    _kind, _reason -> {:error, internal_outcome(preparation)}
  end

  def preflight(_preparation),
    do:
      {:error,
       CommandOutcome.run_error(
         fallback_run_ref(),
         diagnostic(:internal, :internal_error),
         not_requested()
       )}

  @doc false
  @spec preflight_frontend(CommandPreparation.t(), :standalone | :mix) ::
          {:ok, PublicationAuthority.t(), nil}
          | {:error, CommandOutcome.t(), CommandRejection.t() | nil}
  def preflight_frontend(%CommandPreparation{} = preparation, frontend)
      when frontend in [:standalone, :mix] do
    preflight_with_context(preparation, frontend)
  rescue
    _exception -> {:error, internal_outcome(preparation), nil}
  catch
    _kind, _reason -> {:error, internal_outcome(preparation), nil}
  end

  @spec requested_artifact_state(map()) :: %{required(binary()) => binary()}
  def requested_artifact_state(options) when is_map(options) do
    %{
      "trace" => requested_state(options, [:trace_dir, :trace]),
      "inspection" => requested_state(options, [:inspect]),
      "result" => requested_state(options, [:output, :private_output])
    }
  end

  def requested_artifact_state(_options), do: not_requested()

  defp preflight_with_context(preparation, frontend) do
    if CommandPreparation.valid?(preparation) do
      case preparation.artifact_destination_failures do
        [] ->
          authorize_prepared(preparation, frontend)

        [failure | _later] ->
          {:error, outcome} =
            destination_failure(
              preparation,
              destination_diagnostic({:invalid_destination, artifact_name(failure)})
            )

          {:error, outcome, nil}
      end
    else
      {:error, internal_outcome(preparation), nil}
    end
  end

  defp authorize_prepared(preparation, frontend) do
    options = preparation.artifact_destinations

    result =
      with :ok <- ensure_project_artifact_root(preparation) do
        PublicationAuthority.authorize(
          preparation.run_ref,
          Map.to_list(options),
          preparation.prepared_run.effective_event_policy,
          preparation.prepared_run.effective_data_class
        )
      end

    case result do
      {:ok, authority} ->
        {:ok, authority, nil}

      {:error, {:conflicting_destinations, [first, second]} = reason} ->
        {:error, outcome} = destination_failure(preparation, destination_diagnostic(reason))
        rejection = collision_rejection(frontend, first, second)
        {:error, outcome, rejection}

      {:error, reason} ->
        {:error, outcome} = destination_failure(preparation, destination_diagnostic(reason))
        {:error, outcome, nil}
    end
  end

  defp ensure_project_artifact_root(%{project_artifact_root: nil}), do: :ok

  defp ensure_project_artifact_root(%{project_artifact_root: root}),
    do: ProjectArtifactRoot.ensure(root)

  defp destination_failure(preparation, {phase, code}) do
    CommandPreparation.close(preparation)

    options =
      Map.merge(
        preparation.artifact_destinations,
        Map.new(preparation.artifact_destination_failures, &{&1, true})
      )

    {:error,
     CommandOutcome.run_error(
       preparation.run_ref,
       diagnostic(phase, code),
       requested_artifact_state(options)
     )}
  end

  defp destination_diagnostic({:conflicting_destinations, _keys}),
    do: {:arguments, :conflicting_arguments}

  defp destination_diagnostic(:conflicting_trace_destinations),
    do: {:arguments, :conflicting_arguments}

  defp destination_diagnostic(:conflicting_result_destinations),
    do: {:arguments, :conflicting_arguments}

  defp destination_diagnostic({:invalid_destination, destination}),
    do: {:destination, invalid_destination_code(destination)}

  defp destination_diagnostic({reason, destination})
       when reason in [
              :destination_unavailable,
              :source_unavailable,
              :private_directory_unavailable,
              :private_directory_unsupported,
              :private_directory_parent_unavailable
            ] do
    {:destination, unavailable_destination_code(destination)}
  end

  defp destination_diagnostic({:destination_directory_missing, destination}),
    do: {:destination, missing_directory_code(destination)}

  defp destination_diagnostic({:private_directory_parent_unsafe, destination}),
    do: {:destination, unsafe_destination_code(destination)}

  defp destination_diagnostic({:trace_destination_unavailable, :trace}),
    do: {:destination, :trace_destination_unavailable}

  defp destination_diagnostic({:trace_directory_missing, :trace}),
    do: {:destination, :trace_directory_missing}

  defp destination_diagnostic({:trace_destination_unsafe, :trace}),
    do: {:destination, :trace_destination_unsafe}

  defp destination_diagnostic({:invalid_trace_path, :trace}),
    do: {:destination, :invalid_trace_destination}

  defp destination_diagnostic({:inspection_destination_unavailable, :inspection}),
    do: {:destination, :inspection_destination_unavailable}

  defp destination_diagnostic({:inspection_destination_unsafe, :inspection}),
    do: {:destination, :inspection_destination_unsafe}

  defp destination_diagnostic({:inspection_persistence_failed, :inspection}),
    do: {:destination, :inspection_destination_unavailable}

  defp destination_diagnostic({:invalid_inspection_path, :inspection}),
    do: {:destination, :invalid_inspection_destination}

  defp destination_diagnostic({reason, _destination})
       when reason in [
              :destination_exists,
              :private_destination_required,
              :recovery_reservation_failed,
              :destination_collision
            ],
       do: destination_diagnostic(reason)

  defp destination_diagnostic(:destination_exists), do: {:destination, :destination_exists}

  defp destination_diagnostic(:private_destination_required),
    do: {:destination, :private_destination_required}

  defp destination_diagnostic(:recovery_reservation_failed),
    do: {:destination, :recovery_reservation_failed}

  defp destination_diagnostic(:destination_collision), do: {:destination, :destination_exists}
  defp destination_diagnostic(_reason), do: {:destination, :invalid_destination}

  defp invalid_destination_code(:trace), do: :invalid_trace_destination
  defp invalid_destination_code(:inspection), do: :invalid_inspection_destination
  defp invalid_destination_code(:result), do: :invalid_result_destination

  defp unavailable_destination_code(:trace), do: :trace_destination_unavailable
  defp unavailable_destination_code(:inspection), do: :inspection_destination_unavailable
  defp unavailable_destination_code(:result), do: :result_destination_unavailable

  defp missing_directory_code(:trace), do: :trace_directory_missing
  defp missing_directory_code(:inspection), do: :inspection_directory_missing
  defp missing_directory_code(:result), do: :result_directory_missing

  defp unsafe_destination_code(:trace), do: :trace_destination_unsafe
  defp unsafe_destination_code(:inspection), do: :inspection_destination_unsafe
  defp unsafe_destination_code(:result), do: :result_destination_unsafe

  defp artifact_name(:trace_dir), do: :trace
  defp artifact_name(:inspect), do: :inspection
  defp artifact_name(key) when key in [:output, :private_output], do: :result

  defp collision_rejection(nil, _first, _second), do: nil

  defp collision_rejection(frontend, :private_output, :recovery),
    do: CommandRejection.private_output_recovery_collision(frontend)

  defp collision_rejection(frontend, first, second) do
    first = if first == :trace, do: :trace_dir, else: first

    second =
      case second do
        :trace -> :trace_dir
        :recovery -> :private_output
        destination -> destination
      end

    CommandRejection.destination_collision(:run, first, second, frontend)
  end

  defp internal_outcome(%CommandPreparation{run_ref: run_ref}) do
    run_ref = if CommandRunRef.valid?(run_ref), do: run_ref, else: fallback_run_ref()
    CommandOutcome.run_error(run_ref, diagnostic(:internal, :internal_error), not_requested())
  end

  defp requested_state(options, names) do
    if Enum.any?(names, &Map.has_key?(options, &1)),
      do: "not_written",
      else: "not_requested"
  end

  defp first_relative_destination(destinations) do
    Enum.find(@option_keys, fn key ->
      case Map.fetch(destinations, key) do
        {:ok, path} -> Path.type(path) == :relative
        :error -> false
      end
    end)
  end

  defp anchor(destinations, cwd) do
    Enum.reduce(@option_keys, {%{}, []}, fn key, {anchored, failures} ->
      with {:ok, path} <- Map.fetch(destinations, key),
           {:ok, path} <- PrivateDirectory.anchor(path, cwd) do
        {Map.put(anchored, key, path), failures}
      else
        :error -> {anchored, failures}
        {:error, _reason} -> {anchored, failures ++ [key]}
      end
    end)
  end

  defp split_unanchored(destinations) do
    Enum.reduce(@option_keys, {%{}, []}, fn key, {anchored, failures} ->
      case Map.fetch(destinations, key) do
        {:ok, path} ->
          if Path.type(path) == :absolute,
            do: {Map.put(anchored, key, path), failures},
            else: {anchored, failures ++ [key]}

        :error ->
          {anchored, failures}
      end
    end)
  end

  defp not_requested, do: Map.new(@artifact_names, &{&1, "not_requested"})

  defp diagnostic(phase, code), do: CommandDiagnostic.new!(phase, code)

  defp fallback_run_ref, do: "cmd-00000000000000000000000000"
end
