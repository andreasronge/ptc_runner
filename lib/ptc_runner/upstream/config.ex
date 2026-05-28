defmodule PtcRunner.Upstream.Config do
  @moduledoc false

  alias PtcRunner.Upstream.Credentials
  alias PtcRunner.Upstream.OpenAPI

  @header_token ~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/
  @static_header_denylist ~w(
    authorization
    proxy-authorization
    cookie
    set-cookie
    x-api-key
    mcp-protocol-version
    mcp-session-id
    user-agent
  )

  @spec load(keyword()) :: {:ok, map()} | {:error, atom(), String.t()}
  def load(opts) do
    with {:ok, raw} <- raw_config(opts),
         {:ok, credentials} <- Credentials.new(Map.get(raw, "credentials", %{})),
         {:ok, upstreams} <- parse_upstreams(Map.get(raw, "upstreams", %{}), credentials) do
      {:ok, %{credentials: credentials, upstreams: upstreams}}
    end
  end

  defp raw_config(opts) do
    cond do
      path = Keyword.get(opts, :config_path) ->
        with {:ok, body} <- File.read(path),
             {:ok, config} <- decode(body) do
          {:ok, absolutize_schema_files(config, Path.dirname(Path.expand(path)))}
        else
          {:error, reason} when is_atom(reason) ->
            {:error, :upstream_unavailable, "upstreams config: #{:file.format_error(reason)}"}

          err ->
            err
        end

      json = Keyword.get(opts, :config_json) ->
        decode(json)

      config = Keyword.get(opts, :config) ->
        {:ok, config}

      true ->
        {:ok, %{"upstreams" => %{}}}
    end
  end

  defp decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, config} when is_map(config) ->
        {:ok, config}

      {:ok, _} ->
        {:error, :upstream_unavailable, "upstreams config must be a JSON object"}

      {:error, reason} ->
        {:error, :upstream_unavailable, "upstreams config JSON decode failed: #{inspect(reason)}"}
    end
  end

  defp absolutize_schema_files(config, base_dir) do
    update_in(config, ["upstreams"], fn
      upstreams when is_map(upstreams) ->
        Map.new(upstreams, fn {name, entry} -> {name, absolutize_schema_file(entry, base_dir)} end)

      other ->
        other
    end)
  end

  defp absolutize_schema_file(%{"schema_file" => path} = entry, base_dir)
       when is_binary(path) do
    if Path.type(path) == :relative do
      %{entry | "schema_file" => Path.expand(path, base_dir)}
    else
      entry
    end
  end

  defp absolutize_schema_file(entry, _base_dir), do: entry

  defp parse_upstreams(upstreams, credentials) when is_map(upstreams) do
    Enum.reduce_while(upstreams, {:ok, []}, fn {name, entry}, {:ok, acc} ->
      case parse_upstream(name, entry, credentials) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      err -> err
    end
  end

  defp parse_upstreams(_other, _credentials),
    do: {:error, :upstream_unavailable, "upstreams must be an object"}

  defp parse_upstream(name, %{"transport" => old}, _credentials) when old in ["stdio", "http"] do
    {:error, :upstream_unavailable,
     "upstream #{name} uses old transport #{inspect(old)}; use mcp_stdio or mcp_http"}
  end

  defp parse_upstream(name, %{"transport" => "openapi"} = entry, credentials)
       when is_binary(name) do
    allow_insecure_http = bool(entry, "allow_insecure_http", false)
    allow_insecure_auth = bool(entry, "allow_insecure_auth", false)
    auth = auth_emitters!(entry, name)
    static_headers = static_headers!(entry, name)

    :ok = validate_auth_bindings!(name, auth, credentials)

    base_url =
      validated_url!(
        required_string!(entry, "base_url", name),
        name,
        "base_url",
        allow_insecure_http
      )

    schema_url =
      entry
      |> Map.get("schema_url")
      |> optional_validated_url!(name, "schema_url", allow_insecure_http)

    :ok = insecure_auth_gate!(name, allow_insecure_http, allow_insecure_auth, auth)
    :ok = check_auth_static_collision!(name, auth, static_headers)

    config = %{
      base_url: base_url,
      schema_file: Map.get(entry, "schema_file"),
      schema_url: schema_url,
      include_operations: list_of_strings!(entry, "include_operations", name),
      operation_overrides: Map.get(entry, "operation_overrides", %{}),
      auth: auth,
      static_headers: static_headers,
      request_timeout_ms: pos_int(entry, "request_timeout_ms", 30_000),
      connect_timeout_ms: pos_int(entry, "connect_timeout_ms", 5_000),
      max_response_bytes: pos_int(entry, "max_response_bytes", 2 * 1024 * 1024),
      schema_max_bytes: pos_int(entry, "schema_max_bytes", 2 * 1024 * 1024),
      credentials: credentials
    }

    if schema_source_count(config) != 1 do
      {:error, :upstream_unavailable,
       "upstream #{name} must set exactly one of schema_file or schema_url"}
    else
      case OpenAPI.load(config) do
        {:ok, compiled} ->
          {:ok,
           %{
             name: name,
             transport: :openapi,
             config: config,
             tools: compiled.tools,
             operations: compiled.operations,
             metadata: %{"description" => Map.get(entry, "description", "")}
           }}

        {:error, _, _} = err ->
          err
      end
    end
  rescue
    e in ArgumentError -> {:error, :upstream_unavailable, Exception.message(e)}
  end

  defp parse_upstream(name, %{"transport" => "mcp_stdio"} = entry, _credentials)
       when is_binary(name) do
    {:ok,
     %{
       name: name,
       transport: :mcp_stdio,
       config: %{
         command: required_string!(entry, "command", name),
         args: string_list!(entry, "args", name, []),
         env: string_map!(entry, "env", name, %{}),
         cd: optional_string!(entry, "cd", name),
         handshake_timeout_ms: pos_int(entry, "handshake_timeout_ms", 10_000),
         max_response_bytes: pos_int(entry, "max_response_bytes", 2 * 1024 * 1024)
       },
       tools: [],
       operations: %{},
       metadata: %{"description" => Map.get(entry, "description", "")}
     }}
  rescue
    e in ArgumentError -> {:error, :upstream_unavailable, Exception.message(e)}
  end

  defp parse_upstream(name, %{"transport" => "mcp_http"} = entry, credentials)
       when is_binary(name) do
    allow_insecure_http = bool(entry, "allow_insecure_http", false)
    allow_insecure_auth = bool(entry, "allow_insecure_auth", false)
    auth = auth_emitters!(entry, name)
    static_headers = static_headers!(entry, name)

    :ok = validate_auth_bindings!(name, auth, credentials)

    url =
      entry
      |> required_string!("url", name)
      |> validated_url!(name, "url", allow_insecure_http)

    :ok = insecure_auth_gate!(name, allow_insecure_http, allow_insecure_auth, auth)
    :ok = check_auth_static_collision!(name, auth, static_headers)

    {:ok,
     %{
       name: name,
       transport: :mcp_http,
       config: %{
         url: url,
         static_headers: static_headers,
         auth: auth,
         credentials: credentials,
         handshake_timeout_ms: pos_int(entry, "handshake_timeout_ms", 10_000),
         request_timeout_ms: pos_int(entry, "request_timeout_ms", 30_000),
         connect_timeout_ms: pos_int(entry, "connect_timeout_ms", 5_000),
         max_response_bytes: pos_int(entry, "max_response_bytes", 2 * 1024 * 1024)
       },
       tools: [],
       operations: %{},
       metadata: %{"description" => Map.get(entry, "description", "")}
     }}
  rescue
    e in ArgumentError -> {:error, :upstream_unavailable, Exception.message(e)}
  end

  defp parse_upstream(name, %{"transport" => transport}, _credentials) do
    {:error, :upstream_unavailable,
     "upstream #{name} has unsupported transport #{inspect(transport)}"}
  end

  defp parse_upstream(name, _entry, _credentials) do
    {:error, :upstream_unavailable, "upstream #{name} requires explicit transport"}
  end

  defp schema_source_count(%{schema_file: schema_file, schema_url: schema_url}) do
    [schema_file, schema_url]
    |> Enum.count(&(is_binary(&1) and &1 != ""))
  end

  defp required_string!(entry, key, name) do
    case Map.get(entry, key) do
      value when is_binary(value) and value != "" -> value
      _ -> raise ArgumentError, "upstream #{name} requires #{key}"
    end
  end

  defp list_of_strings!(entry, key, name) do
    case Map.get(entry, key) do
      values when is_list(values) and values != [] ->
        if Enum.all?(values, &is_binary/1) do
          values
        else
          raise ArgumentError, "upstream #{name} requires non-empty #{key}"
        end

      _ ->
        raise ArgumentError, "upstream #{name} requires non-empty #{key}"
    end
  end

  defp pos_int(entry, key, default) do
    case Map.get(entry, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp static_headers!(entry, name) do
    case Map.get(entry, "static_headers", %{}) do
      nil ->
        []

      headers when is_map(headers) ->
        Enum.reduce(headers, [], fn {key, value}, acc ->
          key = header_name!(key, name, "static_headers")
          value = header_value!(value, name, key)

          cond do
            String.downcase(key) in @static_header_denylist ->
              raise ArgumentError,
                    "upstream #{name} static_headers header #{inspect(key)} is reserved"

            Enum.any?(acc, fn {existing, _} -> existing == String.downcase(key) end) ->
              raise ArgumentError,
                    "upstream #{name} static_headers duplicate header #{inspect(key)}"

            true ->
              [{String.downcase(key), value} | acc]
          end
        end)
        |> Enum.reverse()

      _other ->
        raise ArgumentError, "upstream #{name} static_headers must be an object"
    end
  end

  defp auth_emitters!(entry, name) do
    case Map.get(entry, "auth", []) do
      nil ->
        []

      emitters when is_list(emitters) ->
        Enum.map(emitters, &auth_emitter!(&1, name))

      _other ->
        raise ArgumentError, "upstream #{name} auth must be a list"
    end
  end

  defp auth_emitter!(%{"scheme" => scheme, "binding" => binding} = emitter, _name)
       when scheme in ["bearer", "basic"] and is_binary(binding) and binding != "" do
    Map.take(emitter, ["scheme", "binding"])
  end

  defp auth_emitter!(%{"scheme" => scheme, "binding" => binding, "header" => header}, name)
       when scheme in ["custom_header", "api_key"] and is_binary(binding) and binding != "" do
    header = header_name!(header, name, "auth")

    if String.downcase(header) in @static_header_denylist do
      raise ArgumentError, "upstream #{name} auth header #{inspect(header)} is reserved"
    end

    %{"scheme" => scheme, "binding" => binding, "header" => header}
  end

  defp auth_emitter!(emitter, name),
    do: raise(ArgumentError, "upstream #{name} has invalid auth emitter #{inspect(emitter)}")

  defp validate_auth_bindings!(name, auth, credentials) do
    known = MapSet.new(Credentials.binding_names(credentials))

    Enum.each(auth, fn %{"binding" => binding} ->
      unless MapSet.member?(known, binding) do
        raise ArgumentError, "upstream #{name} references unknown credential binding #{binding}"
      end
    end)

    :ok
  end

  defp check_auth_static_collision!(name, auth, static_headers) do
    static_names = MapSet.new(static_headers, fn {key, _value} -> key end)

    Enum.each(auth, fn
      %{"header" => header} ->
        if MapSet.member?(static_names, String.downcase(header)) do
          raise ArgumentError,
                "upstream #{name} configures header #{inspect(header)} in both auth and static_headers"
        end

      _emitter ->
        :ok
    end)

    :ok
  end

  defp header_name!(key, name, field) when is_binary(key) and key != "" do
    if Regex.match?(@header_token, key) do
      key
    else
      raise ArgumentError, "upstream #{name} #{field} header #{inspect(key)} is invalid"
    end
  end

  defp header_name!(key, name, field),
    do: raise(ArgumentError, "upstream #{name} #{field} header #{inspect(key)} is invalid")

  defp header_value!(value, _name, _key) when is_binary(value), do: value

  defp header_value!(_value, name, key),
    do:
      raise(
        ArgumentError,
        "upstream #{name} static_headers #{inspect(key)} value must be a string"
      )

  defp optional_validated_url!(nil, _name, _field, _allow_insecure_http), do: nil

  defp optional_validated_url!(url, name, field, allow_insecure_http) when is_binary(url),
    do: validated_url!(url, name, field, allow_insecure_http)

  defp optional_validated_url!(_url, name, field, _allow_insecure_http),
    do: raise(ArgumentError, "upstream #{name} #{field} must be a string")

  defp validated_url!(url, name, field, allow_insecure_http) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        validate_url_scheme!(scheme, url, name, field, allow_insecure_http)
        url

      _other ->
        raise ArgumentError, "upstream #{name} has malformed #{field} #{inspect(url)}"
    end
  end

  defp validate_url_scheme!("https", _url, _name, _field, _allow_insecure_http), do: :ok
  defp validate_url_scheme!("http", _url, _name, _field, true), do: :ok

  defp validate_url_scheme!("http", url, name, field, false) do
    raise ArgumentError,
          "upstream #{name} #{field} #{inspect(url)} uses http:// without allow_insecure_http"
  end

  defp validate_url_scheme!(scheme, url, name, field, _allow_insecure_http) do
    raise ArgumentError,
          "upstream #{name} #{field} #{inspect(url)} has unsupported URL scheme #{inspect(scheme)}"
  end

  defp insecure_auth_gate!(name, true, false, [_ | _]) do
    raise ArgumentError,
          "upstream #{name} uses http:// with auth but allow_insecure_auth is not true"
  end

  defp insecure_auth_gate!(_name, _allow_insecure_http, _allow_insecure_auth, _auth), do: :ok

  defp bool(entry, key, default) do
    case Map.get(entry, key, default) do
      value when is_boolean(value) -> value
      _other -> default
    end
  end

  defp string_list!(entry, key, _name, default) do
    case Map.get(entry, key, default) do
      values when is_list(values) ->
        if Enum.all?(values, &is_binary/1),
          do: values,
          else: raise(ArgumentError, "#{key} must be a list of strings")

      _ ->
        raise ArgumentError, "#{key} must be a list of strings"
    end
  end

  defp string_map!(entry, key, _name, default) do
    case Map.get(entry, key, default) do
      values when is_map(values) -> Map.new(values, fn {k, v} -> {to_string(k), to_string(v)} end)
      _ -> raise ArgumentError, "#{key} must be an object"
    end
  end

  defp optional_string!(entry, key, _name) do
    case Map.get(entry, key) do
      nil -> nil
      value when is_binary(value) -> value
      _ -> raise ArgumentError, "#{key} must be a string"
    end
  end
end
