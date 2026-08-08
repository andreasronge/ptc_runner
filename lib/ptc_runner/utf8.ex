defmodule PtcRunner.Utf8 do
  @moduledoc """
  Byte-bounded UTF-8 helpers shared by diagnostics and public metadata.

  `truncate/2` leaves values within the byte limit unchanged. When truncation
  is required, it backs up to a valid UTF-8 boundary and copies the result so
  retaining a short diagnostic cannot retain its complete source binary.

  This is a truncation helper, not a validator: an invalid binary already
  within the limit is returned unchanged.
  """

  @spec truncate(binary(), non_neg_integer()) :: binary()
  def truncate(value, max_bytes)
      when is_binary(value) and is_integer(max_bytes) and max_bytes >= 0 and
             byte_size(value) <= max_bytes,
      do: value

  def truncate(value, max_bytes)
      when is_binary(value) and is_integer(max_bytes) and max_bytes >= 0 do
    value |> binary_part(0, max_bytes) |> copy_valid_prefix()
  end

  @doc """
  Returns the longest valid UTF-8 prefix within `max_bytes`.

  Unlike `truncate/2`, this also sanitizes an invalid value that is already
  within the byte limit. A changed result is copied out of its parent binary.
  """
  @spec truncate_valid(binary(), non_neg_integer()) :: binary()
  def truncate_valid(value, max_bytes)
      when is_binary(value) and is_integer(max_bytes) and max_bytes >= 0 do
    prefix = binary_part(value, 0, min(byte_size(value), max_bytes))

    if prefix == value and String.valid?(prefix) do
      value
    else
      copy_valid_prefix(prefix)
    end
  end

  defp copy_valid_prefix(value), do: value |> valid_prefix() |> :binary.copy()

  defp valid_prefix(value) do
    if String.valid?(value) do
      value
    else
      valid_prefix(binary_part(value, 0, byte_size(value) - 1))
    end
  end
end
