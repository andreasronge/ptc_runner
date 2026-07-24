defmodule PtcRunner.Kernel.MCPProtocol do
  @moduledoc """
  Pure validation and normalization for the pinned MCP protocol contract.

  `PtcRunner.Kernel.MCPSource` owns transport, deadlines, sessions, capability
  construction, and provider-error translation. This module owns the
  transport-independent JSON-RPC envelopes and responses, catalog-page
  reduction, selected-tool interpretation, and tool-result normalization.

  Catalog reduction validates only the identity and pagination fields needed
  to find installed mappings. Contract fields on unselected tools are retained
  without interpretation. Once a mapped tool is selected, its description,
  schemas, and `execution.taskSupport` declaration are validated. Unknown tool
  fields remain ignored for forward compatibility; task support is interpreted
  because it changes invocation semantics. Tools requiring task-based
  invocation are rejected because the synchronous adapter does not implement
  MCP task primitives.

  Structured results require a frozen output validator and may not include
  non-empty content. Tools without output schemas accept exact text blocks
  only. The functions return closed MCP reason atoms and never construct
  provider errors or expose remote error data.
  """

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.JSONSchema
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.StrictJSON

  @upstream_name ~r/\A[^\s\x00-\x1f\x7f]{1,256}\z/u

  @type catalog_result ::
          {:done, map()}
          | {:continue, binary(), map(), map()}
          | {:error, :mcp_catalog_exceeded | :mcp_invalid_catalog}

  @spec request(pos_integer(), binary(), map()) :: map()
  def request(id, method, params)
      when is_integer(id) and id > 0 and is_binary(method) and is_map(params) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  @spec notification(binary(), map()) :: map()
  def notification(method, params) when is_binary(method) and is_map(params) do
    %{"jsonrpc" => "2.0", "method" => method, "params" => params}
  end

  @spec valid_tool_name?(term()) :: boolean()
  def valid_tool_name?(name),
    do: is_binary(name) and String.valid?(name) and name =~ @upstream_name

  @spec decode_response(binary(), pos_integer()) :: {:ok, map()} | {:error, :mcp_protocol_error}
  def decode_response(body, id) when is_binary(body) and is_integer(id) and id > 0 do
    with {:ok, decoded} <- StrictJSON.decode(body),
         true <- JSONValue.map?(decoded),
         ^id <- decoded["id"],
         "2.0" <- decoded["jsonrpc"] do
      {:ok, decoded}
    else
      _reason -> {:error, :mcp_protocol_error}
    end
  end

  @spec outcome(map()) ::
          {:ok, map()} | {:error, :mcp_protocol_error | :mcp_remote_error}
  def outcome(body) when is_map(body) do
    case {Map.fetch(body, "result"), Map.fetch(body, "error")} do
      {{:ok, result}, :error} when is_map(result) ->
        {:ok, result}

      {:error, {:ok, error}} when is_map(error) ->
        if valid_rpc_error?(error),
          do: {:error, :mcp_remote_error},
          else: {:error, :mcp_protocol_error}

      _invalid ->
        {:error, :mcp_protocol_error}
    end
  end

  def outcome(_body), do: {:error, :mcp_protocol_error}

  @spec catalog_page(map(), map(), map(), pos_integer(), pos_integer()) :: catalog_result()
  def catalog_page(result, tools, seen, max_tools, max_bytes)
      when is_map(result) and is_map(tools) and is_map(seen) and is_integer(max_tools) and
             max_tools > 0 and is_integer(max_bytes) and max_bytes > 0 do
    with page when is_list(page) <- result["tools"],
         true <- length(page) + map_size(tools) <= max_tools,
         {:ok, tools} <- merge_tools(tools, page),
         next <- result["nextCursor"],
         true <- is_nil(next) or (is_binary(next) and byte_size(next) in 1..1_024),
         false <- is_binary(next) and Map.has_key?(seen, next) do
      continue_or_finish(next, tools, seen, max_bytes)
    else
      {:error, _reason} = error -> error
      false -> {:error, :mcp_invalid_catalog}
      _reason -> {:error, :mcp_invalid_catalog}
    end
  end

  def catalog_page(_result, _tools, _seen, _max_tools, _max_bytes),
    do: {:error, :mcp_invalid_catalog}

  @spec selected_tool(map()) ::
          {:ok,
           %{
             description: binary() | nil,
             input_schema: map(),
             output_schema: map() | nil
           }}
          | {:error, :mcp_invalid_catalog | :mcp_invalid_tool_schema | :mcp_tool_task_required}
  def selected_tool(tool) when is_map(tool) and not is_struct(tool) do
    with :ok <- task_support(tool),
         description <- Map.get(tool, "description"),
         true <-
           is_nil(description) or (is_binary(description) and byte_size(description) <= 4_096),
         input when is_map(input) <- tool["inputSchema"],
         {:ok, output} <- optional_output_schema(tool) do
      {:ok,
       %{
         description: description,
         input_schema: input,
         output_schema: output
       }}
    else
      {:error, _reason} = error -> error
      _reason -> {:error, :mcp_invalid_tool_schema}
    end
  end

  def selected_tool(_tool), do: {:error, :mcp_invalid_tool_schema}

  @spec normalize_tool_result(map(), map() | nil) ::
          {:ok, map()} | {:error, :mcp_domain_error | :mcp_invalid_result}
  def normalize_tool_result(%{"isError" => true}, _output_validator),
    do: {:error, :mcp_domain_error}

  def normalize_tool_result(
        %{"structuredContent" => structured} = result,
        output_validator
      )
      when is_map(structured) and not is_nil(output_validator) do
    content = Map.get(result, "content", [])

    if content in [nil, []] and JSONSchema.valid?(output_validator, structured),
      do: {:ok, structured},
      else: {:error, :mcp_invalid_result}
  end

  def normalize_tool_result(%{"content" => content} = result, nil) when is_list(content) do
    if Map.has_key?(result, "structuredContent"),
      do: {:error, :mcp_invalid_result},
      else: text_result(content)
  end

  def normalize_tool_result(_result, _output_validator), do: {:error, :mcp_invalid_result}

  defp valid_rpc_error?(%{"code" => code, "message" => message} = error) do
    Map.keys(error) -- ~w(code message data) == [] and is_integer(code) and
      is_binary(message) and byte_size(message) <= 4_096 and String.valid?(message) and
      (not Map.has_key?(error, "data") or JSONValue.value?(error["data"]))
  end

  defp valid_rpc_error?(_error), do: false

  defp continue_or_finish(nil, tools, _seen, max_bytes) do
    with {:ok, encoded} <- DeterministicJSON.encode(Map.values(tools)),
         true <- byte_size(encoded) <= max_bytes do
      {:done, tools}
    else
      _reason -> {:error, :mcp_catalog_exceeded}
    end
  end

  defp continue_or_finish(next, tools, seen, _max_bytes),
    do: {:continue, next, Map.put(seen, next, true), tools}

  defp merge_tools(existing, page) do
    Enum.reduce_while(page, {:ok, existing}, fn tool, {:ok, tools} ->
      with true <- is_map(tool) and not is_struct(tool),
           name when is_binary(name) <- tool["name"],
           true <- valid_tool_name?(name),
           false <- Map.has_key?(tools, name) do
        {:cont, {:ok, Map.put(tools, name, tool)}}
      else
        _reason -> {:halt, {:error, :mcp_invalid_catalog}}
      end
    end)
  end

  defp task_support(%{"execution" => execution}) when is_map(execution) do
    case Map.fetch(execution, "taskSupport") do
      :error -> :ok
      {:ok, support} when support in ["forbidden", "optional"] -> :ok
      {:ok, "required"} -> {:error, :mcp_tool_task_required}
      {:ok, _invalid} -> {:error, :mcp_invalid_catalog}
    end
  end

  defp task_support(%{"execution" => _invalid}), do: {:error, :mcp_invalid_catalog}
  defp task_support(_tool), do: :ok

  defp optional_output_schema(%{"outputSchema" => output}) when is_map(output),
    do: {:ok, output}

  defp optional_output_schema(tool) do
    if Map.has_key?(tool, "outputSchema"),
      do: {:error, :mcp_invalid_tool_schema},
      else: {:ok, nil}
  end

  defp text_result(content) do
    Enum.reduce_while(content, {:ok, []}, fn
      %{"type" => "text", "text" => text} = block, {:ok, texts}
      when is_binary(text) and map_size(block) == 2 ->
        {:cont, {:ok, [text | texts]}}

      _block, _acc ->
        {:halt, {:error, :mcp_invalid_result}}
    end)
    |> case do
      {:ok, texts} -> {:ok, %{"text" => Enum.reverse(texts)}}
      error -> error
    end
  end
end
