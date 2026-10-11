defmodule PtcRunner.Kernel.HostInstallation.Credentials do
  @moduledoc false

  alias PtcRunner.Kernel.ConfinedFile
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.MCPOAuth.Authority

  @max_credential_bytes 65_536

  @doc """
  Returns the host credential names one installation resolves at runtime.

  An MCP transport binds credentials through `env` or `auth` exactly as an LLM
  installation binds one through `credential`, so anything that reasons about
  what an installation needs must ask this rather than the source tag. An
  OAuth-authorized transport resolves no host credential.
  """
  @spec installation_credential_names(map()) :: [binary()]
  def installation_credential_names(%{source: :mcp, transport: transport}) do
    case transport do
      %{oauth: %Authority{}} -> []
      _other -> credential_names(transport)
    end
  end

  def installation_credential_names(%{source: source, credential: credential})
      when source in [:llm, :decision] and is_binary(credential), do: [credential]

  def installation_credential_names(_installation), do: []

  def installation_credential(%{credential: nil}, _credentials), do: {:ok, nil}

  def installation_credential(%{credential: name}, credentials),
    do: Map.fetch(credentials, name)

  def credential_names(%{type: :stdio, env: env}),
    do: env |> Map.values() |> Enum.uniq() |> Enum.sort()

  def credential_names(%{type: :streamable_http, auth: auth}),
    do: auth |> Enum.map(& &1.binding) |> Enum.uniq() |> Enum.sort()

  @doc false
  @spec resolve_runtime_credentials(HostConfig.t(), [binary()]) ::
          {:ok, %{binary() => binary()}} | {:error, :credential_unavailable}
  def resolve_runtime_credentials(%HostConfig{} = host, names) when is_list(names) do
    Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, resolved} ->
      with {:ok, declaration} <- Map.fetch(host.credentials, name),
           {:ok, value} <- resolve_credential(host.directory, declaration),
           true <- valid_secret?(value) do
        {:cont, {:ok, Map.put(resolved, name, value)}}
      else
        _reason -> {:halt, {:error, :credential_unavailable}}
      end
    end)
  end

  def resolve_runtime_credentials(_host, _names), do: {:error, :credential_unavailable}

  # Surrounding whitespace is never part of a secret, and every ordinary way of
  # putting one in a file adds it: `echo`, an editor save, `gh auth token >
  # file`. The host reference recommends `file:` for secrets, so the newline is
  # on the recommended path. All three sources trim, so the same token supplied
  # three ways is one value.
  defp resolve_credential(directory, declaration) do
    case read_credential(directory, declaration) do
      {:ok, value} when is_binary(value) -> {:ok, String.trim(value)}
      other -> other
    end
  end

  defp read_credential(_directory, %{source: :env, name: name}),
    do: System.fetch_env(name)

  defp read_credential(directory, %{source: :file, path: path}) do
    if Path.type(path) == :absolute do
      with {:ok, canonical} <- ConfinedFile.resolve_absolute(path),
           do:
             ConfinedFile.read(
               Path.dirname(canonical),
               Path.basename(canonical),
               @max_credential_bytes
             )
    else
      ConfinedFile.read(directory, path, @max_credential_bytes)
    end
  end

  defp read_credential(_directory, %{source: :literal, value: value}),
    do: {:ok, value}

  # Only NUL disqualifies a credential outright. The two sinks disagree about
  # the rest: an HTTP header value cannot hold CR or LF, while a child process
  # environment entry legitimately can — a PEM block or a JSON service-account
  # key delivered through `transport.env` is a whole credential with interior
  # newlines. `render_headers/2` owns the stricter rule, because it is the only
  # sink that needs it.
  def valid_secret?(value),
    do:
      is_binary(value) and byte_size(value) in 1..@max_credential_bytes and
        String.valid?(value) and not String.contains?(value, <<0>>)

  def render_environment(bindings, credentials) do
    Enum.reduce_while(bindings, {:ok, %{}}, fn {name, binding}, {:ok, environment} ->
      case Map.fetch(credentials, binding) do
        {:ok, value} ->
          {:cont, {:ok, Map.put(environment, name, value)}}

        :error ->
          {:halt, {:error, :credential_unavailable}}
      end
    end)
  end

  # A header value cannot hold CR or LF, so a credential carrying one cannot
  # authenticate this request. Reporting that as `:mcp_authentication_failed`
  # is what `PtcRunner.Kernel.AcquisitionReason` prescribes for a rejected
  # credential, and it is the same class the endpoint's own refusal produces.
  # Left as a bare `:credential_unavailable` it escaped `acquire/7` unclassified
  # and fell closed as an internal error, which told the reader the fault was
  # not theirs.
  def render_headers(auth, credentials) do
    Enum.reduce_while(auth, {:ok, []}, fn entry, {:ok, headers} ->
      with {:ok, secret} <- Map.fetch(credentials, entry.binding),
           false <- carriable_header_value?(secret) do
        header =
          case entry.scheme do
            :bearer -> {"Authorization", "Bearer " <> secret}
            :basic -> {"Authorization", "Basic " <> secret}
            :api_key -> {entry.header, secret}
          end

        {name, value} = header
        {:cont, {:ok, [{String.downcase(name), value} | headers]}}
      else
        true -> {:halt, {:error, :mcp_authentication_failed}}
        _reason -> {:halt, {:error, :credential_unavailable}}
      end
    end)
    |> case do
      {:ok, headers} -> {:ok, Enum.reverse(headers)}
      {:error, _reason} = error -> error
    end
  end

  defp carriable_header_value?(secret), do: String.contains?(secret, ["\r", "\n"])
end
