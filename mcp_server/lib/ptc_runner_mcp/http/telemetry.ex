defmodule PtcRunnerMcp.Http.Telemetry do
  @moduledoc false

  @spec emit(atom() | [atom()], map(), map()) :: :ok
  def emit(event, measurements, metadata) do
    :telemetry.execute(
      [:ptc_runner_mcp, :http | List.wrap(event)],
      measurements,
      sanitize_metadata(metadata)
    )
  end

  @spec hash_id(term()) :: String.t() | nil
  def hash_id(nil), do: nil

  def hash_id(id) do
    :crypto.hash(:sha256, to_string(id))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp sanitize_metadata(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {key, sanitize_value(value)} end)
  end

  defp sanitize_value(value) when is_binary(value), do: value
  defp sanitize_value(value) when is_atom(value), do: value
  defp sanitize_value(value) when is_integer(value), do: value
  defp sanitize_value(value) when is_boolean(value), do: value
  defp sanitize_value(value), do: inspect(value, limit: 20, printable_limit: 100)
end
