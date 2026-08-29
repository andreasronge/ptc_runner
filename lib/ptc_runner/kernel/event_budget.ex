defmodule PtcRunner.Kernel.EventBudget do
  @moduledoc false

  alias PtcRunner.Lisp.RetainedSize

  @drop_count_limit 4_294_967_295
  @max_drop_type_prefix "e" <> String.duplicate("a", 124)
  @maximum_terminal_reason String.duplicate("r", 1_020)
  # Exact retained-size upper bound for the normalized maximum error terminal
  # on the supported 64-bit runtime: the bounded terminal reason, the saturated
  # reachable drop map at its conservative bound, and the complete fixed
  # `run-stopped` usage projection with every integer field at its catalog
  # maximum and an empty capability and mission inventory. The application-scaled
  # part of that projection cannot be a catalog minimum, so it is admitted per
  # run instead. Keep this explicit because sizing a constructed literal can
  # undercount the ref-counted binaries retained by a real sink;
  # `limit_catalog_test` re-derives it by measurement.
  @minimum_normal_payload_bytes 8_211
  @maximum_dropped_bytes 3_449

  @doc false
  def maximum_dropped do
    1..16
    |> Map.new(fn index ->
      suffix = String.pad_leading(Integer.to_string(index), 3, "0")
      {"#{@max_drop_type_prefix}#{suffix}", @drop_count_limit}
    end)
    |> Map.put("$overflow", @drop_count_limit)
  end

  @doc false
  def maximum_dropped_with_headroom do
    dropped = maximum_dropped()
    bytes = RetainedSize.bytes(dropped)
    {dropped, max(@maximum_dropped_bytes - bytes, 0)}
  end

  @doc false
  def maximum_terminal_reason, do: :binary.copy(@maximum_terminal_reason)

  @doc false
  def minimum_normal_payload_bytes, do: @minimum_normal_payload_bytes

  @doc false
  def normal_terminal_payload_capacity?(limit) when is_integer(limit) and limit > 0,
    do: limit >= @minimum_normal_payload_bytes

  def normal_terminal_payload_capacity?(_limit), do: false

  @doc false
  @spec maximum_event_bytes(binary(), pos_integer()) :: pos_integer()
  def maximum_event_bytes(type, payload_bytes)
      when is_binary(type) and is_integer(payload_bytes) and payload_bytes > 0,
      do: terminal_envelope_bytes(type) + payload_bytes

  @doc false
  def terminal_envelope_bytes(type) when is_binary(type) do
    envelope = %{
      schema_version: 2,
      run_id: String.duplicate("r", 256),
      trace_id: String.duplicate("t", 256),
      sequence: @drop_count_limit,
      timestamp: ~U[9999-12-31 23:59:59.999999Z],
      type: type,
      data: nil
    }

    RetainedSize.bytes(envelope)
  end
end
