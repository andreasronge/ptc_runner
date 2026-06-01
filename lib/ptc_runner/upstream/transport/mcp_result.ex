defmodule PtcRunner.Upstream.Transport.McpResult do
  @moduledoc false

  # Shared normalization of an MCP `tools/call` result envelope into a
  # `PtcRunner.Upstream.Result` tuple. Used by both MCP transports
  # (`Transport.McpHttp`, `Transport.McpStdio`), which receive identically
  # shaped payloads regardless of the wire protocol.

  alias PtcRunner.Upstream.Result

  @doc """
  Normalize an MCP `tools/call` result:

  - `isError: true` → `{:error, :tool_error, text}`
  - `structuredContent` present → `{:ok, value}`
  - otherwise the first text content block, JSON-decoded when possible, else the
    raw text (or `{:ok, nil}` when there is no text content)
  """
  @spec normalize(map()) :: Result.t()
  def normalize(%{"isError" => true} = result),
    do: {:error, :tool_error, error_text(result)}

  def normalize(%{"structuredContent" => value}) when not is_nil(value),
    do: {:ok, value}

  def normalize(result) do
    case text_content(result) do
      nil ->
        {:ok, nil}

      text ->
        case Jason.decode(text) do
          {:ok, value} -> {:ok, value}
          {:error, _} -> {:ok, text}
        end
    end
  end

  defp text_content(%{"content" => [%{"type" => "text", "text" => text} | _]})
       when is_binary(text),
       do: text

  defp text_content(_), do: nil

  defp error_text(result),
    do: text_content(result) || inspect(result, limit: 20, printable_limit: 200)
end
