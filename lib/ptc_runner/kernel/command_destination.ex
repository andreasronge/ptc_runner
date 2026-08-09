defmodule PtcRunner.Kernel.CommandDestination do
  @moduledoc false

  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandPreparation
  alias PtcRunner.Kernel.CommandRunRef
  alias PtcRunner.Kernel.PrivateDirectory
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
    if CommandPreparation.valid?(preparation) do
      case preparation.artifact_destination_failures do
        [] -> authorize_prepared(preparation)
        _failures -> destination_failure(preparation, :invalid_destination)
      end
    else
      {:error, internal_outcome(preparation)}
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

  @spec requested_artifact_state(map()) :: %{required(binary()) => binary()}
  def requested_artifact_state(options) when is_map(options) do
    %{
      "trace" => requested_state(options, [:trace_dir, :trace]),
      "inspection" => requested_state(options, [:inspect]),
      "result" => requested_state(options, [:output, :private_output])
    }
  end

  def requested_artifact_state(_options), do: not_requested()

  defp authorize_prepared(preparation) do
    options = preparation.artifact_destinations

    case PublicationAuthority.authorize(
           preparation.run_ref,
           Map.to_list(options),
           preparation.prepared_run.effective_event_policy,
           preparation.prepared_run.effective_data_class
         ) do
      {:ok, authority} -> {:ok, authority}
      {:error, reason} -> destination_failure(preparation, destination_code(reason))
    end
  end

  defp destination_failure(preparation, code) do
    CommandPreparation.close(preparation)

    options =
      Map.merge(
        preparation.artifact_destinations,
        Map.new(preparation.artifact_destination_failures, &{&1, true})
      )

    {:error,
     CommandOutcome.run_error(
       preparation.run_ref,
       diagnostic(:destination, code),
       requested_artifact_state(options)
     )}
  end

  defp destination_code(:destination_exists), do: :destination_exists
  defp destination_code(:private_destination_required), do: :private_destination_required
  defp destination_code(:recovery_reservation_failed), do: :recovery_reservation_failed
  defp destination_code(:destination_collision), do: :destination_exists
  defp destination_code(_reason), do: :invalid_destination

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
