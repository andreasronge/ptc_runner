defmodule PtcRunner.Kernel.EventBudget do
  @moduledoc false

  alias PtcRunner.Lisp.RetainedSize

  @drop_count_limit 4_294_967_295
  @max_drop_type String.duplicate("e", 128)
  @maximum_terminal_reason String.duplicate("r", 1_020)

  @doc false
  def maximum_dropped do
    1..16
    |> Map.new(&{"#{@max_drop_type}#{&1}", @drop_count_limit})
    |> Map.put("$overflow", @drop_count_limit)
  end

  @doc false
  def maximum_terminal_reason, do: @maximum_terminal_reason

  @doc false
  def minimum_normal_payload_bytes do
    normal_terminal_payloads()
    |> Enum.map(&RetainedSize.bytes/1)
    |> Enum.max()
  end

  @doc false
  def normal_terminal_payload_capacity?(limit) when is_integer(limit) and limit > 0,
    do: Enum.all?(normal_terminal_payloads(), &payload_within?(&1, limit))

  def normal_terminal_payload_capacity?(_limit), do: false

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

  defp normal_terminal_payloads do
    dropped = maximum_dropped()

    [
      %{"counts" => dropped},
      %{
        "outcome" => "error",
        "reason" => @maximum_terminal_reason,
        "usage" => %{"events_dropped" => dropped}
      },
      %{
        "outcome" => "ok",
        "reason" => nil,
        "result_hash" => "sha256:" <> String.duplicate("f", 64),
        "usage" => %{"events_dropped" => dropped}
      }
    ]
  end

  defp payload_within?(payload, limit) do
    case RetainedSize.bytes_with_cap(payload, limit) do
      bytes when is_integer(bytes) -> bytes <= limit
      :oversized -> false
    end
  end
end
