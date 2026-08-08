defmodule PtcRunner.Kernel.TracePublication do
  @moduledoc false

  alias PtcRunner.Kernel.PublicationHandle

  @type normalizer :: ([map()] -> term())
  @type validator :: ([map()] -> {:ok, term(), term()} | {:error, atom()})
  @type encoder :: ([map()] -> {:ok, binary()} | {:error, atom()})
  @type reader :: (PublicationHandle.t(), pos_integer() -> {:ok, binary()} | {:error, atom()})
  @type decoder :: (binary() -> {:ok, [map()]} | {:error, atom()})
  @type limiter :: (binary(), binary() -> :ok | {:error, atom()})
  @type locker :: (binary(), (-> term()) -> term())
  @type path_validator :: (binary(), boolean() -> :ok | {:error, atom()})
  @type fault_callback :: (nil | (atom() -> term()), atom() -> :ok | {:error, atom()})
  @type callbacks :: %{
          normalize: normalizer(),
          validate: validator(),
          encode: encoder(),
          read: reader(),
          decode: decoder(),
          within_limit: limiter(),
          lock: locker(),
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
    validate_path = Map.fetch!(callbacks, :validate_path)

    with true <- PublicationHandle.valid?(handle),
         :ok <- validate_path.(PublicationHandle.path(handle), private?),
         result <-
           publish_with_lock(handle, events, fault_hook, callbacks) do
      normalize_result(result)
    else
      false -> {:error, :invalid_trace_log}
      result -> normalize_result(result)
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

  defp publish_with_lock(handle, events, fault_hook, callbacks) do
    normalize = Map.fetch!(callbacks, :normalize)
    validate = Map.fetch!(callbacks, :validate)
    encode = Map.fetch!(callbacks, :encode)
    read = Map.fetch!(callbacks, :read)
    decode = Map.fetch!(callbacks, :decode)
    within_limit = Map.fetch!(callbacks, :within_limit)
    lock = Map.fetch!(callbacks, :lock)
    fault = Map.fetch!(callbacks, :fault)

    publish = fn ->
      with {:ok, existing_source} <- read.(handle, 8_000_000),
           {:ok, existing_events} <- decode.(existing_source),
           normalized = normalize.(events),
           {:ok, _validated, _source_id} <- validate.(existing_events ++ normalized),
           :ok <- fault.(fault_hook, :after_validation),
           {:ok, encoded} <- encode.(normalized),
           :ok <- within_limit.(existing_source, encoded),
           :ok <- fault.(fault_hook, :after_encoding),
           :ok <- fault.(fault_hook, :before_write),
           :ok <- write_handle(handle, existing_source, encoded),
           :ok <- fault.(fault_hook, :after_write),
           :ok <- PublicationHandle.sync(handle),
           :ok <- after_sync(handle, fault, fault_hook),
           :ok <- PublicationHandle.publish(handle) do
        case fault.(fault_hook, :after_publish) do
          :ok -> :ok
          _post_commit_failure -> {:error, :publication_committed}
        end
      end
    end

    if PublicationHandle.append?(handle) do
      case fault.(fault_hook, :before_lock) do
        :ok -> lock.(PublicationHandle.path(handle), publish)
        failure -> failure
      end
    else
      publish.()
    end
  end

  defp write_handle(handle, existing_source, encoded) do
    if PublicationHandle.append?(handle) do
      PublicationHandle.write_if_unchanged(handle, existing_source, encoded)
    else
      PublicationHandle.write(handle, encoded)
    end
  end

  defp after_sync(handle, fault, fault_hook) do
    case fault.(fault_hook, :after_sync) do
      :ok ->
        :ok

      failure ->
        if PublicationHandle.append?(handle) and PublicationHandle.visible?(handle) do
          {:error, :publication_committed}
        else
          case failure do
            {:error, _reason} = error -> error
            _other -> {:error, :publication_failed}
          end
        end
    end
  end

  defp normalize_result(:ok), do: :ok

  defp normalize_result({:error, reason} = error)
       when reason in [
              :source_limit_exceeded,
              :malformed_source,
              :unsupported_version,
              :partial_write,
              :source_changed,
              :publication_collision,
              :publication_committed
            ],
       do: error

  defp normalize_result({:error, _reason}), do: {:error, :trace_persistence_failed}
  defp normalize_result(_other), do: {:error, :trace_persistence_failed}
end
