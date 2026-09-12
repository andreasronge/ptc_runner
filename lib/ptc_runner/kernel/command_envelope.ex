defmodule PtcRunner.Kernel.CommandEnvelope do
  @moduledoc false

  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.DestinationIdentity
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.ProjectConfig
  alias PtcRunner.Kernel.ProjectContext
  alias PtcRunner.Kernel.PublicationHandle

  @type destination :: binary() | PublicationHandle.t()

  @spec publish(CommandOutcome.t(), destination()) ::
          :ok
          | {:error, :envelope_publication_failed}
          | {:error, {:envelope_destination_parent_unavailable, binary()}}
  def publish(%CommandOutcome{} = outcome, path) when is_binary(path) do
    with {:ok, encoded} <- DeterministicJSON.encode(publication_map(outcome)),
         {:ok, handle} <- reserve(path) do
      publish_handle(handle, encoded)
    else
      {:error, :destination_directory_missing} ->
        {:error, {:envelope_destination_parent_unavailable, path}}

      _failure ->
        {:error, :envelope_publication_failed}
    end
  rescue
    _exception -> {:error, :envelope_publication_failed}
  catch
    _kind, _reason -> {:error, :envelope_publication_failed}
  end

  def publish(%CommandOutcome{} = outcome, %PublicationHandle{kind: :result} = handle) do
    case DeterministicJSON.encode(publication_map(outcome)) do
      {:ok, encoded} -> publish_handle(handle, encoded)
      _failure -> discard(handle)
    end
  rescue
    _exception -> discard(handle)
  catch
    _kind, _reason -> discard(handle)
  end

  def publish(_outcome, _path), do: {:error, :envelope_publication_failed}

  defp publication_map(%CommandOutcome{} = outcome) do
    case CommandOutcome.to_map(outcome) do
      %{
        "command" => "run",
        "status" => "ok",
        "artifact_state" => %{"result" => "not_requested"},
        "result" => %{"result_class" => "normal"} = result
      } = envelope ->
        put_in(envelope, ["result"], Map.delete(result, "value"))

      envelope ->
        envelope
    end
  end

  @doc false
  @spec publish_all(CommandOutcome.t(), [destination()]) ::
          :ok
          | {:partial, [binary()], [{binary(), term()}]}
          | {:error, term()}
  def publish_all(%CommandOutcome{} = outcome, paths) when is_list(paths) do
    results =
      paths
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(&destination_key/1)
      |> Enum.map(fn destination ->
        {destination_path(destination), publish(outcome, destination)}
      end)

    published = for {path, :ok} <- results, do: path
    failures = for {path, {:error, reason}} <- results, do: {path, reason}

    case {published, failures} do
      {[], []} -> {:error, :envelope_publication_failed}
      {[], failures} -> {:error, {:envelope_destinations_failed, failures}}
      {_published, []} -> :ok
      {published, failures} -> {:partial, published, failures}
    end
  end

  defp destination_path(%PublicationHandle{} = handle), do: PublicationHandle.path(handle)
  defp destination_path(path), do: path

  defp reserve(path), do: PublicationHandle.reserve(path, :result, 0o600)

  @doc false
  @spec destinations(CommandArguments.t() | nil, destination() | nil, binary()) :: [destination()]
  def destinations(arguments, envelope_path, run_ref)
      when is_binary(run_ref) or is_nil(run_ref) do
    ledger_path = project_ledger_path(arguments, run_ref)

    case {ledger_path, envelope_path} do
      {nil, nil} ->
        []

      {nil, envelope} ->
        [envelope]

      {ledger, nil} ->
        [ledger]

      {ledger, envelope} ->
        if same_destination?(ledger, envelope), do: [envelope], else: [ledger, envelope]
    end
  end

  defp project_ledger_path(
         %CommandArguments{
           command: :run,
           project: %ProjectContext{
             config: %ProjectConfig{artifact_root: root, artifacts: %{envelope: true}}
           }
         },
         run_ref
       )
       when is_binary(root) and is_binary(run_ref),
       do: Path.join([root, "envelopes", run_ref <> ".json"])

  defp project_ledger_path(_arguments, _run_ref), do: nil

  defp destination_key(%PublicationHandle{} = handle),
    do: handle |> PublicationHandle.path() |> DestinationIdentity.key()

  defp destination_key(path), do: DestinationIdentity.key(path)

  defp same_destination?(left, right), do: destination_key(left) == destination_key(right)

  @doc false
  @spec discard(PublicationHandle.t()) :: {:error, :envelope_publication_failed}
  def discard(%PublicationHandle{} = handle) do
    _ = PublicationHandle.discard(handle)
    _ = PublicationHandle.close(handle)
    {:error, :envelope_publication_failed}
  end

  defp publish_handle(handle, encoded) do
    result =
      with :ok <- PublicationHandle.write(handle, encoded),
           :ok <- PublicationHandle.sync(handle),
           :ok <- PublicationHandle.publish(handle) do
        :ok
      else
        _failure -> {:error, :envelope_publication_failed}
      end

    if result != :ok, do: _ = PublicationHandle.remove(handle)
    :ok = PublicationHandle.close(handle)
    result
  end
end
