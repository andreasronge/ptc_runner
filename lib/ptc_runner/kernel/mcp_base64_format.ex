defmodule PtcRunner.Kernel.MCPBase64Format do
  @moduledoc false

  @behaviour JSV.FormatValidator

  @impl true
  def supported_formats, do: ["byte"]

  @impl true
  def applies_to_type?("byte", value), do: is_binary(value)

  @impl true
  def validate_cast("byte", value) do
    case Base.decode64(value) do
      {:ok, _decoded} ->
        {:ok, value}

      :error ->
        case Base.decode64(value, padding: false) do
          {:ok, _decoded} -> {:ok, value}
          :error -> {:error, :invalid_base64}
        end
    end
  end
end
