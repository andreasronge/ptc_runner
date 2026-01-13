defmodule PtcRunner.SubAgent.Namespace.Tool do
  @moduledoc "Renders available tools for the USER message namespace section."

  alias PtcRunner.SubAgent.Signature
  alias PtcRunner.SubAgent.Signature.Renderer
  alias PtcRunner.Tool

  @doc """
  Render tools section for USER message.

  Returns a formatted string showing available tools or a message indicating
  no tools are available. When tools exist, shows header and entries with
  tool calling syntax, parameters, and return type.

  Tools are called using `tool/` prefix: `(tool/tool-name {:param value})`

  Accepts raw tool formats (fn, {fn, sig}, {fn, opts}) and normalizes them.

  ## Examples

      iex> PtcRunner.SubAgent.Namespace.Tool.render(%{})
      ";; No tools available"

      iex> tool = %PtcRunner.Tool{name: "get-inventory", signature: "-> :map"}
      iex> PtcRunner.SubAgent.Namespace.Tool.render(%{"get-inventory" => tool})
      ";; === tools ===\\ntool/get-inventory() -> map"

      iex> tool = %PtcRunner.Tool{name: "search", signature: "(query :string, limit :int) -> [:string]"}
      iex> PtcRunner.SubAgent.Namespace.Tool.render(%{"search" => tool})
      ";; === tools ===\\ntool/search(query, limit) -> [string]"

      iex> tool = %PtcRunner.Tool{name: "analyze", signature: "-> :map", description: "Analyze data"}
      iex> PtcRunner.SubAgent.Namespace.Tool.render(%{"analyze" => tool})
      ";; === tools ===\\ntool/analyze() -> map  ; Analyze data"
  """
  @spec render(map()) :: String.t()
  def render(tools) when map_size(tools) == 0, do: ";; No tools available"

  def render(tools) do
    lines =
      tools
      |> Enum.map(fn {name, format} -> {name, normalize_tool(name, format)} end)
      |> Enum.reject(fn {_name, tool} -> is_nil(tool) end)
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {_name, tool} -> format_tool(tool) end)

    case lines do
      [] -> ";; No tools available"
      _ -> [";; === tools ===" | lines] |> Enum.join("\n")
    end
  end

  # Normalize tool format to %Tool{} struct
  defp normalize_tool(_name, %Tool{} = tool), do: tool

  defp normalize_tool(name, format) do
    case Tool.new(name, format) do
      {:ok, tool} -> tool
      {:error, _reason} -> nil
    end
  end

  defp format_tool(%{name: name, signature: signature, description: description}) do
    {params, return_type} = parse_signature(signature)
    params_str = Enum.map_join(params, ", ", fn {param_name, _type} -> param_name end)
    return_str = format_return_type(return_type)

    base = "tool/#{name}(#{params_str}) -> #{return_str}"

    case description do
      nil -> base
      "" -> base
      desc -> "#{base}  ; #{desc}"
    end
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
