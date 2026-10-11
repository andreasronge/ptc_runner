defmodule PtcRunner.Kernel.HostConfig.Transport do
  @moduledoc false

  alias PtcRunner.Kernel.MCPOAuth.Authority

  @max_stdio_credential_environment 249
  @max_string_bytes 131_072
  @environment_name ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
  @header_name ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
  @reserved_environment ~w(HOME LC_ALL LOGNAME PATH SHELL TERM USER)
  @reserved_headers ~w(
    authorization
    connection
    content-length
    content-type
    host
    mcp-method
    mcp-name
    mcp-protocol-version
    proxy-authorization
    transfer-encoding
  )

  import PtcRunner.Kernel.HostConfig.Common

  def transport(%{"type" => "stdio"} = value, credentials),
    do: stdio_transport(value, credentials)

  def transport(%{"type" => "streamable_http"} = value, credentials),
    do: http_transport(value, credentials)

  def transport(_value, _credentials), do: {:error, :invalid_transport}

  defp stdio_transport(value, credentials) do
    allowed =
      ~w(type command cwd args env inherit_environment grace_ms stderr_bytes start_timeout_ms)

    with :ok <- exact_keys(value, allowed, ~w(type command)),
         command when is_binary(command) <- value["command"],
         true <- valid_string?(command, 4_096),
         cwd when is_binary(cwd) <- Map.get(value, "cwd", "."),
         true <- valid_path_string?(cwd),
         {:ok, args} <- string_list(Map.get(value, "args", []), 256),
         {:ok, env} <- environment_bindings(Map.get(value, "env", %{}), credentials),
         inherit when is_boolean(inherit) <-
           Map.get(value, "inherit_environment", true),
         grace_ms when is_integer(grace_ms) and grace_ms in 1..5_000 <-
           Map.get(value, "grace_ms", 250),
         stderr_bytes when is_integer(stderr_bytes) and stderr_bytes in 0..1_048_576 <-
           Map.get(value, "stderr_bytes", 65_536),
         start_timeout_ms
         when is_integer(start_timeout_ms) and start_timeout_ms in 1..60_000 <-
           Map.get(value, "start_timeout_ms", 5_000) do
      {:ok,
       %{
         type: :stdio,
         command: command,
         cwd: cwd,
         args: args,
         env: env,
         inherit_environment: inherit,
         grace_ms: grace_ms,
         stderr_bytes: stderr_bytes,
         start_timeout_ms: start_timeout_ms
       }}
    else
      _reason -> {:error, :invalid_transport}
    end
  end

  defp http_transport(value, credentials) do
    with :ok <-
           exact_keys(
             value,
             ~w(type endpoint allow_insecure_loopback auth oauth),
             ~w(type endpoint)
           ),
         endpoint when is_binary(endpoint) <- value["endpoint"],
         true <- valid_string?(endpoint, 4_096),
         insecure_loopback when is_boolean(insecure_loopback) <-
           Map.get(value, "allow_insecure_loopback", false),
         {:ok, auth} <- auth(Map.get(value, "auth", []), credentials),
         {:ok, oauth} <- optional_oauth(value, endpoint, credentials),
         true <- auth == [] or is_nil(oauth),
         :ok <- installed_endpoint(endpoint, insecure_loopback, auth, oauth) do
      {:ok,
       %{
         type: :streamable_http,
         endpoint: endpoint,
         allow_insecure_loopback: insecure_loopback,
         auth: auth,
         oauth: oauth
       }}
    else
      _reason -> {:error, :invalid_transport}
    end
  end

  # An explicit `"oauth": null` is a key the schema counts as present and
  # refuses, so reading it as absent would accept a document the mirror rejects.
  # A transport declares an authority or omits the key.
  defp optional_oauth(value, endpoint, credentials) do
    case Map.fetch(value, "oauth") do
      :error -> {:ok, nil}
      {:ok, nil} -> {:error, :invalid_oauth}
      {:ok, oauth} -> Authority.from_host(oauth, endpoint, MapSet.new(Map.keys(credentials)))
    end
  end

  defp environment_bindings(value, credentials)
       when is_map(value) and map_size(value) <= @max_stdio_credential_environment do
    Enum.reduce_while(value, {:ok, %{}}, fn {name, binding}, {:ok, normalized} ->
      result =
        with true <- is_binary(name) and name =~ @environment_name,
             false <- name in @reserved_environment,
             true <- is_map(binding),
             :ok <- exact_keys(binding, ~w(binding), ~w(binding)),
             credential when is_binary(credential) <- binding["binding"],
             true <- Map.has_key?(credentials, credential) do
          {:ok, Map.put(normalized, name, credential)}
        else
          _reason -> {:error, :invalid_environment_binding}
        end

      case result do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp environment_bindings(_value, _credentials),
    do: {:error, :invalid_environment_binding}

  defp auth(value, credentials) when is_list(value) and length(value) <= 8 do
    Enum.reduce_while(value, {:ok, []}, fn entry, {:ok, normalized} ->
      case auth_entry(entry, credentials) do
        {:ok, auth} -> {:cont, {:ok, [auth | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp auth(_value, _credentials), do: {:error, :invalid_auth}

  defp auth_entry(%{"scheme" => scheme, "binding" => binding} = value, credentials)
       when scheme in ["bearer", "basic"] do
    with :ok <- exact_keys(value, ~w(scheme binding), ~w(scheme binding)),
         true <- is_binary(binding) and Map.has_key?(credentials, binding) do
      {:ok, %{scheme: auth_scheme(scheme), binding: binding}}
    else
      _reason -> {:error, :invalid_auth}
    end
  end

  defp auth_entry(
         %{"scheme" => "api_key", "binding" => binding, "header" => header} = value,
         credentials
       ) do
    with :ok <- exact_keys(value, ~w(scheme binding header), ~w(scheme binding header)),
         true <- is_binary(binding) and Map.has_key?(credentials, binding),
         true <- valid_header?(header) do
      {:ok, %{scheme: :api_key, binding: binding, header: header}}
    else
      _reason -> {:error, :invalid_auth}
    end
  end

  defp auth_entry(_value, _credentials), do: {:error, :invalid_auth}

  defp auth_scheme("bearer"), do: :bearer
  defp auth_scheme("basic"), do: :basic

  defp string_list(value, max_items) when is_list(value) and length(value) <= max_items do
    if Enum.all?(value, &valid_string?(&1, @max_string_bytes)),
      do: {:ok, value},
      else: {:error, :invalid_string_list}
  end

  defp string_list(_value, _max_items), do: {:error, :invalid_string_list}

  defp valid_header?(value) do
    is_binary(value) and value =~ @header_name and
      String.downcase(value) not in @reserved_headers and
      not String.starts_with?(String.downcase(value), "mcp-")
  end
end
