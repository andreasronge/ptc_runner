defmodule PtcRunnerMcp.Http.RoleTokens do
  @moduledoc false

  alias PtcRunnerMcp.Http.{Auth, AuthClaims, Config}

  @role_pattern ~r/\A[A-Za-z0-9_.-]{1,64}\z/
  @role_pattern_text "[A-Za-z0-9_.-]{1,64}"
  @id_pattern @role_pattern
  @token_source_keys ["token_env", "token_file", "token_literal"]

  @type resolved :: %{
          by_hash: %{String.t() => AuthClaims.t()},
          redaction_secrets: [String.t()]
        }

  @spec load_file(String.t(), keyword()) :: {:ok, resolved()} | {:error, String.t()}
  def load_file(path, opts \\ []) when is_binary(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, resolved} <- from_map(decoded, Keyword.get(opts, :admin_token)) do
      {:ok, resolved}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, "invalid HTTP role tokens JSON: #{Exception.message(error)}"}

      {:error, reason} when is_atom(reason) ->
        {:error, "could not read HTTP role tokens file #{path}: #{reason}"}

      {:error, message} when is_binary(message) ->
        {:error, message}
    end
  end

  @spec from_map(map(), String.t() | nil) :: {:ok, resolved()} | {:error, String.t()}
  def from_map(%{"tokens" => tokens} = map, admin_token) when is_list(tokens) do
    with :ok <- validate_keys(map, ["tokens"], "HTTP role tokens") do
      parse_tokens(tokens, admin_token)
    end
  end

  def from_map(map, _admin_token) when is_map(map) do
    {:error, "HTTP role tokens config must contain a tokens array"}
  end

  def from_map(_value, _admin_token),
    do: {:error, "HTTP role tokens config must be a JSON object"}

  defp parse_tokens(tokens, admin_token) do
    tokens
    |> Enum.with_index()
    |> Enum.reduce_while(
      {:ok, %{by_hash: %{}, ids: MapSet.new(), redaction_secrets: []}},
      fn {entry, index}, {:ok, acc} ->
        case parse_token(entry, index, admin_token) do
          {:ok, hash, claims, secret} ->
            cond do
              Map.has_key?(acc.by_hash, hash) ->
                {:halt, {:error, "tokens[#{index}] duplicates another HTTP role token"}}

              MapSet.member?(acc.ids, claims.subject_id) ->
                {:halt, {:error, "tokens[#{index}].id duplicates another HTTP role token id"}}

              true ->
                {:cont,
                 {:ok,
                  %{
                    by_hash: Map.put(acc.by_hash, hash, claims),
                    ids: MapSet.put(acc.ids, claims.subject_id),
                    redaction_secrets: [secret | acc.redaction_secrets]
                  }}}
            end

          {:error, message} ->
            {:halt, {:error, message}}
        end
      end
    )
    |> case do
      {:ok, %{by_hash: by_hash}} when map_size(by_hash) == 0 ->
        {:error, "HTTP role tokens config must contain at least one token"}

      {:ok, resolved} ->
        {:ok, %{resolved | redaction_secrets: Enum.reverse(resolved.redaction_secrets)}}

      error ->
        error
    end
  end

  defp parse_token(entry, index, admin_token) when is_map(entry) do
    label = "tokens[#{index}]"

    with :ok <- validate_keys(entry, ["id", "roles" | @token_source_keys], label),
         {:ok, id} <- valid_id(Map.get(entry, "id"), "#{label}.id"),
         {:ok, roles} <- valid_roles(Map.get(entry, "roles"), "#{label}.roles"),
         {:ok, secret} <- token_secret(entry, label),
         :ok <- validate_token_size(secret, label),
         :ok <- validate_admin_distinct(secret, admin_token, label) do
      hash = Auth.token_hash(secret)

      claims = AuthClaims.new(id, String.slice(hash, 0, 16), roles)

      {:ok, hash, claims, secret}
    end
  end

  defp parse_token(_entry, index, _admin_token),
    do: {:error, "tokens[#{index}] must be an object"}

  defp valid_id(id, label) when is_binary(id) and id != "" do
    if Regex.match?(@id_pattern, id),
      do: {:ok, id},
      else: {:error, "#{label} must match #{@role_pattern_text}"}
  end

  defp valid_id(_id, label), do: {:error, "#{label} must be a non-empty string"}

  defp valid_roles(roles, label) when is_list(roles) and roles != [] do
    roles
    |> Enum.reduce_while({:ok, MapSet.new()}, fn
      role, {:ok, acc} when is_binary(role) and role != "" ->
        if Regex.match?(@role_pattern, role) do
          {:cont, {:ok, MapSet.put(acc, role)}}
        else
          {:halt, {:error, "#{label} entries must match #{@role_pattern_text}"}}
        end

      _role, {:ok, _acc} ->
        {:halt, {:error, "#{label} entries must be non-empty strings"}}
    end)
    |> case do
      {:ok, roles} -> {:ok, roles |> MapSet.to_list() |> Enum.sort()}
      error -> error
    end
  end

  defp valid_roles(_roles, label), do: {:error, "#{label} must be a non-empty array"}

  defp token_secret(entry, label) do
    present = Enum.filter(@token_source_keys, &present_string?(Map.get(entry, &1)))

    case present do
      [key] -> read_token_source(key, Map.fetch!(entry, key), label)
      [] -> {:error, "#{label} must supply exactly one token source"}
      _many -> {:error, "#{label} must supply exactly one token source"}
    end
  end

  defp read_token_source("token_env", env, label) do
    case System.get_env(env) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, "#{label}.token_env did not resolve to a non-empty environment value"}
    end
  end

  defp read_token_source("token_file", path, label) do
    case File.read(path) do
      {:ok, value} ->
        value = String.trim_trailing(value)

        if value == "" do
          {:error, "#{label}.token_file contained an empty token"}
        else
          {:ok, value}
        end

      {:error, reason} ->
        {:error, "#{label}.token_file could not be read: #{reason}"}
    end
  end

  defp read_token_source("token_literal", value, _label), do: {:ok, value}

  defp present_string?(value), do: is_binary(value) and value != ""

  defp validate_token_size(secret, label) do
    if byte_size(secret) >= Config.token_min_bytes() do
      :ok
    else
      {:error, "#{label} token must be at least #{Config.token_min_bytes()} characters"}
    end
  end

  defp validate_admin_distinct(_secret, nil, _label), do: :ok

  defp validate_admin_distinct(secret, admin_token, label) do
    if Plug.Crypto.secure_compare(secret, admin_token) do
      {:error, "#{label} token must be different from HTTP admin token"}
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp validate_keys(map, allowed, label) do
    allowed = MapSet.new(allowed)

    case Enum.reject(Map.keys(map), &MapSet.member?(allowed, &1)) do
      [] ->
        :ok

      unknown ->
        names = unknown |> Enum.sort() |> Enum.map_join(", ", &inspect/1)
        {:error, "#{label} contains unknown key(s): #{names}"}
    end
  end
end
