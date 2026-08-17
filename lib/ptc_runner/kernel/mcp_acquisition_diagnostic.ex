defmodule PtcRunner.Kernel.MCPAcquisitionDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.MCPProtocol

  @missing_tool_prefix "the installed endpoint does not expose declared tool "
  @max_message_bytes byte_size(@missing_tool_prefix) + 514

  @doc false
  @spec missing_tool_message(term()) :: {:ok, binary()} | :error
  def missing_tool_message(name) do
    if MCPProtocol.valid_tool_name?(name) do
      message = @missing_tool_prefix <> Jason.encode!(name)
      if byte_size(message) <= @max_message_bytes, do: {:ok, message}, else: :error
    else
      :error
    end
  end

  @doc false
  @spec valid_missing_tool_message?(term()) :: boolean()
  def valid_missing_tool_message?(@missing_tool_prefix <> encoded)
      when byte_size(encoded) <= @max_message_bytes do
    case Jason.decode(encoded) do
      {:ok, name} -> MCPProtocol.valid_tool_name?(name) and Jason.encode!(name) == encoded
      {:error, _reason} -> false
    end
  end

  def valid_missing_tool_message?(_message), do: false

  @doc false
  @spec missing_tool_message_schema(binary()) :: map()
  def missing_tool_message_schema(fallback) do
    %{
      "oneOf" => [
        %{"const" => fallback},
        %{
          "type" => "string",
          "maxLength" => @max_message_bytes,
          "pattern" =>
            ~S'^the installed endpoint does not expose declared tool "(?:[^"\\\s\x00-\x1f\x7f]|\\["\\]){1,128}"$(?![\s\S])'
        }
      ]
    }
  end
end
