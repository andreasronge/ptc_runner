defmodule PtcRunner.Kernel.CommandEnvelope do
  @moduledoc false

  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.DeterministicJSON
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
