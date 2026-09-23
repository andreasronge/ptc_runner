defmodule PtcGateway.MCP do
  @moduledoc "Strict, stateless MCP 2026-07-28 discovery and static listing boundary."
  @behaviour Plug
  import Plug.Conn

  alias PtcRunner.Kernel.{
    DeterministicJSON,
    MCPProtocol,
    ServingOutcome,
    ServingTemplate,
    StrictJSON,
    WarmProviderRuntime
  }

  @revision "2026-07-28"
  @body_limit 2_097_152
  # A request holds one of `max_inflight_requests` from before its body is read
  # (`admitted/2`) until its response completes, so how long the transport waits
  # for body bytes is how long one stalled client can hold a slot. The default is
  # 15 s, which at a bound of eight is a fifteen-second outage of the whole
  # endpoint caused by eight clients that sent perfect headers and then hung —
  # while readiness, which reports on the warm runtime, stays green throughout.
  # This budget bounds a peer that stops sending. A peer that keeps dribbling
  # bytes renews it by definition; that residue is bounded by the in-flight
  # ceiling, the loopback binding and the bearer requirement. The router option
  # `:body_read_timeout_ms` overrides it so tests need not wait out the default.
  @body_read_timeout_ms 2_000
  # How often a streaming call probes its client while the run is still going.
  # A disconnect is observed at the first probe after it, so this is also how
  # long a vanished client's run continues before cancellation. The router
  # option `:heartbeat_ms` overrides it.
  @heartbeat_ms 5_000
  @response_limit 4_194_304
  @safe_integer 9_007_199_254_740_991
  @call_result_schema_path Path.expand(
                             "../../../site/schemas/mcp-2026-07-28.schema.json",
                             __DIR__
                           )
  @external_resource @call_result_schema_path
  @mcp_schema @call_result_schema_path |> File.read!() |> Jason.decode!()
  @call_result_schema %{
    "$schema" => @mcp_schema["$schema"],
    "$defs" => @mcp_schema["$defs"],
    "$ref" => "#/$defs/CallToolResultResponse"
  }
  @call_result_validator JSV.build!(@call_result_schema, atoms: false, warnings: :silent)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    with :ok <- valid_method(conn),
         :ok <- bounded_headers(conn),
         :ok <- valid_authority(conn, opts),
         :ok <- valid_origin(conn, opts),
         :ok <- authenticated(conn, opts),
         :ok <- valid_content_type(conn),
         :ok <- valid_accept(conn) do
      admitted(conn, opts)
    else
      {:fixed, conn, status, value, headers} -> fixed_reply(conn, status, value, headers)
    end
  rescue
    _ -> rpc_error(conn, 500, -32603, "Internal error", nil, nil)
  catch
    _, _ -> rpc_error(conn, 500, -32603, "Internal error", nil, nil)
  end

  defp admitted(conn, opts) do
    case PtcGateway.RequestAdmission.acquire(opts[:request_admission]) do
      {:ok, lease} ->
        try do
          handle_body(conn, opts)
        after
          PtcGateway.RequestAdmission.release(opts[:request_admission], lease)
        end

      :full ->
        rpc_error(conn, 429, -31999, "Server busy", nil, nil)

      :unavailable ->
        rpc_error(conn, 503, -31998, "Server unavailable", nil, nil)
    end
  end

  defp handle_body(conn, opts) do
    with {:ok, body, conn} <- read_bounded_body(conn, opts),
         {:ok, request} <- decode(body, conn),
         {:ok, id, method, params} <- envelope(request, conn),
         :ok <- valid_metadata(conn, id, method, params),
         {:ok, result} <- dispatch(conn, id, method, params, opts) do
      case result do
        {:stream, streamed} -> streamed
        value -> json_reply(conn, 200, %{"jsonrpc" => "2.0", "id" => id, "result" => value})
      end
    else
      {:fixed, conn, status, value, headers} ->
        fixed_reply(conn, status, value, headers)

      {:rpc, conn, status, code, message, id, data} ->
        rpc_error(conn, status, code, message, id, data)
    end
  end

  defp valid_method(%{method: "POST"}), do: :ok
  defp valid_method(conn), do: {:fixed, conn, 405, "method_not_allowed", [{"allow", "POST"}]}

  defp bounded_headers(conn) do
    bytes =
      Enum.reduce(conn.req_headers, 0, fn {name, value}, total ->
        total + byte_size(name) + byte_size(value)
      end)

    if length(conn.req_headers) <= 64 and bytes <= 32_768,
      do: :ok,
      else: {:fixed, conn, 431, "request_headers_too_large", []}
  end

  defp valid_authority(conn, opts) do
    if PtcGateway.Policy.valid_authority?(conn, opts[:listen]),
      do: :ok,
      else: {:fixed, conn, 400, "invalid_authority", []}
  end

  defp valid_origin(conn, opts) do
    if PtcGateway.Policy.allowed_origin?(conn, opts[:listen]),
      do: :ok,
      else: {:fixed, conn, 403, "origin_forbidden", []}
  end

  defp authenticated(conn, opts) do
    valid? =
      case get_req_header(conn, "authorization") do
        [value] when is_binary(value) ->
          if not String.valid?(value) do
            false
          else
            case Regex.run(~r/^([^ \t]+) +([^ \t]+)$/u, value, capture: :all_but_first) do
              [scheme, token] ->
                String.downcase(scheme) == "bearer" and
                  WarmProviderRuntime.authenticate(opts[:warm], token)

              _ ->
                false
            end
          end

        _ ->
          false
      end

    if valid?,
      do: :ok,
      else: {:fixed, conn, 401, "unauthorized", [{"www-authenticate", "Bearer"}]}
  end

  defp valid_content_type(conn) do
    valid? =
      case get_req_header(conn, "content-type") do
        [value] when is_binary(value) ->
          String.valid?(value) and
            Regex.match?(
              ~r/^application\/json(?:[ \t]*;[ \t]*charset[ \t]*=[ \t]*(?:utf-8|"utf-8"))?$/iu,
              value
            )

        _ ->
          false
      end

    if valid?, do: :ok, else: {:fixed, conn, 415, "unsupported_media_type", []}
  end

  defp valid_accept(conn) do
    valid? =
      case get_req_header(conn, "accept") do
        [value] when is_binary(value) ->
          with true <- String.valid?(value),
               {:ok, ranges} <- media_ranges(value) do
            accepts?(ranges, "application", "json") and
              accepts?(ranges, "text", "event-stream")
          else
            _ -> false
          end

        _ ->
          false
      end

    if valid?, do: :ok, else: {:fixed, conn, 406, "not_acceptable", []}
  end

  defp accepts?(ranges, wanted_type, wanted_subtype) do
    ranges
    |> Enum.filter(fn {type, subtype, params, _quality} ->
      type in ["*", wanted_type] and subtype in ["*", wanted_subtype] and
        compatible_params?(wanted_type, wanted_subtype, params)
    end)
    |> Enum.max_by(
      fn {type, subtype, params, _quality} -> {specificity(type, subtype), map_size(params)} end,
      fn -> {"*", "*", %{}, 0.0} end
    )
    |> elem(3)
    |> Kernel.>(0)
  end

  defp media_ranges(header) do
    ranges = header |> quoted_split(?,) |> Enum.map(&media_range/1)
    if :invalid in ranges, do: :error, else: {:ok, ranges}
  end

  defp media_range(range) do
    [media | params] = quoted_split(range, ?;)

    with [type, subtype] <- String.split(String.trim(media), "/", parts: 2),
         type <- String.downcase(type),
         subtype <- String.downcase(subtype),
         true <- media_token?(type) and media_token?(subtype),
         true <- type != "*" or subtype == "*",
         {:ok, media_params, quality} <- media_params(params) do
      {type, subtype, media_params, quality}
    else
      _ -> :invalid
    end
  end

  defp quoted_split(value, separator),
    do: quoted_split(value, separator, false, false, [], [])

  defp quoted_split(<<>>, _separator, _quoted?, _escaped?, current, parts) do
    part = current |> Enum.reverse() |> IO.iodata_to_binary()
    Enum.reverse([part | parts])
  end

  defp quoted_split(<<byte, rest::binary>>, separator, quoted?, escaped?, current, parts) do
    cond do
      escaped? ->
        quoted_split(rest, separator, quoted?, false, [byte | current], parts)

      quoted? and byte == ?\\ ->
        quoted_split(rest, separator, quoted?, true, [byte | current], parts)

      byte == ?" ->
        quoted_split(rest, separator, not quoted?, false, [byte | current], parts)

      byte == separator and not quoted? ->
        part = current |> Enum.reverse() |> IO.iodata_to_binary()
        quoted_split(rest, separator, false, false, [], [part | parts])

      true ->
        quoted_split(rest, separator, quoted?, false, [byte | current], parts)
    end
  end

  defp media_params(params) do
    Enum.reduce_while(params, {:ok, %{}, 1.0, false}, fn param, {:ok, values, quality, seen_q?} ->
      case String.split(String.trim(param), "=", parts: 2) do
        [name, value] ->
          parse_media_param(String.downcase(name), value, values, quality, seen_q?)

        _ ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, values, quality, _seen_q?} -> {:ok, values, quality}
      :error -> :error
    end
  end

  defp parse_media_param("q", value, values, _quality, false) do
    case parse_quality(value) do
      {:ok, quality} -> {:cont, {:ok, values, quality, true}}
      :error -> {:halt, :error}
    end
  end

  defp parse_media_param("q", _value, _values, _quality, true), do: {:halt, :error}

  defp parse_media_param(name, value, values, quality, false) do
    with true <- media_token?(name) and not Map.has_key?(values, name),
         {:ok, value} <- media_parameter_value(value) do
      {:cont, {:ok, Map.put(values, name, String.downcase(value)), quality, false}}
    else
      _ -> {:halt, :error}
    end
  end

  defp parse_media_param(name, value, values, quality, true) do
    with true <- media_token?(name),
         {:ok, _value} <- media_parameter_value(value) do
      {:cont, {:ok, values, quality, true}}
    else
      _ -> {:halt, :error}
    end
  end

  defp parse_quality(value) do
    if Regex.match?(~r/^(?:0(?:\.\d{0,3})?|1(?:\.0{0,3})?)$/, value),
      do:
        {:ok, String.to_float(if(String.contains?(value, "."), do: value, else: value <> ".0"))},
      else: :error
  end

  defp media_token?("*"), do: true
  defp media_token?(value), do: Regex.match?(~r/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/, value)

  defp media_parameter_value(value) do
    cond do
      media_token?(value) ->
        {:ok, value}

      Regex.match?(~r/^"(?:[^"\\\r\n]|\\[\x09\x20-\x7E])*"$/u, value) ->
        decoded =
          value
          |> binary_part(1, byte_size(value) - 2)
          |> then(&Regex.replace(~r/\\(.)/u, &1, "\\1"))

        {:ok, decoded}

      true ->
        :error
    end
  end

  defp compatible_params?("application", "json", params),
    do: params in [%{}, %{"charset" => "utf-8"}]

  defp compatible_params?(_type, _subtype, params), do: map_size(params) == 0
  defp specificity("*", "*"), do: 0
  defp specificity(_type, "*"), do: 1
  defp specificity(_type, _subtype), do: 2

  defp read_bounded_body(conn, opts) do
    case read_body(conn,
           length: @body_limit + 1,
           read_length: 64_000,
           read_timeout: Keyword.get(opts, :body_read_timeout_ms, @body_read_timeout_ms)
         ) do
      {:ok, body, conn} when byte_size(body) <= @body_limit -> {:ok, body, conn}
      {:ok, _body, conn} -> {:fixed, conn, 413, "request_too_large", []}
      {:more, _body, conn} -> {:fixed, conn, 413, "request_too_large", []}
      {:error, _reason} -> {:rpc, conn, 500, -32603, "Internal error", nil, nil}
    end
  rescue
    error in Bandit.HTTPError -> incomplete_body(conn, error)
  end

  # The transport raises rather than returns when a body read fails: a peer that
  # stops sending becomes `:request_timeout`, a malformed transfer encoding a bad
  # request. Without this clause the module's outer rescue answers both with
  # -32603, telling a client that its own unfinished request was a server fault.
  #
  # Both close the connection. The body was not read and the raise discarded the
  # adapter state that knew how much of it had been, so leaving the connection
  # open asks the transport to drain an unread body on its own default timeout —
  # which is the wait this budget exists to bound, reintroduced after the reply.
  defp incomplete_body(conn, %{plug_status: :request_timeout}),
    do: {:fixed, conn, 408, "request_timeout", [{"connection", "close"}]}

  defp incomplete_body(conn, _error),
    do: {:fixed, conn, 400, "request_invalid", [{"connection", "close"}]}

  defp decode(body, conn) do
    case StrictJSON.decode(body, max_depth: 64, max_nodes: 100_000) do
      {:ok, value} -> {:ok, value}
      _ -> {:rpc, conn, 400, -32700, "Parse error", nil, nil}
    end
  end

  defp envelope(
         %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params} = request,
         conn
       )
       when map_size(request) == 4 and is_binary(method) and is_map(params) do
    if valid_id?(id), do: {:ok, id, method, params}, else: invalid_envelope(conn, nil)
  end

  defp envelope(request, conn) when is_map(request),
    do: invalid_envelope(conn, valid_id(request["id"]))

  defp envelope(_request, conn), do: invalid_envelope(conn, nil)
  defp invalid_envelope(conn, id), do: {:rpc, conn, 400, -32600, "Invalid Request", id, nil}

  defp valid_id?(id) when is_binary(id), do: byte_size(id) in 1..256 and String.valid?(id)
  defp valid_id?(id) when is_integer(id), do: id in -@safe_integer..@safe_integer
  defp valid_id?(_id), do: false
  defp valid_id(id), do: if(valid_id?(id), do: id)

  defp valid_metadata(conn, id, method, params) do
    meta = params["_meta"]
    version = is_map(meta) && meta["io.modelcontextprotocol/protocolVersion"]
    capabilities = is_map(meta) && meta["io.modelcontextprotocol/clientCapabilities"]

    cond do
      not is_map(meta) or not is_binary(version) or not is_map(capabilities) or
        not valid_client_info?(meta) or encoded_size(meta) > 65_536 ->
        {:rpc, conn, 400, -32602, "Invalid Params", id, nil}

      single(conn, "mcp-protocol-version") != version or single(conn, "mcp-method") != method or
          (method != "tools/call" and get_req_header(conn, "mcp-name") != []) ->
        {:rpc, conn, 400, -32020, "Header mismatch", id, nil}

      version != @revision ->
        {:rpc, conn, 400, -32022, "Unsupported protocol version", id,
         %{"requested" => version, "supported" => [@revision]}}

      true ->
        :ok
    end
  end

  defp valid_client_info?(meta) do
    case Map.fetch(meta, "io.modelcontextprotocol/clientInfo") do
      :error ->
        true

      {:ok, %{"name" => name, "version" => version} = info} ->
        is_binary(name) and is_binary(version) and optional_string?(info, "title") and
          optional_string?(info, "description") and valid_website?(info) and valid_icons?(info)

      _ ->
        false
    end
  end

  defp optional_string?(map, key), do: not Map.has_key?(map, key) or is_binary(map[key])

  defp valid_website?(info) do
    case Map.fetch(info, "websiteUrl") do
      :error -> true
      {:ok, value} when is_binary(value) -> valid_uri?(value)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp valid_icons?(info) do
    case Map.fetch(info, "icons") do
      :error -> true
      {:ok, icons} when is_list(icons) -> Enum.all?(icons, &valid_icon?/1)
      _ -> false
    end
  end

  defp valid_icon?(%{"src" => src} = icon) when is_binary(src) do
    valid_uri?(src) and optional_string?(icon, "mimeType") and
      (not Map.has_key?(icon, "sizes") or
         (is_list(icon["sizes"]) and Enum.all?(icon["sizes"], &is_binary/1))) and
      (not Map.has_key?(icon, "theme") or icon["theme"] in ["dark", "light"])
  rescue
    _ -> false
  end

  defp valid_icon?(_icon), do: false

  defp valid_uri?(value) do
    case URI.new(value) do
      {:ok, uri} ->
        is_binary(uri.scheme) and uri.scheme != "" and valid_percent_encoding?(value)

      _ ->
        false
    end
  end

  defp valid_percent_encoding?(<<>>), do: true

  defp valid_percent_encoding?(<<"%", high, low, rest::binary>>)
       when high in ?0..?9 or high in ?A..?F or high in ?a..?f do
    if low in ?0..?9 or low in ?A..?F or low in ?a..?f,
      do: valid_percent_encoding?(rest),
      else: false
  end

  defp valid_percent_encoding?(<<"%", _rest::binary>>), do: false
  defp valid_percent_encoding?(<<_byte, rest::binary>>), do: valid_percent_encoding?(rest)

  defp single(conn, header) do
    case get_req_header(conn, header) do
      [value] -> trim_ows(value)
      _ -> nil
    end
  end

  defp trim_ows(<<byte, rest::binary>>) when byte in [32, 9], do: trim_ows(rest)

  defp trim_ows(value) do
    size = byte_size(value)

    if size > 0 and :binary.last(value) in [32, 9] do
      trim_ows(binary_part(value, 0, size - 1))
    else
      value
    end
  end

  defp dispatch(conn, id, "server/discover", params, _opts) do
    if Map.keys(params) == ["_meta"] do
      {:ok,
       %{
         "resultType" => "complete",
         "supportedVersions" => [@revision],
         "capabilities" => %{"tools" => %{"listChanged" => false}},
         "ttlMs" => 0,
         "cacheScope" => "private"
       }}
    else
      {:rpc, conn, 200, -32602, "Invalid Params", id, nil}
    end
  end

  defp dispatch(conn, id, "tools/list", params, opts) do
    list_tools(conn, id, params, opts)
  end

  defp dispatch(conn, id, "tools/call", params, opts), do: call_tool(conn, id, params, opts)

  defp dispatch(conn, id, _method, _params, _opts),
    do: {:rpc, conn, 404, -32601, "Method not found", id, nil}

  defp list_tools(conn, id, params, opts) do
    cond do
      Map.keys(params) != ["_meta"] ->
        {:rpc, conn, 200, -32602, "Invalid Params", id, nil}

      not WarmProviderRuntime.snapshot(opts[:warm]).ready ->
        {:rpc, conn, 503, -31998, "Server unavailable", id, nil}

      true ->
        {:ok,
         %{
           "resultType" => "complete",
           "tools" => opts[:tools],
           "ttlMs" => 0,
           "cacheScope" => "private"
         }}
    end
  end

  defp call_tool(conn, id, params, opts) do
    with {:ok, name, arguments} <- call_params(params),
         :ok <- call_name_header(conn, name),
         {:ok, %{template: raw_template}} <- fetch_tool(opts[:tool_entries], name),
         :ok <- parameter_headers(conn, ServingTemplate.input_schema(raw_template), arguments),
         {:ok, template} <- WarmProviderRuntime.template(opts[:warm], name) do
      execute_sse(conn, id, name, arguments, template, opts)
    else
      :invalid_params -> {:rpc, conn, 200, -32602, "Invalid Params", id, nil}
      :header_mismatch -> {:rpc, conn, 400, -32020, "Header mismatch", id, nil}
      :unknown_tool -> {:rpc, conn, 200, -32602, "Invalid Params", id, nil}
      _ -> {:rpc, conn, 503, -31998, "Server unavailable", id, nil}
    end
  end

  defp call_params(params) do
    allowed = ["_meta", "arguments", "name"]

    if Enum.all?(Map.keys(params), &(&1 in allowed)) and is_binary(params["name"]) and
         byte_size(params["name"]) in 1..128 and
         (not Map.has_key?(params, "arguments") or is_map(params["arguments"])) do
      {:ok, params["name"], Map.get(params, "arguments", %{})}
    else
      :invalid_params
    end
  end

  defp call_name_header(conn, name) do
    case get_req_header(conn, "mcp-name") do
      [value] ->
        case MCPProtocol.decode_header(trim_ows(value)) do
          {:ok, ^name} -> :ok
          _ -> :header_mismatch
        end

      _ ->
        :header_mismatch
    end
  end

  defp fetch_tool(tools, name) do
    case Map.fetch(tools, name) do
      {:ok, tool} -> {:ok, tool}
      :error -> :unknown_tool
    end
  end

  defp parameter_headers(conn, schema, arguments) do
    with {:ok, parameters} <- MCPProtocol.header_parameters(schema),
         {:ok, expected} <- MCPProtocol.header_values(parameters, arguments),
         true <- exact_parameter_headers?(conn, expected) do
      :ok
    else
      _ -> :header_mismatch
    end
  end

  defp exact_parameter_headers?(conn, expected) do
    actual =
      Enum.filter(conn.req_headers, fn {name, _} -> String.starts_with?(name, "mcp-param-") end)

    length(actual) == length(expected) and
      Enum.all?(expected, fn {name, expected_value} ->
        values =
          for {actual_name, value} <- actual, actual_name == String.downcase(name), do: value

        case values do
          [value] ->
            with {:ok, decoded} <- MCPProtocol.decode_header(trim_ows(value)),
                 {:ok, expected_decoded} <- MCPProtocol.decode_header(expected_value) do
              decoded == expected_decoded
            else
              _ -> false
            end

          _ ->
            false
        end
      end)
  end

  defp execute_sse(conn, id, name, arguments, template, opts) do
    parent = self()
    started_at = DateTime.utc_now() |> DateTime.truncate(:millisecond)

    {owner, monitor} =
      spawn_monitor(fn ->
        request_monitor = Process.monitor(parent)
        reservation = ServingTemplate.reserve(template, arguments, opts[:run_admission])
        send(parent, {:reserved, self(), reservation})

        receive do
          {:activate, request} ->
            outcome =
              case reservation do
                {:ok, reserved} ->
                  activate_transport(
                    reserved,
                    id,
                    request,
                    parent,
                    name,
                    template,
                    started_at,
                    opts
                  )

                closed ->
                  closed = wire_outcome(id, template, closed)
                  request_monitor = monitor_request(request, self(), nil)
                  _ = publish_terminal(request, request_monitor, parent, closed)
                  send(request_monitor, :stop)
                  _ = audit_terminal(name, template, closed, started_at, opts)
                  closed
              end

            send(parent, {:done, self(), outcome})

          :close ->
            if match?({:ok, _}, reservation),
              do: reservation |> elem(1) |> ServingTemplate.close()

          {:DOWN, ^request_monitor, :process, ^parent, _reason} ->
            if match?({:ok, _}, reservation),
              do: reservation |> elem(1) |> ServingTemplate.cancel_external()
        end
      end)

    receive do
      {:reserved, ^owner, reservation} ->
        case precommit_outcome(reservation) do
          :reserved ->
            heartbeat_ms = Keyword.get(opts, :heartbeat_ms, @heartbeat_ms)
            commit_sse(conn, id, owner, monitor, reservation, heartbeat_ms)

          {:error, status, code, message} ->
            send(owner, :close)
            {:rpc, conn, status, code, message, id, nil}
        end
    after
      5_000 ->
        Process.exit(owner, :kill)
        {:rpc, conn, 503, -31998, "Server unavailable", id, nil}
    end
  end

  defp activate_transport(reserved, id, request, parent, name, template, started_at, opts) do
    request_monitor = monitor_request(request, self(), reserved)
    close = &wire_outcome(id, template, &1)
    publish = &publish_terminal(request, request_monitor, parent, &1)
    audit = &audit_terminal(name, template, &1, started_at, opts)

    try do
      case opts[:serving_hooks] do
        nil ->
          ServingTemplate.activate_transport(reserved, close, publish, audit)

        hooks ->
          ServingTemplate.activate(reserved, %{
            close_outcome: close,
            before_release: publish,
            before_release_audit: audit,
            after_activation: hooks[:after_activation]
          })
      end
    after
      send(request_monitor, :stop)
    end
  end

  defp monitor_request(request, worker, reserved) do
    spawn(fn ->
      reference = Process.monitor(request)

      receive do
        {:DOWN, ^reference, :process, ^request, _reason} ->
          if reserved, do: ServingTemplate.cancel_external(reserved)
          send(worker, {:disconnected, request})

        :stop ->
          Process.demonitor(reference, [:flush])
      end
    end)
  end

  defp precommit_outcome({:ok, _}), do: :reserved

  defp precommit_outcome(outcome) do
    case ServingOutcome.code(outcome) do
      :busy -> {:error, 429, -31999, "Server busy"}
      :invalid_input -> :reserved
      _ -> {:error, 503, -31998, "Server unavailable"}
    end
  end

  defp commit_sse(conn, id, owner, monitor, reservation, heartbeat_ms) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("mcp-protocol-version", @revision)
      |> send_chunked(200)

    case chunk(conn, ": accepted\n\n") do
      {:ok, conn} ->
        send(owner, {:activate, self()})
        await_outcome(conn, id, owner, monitor, reservation, heartbeat_ms)

      {:error, _} ->
        send(owner, :close)
        {:ok, {:stream, conn}}
    end
  end

  defp await_outcome(conn, id, owner, monitor, reservation, heartbeat_ms) do
    receive do
      {:publish, ^owner, outcome} ->
        {:ok, encoded} = encode_call_response(id, outcome)

        published? =
          match?({:ok, _}, chunk(conn, ["event: message\n", "data: ", encoded, "\n\n"]))

        send(owner, {:published, self(), published?})
        Process.demonitor(monitor, [:flush])
        {:ok, {:stream, conn}}

      {:done, ^owner, _outcome} ->
        Process.demonitor(monitor, [:flush])
        {:ok, {:stream, conn}}

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        {:ok, {:stream, conn}}
    after
      heartbeat_ms ->
        if connection_down?(conn) do
          disconnect(conn, owner, reservation)
        else
          case chunk(conn, ": heartbeat\n\n") do
            {:ok, conn} -> await_outcome(conn, id, owner, monitor, reservation, heartbeat_ms)
            {:error, _} -> disconnect(conn, owner, reservation)
          end
        end
    end
  end

  defp connection_down?(%{adapter: {Bandit.Adapter, %{transport: %{socket: socket}}}}) do
    case ThousandIsland.Socket.recv(socket, 0, 0) do
      {:error, reason} when reason in [:timeout, :eagain] -> false
      _ -> true
    end
  end

  defp connection_down?(_conn), do: false

  defp disconnect(conn, owner, reservation) do
    if match?({:ok, _}, reservation),
      do: reservation |> elem(1) |> ServingTemplate.cancel_external()

    send(owner, {:disconnected, self()})
    {:ok, {:stream, conn}}
  end

  defp publish_terminal(request, request_monitor, parent, outcome) do
    disconnected =
      receive do
        {:disconnected, ^request} -> true
      after
        0 -> false
      end

    Process.put(:ptc_gateway_disconnected, disconnected)

    if disconnected do
      :ok
    else
      send(parent, {:publish, self(), outcome})

      receive do
        {:published, ^request, true} -> :ok
        {:published, ^request, false} -> mark_disconnected()
        {:disconnected, ^request} -> mark_disconnected()
      after
        10_000 -> publication_timeout(request, request_monitor)
      end
    end
  end

  defp publication_timeout(request, request_monitor) do
    reference = Process.monitor(request)
    Process.exit(request, :kill)

    receive do
      {:DOWN, ^reference, :process, ^request, _reason} ->
        send(request_monitor, :stop)
        {:error, :publication_timeout}
    end
  end

  defp mark_disconnected do
    Process.put(:ptc_gateway_disconnected, true)
    :ok
  end

  defp audit_terminal(name, template, outcome, started_at, opts) do
    disconnected = Process.get(:ptc_gateway_disconnected, false)
    if hook = get_in(opts, [:serving_hooks, :before_audit]), do: hook.(outcome, disconnected)
    audit_result(opts[:audit], name, template, outcome, started_at, disconnected)
  end

  defp wire_outcome(id, template, outcome) do
    case encode_call_response(id, outcome) do
      {:ok, _encoded} ->
        outcome

      :too_large ->
        ServingTemplate.invalid_result(template, outcome)
    end
  end

  defp encode_call_response(id, outcome) do
    response = %{"jsonrpc" => "2.0", "id" => id, "result" => tool_result(outcome)}

    with {:ok, _} <- JSV.validate(response, @call_result_validator, cast: false),
         {:ok, encoded} when byte_size(encoded) <= @response_limit <-
           DeterministicJSON.encode(response) do
      {:ok, encoded}
    else
      _ -> :too_large
    end
  end

  defp tool_result(outcome) do
    metadata = ServingOutcome.metadata(outcome)

    case {ServingOutcome.code(outcome), ServingOutcome.value(outcome)} do
      {:success, {:ok, value}} ->
        {:ok, encoded} = DeterministicJSON.encode(value)

        %{
          "resultType" => "complete",
          "content" => [%{"type" => "text", "text" => encoded}],
          "structuredContent" => value,
          "isError" => false
        }

      _ ->
        text =
          if metadata.write_effects_possible,
            do: "Operation may have changed data; do not retry automatically",
            else: error_text(ServingOutcome.code(outcome))

        %{
          "resultType" => "complete",
          "content" => [%{"type" => "text", "text" => text}],
          "isError" => true
        }
    end
  end

  defp error_text(:invalid_input), do: "Tool input did not satisfy its contract"
  defp error_text(:cancelled), do: "Tool execution was cancelled"
  defp error_text(_), do: "Tool execution failed"

  defp audit_result(nil, _name, _template, _outcome, _started_at, _disconnected), do: :ok

  defp audit_result(audit, name, template, outcome, started_at, disconnected) do
    if ServingTemplate.effect(template) == :write and
         ServingOutcome.metadata(outcome).dispatched != false do
      metadata = ServingOutcome.metadata(outcome)

      PtcGateway.PrivateAudit.append(audit, %{
        "call_id" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
        "tool_name" => name,
        "started_at" => DateTime.to_iso8601(started_at),
        "ended_at" =>
          DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
        "outcome_code" => Atom.to_string(ServingOutcome.code(outcome)),
        "dispatch_state" => to_string(metadata.dispatched),
        "write_effects_may_have_occurred" => metadata.write_effects_possible,
        "disconnected" => disconnected,
        "cleanup_status" =>
          if(ServingOutcome.code(outcome) == :cleanup_failed, do: "uncertain", else: "complete")
      })
    else
      :ok
    end
  end

  defp encoded_size(value) do
    case DeterministicJSON.encode(value) do
      {:ok, body} -> byte_size(body)
      _ -> @response_limit + 1
    end
  end

  defp fixed_reply(conn, status, value, headers) do
    headers
    |> Enum.reduce(conn, fn {name, header_value}, acc ->
      put_resp_header(acc, name, header_value)
    end)
    |> json_reply(status, %{"error" => value})
  end

  defp rpc_error(conn, status, code, message, id, data) do
    error = %{"code" => code, "message" => message}
    error = if is_nil(data), do: error, else: Map.put(error, "data", data)
    response = %{"jsonrpc" => "2.0", "error" => error}
    response = if is_nil(id), do: response, else: Map.put(response, "id", id)
    json_reply(conn, status, response)
  end

  defp json_reply(conn, status, value) do
    case DeterministicJSON.encode(value) do
      {:ok, body} when byte_size(body) <= @response_limit ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(status, body)

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(
          500,
          ~s({"error":{"code":-32603,"message":"Internal error"},"jsonrpc":"2.0"})
        )
    end
  end
end
