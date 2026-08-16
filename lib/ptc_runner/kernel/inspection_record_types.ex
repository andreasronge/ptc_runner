defmodule PtcRunner.Kernel.InspectionRecordTypes do
  @moduledoc """
  The closed private inspection record vocabulary.

  `PtcRunner.Kernel.InspectionSink` (retention) and
  `PtcRunner.Kernel.InspectionArtifact` (persistence and loading) must accept
  and reject the exact same record types; drift
  between two independent copies of that vocabulary is a defect, not a
  divergence either module is free to make on its own.
  """

  @record_types ~w(capability-input capability-exception capability-output evaluation-source evaluation-analysis prelude-source mcp-request mcp-response execution-prints execution-error run-result)
  @max_exception_class_bytes 1_024
  @max_exception_message_bytes 4_096
  @max_exception_stacktrace_bytes 65_536

  @spec all() :: [binary()]
  @doc "Returns every record type admitted by the current schema."
  def all, do: @record_types

  @doc false
  @spec max_exception_class_bytes() :: pos_integer()
  def max_exception_class_bytes, do: @max_exception_class_bytes

  @doc false
  @spec max_exception_message_bytes() :: pos_integer()
  def max_exception_message_bytes, do: @max_exception_message_bytes

  @doc false
  @spec max_exception_stacktrace_bytes() :: pos_integer()
  def max_exception_stacktrace_bytes, do: @max_exception_stacktrace_bytes

  @doc false
  @spec valid_capability_exception?(binary(), map()) :: boolean()
  def valid_capability_exception?(id, payload) when is_map(payload) do
    valid_id?(id) and valid_capability_identity?(payload) and
      bounded_string?(payload["exception_class"], @max_exception_class_bytes, false) and
      bounded_string?(payload["message"], @max_exception_message_bytes, true) and
      is_boolean(payload["message_truncated"]) and
      bounded_string?(payload["stacktrace"], @max_exception_stacktrace_bytes, true) and
      is_boolean(payload["stacktrace_truncated"])
  end

  def valid_capability_exception?(_id, _payload), do: false

  @doc false
  @spec valid_boundary_producer_details?(map()) :: boolean()
  def valid_boundary_producer_details?(details) when is_map(details) do
    case Map.fetch(details, "boundary_producer") do
      :error -> true
      {:ok, producer} -> valid_boundary_producer?(producer)
    end
  end

  defp valid_boundary_producer?(producer) when is_map(producer) do
    Enum.sort(Map.keys(producer)) == ~w(complete? evaluation_ids) and
      is_boolean(producer["complete?"]) and
      is_list(producer["evaluation_ids"]) and
      Enum.all?(producer["evaluation_ids"], &valid_id?/1) and
      producer["evaluation_ids"] == Enum.uniq(producer["evaluation_ids"])
  end

  defp valid_boundary_producer?(_producer), do: false

  defp valid_capability_identity?(%{"environment" => "workflow", "name" => name} = payload) do
    Map.keys(payload) |> Enum.sort() ==
      ~w(environment exception_class message message_truncated name stacktrace stacktrace_truncated) and
      valid_id?(name)
  end

  defp valid_capability_identity?(
         %{
           "environment" => "mission",
           "mission_name" => mission_name,
           "name" => name
         } = payload
       ) do
    Map.keys(payload) |> Enum.sort() ==
      ~w(environment exception_class message message_truncated mission_name name stacktrace stacktrace_truncated) and
      valid_id?(mission_name) and valid_id?(name)
  end

  defp valid_capability_identity?(_payload), do: false

  defp bounded_string?(value, max_bytes, empty?) do
    is_binary(value) and String.valid?(value) and byte_size(value) <= max_bytes and
      (empty? or value != "")
  end

  defp valid_id?(id),
    do: is_binary(id) and byte_size(id) in 1..256 and String.valid?(id)
end
