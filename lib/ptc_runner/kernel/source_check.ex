defmodule PtcRunner.Kernel.SourceCheck do
  @moduledoc false

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.Evaluation
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Parser
  alias PtcRunner.Utf8

  @diagnostic_bytes 4_096

  @spec check(RunState.t(), binary(), struct(), binary(), map(), term(), keyword()) :: map()
  def check(state, mission_name, mission, source, limits, event_sink, opts \\ [])
      when is_binary(mission_name) and is_binary(source) and is_list(opts) do
    source_bytes = byte_size(source)

    if source_bytes > limits.subordinate_source_bytes do
      %{
        outcome: :limit_exceeded,
        reason: :subordinate_source_bytes,
        source_bytes: source_bytes
      }
    else
      identity = %{
        source_hash: fingerprint(source),
        source_bytes: source_bytes
      }

      case RunState.reserve_source_check(state, mission_name) do
        {:ok, memory, revision} ->
          compile_and_finish(
            state,
            {mission_name, mission, source, limits, event_sink},
            {memory, revision},
            identity,
            opts
          )

        {:error, reason} ->
          Map.merge(identity, reservation_failure(reason))
      end
    end
  end

  defp compile_and_finish(
         state,
         {mission_name, mission, source, limits, event_sink},
         {memory, revision},
         identity,
         opts
       ) do
    timeout_ms = max(min(limits.evaluation_timeout_ms, RunState.remaining_ms(state)), 1)
    compile_timeout_ms = Keyword.get(opts, :compile_timeout, timeout_ms)

    compile_result =
      case required_shape(source, Keyword.get(opts, :required_shape)) do
        :ok ->
          Lisp.check_native(source,
            memory: memory,
            tools:
              Evaluation.mission_tools(
                mission,
                state,
                timeout_ms,
                event_sink,
                nil,
                nil,
                nil,
                mission_name
              ),
            prelude: bundle_prelude(mission),
            timeout: timeout_ms,
            compile_timeout: compile_timeout_ms,
            max_heap: limits.evaluation_heap_words,
            compile_max_heap: limits.evaluation_heap_words,
            max_program_bytes: limits.subordinate_source_bytes,
            filter_context: false,
            caller: :kernel,
            preserve_runtime_callables: true,
            link: true
          )

        {:error, failure} ->
          {:error, %{fail: failure}}
      end

    :ok = after_compile(Keyword.get(opts, :after_compile))

    case RunState.finish_source_check(state, mission_name, revision) do
      :ok -> Map.merge(identity, compile_projection(compile_result))
      {:error, reason} -> Map.merge(identity, finish_failure(reason))
    end
  end

  defp compile_projection(:ok), do: %{outcome: :valid}

  defp compile_projection({:error, %{fail: %{reason: reason}}})
       when reason in [:compile_timeout, :compile_memory_exceeded],
       do: %{outcome: :limit_exceeded, reason: reason}

  defp compile_projection(
         {:error, %{fail: %{reason: reason, message: message, details: details}}}
       ) do
    %{
      outcome: :invalid,
      diagnostic: %{
        kind: reason,
        message: truncate_utf8(message, @diagnostic_bytes),
        details: bounded_details(details)
      }
    }
  end

  defp reservation_failure(:busy),
    do: %{outcome: :busy, reason: :evaluation_in_progress}

  defp reservation_failure(:limit_exceeded),
    do: %{outcome: :limit_exceeded, reason: :subordinate_source_checks}

  defp reservation_failure(reason) when reason in [:deadline_expired, :run_closed],
    do: %{outcome: :limit_exceeded, reason: reason}

  defp finish_failure(:stale), do: %{outcome: :stale, reason: :continuation_changed}

  defp finish_failure(reason) when reason in [:deadline_expired, :run_closed],
    do: %{outcome: :limit_exceeded, reason: reason}

  defp bounded_details(details) do
    with {:ok, projected} <- Lisp.project_boundary_value(details, :kernel_json),
         true <- JSONValue.value?(projected),
         {:ok, encoded} <- DeterministicJSON.encode(projected),
         true <- byte_size(encoded) <= @diagnostic_bytes do
      projected
    else
      _other -> %{}
    end
  end

  defp truncate_utf8(message, max_bytes) when is_binary(message),
    do: Utf8.truncate(message, max_bytes)

  defp truncate_utf8(_message, _max_bytes), do: "Compilation failed"

  defp fingerprint(source) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, source), case: :lower)
  end

  defp bundle_prelude(%{bundle: %{prelude: prelude}}), do: prelude
  defp bundle_prelude(_mission), do: nil

  defp required_shape(_source, nil), do: :ok

  defp required_shape(source, :terminal) do
    case Parser.parse(source) do
      {:ok, {:list, [{:symbol, head} | _arguments]}} when head in [:return, :fail] ->
        :ok

      {:error, _parse_error} ->
        # Preserve the ordinary parser diagnostic from check_native/2.
        :ok

      {:ok, _other} ->
        {:error,
         %{
           reason: :terminal_source_required,
           message: "expected exactly one top-level return or fail form",
           details: %{}
         }}
    end
  end

  defp after_compile(nil), do: :ok
  defp after_compile(callback) when is_function(callback, 0), do: callback.()
end
