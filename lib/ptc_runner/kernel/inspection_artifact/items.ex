defmodule PtcRunner.Kernel.InspectionArtifact.Items do
  @moduledoc false

  alias PtcRunner.Kernel.InspectionArtifact.Codec
  alias PtcRunner.Kernel.InspectionArtifact.Conversation
  alias PtcRunner.Kernel.InspectionArtifact.Handle
  alias PtcRunner.Kernel.InspectionArtifact.Indexes

  @spec read_record(Handle.t(), Indexes.t(), binary(), pos_integer(), pos_integer()) ::
          {:ok, map(), non_neg_integer()} | {:error, atom()}
  def read_record(handle, indexes, run_id, sequence, max_range_bytes)
      when is_integer(max_range_bytes) and max_range_bytes > 0 do
    case Indexes.lookup(indexes, :records, {run_id, sequence}) do
      [{_key, {type, offset, length, digest}}] ->
        if length > max_range_bytes do
          {:error, :range_limit_exceeded}
        else
          with {:ok, bytes} <- Handle.verify_range(handle, offset, length, digest),
               {:ok, record} <- Codec.decode_record(bytes),
               true <- record["record_type"] == type and record["sequence"] == sequence do
            {:ok, record, length}
          else
            false -> {:error, :source_changed}
            {:error, _reason} = error -> error
          end
        end

      _other ->
        {:error, :source_changed}
    end
  end

  @spec capability_item(map(), map() | nil, map() | nil) :: map()
  def capability_item(input, output, exception) do
    payload = input["payload"]

    item = %{
      "run_id" => input["run_id"],
      "trace_id" => input["trace_id"],
      "capability_id" => input["correlation"]["capability_id"],
      "environment" => payload["environment"],
      "mission_name" => payload["mission_name"],
      "name" => payload["name"],
      "input_sequence" => input["sequence"],
      "input_timestamp" => input["timestamp"],
      "arguments" => payload["arguments"]
    }

    item
    |> maybe_output(output)
    |> maybe_exception(exception)
  end

  @spec provider_item(map(), map(), map() | nil) :: map()
  def provider_item(request, response, stderr) do
    correlation = request["correlation"]

    %{
      "run_id" => request["run_id"],
      "trace_id" => request["trace_id"],
      "capability_id" => correlation["capability_id"],
      "request_id" => correlation["request_id"],
      "transport" => request["payload"]["transport"],
      "mission_name" => request["payload"]["mission_name"],
      "request_sequence" => request["sequence"],
      "response_sequence" => response["sequence"],
      "request_timestamp" => request["timestamp"],
      "response_timestamp" => response["timestamp"],
      "request" => request["payload"]["body"],
      "response" => response["payload"]["body"]
    }
    |> maybe_stderr(stderr)
  end

  @spec source_item(map(), [map()] | nil, binary() | nil, term()) :: map()
  def source_item(record, prelude_calls, parent_evaluation_id, relationships) do
    payload = record["payload"]

    %{
      "run_id" => record["run_id"],
      "trace_id" => record["trace_id"],
      "evaluation_id" => record["correlation"]["evaluation_id"],
      "sequence" => record["sequence"],
      "timestamp" => record["timestamp"],
      "environment" => payload["environment"],
      "mission_name" => payload["mission_name"],
      "program_kind" => payload["program_kind"],
      "source" => payload["source"],
      "source_hash" => "sha256:" <> payload["source_hash"],
      "source_bytes" => payload["source_bytes"],
      "prelude_calls_available?" => is_list(prelude_calls),
      "prelude_calls" => prelude_calls || []
    }
    |> maybe_parent(parent_evaluation_id)
    |> Map.put("relationships", relationships || [])
  end

  @spec prelude_item(map(), term()) :: map()
  def prelude_item(record, relationships) do
    payload = record["payload"]

    %{
      "run_id" => record["run_id"],
      "trace_id" => record["trace_id"],
      "component_id" => record["correlation"]["component_id"],
      "sequence" => record["sequence"],
      "timestamp" => record["timestamp"],
      "environment" => payload["environment"],
      "mission_name" => payload["mission_name"],
      "source" => payload["source"],
      "source_hash" => "sha256:" <> payload["source_hash"],
      "source_bytes" => payload["source_bytes"],
      "relationships" => relationships || []
    }
  end

  @spec execution_item(map(), term()) :: map()
  def execution_item(record, relationships) do
    %{
      "run_id" => record["run_id"],
      "trace_id" => record["trace_id"],
      "evaluation_id" => record["correlation"]["evaluation_id"],
      "sequence" => record["sequence"],
      "timestamp" => record["timestamp"]
    }
    |> Map.merge(record["payload"])
    |> maybe_relationships(relationships)
  end

  @spec result_item(map()) :: map()
  def result_item(record) do
    payload = record["payload"]

    %{
      "run_id" => record["run_id"],
      "trace_id" => record["trace_id"],
      "sequence" => record["sequence"],
      "timestamp" => record["timestamp"],
      "result_hash" => payload["result_hash"],
      "value" => payload["value"]
    }
  end

  defdelegate assemble_turn(turn_meta, input, output, generated), to: Conversation

  defp maybe_output(item, nil), do: Map.put(item, "complete?", false)

  defp maybe_output(item, output) do
    Map.merge(item, %{
      "complete?" => true,
      "output_sequence" => output["sequence"],
      "output_timestamp" => output["timestamp"],
      "result" => output["payload"]["result"]
    })
  end

  defp maybe_exception(item, nil), do: item

  defp maybe_exception(item, exception) do
    payload = exception["payload"]

    Map.merge(item, %{
      "exception_sequence" => exception["sequence"],
      "exception_timestamp" => exception["timestamp"],
      "exception" =>
        Map.take(
          payload,
          ~w(exception_class message message_truncated stacktrace stacktrace_truncated)
        )
    })
  end

  defp maybe_stderr(item, nil), do: item

  defp maybe_stderr(item, stderr) do
    payload = stderr["payload"]

    Map.merge(item, %{
      "stderr_sequence" => stderr["sequence"],
      "stderr_timestamp" => stderr["timestamp"],
      "stderr" => payload["text"],
      "stderr_truncated" => payload["truncated"]
    })
  end

  defp maybe_parent(item, parent) when is_binary(parent),
    do: Map.put(item, "parent_evaluation_id", parent)

  defp maybe_parent(item, _parent), do: item

  defp maybe_relationships(item, nil), do: item
  defp maybe_relationships(item, relationships), do: Map.put(item, "relationships", relationships)
end
