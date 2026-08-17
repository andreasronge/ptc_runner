defmodule PtcGateway.Protocol do
  @moduledoc """
  Newline-delimited JSON-RPC 2.0 framing for the gateway's MCP server.

  One document per line. HTTP-style `Content-Length` headers are rejected on
  input and never emitted. Envelope helpers here are transport-independent;
  `PtcRunner.Kernel.MCPProtocol` remains the client-side validator.
  """

  alias PtcGateway.Errors

  @protocol "2026-07-28"
  @max_frame_bytes 1_048_576
  @server_name "ptc-gateway"
  @server_version "0.1.0"

  @type inbound ::
          {:request, pos_integer(), binary(), map()}
          | {:notification, binary(), map()}

  @spec protocol_version() :: binary()
  def protocol_version, do: @protocol

  @spec max_frame_bytes() :: pos_integer()
  def max_frame_bytes, do: @max_frame_bytes

  @spec decode_line(binary()) :: {:ok, inbound()} | {:error, Errors.kind()}
  def decode_line(line) when is_binary(line) do
    cond do
      String.starts_with?(line, "Content-Length:") ->
        {:error, :invalid_request}

      byte_size(line) > @max_frame_bytes ->
        {:error, :parse}

      true ->
        decode_document(line)
    end
  end

  def decode_line(_line), do: {:error, :parse}

  @spec encode_result(pos_integer(), map()) :: binary()
  def encode_result(id, result) when is_integer(id) and id > 0 and is_map(result) do
    encode(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  @spec encode_rpc_error(pos_integer() | nil, Errors.kind()) :: binary()
  def encode_rpc_error(id, kind) when kind in [:parse, :invalid_request] or is_integer(id) do
    error = %{"code" => Errors.rpc_code(kind), "message" => Errors.rpc_message(kind)}
    payload = %{"jsonrpc" => "2.0", "error" => error}
    encode(if(is_integer(id) and id > 0, do: Map.put(payload, "id", id), else: payload))
  end

  @spec encode_call_error(pos_integer(), Errors.kind()) :: binary()
  def encode_call_error(id, kind) when is_integer(id) and id > 0 do
    encode_result(id, %{
      "isError" => true,
      "content" => [%{"type" => "text", "text" => Errors.call_message(kind)}]
    })
  end

  @spec encode_call_success(pos_integer(), map()) :: binary()
  def encode_call_success(id, value) when is_integer(id) and id > 0 and is_map(value) do
    text = encode_json(value)

    encode_result(id, %{
      "isError" => false,
      "structuredContent" => value,
      "content" => [%{"type" => "text", "text" => text}]
    })
  end

  @spec discover_result() :: map()
  def discover_result do
    %{
      "supportedVersions" => [@protocol],
      "capabilities" => %{"tools" => %{}},
      "_meta" => %{
        "io.modelcontextprotocol/serverInfo" => %{
          "name" => @server_name,
          "version" => @server_version
        }
      }
    }
  end

  @spec tools_list_result([map()]) :: map()
  def tools_list_result(tools) when is_list(tools) do
    %{
      "tools" => Enum.map(tools, &tool_descriptor/1),
      "cacheScope" => "public",
      "ttlMs" => 0
    }
  end

  defp tool_descriptor(tool) do
    %{
      "name" => tool.name,
      "description" => tool.description,
      "inputSchema" => tool.input_schema,
      "outputSchema" => tool.output_schema,
      "_meta" => tool.meta
    }
  end

  defp decode_document(line) do
    case Jason.decode(line) do
      {:ok, decoded} when is_map(decoded) -> classify(decoded)
      {:ok, _decoded} -> {:error, :invalid_request}
      {:error, _reason} -> {:error, :parse}
    end
  end

  defp classify(%{"jsonrpc" => "2.0"} = decoded) do
    id = Map.get(decoded, "id")
    method = Map.get(decoded, "method")
    params = Map.get(decoded, "params", %{})
    has_result? = Map.has_key?(decoded, "result") or Map.has_key?(decoded, "error")

    cond do
      has_result? ->
        {:error, :invalid_request}

      is_binary(method) and byte_size(method) > 0 and is_integer(id) and id > 0 and
        is_map(params) and not is_struct(params) ->
        {:ok, {:request, id, method, params}}

      is_binary(method) and String.starts_with?(method, "notifications/") and is_nil(id) and
        is_map(params) and not is_struct(params) ->
        {:ok, {:notification, method, params}}

      true ->
        {:error, :invalid_request}
    end
  end

  defp classify(_decoded), do: {:error, :invalid_request}

  defp encode(map), do: encode_json(map) <> "\n"

  defp encode_json(value) do
    case Jason.encode(value) do
      {:ok, encoded} ->
        encoded

      {:error, _reason} ->
        ~s({"jsonrpc":"2.0","error":{"code":-32603,"message":"internal error"}})
    end
  end
end
