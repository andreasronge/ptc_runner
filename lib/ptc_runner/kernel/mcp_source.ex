defmodule PtcRunner.Kernel.MCPSource do
  @moduledoc """
  Builds one host-installed, read-only MCP Streamable HTTP capability source.

  The host freezes the endpoint, credential/header callback, upstream-to-public
  tool mapping, and installed ceilings in `builder/1`. A manifest can only
  select mapped public names and lower the request timeout or result ceiling.
  Each run build initializes one MCP 2025-11-25 session, discovers tools in
  that session, compiles their bounded schemas, and returns ordinary frozen
  Kernel capabilities plus a safe deterministic snapshot. Request deadlines
  bound connection checkout, connection establishment, response receipt, and
  total elapsed work. Responses reject duplicate JSON object keys before
  protocol validation. Input and output schemas are compiled once during
  assembly and the compiled validators are reused for every invocation.

  The session lease owns every active request. Closing the lease first kills
  and drains request owners, then issues a separately bounded session DELETE,
  establishing the required request-termination-before-session-close order.

  This pre-production source supports JSON and SSE responses to POST requests,
  structured object results, and text-only results. It rejects mixed or
  unsupported content, redirects, remote endpoint changes, writes, and
  manifest-supplied connection or credential configuration.
  """

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.MCPLease
  alias PtcRunner.Kernel.MCPProtocol
  alias PtcRunner.Kernel.ProviderError

  @protocol "2025-11-25"
  @max_discovery_bytes 1_048_576
  @max_headers 32
  @max_header_bytes 16_384
  @name ~r/\A[a-z][a-z0-9._-]{0,127}\z/

  @type builder :: PtcRunner.Kernel.ProviderRegistry.builder()

  @spec builder(keyword()) :: builder()
  @doc """
  Returns an installed provider builder for one fixed MCP source.

  ## Options

    * `:endpoint` - required fixed HTTPS URL. Loopback HTTP is accepted only
      when `:allow_insecure_loopback` is `true` (default `false`). Userinfo and
      fragments are rejected.
    * `:headers` - zero-argument credential/header callback, evaluated inside
      each request deadline (default `fn -> [] end`). At most 32 valid headers
      totaling 16,384 bytes are accepted. Values never enter capabilities,
      snapshots, errors, Logger, Telemetry, or canonical events.
    * `:tools` - required map from fixed upstream names to
      `%{as: public_name, effect: :read}`. Both names are unique and bounded;
      only the public name crosses the capability boundary.
    * `:timeout_ms` - installed end-to-end ceiling for discovery, calls, and
      session cleanup (default `5_000`). A manifest may only lower it.
    * `:max_result_bytes` - installed response ceiling (default `1_000_000`).
    * `:max_catalog_tools` - discovery catalog ceiling from 1 through 128
      (default `128`).
    * `:max_pages` - discovery pagination ceiling from 1 through 64
      (default `16`).

  Unknown or invalid installation options raise `ArgumentError` without
  including option values. The returned registry builder accepts an `"allow"`
  list of installed public names, an optional `"model_visible"` subset
  (defaulting to the full allow list), and optional lower `"timeout_ms"` and
  `"max_result_bytes"` values; invalid selections return
  `{:error, :invalid_mcp_selection}`. Assembly returns
  `{:ok, %{capabilities: list, snapshot: map, close: zero_arity_function}}` or a
  stable atom error: `:mcp_authentication_failed`, `:mcp_timeout`,
  `:mcp_transport_error`, `:mcp_protocol_error`, `:mcp_remote_error`,
  `:mcp_response_exceeded`,
  `:mcp_session_expired`, `:mcp_catalog_exceeded`, `:mcp_invalid_catalog`,
  `:mcp_invalid_tool_schema`, `:mcp_tool_task_required`, or
  `:mcp_mapped_tool_missing`.

  ## Frozen result and snapshot contracts

  Discovery produces ordinary read-only `PtcRunner.Kernel.Capability` values.
  An advertised object output schema accepts only schema-valid
  `structuredContent` with absent or empty `content`. A tool without an output
  schema accepts only exact text blocks and returns `%{"text" => [string()]}`.
  MCP `isError`, malformed/mixed content, invalid JSON-RPC envelopes, and
  schema failures become bounded `PtcRunner.Kernel.ProviderError` values with
  closed reasons. Authentication, timeout, session-expiry, invalid-result, and
  transport failures never include remote messages or payloads.

  The safe connector snapshot has exact top-level fields `provider`,
  `protocol`, `snapshot_hash`, and `tools`. Each sorted tool entry contains
  only its public `name`, fixed `"read"` effect, `input_schema_hash`, and
  nullable `output_schema_hash`. Hashes are lowercase SHA-256; endpoints,
  upstream names, descriptions, headers, credentials, session IDs, arguments,
  and results are excluded.
  """
  def builder(opts) when is_list(opts) do
    case installed_config(opts) do
      {:ok, installed} -> fn selection, context -> build(installed, selection, context) end
      {:error, reason} -> raise ArgumentError, "invalid MCP source: #{reason}"
    end
  end

  def builder(_opts), do: raise(ArgumentError, "invalid MCP source")

  defp installed_config(opts) do
    allowed = [
      :endpoint,
      :headers,
      :tools,
      :timeout_ms,
      :max_result_bytes,
      :max_catalog_tools,
      :max_pages,
      :allow_insecure_loopback
    ]

    with true <- Keyword.keys(opts) -- allowed == [],
         endpoint when is_binary(endpoint) <- Keyword.get(opts, :endpoint),
         :ok <- endpoint(endpoint, Keyword.get(opts, :allow_insecure_loopback, false)),
         headers when is_function(headers, 0) <- Keyword.get(opts, :headers, fn -> [] end),
         {:ok, tools} <- installed_tools(Keyword.get(opts, :tools)),
         timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 <-
           Keyword.get(opts, :timeout_ms, 5_000),
         max_result_bytes when is_integer(max_result_bytes) and max_result_bytes > 0 <-
           Keyword.get(opts, :max_result_bytes, 1_000_000),
         max_catalog_tools when max_catalog_tools in 1..128 <-
           Keyword.get(opts, :max_catalog_tools, 128),
         max_pages when max_pages in 1..64 <- Keyword.get(opts, :max_pages, 16) do
      {:ok,
       %{
         endpoint: endpoint,
         headers: headers,
         tools: tools,
         timeout_ms: timeout_ms,
         max_result_bytes: max_result_bytes,
         max_catalog_tools: max_catalog_tools,
         max_pages: max_pages
       }}
    else
      _reason -> {:error, :invalid_installation}
    end
  end

  defp endpoint(endpoint, allow_loopback?) do
    case URI.parse(endpoint) do
      %URI{scheme: "https", host: host, userinfo: nil, fragment: nil} when is_binary(host) ->
        :ok

      %URI{scheme: "http", host: host, userinfo: nil, fragment: nil}
      when allow_loopback? and host in ["127.0.0.1", "localhost", "::1"] ->
        :ok

      _uri ->
        {:error, :invalid_endpoint}
    end
  end

  defp installed_tools(tools) when is_map(tools) and map_size(tools) in 1..128 do
    Enum.reduce_while(tools, {:ok, %{}, MapSet.new()}, fn
      {upstream, %{as: public, effect: :read} = mapping}, {:ok, normalized, public_names}
      when is_binary(upstream) and is_binary(public) ->
        if Map.keys(mapping) -- [:as, :effect] == [] and MCPProtocol.valid_tool_name?(upstream) and
             public =~ @name and not MapSet.member?(public_names, public) do
          {:cont,
           {:ok, Map.put(normalized, upstream, %{as: public, effect: :read}),
            MapSet.put(public_names, public)}}
        else
          {:halt, {:error, :invalid_tools}}
        end

      _mapping, _acc ->
        {:halt, {:error, :invalid_tools}}
    end)
    |> case do
      {:ok, normalized, _names} -> {:ok, normalized}
      error -> error
    end
  end

  defp installed_tools(_tools), do: {:error, :invalid_tools}

  defp build(installed, selection, context) do
    with {:ok, selected} <- selection(installed, selection, context),
         {:ok, lease} <-
           MCPLease.start(
             owner: context.owner,
             endpoint: installed.endpoint,
             headers: installed.headers,
             timeout_ms: selected.timeout_ms
           ) do
      case discover(lease, installed, selected, context.provider) do
        {:ok, capabilities, snapshot} ->
          {:ok,
           %{
             capabilities: capabilities,
             snapshot: snapshot,
             close: fn -> MCPLease.close(lease) end
           }}

        {:error, reason} ->
          MCPLease.close(lease)
          {:error, reason}
      end
    end
  end

  defp selection(installed, selection, context) do
    with true <- is_map(selection) and not is_struct(selection),
         true <-
           Map.keys(selection) -- ~w(allow model_visible timeout_ms max_result_bytes) == [],
         allow when is_list(allow) and length(allow) in 1..128 <- selection["allow"],
         true <- Enum.all?(allow, &is_binary/1) and Enum.uniq(allow) == allow,
         public_names =
           Map.new(installed.tools, fn {_upstream, mapping} -> {mapping.as, true} end),
         true <- Enum.all?(allow, &Map.has_key?(public_names, &1)),
         model_visible when is_list(model_visible) and length(model_visible) <= 128 <-
           Map.get(selection, "model_visible", allow),
         true <-
           Enum.all?(model_visible, &is_binary/1) and
             Enum.uniq(model_visible) == model_visible,
         true <- Enum.all?(model_visible, &(&1 in allow)),
         timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 <-
           Map.get(selection, "timeout_ms", installed.timeout_ms),
         true <- timeout_ms <= installed.timeout_ms,
         true <- timeout_ms <= destination_timeout(context),
         max_result_bytes when is_integer(max_result_bytes) and max_result_bytes > 0 <-
           Map.get(selection, "max_result_bytes", installed.max_result_bytes),
         true <- max_result_bytes <= installed.max_result_bytes,
         true <- max_result_bytes <= context.limits.capability_result_bytes do
      {:ok,
       %{
         allow: MapSet.new(allow),
         model_visible: MapSet.new(model_visible),
         timeout_ms: timeout_ms,
         max_result_bytes: max_result_bytes
       }}
    else
      _reason -> {:error, :invalid_mcp_selection}
    end
  end

  defp destination_timeout(%{destination: :workflow, limits: limits}),
    do: limits.workflow_timeout_ms

  defp destination_timeout(%{destination: :mission, limits: limits}),
    do: limits.evaluation_timeout_ms

  defp discover(lease, installed, selected, provider) do
    with {:ok, initialized} <-
           rpc(
             lease,
             "initialize",
             %{
               "protocolVersion" => @protocol,
               "capabilities" => %{},
               "clientInfo" => %{"name" => "ptc_runner", "version" => "0.x"}
             },
             @max_discovery_bytes
           ),
         @protocol <- initialized["protocolVersion"],
         :ok <- notification(lease, "notifications/initialized", %{}),
         {:ok, discovered} <- list_tools(lease, installed),
         {:ok, capabilities, tools} <- capabilities(lease, installed, selected, discovered),
         {:ok, snapshot} <- snapshot(provider, tools) do
      {:ok, capabilities, snapshot}
    else
      {:error, _reason} = error -> error
      _reason -> {:error, :mcp_protocol_error}
    end
  end

  defp list_tools(lease, installed),
    do: list_tools(lease, installed, nil, %{}, %{}, 0)

  defp list_tools(_lease, installed, _cursor, _seen, tools, pages)
       when pages >= installed.max_pages or map_size(tools) > installed.max_catalog_tools,
       do: {:error, :mcp_catalog_exceeded}

  defp list_tools(lease, installed, cursor, seen, tools, pages) do
    params = if is_nil(cursor), do: %{}, else: %{"cursor" => cursor}

    with {:ok, result} <- rpc(lease, "tools/list", params, @max_discovery_bytes) do
      case MCPProtocol.catalog_page(
             result,
             tools,
             seen,
             installed.max_catalog_tools,
             @max_discovery_bytes
           ) do
        {:done, tools} ->
          {:ok, tools}

        {:continue, next, seen, tools} ->
          list_tools(lease, installed, next, seen, tools, pages + 1)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp capabilities(lease, installed, selected, discovered) do
    installed.tools
    |> Enum.filter(fn {_upstream, mapping} -> MapSet.member?(selected.allow, mapping.as) end)
    |> Enum.sort_by(fn {_upstream, mapping} -> mapping.as end)
    |> Enum.reduce_while({:ok, [], []}, fn {upstream, mapping}, {:ok, capabilities, tools} ->
      case capability(lease, upstream, mapping, discovered[upstream], selected) do
        {:ok, capability, snapshot_tool} ->
          {:cont, {:ok, [capability | capabilities], [snapshot_tool | tools]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, capabilities, tools} -> {:ok, Enum.reverse(capabilities), Enum.reverse(tools)}
      error -> error
    end
  end

  defp capability(_lease, _upstream, _mapping, nil, _selected),
    do: {:error, :mcp_mapped_tool_missing}

  defp capability(lease, upstream, mapping, tool, selected) do
    case MCPProtocol.selected_tool(tool) do
      {:ok, contract} ->
        assemble_capability(lease, upstream, mapping, contract, selected)

      {:error, _reason} = error ->
        error
    end
  end

  defp assemble_capability(lease, upstream, mapping, contract, selected) do
    with {:ok, capability} <-
           Capability.new(
             name: mapping.as,
             description: contract.description,
             model_visible: MapSet.member?(selected.model_visible, mapping.as),
             input_schema: contract.input_schema,
             output_schema: contract.output_schema,
             effect: :read,
             callback: fn _arguments -> {:error, :uninstalled_mcp_callback} end
           ),
         capability = %{
           capability
           | callback: callback(lease, upstream, capability.output_validator, selected)
         },
         {:ok, input_hash} <- schema_hash(capability.input_schema),
         {:ok, output_hash} <- optional_schema_hash(capability.output_schema) do
      {:ok, capability,
       %{
         "name" => mapping.as,
         "effect" => "read",
         "input_schema_hash" => input_hash,
         "output_schema_hash" => output_hash
       }}
    else
      _reason -> {:error, :mcp_invalid_tool_schema}
    end
  end

  defp callback(lease, upstream, output_validator, selected) do
    fn arguments ->
      case rpc(
             lease,
             "tools/call",
             %{"name" => upstream, "arguments" => arguments},
             selected.max_result_bytes
           ) do
        {:ok, result} -> normalize_result(result, output_validator)
        {:error, reason} -> {:error, provider_error(reason)}
      end
    end
  end

  defp normalize_result(result, output_validator) do
    case MCPProtocol.normalize_tool_result(result, output_validator) do
      {:ok, value} ->
        {:ok, value}

      {:error, :mcp_domain_error} ->
        {:error, ProviderError.new(:domain_error, "mcp_domain_error")}

      {:error, :mcp_invalid_result} ->
        {:error, ProviderError.new(:invalid_result, "mcp_invalid_result")}
    end
  end

  defp snapshot(provider, tools) when is_binary(provider) do
    projection =
      {:object,
       [
         {"protocol", "mcp-#{@protocol}"},
         {"tools",
          Enum.map(tools, fn tool ->
            {:object,
             [
               {"name", tool["name"]},
               {"effect", tool["effect"]},
               {"input_schema_hash", tool["input_schema_hash"]},
               {"output_schema_hash", tool["output_schema_hash"]}
             ]}
          end)}
       ]}

    with {:ok, encoded} <- DeterministicJSON.encode(projection) do
      {:ok,
       %{
         "provider" => provider,
         "protocol" => "mcp-#{@protocol}",
         "snapshot_hash" => sha256(encoded),
         "tools" => tools
       }}
    end
  end

  defp schema_hash(schema) do
    with {:ok, encoded} <- DeterministicJSON.encode(schema), do: {:ok, sha256(encoded)}
  end

  defp optional_schema_hash(nil), do: {:ok, nil}
  defp optional_schema_hash(schema), do: schema_hash(schema)

  defp rpc(lease, method, params, max_bytes) do
    with_request(lease, fn request ->
      with {:ok, headers} <- request_headers(request),
           payload = MCPProtocol.request(request.id, method, params),
           {:ok, response} <- http(:post, lease, request, headers, payload, max_bytes),
           :ok <- maybe_capture_session(lease, response),
           {:ok, body} <- response_body(response, request.id) do
        MCPProtocol.outcome(body)
      end
    end)
  end

  defp notification(lease, method, params) do
    with_request(lease, fn request ->
      with {:ok, headers} <- request_headers(request),
           payload = MCPProtocol.notification(method, params),
           {:ok, response} <- http(:post, lease, request, headers, payload, 65_536) do
        if response.status in [200, 202, 204], do: :ok, else: {:error, :mcp_transport_error}
      end
    end)
  end

  defp with_request(lease, callback) do
    case MCPLease.begin_request(lease) do
      {:ok, request} ->
        try do
          task =
            Task.async(fn ->
              try do
                callback.(request)
              rescue
                _exception -> {:error, :mcp_transport_error}
              catch
                _kind, _reason -> {:error, :mcp_transport_error}
              end
            end)

          case Task.yield(task, request.timeout_ms) || Task.shutdown(task, :brutal_kill) do
            {:ok, result} -> result
            {:exit, _reason} -> {:error, :mcp_transport_error}
            nil -> {:error, :mcp_timeout}
          end
        after
          MCPLease.finish_request(lease)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_headers(request) do
    with {:ok, installed} <- safe_headers(request.headers),
         :ok <- validate_headers(installed) do
      protocol_headers =
        [
          {"accept", "application/json, text/event-stream"},
          {"content-type", "application/json"}
        ] ++
          if(request.id > 1, do: [{"mcp-protocol-version", request.protocol}], else: []) ++
          if(is_binary(request.session_id),
            do: [{"mcp-session-id", request.session_id}],
            else: []
          )

      {:ok, installed ++ protocol_headers}
    end
  end

  defp safe_headers(callback) do
    case callback.() do
      headers when is_list(headers) -> {:ok, headers}
      _headers -> {:error, :mcp_authentication_failed}
    end
  rescue
    _exception -> {:error, :mcp_authentication_failed}
  catch
    _kind, _reason -> {:error, :mcp_authentication_failed}
  end

  defp validate_headers(headers) do
    reserved = ~w(accept content-type mcp-protocol-version mcp-session-id)

    valid? =
      length(headers) <= @max_headers and
        Enum.all?(headers, fn
          {name, value} when is_binary(name) and is_binary(value) ->
            name =~ ~r/\A[a-z0-9-]+\z/ and name not in reserved and
              not String.contains?(value, ["\r", "\n"])

          _header ->
            false
        end) and byte_size(:erlang.term_to_binary(headers)) <= @max_header_bytes

    if valid?, do: :ok, else: {:error, :mcp_authentication_failed}
  end

  defp http(method, lease, request, headers, payload, max_bytes) do
    into = fn {:data, data}, {req, response} ->
      body = if is_binary(response.body), do: response.body, else: ""

      if byte_size(body) + byte_size(data) <= max_bytes do
        {:cont, {req, %{response | body: body <> data}}}
      else
        {:halt, {req, %{response | body: :body_exceeded}}}
      end
    end

    case Req.request(
           method: method,
           url: request.endpoint,
           headers: headers,
           json: payload,
           connect_options: [timeout: request.timeout_ms],
           pool_timeout: request.timeout_ms,
           receive_timeout: request.timeout_ms,
           retry: false,
           redirect: false,
           decode_body: false,
           into: into
         ) do
      {:ok, %{status: 404}} ->
        MCPLease.expire(lease)
        {:error, :mcp_session_expired}

      {:ok, %{status: status, body: :body_exceeded}} when status in 200..299 ->
        {:error, :mcp_response_exceeded}

      {:ok, %{status: status} = response} when status in 200..299 ->
        {:ok, response}

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, :mcp_authentication_failed}

      {:ok, _response} ->
        {:error, :mcp_transport_error}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :mcp_timeout}

      {:error, _reason} ->
        {:error, :mcp_transport_error}
    end
  end

  defp maybe_capture_session(lease, response) do
    case Req.Response.get_header(response, "mcp-session-id") do
      [] ->
        :ok

      [session_id]
      when is_binary(session_id) and byte_size(session_id) in 1..1_024 ->
        MCPLease.set_session(lease, session_id)

      _headers ->
        {:error, :mcp_protocol_error}
    end
  end

  defp response_body(%{body: body} = response, id) when is_binary(body) do
    content_types = Req.Response.get_header(response, "content-type")

    cond do
      Enum.any?(content_types, &String.starts_with?(&1, "application/json")) ->
        MCPProtocol.decode_response(body, id)

      Enum.any?(content_types, &String.starts_with?(&1, "text/event-stream")) ->
        decode_sse(body, id)

      true ->
        {:error, :mcp_protocol_error}
    end
  end

  defp response_body(_response, _id), do: {:error, :mcp_response_exceeded}

  defp decode_sse(body, id) do
    body
    |> String.split(~r/\r?\n\r?\n/, trim: true)
    |> Enum.reduce_while({:error, :mcp_protocol_error}, fn event, _acc ->
      data =
        event
        |> String.split(~r/\r?\n/)
        |> Enum.filter(&String.starts_with?(&1, "data:"))
        |> Enum.map_join("\n", &String.trim_leading(&1, "data:"))

      case MCPProtocol.decode_response(data, id) do
        {:ok, decoded} -> {:halt, {:ok, decoded}}
        {:error, :mcp_protocol_error} -> {:cont, {:error, :mcp_protocol_error}}
      end
    end)
  end

  defp provider_error(:mcp_session_expired),
    do: ProviderError.new(:session_expired, "mcp_session_expired")

  defp provider_error(:mcp_authentication_failed),
    do: ProviderError.new(:authentication_failed, "mcp_authentication_failed")

  defp provider_error(:mcp_timeout),
    do: ProviderError.new(:timeout, "mcp_timeout", retryable?: true)

  defp provider_error(:mcp_response_exceeded),
    do: ProviderError.new(:invalid_result, "mcp_response_exceeded")

  defp provider_error(:mcp_protocol_error),
    do: ProviderError.new(:invalid_result, "mcp_protocol_error")

  defp provider_error(:mcp_remote_error),
    do: ProviderError.new(:domain_error, "mcp_remote_error")

  defp provider_error(_reason),
    do: ProviderError.new(:transport_error, "mcp_transport_error", retryable?: true)

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
