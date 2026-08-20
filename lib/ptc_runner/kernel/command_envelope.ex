defmodule PtcRunner.Kernel.CommandEnvelope do
  @moduledoc false

  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.DestinationIdentity
  alias PtcRunner.Kernel.ProjectConfig
  alias PtcRunner.Kernel.ProjectContext
  alias PtcRunner.Kernel.PublicationHandle

  @spec publish(CommandOutcome.t(), binary()) :: :ok | {:error, :envelope_publication_failed}
  def publish(%CommandOutcome{} = outcome, path) when is_binary(path) do
    with {:ok, encoded} <- DeterministicJSON.encode(CommandOutcome.to_map(outcome)),
         {:ok, handle} <- PublicationHandle.reserve(path, :result, 0o600) do
      publish_handle(handle, encoded)
    else
      _failure -> {:error, :envelope_publication_failed}
    end
  rescue
    _exception -> {:error, :envelope_publication_failed}
  catch
    _kind, _reason -> {:error, :envelope_publication_failed}
  end

  def publish(_outcome, _path), do: {:error, :envelope_publication_failed}

  @doc false
  @spec publish_all(CommandOutcome.t(), [binary()]) ::
          :ok | {:error, :envelope_publication_failed}
  def publish_all(%CommandOutcome{} = outcome, paths) when is_list(paths) do
    paths
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&DestinationIdentity.key/1)
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case publish(outcome, path) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc false
  @spec destinations(CommandArguments.t() | nil, binary() | nil, binary()) :: [binary()]
  def destinations(arguments, envelope_path, run_ref)
      when is_binary(run_ref) or is_nil(run_ref) do
    [envelope_path, project_ledger_path(arguments, run_ref)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&DestinationIdentity.key/1)
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
