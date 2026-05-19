defmodule PtcRunnerMcp.McpResult do
  @moduledoc """
  Shared PTC-Lisp-visible result shaping for upstream MCP tool calls.
  """

  @type value_kind :: :json | :text | :none
  @tool_error_message_cap 500

  @doc "Builds the tagged success shape from an upstream MCP result envelope."
  @spec success(term(), keyword()) :: map()
  def success(envelope, opts \\ []) do
    {value, value_kind} = unwrap(envelope)

    %{
      ok: true,
      value: value,
      value_kind: value_kind
    }
    |> maybe_put_raw(envelope, opts)
  end

  @doc "Builds the tagged recoverable failure shape."
  @spec error(atom(), String.t(), term(), keyword()) :: map()
  def error(reason, message, envelope \\ nil, opts \\ [])
      when is_atom(reason) and is_binary(message) do
    %{
      ok: false,
      reason: reason,
      message: message
    }
    |> maybe_put_raw(envelope, opts)
  end

  @doc """
  Extracts the default domain payload from an upstream MCP result envelope.

  The order matches the public `tool/mcp-call` contract:
  structuredContent, JSON text, plain text, then no default payload.
  """
  @spec unwrap(term()) :: {term(), value_kind()}
  def unwrap(%{"structuredContent" => structured}) when not is_nil(structured) do
    {structured, :json}
  end

  def unwrap(envelope) do
    case first_text(envelope) do
      text when is_binary(text) ->
        case Jason.decode(text) do
          {:ok, value} -> {value, :json}
          {:error, _reason} -> {text, :text}
        end

      nil ->
        unwrap_non_envelope(envelope)
    end
  end

  defp unwrap_non_envelope(%{"content" => _}), do: {nil, :none}
  defp unwrap_non_envelope(value) when is_map(value), do: {nil, :none}
  defp unwrap_non_envelope(value) when is_list(value), do: {value, :json}
  defp unwrap_non_envelope(value) when is_boolean(value), do: {value, :json}
  defp unwrap_non_envelope(value) when is_number(value), do: {value, :json}
  defp unwrap_non_envelope(value) when is_binary(value), do: {value, :text}
  defp unwrap_non_envelope(nil), do: {nil, :json}
  defp unwrap_non_envelope(_), do: {nil, :none}

  @doc "Extracts the bounded MCP `isError` detail text used for diagnostics."
  @spec tool_error_message(term()) :: String.t()
  def tool_error_message(envelope) do
    case first_error_text(envelope) do
      text when is_binary(text) ->
        cap_tool_error_message(text)

      _ ->
        cap_tool_error_message(
          "upstream isError envelope: #{inspect(envelope, limit: 50, printable_limit: 200)}"
        )
    end
  end

  defp first_text(%{"content" => [%{"type" => "text", "text" => text} | _]})
       when is_binary(text),
       do: text

  defp first_text(_), do: nil

  defp first_error_text(%{"content" => [%{"text" => text} | _]}) when is_binary(text),
    do: text

  defp first_error_text(_), do: nil

  defp cap_tool_error_message(text) when is_binary(text) do
    if String.length(text) > @tool_error_message_cap do
      String.slice(text, 0, @tool_error_message_cap) <> "…"
    else
      text
    end
  end

  defp maybe_put_raw(result, envelope, opts) do
    if Keyword.get(opts, :raw?, false) and not is_nil(envelope) do
      Map.put(result, :raw, envelope)
    else
      result
    end
  end
end
