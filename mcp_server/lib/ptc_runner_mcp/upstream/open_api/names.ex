defmodule PtcRunnerMcp.Upstream.OpenApi.Names do
  @moduledoc false

  @doc """
  Converts an OpenAPI operation id or x-ptc-name into the Lisp-facing
  tool name.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(name) when is_binary(name) do
    name
    |> String.trim()
    |> Macro.underscore()
    |> String.replace("_", "-")
  end
end
