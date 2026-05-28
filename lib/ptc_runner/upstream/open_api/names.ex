defmodule PtcRunner.Upstream.OpenAPI.Names do
  @moduledoc false

  @spec normalize(String.t()) :: String.t()
  def normalize(name) when is_binary(name) do
    name
    |> String.trim()
    |> Macro.underscore()
    |> String.replace("_", "-")
  end
end
