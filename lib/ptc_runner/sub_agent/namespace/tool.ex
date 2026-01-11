defmodule PtcRunner.SubAgent.Namespace.Tool do
  @moduledoc "Renders the tool/ namespace section."

  alias PtcRunner.SubAgent.Signature
  alias PtcRunner.SubAgent.Signature.Renderer

  @doc """
  Render tool/ namespace section for USER message.

  Returns `nil` for empty tools maps, otherwise a formatted string with header
  and entries showing tool name, parameters, and return type.

  ## Examples

      iex> PtcRunner.SubAgent.Namespace.Tool.render(%{})
      nil

      iex> tool = %PtcRunner.Tool{name: "get-inventory", signature: "-> :map"}
      iex> PtcRunner.SubAgent.Namespace.Tool.render(%{"get-inventory" => tool})
      ";; === tool/ ===\\ntool/get-inventory() -> map"

      iex> tool = %PtcRunner.Tool{name: "search", signature: "(query :string, limit :int) -> [:string]"}
      iex> PtcRunner.SubAgent.Namespace.Tool.render(%{"search" => tool})
      ";; === tool/ ===\\ntool/search(query, limit) -> [string]"
  """
  @spec render(map()) :: String.t() | nil
  def render(tools) when map_size(tools) == 0, do: nil

  def render(tools) do
    lines =
      tools
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {_name, tool} -> format_tool(tool) end)

    [";; === tool/ ===" | lines] |> Enum.join("\n")
  end

  defp format_tool(%{name: name, signature: signature}) do
    {params, return_type} = parse_signature(signature)
    params_str = Enum.map_join(params, ", ", fn {param_name, _type} -> param_name end)
    return_str = format_return_type(return_type)
    "tool/#{name}(#{params_str}) -> #{return_str}"
  end

  defp parse_signature(nil), do: {[], :any}

  defp parse_signature(signature) when is_binary(signature) do
    # Normalize "-> :type" format to "() -> :type" for parser
    normalized = normalize_signature(signature)

    case Signature.parse(normalized) do
      {:ok, {:signature, params, return_type}} -> {params, return_type}
      {:error, _reason} -> {[], :any}
    end
  end

  # Handle arrow-only format: "-> :type" -> "() -> :type"
  defp normalize_signature(sig) do
    trimmed = String.trim(sig)

    if String.starts_with?(trimmed, "->") do
      "()" <> trimmed
    else
      sig
    end
  end

  # Format return type without colons for display
  # Converts ":string" -> "string", "[:string]" -> "[string]", "{score :float}" -> "{score float}"
  defp format_return_type(type) do
    Renderer.render_type(type) |> String.replace(":", "")
  end
end
