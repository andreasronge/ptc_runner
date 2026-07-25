defmodule PtcRunner.Kernel.MCPProtocol do
  @moduledoc """
  Pure validation and normalization for the pinned MCP protocol contract.

  `PtcRunner.Kernel.MCPSource` owns transport, deadlines, capability
  construction, and provider-error translation. This module owns the
  transport-independent JSON-RPC envelopes and responses, catalog-page
  reduction, selected-tool interpretation, HTTP parameter-header projection,
  and tool-result normalization.

  Catalog reduction validates only the identity and pagination fields needed
  to find installed mappings. Contract fields on unselected tools are retained
  without interpretation. Once a mapped tool is selected, its description,
  schemas, and transport annotations are validated. Unknown tool fields remain
  ignored for forward compatibility. The removed 2025-11-25
  `execution.taskSupport` field has no semantics in the pinned modern core.

  Structured results require a frozen object-output validator and explicit
  content containing only exact text blocks; those companion blocks are
  validated and discarded. Tools without output schemas return exact text
  blocks only. The functions return closed MCP reason atoms and never
  construct provider errors or expose remote error data.
  """

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.JSONSchema
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.StrictJSON

  @upstream_name ~r/\A[^\s\x00-\x1f\x7f]{1,128}\z/u
  @header_token ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
  @max_safe_integer 9_007_199_254_740_991
  @max_header_parameters 24
  @max_header_name_bytes 128
  @max_parameter_header_bytes 16_384
  @max_schema_depth 16
  @schema_instance_keywords ~w(const enum)
  @schema_value_keywords ~w(additionalProperties contains if items not then else)
  @schema_list_keywords ~w(allOf anyOf oneOf prefixItems)
  @schema_map_keywords ~w($defs definitions dependentSchemas patternProperties)

  defguardp valid_catalog_counters(received_tools, received_bytes)
            when is_integer(received_tools) and received_tools >= 0 and
                   is_integer(received_bytes) and received_bytes >= 0

  defguardp valid_catalog_limits(max_tools, max_bytes)
            when is_integer(max_tools) and max_tools > 0 and is_integer(max_bytes) and
                   max_bytes > 0

  @type catalog_result ::
          {:done, map()}
          | {:continue, binary(), map()}
          | {:error, :mcp_catalog_exceeded | :mcp_invalid_catalog}
  @type inbound_message ::
          {:response, pos_integer(), map()}
          | {:notification, map()}

  @spec request(pos_integer(), binary(), map(), map()) :: map()
  def request(id, method, params, metadata)
      when is_integer(id) and id > 0 and is_binary(method) and is_map(params) and
             is_map(metadata) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => Map.put(params, "_meta", metadata)
    }
  end

  @spec notification(binary(), map(), map()) :: map()
  def notification(method, params, metadata)
      when is_binary(method) and is_map(params) and is_map(metadata) do
    %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => Map.put(params, "_meta", metadata)
    }
  end

  @spec valid_tool_name?(term()) :: boolean()
  def valid_tool_name?(name),
    do: is_binary(name) and String.valid?(name) and name =~ @upstream_name

  @spec decode_response(binary(), pos_integer()) :: {:ok, map()} | {:error, :mcp_protocol_error}
  def decode_response(body, id) when is_binary(body) and is_integer(id) and id > 0 do
    case decode_message(body) do
      {:ok, {:response, ^id, decoded}} -> {:ok, decoded}
      _invalid -> {:error, :mcp_protocol_error}
    end
  end

  @spec decode_message(binary()) ::
          {:ok, inbound_message()} | {:error, :mcp_protocol_error}
  def decode_message(body) when is_binary(body) do
    with {:ok, decoded} <- StrictJSON.decode(body),
         true <- JSONValue.map?(decoded),
         "2.0" <- decoded["jsonrpc"] do
      classify_message(decoded)
    else
      _reason -> {:error, :mcp_protocol_error}
    end
  end

  def decode_message(_body), do: {:error, :mcp_protocol_error}

  defp classify_message(%{"id" => id} = decoded) when is_integer(id) and id > 0 do
    case {
      Map.has_key?(decoded, "method"),
      Map.has_key?(decoded, "result"),
      Map.has_key?(decoded, "error")
    } do
      {false, true, false} -> {:ok, {:response, id, decoded}}
      {false, false, true} -> {:ok, {:response, id, decoded}}
      _invalid -> {:error, :mcp_protocol_error}
    end
  end

  defp classify_message(decoded) do
    case {
      Map.has_key?(decoded, "id"),
      decoded["method"],
      Map.fetch(decoded, "params"),
      Map.has_key?(decoded, "result") or Map.has_key?(decoded, "error")
    } do
      {false, "notifications/" <> name, :error, false} when byte_size(name) > 0 ->
        {:ok, {:notification, decoded}}

      {false, "notifications/" <> name, {:ok, params}, false}
      when byte_size(name) > 0 and is_map(params) and not is_struct(params) ->
        {:ok, {:notification, decoded}}

      _invalid ->
        {:error, :mcp_protocol_error}
    end
  end

  @spec outcome(map(), binary()) ::
          {:ok, map()}
          | {:error, :mcp_protocol_error | :mcp_remote_error | :mcp_unsupported_result}
  def outcome(body, method) when is_map(body) and is_binary(method) do
    case {Map.fetch(body, "result"), Map.fetch(body, "error")} do
      {{:ok, result}, :error} when is_map(result) ->
        classify_result(result, method)

      {:error, {:ok, error}} when is_map(error) ->
        if valid_rpc_error?(error),
          do: {:error, :mcp_remote_error},
          else: {:error, :mcp_protocol_error}

      _invalid ->
        {:error, :mcp_protocol_error}
    end
  end

  def outcome(_body, _method), do: {:error, :mcp_protocol_error}

  @spec discover_result(map(), binary()) :: {:ok, map()} | {:error, :mcp_protocol_error}
  def discover_result(result, protocol) when is_map(result) and is_binary(protocol) do
    with versions when is_list(versions) and length(versions) in 1..32 <-
           result["supportedVersions"],
         true <-
           Enum.all?(versions, &(is_binary(&1) and byte_size(&1) in 1..64)) and
             protocol in versions,
         capabilities when is_map(capabilities) and not is_struct(capabilities) <-
           result["capabilities"],
         tools when is_map(tools) and not is_struct(tools) <- capabilities["tools"] do
      {:ok, %{capabilities: capabilities, server_info: server_info(result)}}
    else
      _reason -> {:error, :mcp_protocol_error}
    end
  end

  def discover_result(_result, _protocol), do: {:error, :mcp_protocol_error}

  @spec catalog_page(map(), map(), pos_integer(), pos_integer()) :: catalog_result()
  def catalog_page(
        result,
        %{
          tools: tools,
          names: names,
          seen: seen,
          received_tools: received_tools,
          received_bytes: received_bytes
        } = state,
        max_tools,
        max_bytes
      )
      when is_map(result) and is_map(tools) and is_map(names) and is_map(seen) and
             valid_catalog_counters(received_tools, received_bytes) and
             valid_catalog_limits(max_tools, max_bytes) do
    with page when is_list(page) <- result["tools"],
         {:ok, received_tools, received_bytes} <-
           catalog_usage(page, received_tools, received_bytes, max_tools, max_bytes),
         {:ok, tools, names} <- merge_tools(tools, names, page),
         next <- result["nextCursor"],
         true <- is_nil(next) or (is_binary(next) and byte_size(next) in 1..1_024),
         false <- is_binary(next) and Map.has_key?(seen, next) do
      continue_or_finish(next, %{
        state
        | tools: tools,
          names: names,
          seen: if(is_binary(next), do: Map.put(seen, next, true), else: seen),
          received_tools: received_tools,
          received_bytes: received_bytes
      })
    else
      {:error, _reason} = error -> error
      false -> {:error, :mcp_invalid_catalog}
      _reason -> {:error, :mcp_invalid_catalog}
    end
  end

  def catalog_page(_result, _state, _max_tools, _max_bytes),
    do: {:error, :mcp_invalid_catalog}

  @spec selected_tool(map()) ::
          {:ok,
           %{
             description: binary() | nil,
             header_parameters: [map()],
             input_schema: map(),
             output_schema: map() | nil
           }}
          | {:error, :mcp_invalid_tool_schema}
  def selected_tool(tool) when is_map(tool) and not is_struct(tool) do
    with description <- Map.get(tool, "description"),
         true <-
           is_nil(description) or (is_binary(description) and byte_size(description) <= 4_096),
         input when is_map(input) <- tool["inputSchema"],
         {:ok, header_parameters} <- header_parameters(input),
         {:ok, output} <- optional_output_schema(tool) do
      {:ok,
       %{
         description: description,
         header_parameters: header_parameters,
         input_schema: input,
         output_schema: output
       }}
    else
      {:error, _reason} = error -> error
      _reason -> {:error, :mcp_invalid_tool_schema}
    end
  end

  def selected_tool(_tool), do: {:error, :mcp_invalid_tool_schema}

  @spec header_parameters(map()) :: {:ok, [map()]} | {:error, :mcp_invalid_tool_schema}
  def header_parameters(input_schema) when is_map(input_schema) and not is_struct(input_schema) do
    with {:ok, parameters} <- scan_schema(input_schema, [], false, true, [], 1),
         true <- length(parameters) <= @max_header_parameters,
         names = Enum.map(parameters, &String.downcase(&1.name)),
         true <- Enum.uniq(names) == names do
      {:ok, Enum.sort_by(parameters, &{String.downcase(&1.name), &1.path})}
    else
      _reason -> {:error, :mcp_invalid_tool_schema}
    end
  end

  def header_parameters(_input_schema), do: {:error, :mcp_invalid_tool_schema}

  @spec header_values([map()], map()) ::
          {:ok, [{binary(), binary()}]} | {:error, :mcp_protocol_error}
  def header_values(parameters, arguments) when is_list(parameters) and is_map(arguments) do
    Enum.reduce_while(parameters, {:ok, []}, fn parameter, {:ok, headers} ->
      case fetch_path(arguments, parameter.path) do
        :missing ->
          {:cont, {:ok, headers}}

        {:ok, nil} ->
          {:cont, {:ok, headers}}

        {:ok, value} ->
          case parameter_value(value, parameter.type) do
            {:ok, encoded} ->
              {:cont, {:ok, [{"mcp-param-#{parameter.name}", encode_header(encoded)} | headers]}}

            :error ->
              {:halt, {:error, :mcp_protocol_error}}
          end
      end
    end)
    |> case do
      {:ok, headers} ->
        headers = Enum.reverse(headers)

        if length(headers) <= @max_header_parameters and
             header_wire_bytes(headers) <= @max_parameter_header_bytes,
           do: {:ok, headers},
           else: {:error, :mcp_protocol_error}

      error ->
        error
    end
  end

  def header_values(_parameters, _arguments), do: {:error, :mcp_protocol_error}

  @spec encode_header(binary()) :: binary()
  def encode_header(value) when is_binary(value) do
    if plain_header_value?(value) do
      value
    else
      "=?base64?#{Base.encode64(value)}?="
    end
  end

  @spec normalize_tool_result(map(), map() | nil) ::
          {:ok, term()} | {:error, :mcp_domain_error | :mcp_invalid_result}
  def normalize_tool_result(result, output_validator) when is_map(result) do
    if valid_is_error?(result),
      do: normalize_valid_tool_result(result, output_validator),
      else: {:error, :mcp_invalid_result}
  end

  def normalize_tool_result(_result, _output_validator), do: {:error, :mcp_invalid_result}

  defp normalize_valid_tool_result(
         %{"isError" => true, "content" => content} = result,
         _output_validator
       )
       when is_list(content) do
    if Map.has_key?(result, "structuredContent") do
      {:error, :mcp_invalid_result}
    else
      case text_result(content) do
        {:ok, _text} -> {:error, :mcp_domain_error}
        {:error, :mcp_invalid_result} -> {:error, :mcp_invalid_result}
      end
    end
  end

  defp normalize_valid_tool_result(
         %{"structuredContent" => structured, "content" => content},
         output_validator
       )
       when not is_nil(output_validator) and is_list(content) do
    with true <- JSONSchema.valid?(output_validator, structured),
         {:ok, _text} <- text_result(content) do
      {:ok, structured}
    else
      _invalid -> {:error, :mcp_invalid_result}
    end
  end

  defp normalize_valid_tool_result(%{"content" => content} = result, nil)
       when is_list(content) do
    if Map.has_key?(result, "structuredContent"),
      do: {:error, :mcp_invalid_result},
      else: text_result(content)
  end

  defp normalize_valid_tool_result(_result, _output_validator),
    do: {:error, :mcp_invalid_result}

  defp valid_rpc_error?(%{"code" => code, "message" => message} = error) do
    Map.keys(error) -- ~w(code message data) == [] and is_integer(code) and
      is_binary(message) and byte_size(message) <= 4_096 and String.valid?(message) and
      (not Map.has_key?(error, "data") or JSONValue.value?(error["data"]))
  end

  defp valid_rpc_error?(_error), do: false

  defp continue_or_finish(nil, %{tools: tools}), do: {:done, tools}
  defp continue_or_finish(next, state), do: {:continue, next, state}

  defp catalog_usage(page, received_tools, received_bytes, max_tools, max_bytes) do
    with count when count <= max_tools <- received_tools + length(page),
         {:ok, encoded_page} <- DeterministicJSON.encode(page),
         bytes when bytes <= max_bytes <- received_bytes + byte_size(encoded_page) do
      {:ok, count, bytes}
    else
      _reason -> {:error, :mcp_catalog_exceeded}
    end
  end

  defp valid_is_error?(result) do
    case Map.fetch(result, "isError") do
      :error -> true
      {:ok, value} -> is_boolean(value)
    end
  end

  defp merge_tools(existing, names, page) do
    Enum.reduce_while(page, {:ok, existing, names}, fn tool, {:ok, tools, seen_names} ->
      merge_tool(tool, tools, seen_names)
    end)
  end

  defp merge_tool(tool, tools, names) do
    with true <- is_map(tool) and not is_struct(tool),
         name when is_binary(name) <- tool["name"],
         true <- valid_tool_name?(name),
         false <- Map.has_key?(names, name) do
      merge_tool_schema(tool["inputSchema"], name, tool, tools, Map.put(names, name, true))
    else
      _reason -> {:halt, {:error, :mcp_invalid_catalog}}
    end
  end

  defp merge_tool_schema(schema, name, tool, tools, names) when is_map(schema) do
    case header_parameters(schema) do
      {:ok, _parameters} -> {:cont, {:ok, Map.put(tools, name, tool), names}}
      {:error, :mcp_invalid_tool_schema} -> {:cont, {:ok, tools, names}}
    end
  end

  defp merge_tool_schema(_schema, name, tool, tools, names),
    do: {:cont, {:ok, Map.put(tools, name, tool), names}}

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

  defp classify_result(%{"resultType" => "complete"} = result, method) do
    if cacheable_method?(method), do: validate_cache_hints(result), else: {:ok, result}
  end

  defp classify_result(%{"resultType" => type}, _method)
       when type in ["input_required", "task"],
       do: {:error, :mcp_unsupported_result}

  defp classify_result(result, _method) when not is_map_key(result, "resultType"),
    do: {:error, :mcp_protocol_error}

  defp classify_result(%{"resultType" => type}, _method) when is_binary(type),
    do: {:error, :mcp_unsupported_result}

  defp classify_result(_result, _method), do: {:error, :mcp_protocol_error}

  defp validate_cache_hints(%{"ttlMs" => ttl, "cacheScope" => scope} = result)
       when is_integer(ttl) and ttl >= 0 and scope in ["public", "private"],
       do: {:ok, result}

  defp validate_cache_hints(_result), do: {:error, :mcp_protocol_error}

  defp cacheable_method?(method),
    do:
      method in [
        "server/discover",
        "tools/list",
        "prompts/list",
        "resources/list",
        "resources/templates/list",
        "resources/read"
      ]

  defp server_info(%{"_meta" => %{"io.modelcontextprotocol/serverInfo" => info}})
       when is_map(info) do
    case info do
      %{"name" => name, "version" => version}
      when is_binary(name) and byte_size(name) in 1..256 and is_binary(version) and
             byte_size(version) in 1..128 ->
        %{"name" => name, "version" => version}

      _invalid ->
        nil
    end
  end

  defp server_info(_result), do: nil

  defp scan_schema(_value, _path, _property?, _properties_allowed?, _acc, depth)
       when depth > @max_schema_depth,
       do: {:error, :mcp_invalid_tool_schema}

  defp scan_schema(value, path, property?, properties_allowed?, acc, depth)
       when is_map(value) do
    with {:ok, acc} <- maybe_add_header(value, path, property?, acc) do
      Enum.reduce_while(value, {:ok, acc}, fn
        {"properties", properties}, {:ok, current}
        when is_map(properties) and properties_allowed? ->
          scan_properties(properties, path, current, depth)

        {"properties", properties}, {:ok, current} when is_map(properties) ->
          continue_scan_collection(scan_schema_map(properties, path, current, depth))

        {"x-mcp-header", _value}, {:ok, current} ->
          {:cont, {:ok, current}}

        {"additionalProperties", value}, {:ok, current} when is_boolean(value) ->
          {:cont, {:ok, current}}

        {key, nested}, {:ok, current} when key in @schema_instance_keywords ->
          continue_scan_collection(validate_instance_depth(nested, 1, current))

        {key, nested}, {:ok, current} when key in @schema_value_keywords ->
          continue_scan(nested, path, false, false, current, depth + 1)

        {key, nested}, {:ok, current} when key in @schema_list_keywords and is_list(nested) ->
          continue_scan_collection(scan_schema_list(nested, path, current, depth))

        {key, nested}, {:ok, current} when key in @schema_map_keywords and is_map(nested) ->
          continue_scan_collection(scan_schema_map(nested, path, current, depth))

        {_key, _instance_or_annotation_data}, {:ok, current} ->
          {:cont, {:ok, current}}
      end)
    end
  end

  defp scan_schema(_value, _path, _property?, _properties_allowed?, acc, _depth), do: {:ok, acc}

  defp scan_schema_list(value, path, acc, depth) do
    Enum.reduce_while(value, {:ok, acc}, fn nested, {:ok, current} ->
      continue_scan(nested, path, false, false, current, depth + 1)
    end)
  end

  defp scan_schema_map(value, path, acc, depth) do
    Enum.reduce_while(value, {:ok, acc}, fn {_name, nested}, {:ok, current} ->
      continue_scan(nested, path, false, false, current, depth + 1)
    end)
  end

  defp continue_scan_collection({:ok, nested}), do: {:cont, {:ok, nested}}
  defp continue_scan_collection({:error, _reason} = error), do: {:halt, error}

  defp validate_instance_depth(_value, depth, _acc) when depth > @max_schema_depth,
    do: {:error, :mcp_invalid_tool_schema}

  defp validate_instance_depth(value, depth, acc) when is_map(value) do
    Enum.reduce_while(value, {:ok, acc}, fn {_key, nested}, {:ok, current} ->
      continue_scan_collection(validate_instance_depth(nested, depth + 1, current))
    end)
  end

  defp validate_instance_depth(value, depth, acc) when is_list(value) do
    Enum.reduce_while(value, {:ok, acc}, fn nested, {:ok, current} ->
      continue_scan_collection(validate_instance_depth(nested, depth + 1, current))
    end)
  end

  defp validate_instance_depth(_value, _depth, acc), do: {:ok, acc}

  defp scan_properties(properties, path, acc, depth) do
    case Enum.reduce_while(properties, {:ok, acc}, fn
           {name, schema}, {:ok, nested} when is_binary(name) ->
             continue_scan(schema, path ++ [name], true, true, nested, depth + 1)

           _property, _nested ->
             {:halt, {:error, :mcp_invalid_tool_schema}}
         end) do
      {:ok, nested} -> {:cont, {:ok, nested}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp continue_scan(value, path, property?, properties_allowed?, acc, depth) do
    case scan_schema(value, path, property?, properties_allowed?, acc, depth) do
      {:ok, nested} -> {:cont, {:ok, nested}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp maybe_add_header(%{"x-mcp-header" => name} = schema, path, true, acc)
       when is_binary(name) do
    type = schema["type"]

    if byte_size(name) in 1..@max_header_name_bytes and name =~ @header_token and
         type in ["string", "integer", "boolean"] do
      {:ok, [%{name: name, path: path, type: type} | acc]}
    else
      {:error, :mcp_invalid_tool_schema}
    end
  end

  defp maybe_add_header(schema, _path, _reachable_property?, acc) do
    if Map.has_key?(schema, "x-mcp-header"),
      do: {:error, :mcp_invalid_tool_schema},
      else: {:ok, acc}
  end

  defp fetch_path(value, []), do: {:ok, value}

  defp fetch_path(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> fetch_path(value, rest)
      :error -> :missing
    end
  end

  defp fetch_path(_value, _path), do: :missing

  defp parameter_value(value, "string") when is_binary(value), do: {:ok, value}
  defp parameter_value(true, "boolean"), do: {:ok, "true"}
  defp parameter_value(false, "boolean"), do: {:ok, "false"}

  defp parameter_value(value, "integer")
       when is_integer(value) and value >= -@max_safe_integer and value <= @max_safe_integer,
       do: {:ok, Integer.to_string(value)}

  defp parameter_value(value, "integer")
       when is_float(value) and value == value and value >= -@max_safe_integer and
              value <= @max_safe_integer and trunc(value) == value,
       do: {:ok, value |> trunc() |> Integer.to_string()}

  defp parameter_value(_value, _type), do: :error

  defp header_wire_bytes(headers) do
    Enum.reduce(headers, 0, fn {name, value}, total ->
      total + byte_size(name) + byte_size(value) + 4
    end)
  end

  defp plain_header_value?(value) do
    value == String.trim(value) and
      not (String.starts_with?(value, "=?base64?") and String.ends_with?(value, "?=")) and
      Enum.all?(:binary.bin_to_list(value), &(&1 in 0x20..0x7E or &1 == 0x09))
  end
end
