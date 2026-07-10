defmodule PtcRunner.PreludeRolePolicy do
  @moduledoc """
  Parses and resolves the core kernel subset of prelude role policy.
  """

  alias __MODULE__.Grant

  defstruct default_role: nil, roles: %{}

  @role_pattern ~r/\A[A-Za-z0-9_.-]{1,64}\z/
  @prelude_id_pattern ~r/\A[A-Za-z][A-Za-z0-9_.-]*\z/
  @grant_fingerprint_schema_version 2

  @type t :: %__MODULE__{
          default_role: String.t() | nil,
          roles: %{String.t() => Grant.t()}
        }

  @spec from_map(map()) :: {:ok, t()} | {:error, map()}
  def from_map(map) when is_map(map) do
    with :ok <- validate_keys(map, ["default_role", "roles"], "prelude role policy"),
         {:ok, default_role} <- optional_role(field(map, "default_role")),
         {:ok, roles} <- parse_roles(field(map, "roles", %{})),
         :ok <- validate_default_role(default_role, roles) do
      {:ok, %__MODULE__{default_role: default_role, roles: roles}}
    end
  end

  def from_map(_map),
    do: {:error, error(:invalid_policy, "prelude role policy must be a map")}

  @spec resolve(t(), term()) :: {:ok, Grant.t() | nil} | {:error, map()}
  def resolve(%__MODULE__{roles: roles}, role_arg) when map_size(roles) == 0 do
    case role_arg do
      nil ->
        {:ok, nil}

      _ ->
        {:error, error(:role_policy_required, "role requires a configured prelude role policy")}
    end
  end

  def resolve(%__MODULE__{} = policy, role_arg) do
    with {:ok, role} <- requested_role(role_arg, policy.default_role) do
      fetch_role(policy, role)
    end
  end

  def resolve(policy, role_arg) when is_map(policy) do
    with {:ok, parsed} <- from_map(policy), do: resolve(parsed, role_arg)
  end

  def resolve(_policy, _role_arg),
    do: {:error, error(:invalid_policy, "prelude role policy must be a map")}

  @spec selected_refs(Grant.t(), keyword()) :: {:ok, [term()]} | {:error, map()}
  def selected_refs(%Grant{} = grant, opts) when is_list(opts) do
    selected_refs(grant, opts, :loop)
  end

  @spec selected_refs(Grant.t(), keyword(), :loop | :inner) :: {:ok, [term()]} | {:error, map()}
  def selected_refs(%Grant{} = grant, opts, surface)
      when is_list(opts) and surface in [:loop, :inner] do
    {option, allowed, defaults, label} = surface_grant(grant, surface)
    requested? = Keyword.has_key?(opts, option)
    refs = if requested?, do: Keyword.get(opts, option), else: defaults

    with {:ok, refs} <- request_refs(refs, requested?, label),
         :ok <- preludes_allowed(grant, refs, allowed, label) do
      {:ok, refs}
    end
  end

  @spec preludes_allowed(Grant.t(), [term()]) :: :ok | {:error, map()}
  def preludes_allowed(%Grant{role: role, preludes: allowed}, refs) when is_list(refs) do
    preludes_allowed(%Grant{role: role}, refs, allowed, "preludes")
  end

  defp preludes_allowed(%Grant{role: role}, refs, allowed, label) when is_list(refs) do
    refs
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {ref, index}, :ok ->
      case parse_request_ref(ref) do
        {:ok, parsed} ->
          if ref_allowed?(allowed, parsed) do
            {:cont, :ok}
          else
            {:halt,
             {:error,
              error(
                :prelude_not_granted,
                "#{label}[#{index}] is not granted for role #{inspect(role)}",
                %{index: index, ref: public_ref(parsed)}
              )}}
          end

        {:error, %{message: message}} ->
          {:halt,
           {:error,
            error(:invalid_prelude_ref, "#{label}[#{index}] #{message}", %{
              index: index,
              value: inspect(ref, limit: 5)
            })}}
      end
    end)
  end

  defp parse_roles(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {role, grant_map}, {:ok, acc} ->
      with {:ok, role} <- required_role(role),
           {:ok, grant} <- parse_grant(role, grant_map) do
        {:cont, {:ok, Map.put(acc, role, grant)}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp parse_roles(_value), do: {:error, error(:invalid_policy, "roles must be a map")}

  defp parse_grant(role, map) when is_map(map) do
    with :ok <-
           validate_keys(
             map,
             [
               "prelude_store_access",
               "preludes",
               "default_preludes",
               "inner_preludes",
               "default_inner_preludes"
             ],
             "roles.#{role}"
           ),
         {:ok, access} <- prelude_store_access(field(map, "prelude_store_access", "none"), role),
         {:ok, preludes} <- prelude_grants(field(map, "preludes", []), role),
         {:ok, default_preludes} <- default_preludes(field(map, "default_preludes", []), role),
         :ok <- defaults_allowed(role, preludes, default_preludes, "preludes", "default_preludes"),
         {:ok, inner_preludes} <- prelude_grants(field(map, "inner_preludes", []), role),
         {:ok, default_inner_preludes} <-
           default_preludes(field(map, "default_inner_preludes", []), role),
         :ok <-
           defaults_allowed(
             role,
             inner_preludes,
             default_inner_preludes,
             "inner_preludes",
             "default_inner_preludes"
           ) do
      grant = %Grant{
        role: role,
        prelude_store_access: access,
        preludes: preludes,
        default_preludes: default_preludes,
        inner_preludes: inner_preludes,
        default_inner_preludes: default_inner_preludes
      }

      {:ok, %{grant | fingerprint: fingerprint(grant)}}
    end
  end

  defp parse_grant(role, _map),
    do: {:error, error(:invalid_policy, "roles.#{role} must be a map")}

  defp prelude_store_access(value, _role) when value in ["none", :none], do: {:ok, :none}
  defp prelude_store_access(value, _role) when value in ["read", :read], do: {:ok, :read}
  defp prelude_store_access(value, _role) when value in ["write", :write], do: {:ok, :write}

  defp prelude_store_access(value, role) do
    {:error,
     error(
       :invalid_policy,
       "roles.#{role}.prelude_store_access must be none, read, or write, got: #{inspect(value)}"
     )}
  end

  defp prelude_grants(values, role) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {value, index}, {:ok, acc} ->
      case parse_exact_ref(value) do
        {:ok, ref} ->
          key = {ref.id, ref.version}

          if Map.has_key?(acc, key) do
            {:halt,
             {:error,
              error(
                :invalid_policy,
                "roles.#{role}.preludes[#{index}] duplicates #{ref.id}@#{ref.version}"
              )}}
          else
            {:cont, {:ok, Map.put(acc, key, ref)}}
          end

        {:error, %{message: message}} ->
          {:halt, {:error, error(:invalid_policy, "roles.#{role}.preludes[#{index}] #{message}")}}
      end
    end)
  end

  defp prelude_grants(_values, role),
    do: {:error, error(:invalid_policy, "roles.#{role}.preludes must be a list")}

  defp default_preludes(values, role) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case parse_request_ref(value) do
        {:ok, _ref} ->
          {:cont, {:ok, [value | acc]}}

        {:error, %{message: message}} ->
          {:halt,
           {:error, error(:invalid_policy, "roles.#{role}.default_preludes[#{index}] #{message}")}}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      {:error, _} = error -> error
    end
  end

  defp default_preludes(_values, role),
    do: {:error, error(:invalid_policy, "roles.#{role}.default_preludes must be a list")}

  defp defaults_allowed(role, allowed, default_refs, allowed_label, default_label) do
    case preludes_allowed(%Grant{role: role}, default_refs, allowed, allowed_label) do
      :ok ->
        :ok

      {:error, %{details: %{index: index}}} ->
        {:error,
         error(
           :invalid_policy,
           "roles.#{role}.#{default_label}[#{index}] is not granted by roles.#{role}.#{allowed_label}"
         )}
    end
  end

  defp request_refs(refs, _requested?, _label) when is_list(refs), do: {:ok, refs}

  defp request_refs(refs, _requested?, label),
    do: {:error, error(:invalid_prelude_ref, "#{label} must be a list, got: #{inspect(refs)}")}

  defp surface_grant(grant, :loop),
    do: {:preludes, grant.preludes, grant.default_preludes, "preludes"}

  defp surface_grant(grant, :inner),
    do: {:inner_preludes, grant.inner_preludes, grant.default_inner_preludes, "inner_preludes"}

  defp parse_exact_ref(value) when is_binary(value), do: parse_ref_string(value)

  defp parse_exact_ref(value) when is_map(value) do
    with :ok <- validate_keys(value, ["id", "version", "checksum"], "prelude grant"),
         {:ok, id} <- non_empty_string(field(value, "id")),
         {:ok, version} <- positive_int(field(value, "version")),
         {:ok, checksum} <- optional_non_empty_string(field(value, "checksum")) do
      valid_prelude_id(id, %{id: id, version: version, checksum: checksum})
    end
  end

  defp parse_exact_ref(_value),
    do: {:error, error(:invalid_prelude_ref, "must be an exact prelude ref")}

  defp parse_request_ref(value) when is_binary(value), do: parse_ref_string(value)
  defp parse_request_ref(value) when is_map(value), do: parse_exact_ref(value)

  defp parse_request_ref(_value),
    do: {:error, error(:invalid_prelude_ref, "must be an exact prelude ref")}

  defp parse_ref_string(value) do
    case String.split(value, "@", parts: 2) do
      [id, version] ->
        with true <- valid_prelude_id?(id),
             {version, ""} when version > 0 <- Integer.parse(version) do
          {:ok, %{id: id, version: version, checksum: nil}}
        else
          _ -> {:error, error(:invalid_prelude_ref, "must be a valid id@version ref")}
        end

      _other ->
        {:error, error(:invalid_prelude_ref, "must be an exact id@version ref")}
    end
  end

  defp ref_allowed?(allowed, request) do
    case Map.get(allowed, {request.id, request.version}) do
      nil -> false
      %{checksum: nil} -> true
      %{checksum: checksum} -> request.checksum == checksum
    end
  end

  defp public_ref(%{id: id, version: version, checksum: checksum}) do
    %{id: id, version: version, checksum: checksum}
  end

  defp requested_role(nil, default) when is_binary(default), do: {:ok, default}

  defp requested_role(nil, nil),
    do: {:error, error(:role_required, "role is required when prelude roles are configured")}

  defp requested_role(role, _default), do: required_role(role)

  defp fetch_role(%__MODULE__{roles: roles}, role) do
    case Map.fetch(roles, role) do
      {:ok, grant} -> {:ok, grant}
      :error -> {:error, error(:unknown_role, "unknown prelude role #{inspect(role)}")}
    end
  end

  defp validate_default_role(nil, _roles), do: :ok

  defp validate_default_role(role, roles) do
    if Map.has_key?(roles, role) do
      :ok
    else
      {:error, error(:invalid_policy, "default_role #{inspect(role)} is not defined in roles")}
    end
  end

  defp optional_role(nil), do: {:ok, nil}
  defp optional_role(role), do: required_role(role)

  defp required_role(role) when is_binary(role) and role != "" do
    if Regex.match?(@role_pattern, role),
      do: {:ok, role},
      else: {:error, error(:invalid_role, "invalid role #{inspect(role)}")}
  end

  defp required_role(role),
    do: {:error, error(:invalid_role, "role must be a non-empty string, got: #{inspect(role)}")}

  defp validate_keys(map, allowed, label) do
    allowed = MapSet.new(allowed)

    unknown =
      map
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&MapSet.member?(allowed, &1))

    case unknown do
      [] ->
        :ok

      keys ->
        names = keys |> Enum.sort() |> Enum.map_join(", ", &inspect/1)
        {:error, error(:unknown_policy_key, "#{label} contains unknown key(s): #{names}")}
    end
  end

  defp valid_prelude_id?(id) when is_binary(id), do: Regex.match?(@prelude_id_pattern, id)

  defp valid_prelude_id(id, ref) do
    if valid_prelude_id?(id),
      do: {:ok, ref},
      else: {:error, error(:invalid_prelude_ref, "id must be a valid prelude id")}
  end

  defp non_empty_string(value) when is_binary(value) and value != "", do: {:ok, value}

  defp non_empty_string(value),
    do:
      {:error, error(:invalid_prelude_ref, "must be a non-empty string, got: #{inspect(value)}")}

  defp optional_non_empty_string(nil), do: {:ok, nil}
  defp optional_non_empty_string(value) when is_binary(value) and value != "", do: {:ok, value}

  defp optional_non_empty_string(_value),
    do: {:error, error(:invalid_prelude_ref, "checksum must be a non-empty string")}

  defp positive_int(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_int(value),
    do:
      {:error,
       error(:invalid_prelude_ref, "version must be a positive integer, got: #{inspect(value)}")}

  defp fingerprint(%Grant{} = grant) do
    data = %{
      "schema_version" => @grant_fingerprint_schema_version,
      "default_preludes" => ref_fingerprint(grant.default_preludes),
      "default_inner_preludes" => ref_fingerprint(grant.default_inner_preludes),
      "inner_preludes" => prelude_fingerprint(grant.inner_preludes),
      "prelude_store_access" => Atom.to_string(grant.prelude_store_access),
      "preludes" => prelude_fingerprint(grant.preludes),
      "role" => grant.role
    }

    data
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("sha256:" <> &1))
  end

  defp ref_fingerprint(refs) do
    Enum.map(refs, fn ref ->
      {:ok, parsed} = parse_request_ref(ref)
      %{"id" => parsed.id, "version" => parsed.version, "checksum" => parsed.checksum}
    end)
  end

  defp prelude_fingerprint(refs) do
    refs
    |> Map.values()
    |> Enum.map(fn ref ->
      %{"id" => ref.id, "version" => ref.version, "checksum" => ref.checksum}
    end)
    |> Enum.sort_by(&{&1["id"], &1["version"], &1["checksum"] || ""})
  end

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.map(fn {key, inner} -> {to_string(key), inner} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_intersperse(",", fn {key, inner} ->
      [Jason.encode!(key), ":", canonical_json(inner)]
    end)
    |> then(&["{", &1, "}"])
    |> IO.iodata_to_binary()
  end

  defp canonical_json(value) when is_list(value) do
    value
    |> Enum.map_intersperse(",", &canonical_json/1)
    |> then(&["[", &1, "]"])
    |> IO.iodata_to_binary()
  end

  defp canonical_json(value), do: Jason.encode!(value)

  defp field(map, key, default \\ nil) when is_map(map) and is_binary(key) do
    Map.get(map, key, Map.get(map, String.to_existing_atom(key), default))
  rescue
    ArgumentError -> Map.get(map, key, default)
  end

  defp error(reason, message, details \\ %{}) do
    %{reason: reason, message: message, details: details}
  end
end
