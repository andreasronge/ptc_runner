defmodule PtcRunner.Kernel.BoundedUTF8 do
  @moduledoc false

  # Shared UTF-8 byte ceiling used by session result projection and private
  # diagnostic admission. Returns whether the input was shortened so callers can
  # mark the truncation instead of silently dropping a tail.

  @spec clip(binary(), pos_integer()) :: {binary(), boolean()}
  def clip(value, max_bytes)
      when is_binary(value) and is_integer(max_bytes) and max_bytes > 0 do
    if byte_size(value) <= max_bytes do
      {value, false}
    else
      {trim_invalid_suffix(binary_part(value, 0, max_bytes)), true}
    end
  end

  defp trim_invalid_suffix(value) do
    if String.valid?(value),
      do: value,
      else: trim_invalid_suffix(binary_part(value, 0, byte_size(value) - 1))
  end
end
