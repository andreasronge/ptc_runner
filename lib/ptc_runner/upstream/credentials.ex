defmodule PtcRunner.Upstream.Credentials do
  @moduledoc false

  defstruct bindings: %{}, secrets: []

  @type t :: %__MODULE__{bindings: map(), secrets: [String.t()]}

  @spec new(map()) :: {:ok, t()} | {:error, atom(), String.t()}
  def new(config) when is_map(config) do
    Enum.reduce_while(config, {:ok, %{}, []}, fn {name, spec}, {:ok, bindings, secrets} ->
      case materialize_binding(name, spec) do
        {:ok, value, meta} ->
          {:cont, {:ok, Map.put(bindings, name, {value, meta}), [value | secrets]}}

        {:error, reason, detail} ->
          {:halt, {:error, reason, detail}}
      end
    end)
    |> case do
      {:ok, bindings, secrets} -> {:ok, %__MODULE__{bindings: bindings, secrets: secrets}}
      err -> err
    end
  end

  @spec headers(t(), [map()]) :: {:ok, [{String.t(), String.t()}]} | {:error, atom(), String.t()}
  def headers(%__MODULE__{} = credentials, emitters) when is_list(emitters) do
    Enum.reduce_while(emitters, {:ok, []}, fn emitter, {:ok, acc} ->
      with {:ok, binding} <- fetch_binding(credentials, emitter),
           {:ok, header} <- header_for(binding, emitter) do
        {:cont, {:ok, [header | acc]}}
      else
        {:error, reason, detail} -> {:halt, {:error, reason, detail}}
      end
    end)
    |> case do
      {:ok, headers} -> {:ok, Enum.reverse(headers)}
      err -> err
    end
  end

  @spec scrub(t(), term()) :: term()
  def scrub(%__MODULE__{secrets: secrets}, text) when is_binary(text) do
    Enum.reduce(secrets, text, fn
      secret, acc when is_binary(secret) and byte_size(secret) > 0 ->
        String.replace(acc, secret, "[REDACTED]")

      _secret, acc ->
        acc
    end)
  end

  def scrub(%__MODULE__{} = credentials, list) when is_list(list) do
    Enum.map(list, &scrub(credentials, &1))
  end

  def scrub(%__MODULE__{} = credentials, map) when is_map(map) do
    Map.new(map, fn {key, value} -> {scrub(credentials, key), scrub(credentials, value)} end)
  end

  def scrub(_credentials, term), do: term

  @spec binding_names(t()) :: [String.t()]
  def binding_names(%__MODULE__{bindings: bindings}) do
    Map.keys(bindings)
  end

  @doc false
  @spec redaction_secrets(t()) :: [String.t()]
  def redaction_secrets(%__MODULE__{secrets: secrets}) do
    Enum.filter(secrets, &(is_binary(&1) and byte_size(&1) > 0))
  end

  defp materialize_binding(name, %{"source" => "env", "var" => var} = spec)
       when is_binary(name) and is_binary(var) do
    case System.get_env(var) do
      value when is_binary(value) and value != "" ->
        {:ok, value, %{scheme_hint: Map.get(spec, "scheme_hint")}}

      _ ->
        {:error, :upstream_unavailable, "credential #{name} env #{var} is not set"}
    end
  end

  defp materialize_binding(name, %{"source" => "file", "path" => path} = spec)
       when is_binary(name) and is_binary(path) do
    case File.read(path) do
      {:ok, value} ->
        {:ok, String.trim_trailing(value), %{scheme_hint: Map.get(spec, "scheme_hint")}}

      {:error, reason} ->
        {:error, :upstream_unavailable, "credential #{name}: #{:file.format_error(reason)}"}
    end
  end

  defp materialize_binding(_name, %{"source" => "literal", "value" => value} = spec)
       when is_binary(value) do
    {:ok, value, %{scheme_hint: Map.get(spec, "scheme_hint")}}
  end

  defp materialize_binding(name, _spec),
    do: {:error, :upstream_unavailable, "invalid credential binding #{inspect(name)}"}

  defp fetch_binding(%__MODULE__{bindings: bindings}, %{"binding" => name})
       when is_binary(name) do
    case Map.fetch(bindings, name) do
      {:ok, binding} -> {:ok, binding}
      :error -> {:error, :upstream_unavailable, "unknown credential binding #{name}"}
    end
  end

  defp fetch_binding(_credentials, emitter),
    do: {:error, :upstream_unavailable, "invalid auth emitter #{inspect(emitter)}"}

  defp header_for({value, _meta}, %{"scheme" => "bearer"}),
    do: {:ok, {"authorization", "Bearer #{value}"}}

  defp header_for({value, _meta}, %{"scheme" => "basic"}) do
    with {:ok, user, pass} <- basic_parts(value) do
      {:ok, {"authorization", "Basic #{Base.encode64("#{user}:#{pass}")}"}}
    end
  end

  defp header_for({value, _meta}, %{"scheme" => "custom_header", "header" => header})
       when is_binary(header) do
    if valid_custom_header?(header) do
      {:ok, {header, value}}
    else
      {:error, :upstream_unavailable, "invalid custom auth header #{inspect(header)}"}
    end
  end

  defp header_for({value, _meta}, %{"scheme" => "api_key", "header" => header})
       when is_binary(header) do
    if valid_custom_header?(header) do
      {:ok, {header, value}}
    else
      {:error, :upstream_unavailable, "invalid api_key auth header #{inspect(header)}"}
    end
  end

  defp header_for(_binding, emitter),
    do: {:error, :upstream_unavailable, "unsupported auth emitter #{inspect(emitter)}"}

  defp basic_parts(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{"user" => user, "pass" => pass}} when is_binary(user) and is_binary(pass) ->
        {:ok, user, pass}

      {:ok, _other} ->
        {:error, :upstream_unavailable, "basic credential JSON must contain user and pass"}

      {:error, _} ->
        case String.split(value, ":", parts: 2) do
          [user, pass] when user != "" -> {:ok, user, pass}
          _ -> {:error, :upstream_unavailable, "basic credential must be user:pass"}
        end
    end
  end

  defp valid_custom_header?(header) do
    Regex.match?(~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/, header) and
      String.downcase(header) not in [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "mcp-protocol-version",
        "mcp-session-id",
        "user-agent"
      ]
  end
end
