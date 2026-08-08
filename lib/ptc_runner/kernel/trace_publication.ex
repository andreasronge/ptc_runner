defmodule PtcRunner.Kernel.TracePublication do
  @moduledoc false

  alias PtcRunner.Kernel.PublicationHandle

  @type normalizer :: ([map()] -> term())
  @type validator :: ([map()] -> {:ok, term(), term()} | {:error, atom()})
  @type encoder :: ([map()] -> {:ok, binary()} | {:error, atom()})
  @type path_validator :: (binary(), boolean() -> :ok | {:error, atom()})
  @type fault_callback :: (nil | (atom() -> term()), atom() -> :ok | {:error, atom()})
  @type callbacks :: %{
          normalize: normalizer(),
          validate: validator(),
          encode: encoder(),
          validate_path: path_validator(),
          fault: fault_callback()
        }

  @doc false
  @spec publish(
          PublicationHandle.t(),
          [map()],
          boolean(),
          nil | (atom() -> term()),
          callbacks()
        ) :: :ok | {:error, atom()}
  def publish(
        handle,
        events,
        private?,
        fault_hook,
        callbacks
      )
      when is_list(events) and is_boolean(private?) and
             (is_nil(fault_hook) or is_function(fault_hook, 1)) and
             is_map(callbacks) do
    normalize = Map.fetch!(callbacks, :normalize)
    validate = Map.fetch!(callbacks, :validate)
    encode = Map.fetch!(callbacks, :encode)
    validate_path = Map.fetch!(callbacks, :validate_path)
    fault = Map.fetch!(callbacks, :fault)

    with true <- PublicationHandle.valid?(handle),
         :ok <- validate_path.(PublicationHandle.path(handle), private?),
         normalized = normalize.(events),
         {:ok, _validated, _source_id} <- validate.(normalized),
         :ok <- fault.(fault_hook, :after_validation),
         {:ok, encoded} <- encode.(normalized),
         :ok <- fault.(fault_hook, :after_encoding),
         :ok <- fault.(fault_hook, :before_write),
         :ok <- PublicationHandle.write(handle, encoded),
         :ok <- fault.(fault_hook, :after_write),
         :ok <- PublicationHandle.sync(handle),
         :ok <- fault.(fault_hook, :after_sync),
         :ok <- PublicationHandle.publish(handle) do
      case fault.(fault_hook, :after_publish) do
        :ok -> :ok
        _post_commit_failure -> {:error, :publication_committed}
      end
    else
      false ->
        {:error, :invalid_trace_log}

      {:error, :source_limit_exceeded} = error ->
        error

      {:error, reason} = error when reason in [:malformed_source, :unsupported_version] ->
        error

      {:error, :partial_write} = error ->
        error

      {:error, :publication_collision} = error ->
        error

      {:error, _reason} ->
        {:error, :trace_persistence_failed}
    end
  rescue
    _exception -> {:error, :trace_persistence_failed}
  end

  def publish(
        _handle,
        _events,
        _private?,
        _fault_hook,
        _callbacks
      ),
      do: {:error, :invalid_trace_log}
end
