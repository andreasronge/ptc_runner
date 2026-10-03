defmodule PtcRunner.Kernel.MCPAcquisitionDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.DiagnosticPattern
  alias PtcRunner.Kernel.MCPProtocol

  @missing_tool_prefix "the installed endpoint does not expose declared tool "
  @max_message_bytes byte_size(@missing_tool_prefix) + 514
  @discovery_method_unsupported_message "the endpoint rejected the required server/discover method and does not support MCP protocol 2026-07-28"

  @template [
    {:literal, @missing_tool_prefix},
    {:slot, :encoded, :text, ~S'"(?:[^"\\\s\x00-\x1f\x7f]|\\["\\]){1,128}"'}
  ]

  @doc false
  @spec missing_tool_message(term()) :: {:ok, binary()} | :error
  def missing_tool_message(name) do
    if MCPProtocol.valid_tool_name?(name) do
      message = DiagnosticPattern.render(@template, %{encoded: Jason.encode!(name)})
      if byte_size(message) <= @max_message_bytes, do: {:ok, message}, else: :error
    else
      :error
    end
  end

  @doc false
  @spec valid_missing_tool_message?(term()) :: boolean()
  def valid_missing_tool_message?(message) do
    with true <- is_binary(message) and String.valid?(message),
         {:ok, %{encoded: encoded}} <- DiagnosticPattern.parse(@template, message, "u"),
         true <- byte_size(encoded) <= @max_message_bytes,
         {:ok, name} <- Jason.decode(encoded) do
      MCPProtocol.valid_tool_name?(name) and Jason.encode!(name) == encoded
    else
      _invalid -> false
    end
  end

  @doc false
  @spec discovery_method_unsupported_message() :: binary()
  def discovery_method_unsupported_message, do: @discovery_method_unsupported_message

  @doc false
  @spec valid_protocol_version_message?(term()) :: boolean()
  def valid_protocol_version_message?(message),
    do: message == @discovery_method_unsupported_message

  @doc false
  @spec protocol_version_message_schema(binary()) :: map()
  def protocol_version_message_schema(fallback) do
    %{
      "oneOf" => [
        %{"const" => fallback},
        %{"const" => @discovery_method_unsupported_message}
      ]
    }
  end

  @doc false
  @spec missing_tool_message_schema(binary()) :: map()
  def missing_tool_message_schema(fallback) do
    %{
      "oneOf" => [
        %{"const" => fallback},
        DiagnosticPattern.exact_message_schema(@max_message_bytes, @template)
        |> Map.delete("minLength")
      ]
    }
  end
end
