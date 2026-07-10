defmodule PtcRunner.PreludeOrigin do
  @moduledoc false

  @max_safe_bytes 160

  @spec sanitize(term()) :: String.t() | nil
  def sanitize(nil), do: nil

  def sanitize(origin) when is_binary(origin) do
    if safe?(origin) and byte_size(origin) <= @max_safe_bytes do
      origin
    else
      "redacted:" <> sha256(origin)
    end
  end

  def sanitize(origin) do
    origin
    |> inspect(limit: 5, printable_limit: @max_safe_bytes)
    |> sanitize()
  end

  defp safe?("memory"), do: true
  defp safe?("file:priv/" <> _rest), do: true
  defp safe?("file:test/" <> _rest), do: true
  defp safe?(_origin), do: false

  defp sha256(source) do
    :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
  end
end
