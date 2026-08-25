defmodule PtcRunner.Research.SealedEvidenceLog.ValueHash do
  @moduledoc false

  @domain "ptc-inspection-value-v1\0"

  @spec hash(nil | binary() | pos_integer()) :: binary()
  def hash(nil), do: digest(3, "")
  def hash(value) when is_binary(value), do: digest(1, value)

  def hash(value) when is_integer(value) and value > 0,
    do: digest(2, <<value::unsigned-big-64>>)

  defp digest(tag, payload) do
    :crypto.hash(:sha256, [
      @domain,
      <<byte_size(payload)::unsigned-big-64>>,
      tag,
      payload
    ])
  end
end
