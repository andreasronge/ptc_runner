defmodule PtcRunnerMcp.Sessions.Policy do
  @moduledoc false

  alias __MODULE__.{Grant, OuterPolicy}
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Export
  alias PtcRunner.PreludeStore.Tools, as: PreludeStoreTools

  defstruct default_role: nil, outer_policy: %OuterPolicy{}, roles: %{}

  @role_pattern ~r/\A[A-Za-z0-9_.-]{1,64}\z/
  @prelude_id_pattern ~r/\A[A-Za-z][A-Za-z0-9_.-]*\z/
  @grant_fingerprint_schema_version 2
  # Dialyzer reports generated boolean branch code at module line 1; lifecycle
  # tests cover the denied-role/tool/prelude branches that trigger it.
  @dialyzer :no_match
  @read_prelude_store_tools ~w(
    prelude_store_list
    prelude_store_history
    prelude_store_read
    prelude_store_forms
    prelude_store_form_deps
    prelude_store_deps
    prelude_store_form
  )
  @type t :: %__MODULE__{}
  @type grant :: %Grant{}

  @spec unrestricted() :: t()
  def unrestricted, do: %__MODULE__{}

  @spec load_file(String.t()) :: {:ok, t()} | {:error, String.t()}
  def load_file(path) when is_binary(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, policy} <- from_map(decoded) do
      {:ok, policy}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, "invalid session roles JSON: #{Exception.message(error)}"}

      {:error, reason} when is_atom(reason) ->
        {:error, "could not read session roles file #{path}: #{reason}"}

      {:error, message} when is_binary(message) ->
        {:error, message}
    end
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(map) when is_map(map) do
    with :ok <- validate_keys(map, ["default_role", "outer_policy", "roles"], "session roles"),
         {:ok, default_role} <- optional_role(Map.get(map, "default_role")),
         {:ok, outer_policy} <- parse_outer_policy(Map.get(map, "outer_policy", %{})),
         {:ok, roles} <- parse_roles(Map.get(map, "roles", %{})),
         :ok <- validate_default_role(default_role, roles) do
      {:ok, %__MODULE__{default_role: default_role, outer_policy: outer_policy, roles: roles}}
    end
  end

  def from_map(_map), do: {:error, "session roles config must be a JSON object"}

  @spec resolve_grant(t(), term()) :: {:ok, grant() | nil} | {:error, String.t()}
  def resolve_grant(%__MODULE__{roles: roles}, role_arg) when map_size(roles) == 0 do
    case role_arg do
      nil -> {:ok, nil}
      _ -> {:error, "role requires --session-roles / PTC_RUNNER_MCP_SESSION_ROLES"}
    end
  end

  def resolve_grant(%__MODULE__{} = policy, role_arg) do
    case requested_role(role_arg, policy.default_role) do
      {:ok, role} -> fetch_role(policy, role)
      {:error, _message} = error -> error
    end
  end

  @spec mcp_tool_allowed?(t() | nil, String.t()) :: boolean()
  def mcp_tool_allowed?(%__MODULE__{outer_policy: %OuterPolicy{mcp_tools: :all}}, _name), do: true

  def mcp_tool_allowed?(%__MODULE__{outer_policy: %OuterPolicy{mcp_tools: tools}}, name)
      when is_binary(name) do
    MapSet.member?(tools, name)
  end

  def mcp_tool_allowed?(_policy, _name), do: true

  @spec mode_allowed?(grant() | nil, atom()) :: boolean()
  def mode_allowed?(nil, _mode), do: true
  def mode_allowed?(%Grant{modes: modes}, mode), do: MapSet.member?(modes, mode)

  @spec prelude_store_level(grant() | nil) :: :none | :read | :write
  def prelude_store_level(nil), do: :write
  def prelude_store_level(%Grant{prelude_store: level}), do: level

  @spec ptc_tool_allowed?(grant() | nil, String.t()) :: boolean()
  def ptc_tool_allowed?(nil, _name), do: true

  # Tool injection is the authority boundary. This filter can only remove tools
  # from a host-provided set; it never grants backing tools that were not already
  # injected by the session mode/prelude-store/evidence configuration.
  def ptc_tool_allowed?(%Grant{} = grant, name) when is_binary(name) do
    store_tool_allowed?(grant, name) or configured_ptc_tool_allowed?(grant, name)
  end

  def ptc_tool_allowed?(%Grant{} = grant, name), do: ptc_tool_allowed?(grant, to_string(name))

  defp configured_ptc_tool_allowed?(%Grant{ptc_tools: :all}, _name), do: true

  defp configured_ptc_tool_allowed?(%Grant{ptc_tools: tools}, name),
    do: MapSet.member?(tools, name)

  defp store_tool_allowed?(%Grant{prelude_store: :write}, name),
    do: name in PreludeStoreTools.reserved_names()

  defp store_tool_allowed?(%Grant{prelude_store: :read}, name),
    do: name in @read_prelude_store_tools

  defp store_tool_allowed?(%Grant{prelude_store: :none}, _name), do: false

  @spec credential_allowed?(grant() | nil, String.t()) :: boolean()
  def credential_allowed?(nil, _name), do: true
  def credential_allowed?(%Grant{credentials: :all}, _name), do: true

  def credential_allowed?(%Grant{credentials: credentials}, name) when is_binary(name) do
    MapSet.member?(credentials, name)
  end

  @spec credential_grants(grant() | nil) :: :all | MapSet.t()
  def credential_grants(nil), do: :all
  def credential_grants(%Grant{credentials: credentials}), do: credentials

  @spec upstream_tool_allowed?(grant() | nil, String.t()) :: boolean()
  def upstream_tool_allowed?(nil, _id), do: true
  def upstream_tool_allowed?(%Grant{upstream_tools: :all}, _id), do: true

  def upstream_tool_allowed?(%Grant{upstream_tools: upstream_tools}, id) when is_binary(id) do
    MapSet.member?(upstream_tools, id)
  end

  def upstream_tool_allowed?(%Grant{} = grant, server, tool)
      when is_binary(server) and is_binary(tool) do
    upstream_tool_allowed?(grant, "upstream:#{server}/#{tool}")
  end

  @spec upstream_tool_grants(grant() | nil) :: :all | MapSet.t()
  def upstream_tool_grants(nil), do: :all
  def upstream_tool_grants(%Grant{upstream_tools: upstream_tools}), do: upstream_tools

  @spec filter_ptc_tools(map() | keyword() | nil, grant() | nil) :: map() | keyword() | nil
  def filter_ptc_tools(base, nil), do: base

  def filter_ptc_tools(base, %Grant{} = grant) do
    base
    |> as_tool_map()
    |> Enum.filter(fn {name, _tool} -> eval_tool_allowed?(grant, to_string(name)) end)
    |> Map.new()
  end

  @spec filter_prelude(Prelude.t() | nil, grant() | nil) :: Prelude.t() | nil
  def filter_prelude(nil, _grant), do: nil
  def filter_prelude(%Prelude{} = prelude, nil), do: prelude

  def filter_prelude(%Prelude{exports: exports} = prelude, %Grant{} = grant) do
    allowed_exports = Enum.filter(exports, &prelude_export_allowed?(grant, &1))

    %{
      prelude
      | exports: allowed_exports,
        source_index: filtered_source_index(prelude, allowed_exports)
    }
  end

  @spec prelude_export_allowed?(grant() | nil, Export.t()) :: boolean()
  def prelude_export_allowed?(nil, %Export{}), do: true

  def prelude_export_allowed?(%Grant{} = grant, %Export{} = export) do
    upstream_requirements = export_upstream_requirements(export)

    Enum.all?(export_tool_requirements(export), &ptc_tool_allowed?(grant, &1)) and
      Enum.all?(upstream_requirements, &upstream_tool_allowed?(grant, &1)) and
      dynamic_upstream_export_allowed?(grant, export, upstream_requirements)
  end

  @spec preludes_allowed?(grant() | nil, [term()]) :: :ok | {:error, String.t()}
  def preludes_allowed?(nil, _refs), do: :ok
  def preludes_allowed?(%Grant{preludes: :all}, _refs), do: :ok

  def preludes_allowed?(%Grant{preludes: allowed}, refs) do
    refs
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {ref, index}, :ok ->
      if prelude_request_allowed?(allowed, ref) do
        {:cont, :ok}
      else
        {:halt, {:error, "preludes[#{index}] is not granted for this role"}}
      end
    end)
  end

  defp prelude_request_allowed?(allowed, ref) when is_binary(ref) do
    case parse_prelude_ref(ref, allow_bare?: false) do
      {:ok, request} -> prelude_ref_allowed?(allowed, request)
      {:error, _message} -> false
    end
  end

  defp prelude_request_allowed?(allowed, ref) when is_map(ref) do
    with {:ok, id} <- non_empty_string(Map.get(ref, "id") || Map.get(ref, :id)),
         {:ok, version} <- positive_int(Map.get(ref, "version") || Map.get(ref, :version)),
         {:ok, checksum} <-
           optional_non_empty_string(Map.get(ref, "checksum") || Map.get(ref, :checksum)) do
      prelude_ref_allowed?(allowed, %{id: id, version: version, checksum: checksum})
    else
      {:error, _message} -> false
    end
  end

  defp prelude_request_allowed?(_allowed, _ref), do: false

  defp prelude_ref_allowed?(allowed, request) do
    case Map.get(allowed, {request.id, request.version}) do
      nil -> false
      %{checksum: nil} -> true
      %{checksum: checksum} -> request.checksum == checksum
    end
  end

  defp export_tool_requirements(%Export{requires: requires, tool_refs: tool_refs}) do
    requires
    |> Enum.flat_map(fn
      "tool:" <> name when name != "" -> [name]
      _other -> []
    end)
    |> Kernel.++(Enum.reject(tool_refs, &(&1 == "call")))
    |> Enum.uniq()
  end

  defp eval_tool_allowed?(%Grant{} = grant, "call"), do: upstream_call_tool_allowed?(grant)
  defp eval_tool_allowed?(%Grant{} = grant, name), do: ptc_tool_allowed?(grant, name)

  defp upstream_call_tool_allowed?(%Grant{}), do: true

  defp export_upstream_requirements(%Export{requires: requires}) do
    Enum.flat_map(requires, fn
      "upstream:" <> rest = id ->
        case String.split(rest, "/", parts: 2) do
          [server, tool] when server != "" and tool != "" -> [id]
          _ -> []
        end

      _other ->
        []
    end)
  end

  defp dynamic_upstream_export_allowed?(%Grant{upstream_tools: :all}, %Export{}, _requirements),
    do: true

  defp dynamic_upstream_export_allowed?(_grant, %Export{tool_refs: tool_refs}, []) do
    "call" not in tool_refs
  end

  defp dynamic_upstream_export_allowed?(_grant, %Export{}, _requirements), do: true

  defp filtered_source_index(%Prelude{source_index: source_index} = prelude, allowed_exports)
       when is_map(source_index) do
    allowed_refs = source_refs_for_allowed_exports(prelude, allowed_exports)
    Map.take(source_index, MapSet.to_list(allowed_refs))
  end

  defp filtered_source_index(_prelude, _allowed_exports), do: %{}

  defp source_refs_for_allowed_exports(
         %Prelude{source_index: source_index, form_graph: form_graph},
         allowed_exports
       ) do
    allowed_export_refs = MapSet.new(allowed_exports, & &1.ref)

    allowed_exports
    |> Enum.reduce(allowed_export_refs, fn export, acc ->
      source_reachable_refs(form_graph, source_index, allowed_export_refs, export.namespace, [
        export.symbol
      ])
      |> MapSet.union(acc)
    end)
  end

  defp source_reachable_refs(form_graph, source_index, allowed_export_refs, namespace, symbols) do
    graph = Map.get(form_graph || %{}, namespace, %{})

    symbols
    |> List.wrap()
    |> Enum.reduce({MapSet.new(), %{}}, fn symbol, {refs, seen} ->
      collect_source_ref(graph, source_index, allowed_export_refs, namespace, symbol, refs, seen)
    end)
    |> elem(0)
  end

  defp collect_source_ref(graph, source_index, allowed_export_refs, namespace, symbol, refs, seen) do
    case seen do
      %{^symbol => true} ->
        {refs, seen}

      _other ->
        seen = Map.put(seen, symbol, true)
        ref = "#{namespace}/#{symbol}"

        case Map.fetch(graph, symbol) do
          {:ok, %{visibility: :private, calls: calls}} ->
            refs = put_existing_source_ref(source_index, ref, refs)

            collect_source_refs(
              graph,
              source_index,
              allowed_export_refs,
              namespace,
              calls,
              refs,
              seen
            )

          {:ok, %{visibility: :public, calls: calls}} ->
            collect_source_refs(
              graph,
              source_index,
              allowed_export_refs,
              namespace,
              calls,
              refs,
              seen
            )

          _other ->
            {refs, seen}
        end
    end
  end

  defp put_existing_source_ref(source_index, ref, refs) do
    case Map.fetch(source_index, ref) do
      {:ok, _source} -> MapSet.put(refs, ref)
      :error -> refs
    end
  end

  defp collect_source_refs(graph, source_index, allowed_export_refs, namespace, calls, refs, seen) do
    Enum.reduce(calls, {refs, seen}, fn call, {refs, seen} ->
      collect_source_ref(graph, source_index, allowed_export_refs, namespace, call, refs, seen)
    end)
  end

  defp parse_outer_policy(value) when is_map(value) do
    with :ok <- validate_keys(value, ["mcp_tools"], "outer_policy"),
         {:ok, mcp_tools} <-
           string_set(Map.get(value, "mcp_tools", :all), "outer_policy.mcp_tools") do
      {:ok, %OuterPolicy{mcp_tools: mcp_tools}}
    end
  end

  defp parse_outer_policy(_value), do: {:error, "outer_policy must be an object"}

  defp parse_roles(value) when is_map(value) and map_size(value) > 0 do
    Enum.reduce_while(value, {:ok, %{}}, fn {role, grant_map}, {:ok, acc} ->
      with {:ok, role} <- required_role(role),
           {:ok, grant} <- parse_grant(role, grant_map) do
        {:cont, {:ok, Map.put(acc, role, grant)}}
      else
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp parse_roles(value) when is_map(value), do: {:ok, %{}}
  defp parse_roles(_value), do: {:error, "roles must be an object"}

  defp parse_grant(role, map) when is_map(map) do
    with :ok <-
           validate_keys(
             map,
             ["ptc_tools", "upstream_tools", "credentials", "prelude_store", "preludes", "modes"],
             "roles.#{role}"
           ),
         {:ok, ptc_tools} <-
           string_set(Map.get(map, "ptc_tools", :all), "roles.#{role}.ptc_tools"),
         {:ok, upstream_tools} <-
           upstream_tools(Map.get(map, "upstream_tools", []), role),
         {:ok, credentials} <-
           string_set(Map.get(map, "credentials", []), "roles.#{role}.credentials"),
         {:ok, prelude_store} <- prelude_store_level(Map.get(map, "prelude_store", "read"), role),
         {:ok, preludes} <- prelude_grants(Map.get(map, "preludes", :all), role),
         {:ok, modes} <- modes(Map.get(map, "modes", ["read_only"]), role) do
      grant = %Grant{
        role: role,
        ptc_tools: ptc_tools,
        upstream_tools: upstream_tools,
        credentials: credentials,
        prelude_store: prelude_store,
        preludes: preludes,
        modes: modes
      }

      {:ok, %{grant | fingerprint: fingerprint(grant)}}
    end
  end

  defp parse_grant(role, _map), do: {:error, "roles.#{role} must be an object"}

  defp requested_role(nil, default) when is_binary(default), do: {:ok, default}

  defp requested_role(nil, nil),
    do: {:error, "role is required when session roles are configured"}

  defp requested_role(role, _default), do: required_role(role)

  defp fetch_role(%__MODULE__{roles: roles}, role) do
    case Map.fetch(roles, role) do
      {:ok, grant} -> {:ok, grant}
      :error -> {:error, "unknown session role #{inspect(role)}"}
    end
  end

  defp validate_default_role(nil, _roles), do: :ok

  defp validate_default_role(role, roles) do
    if Map.has_key?(roles, role) do
      :ok
    else
      {:error, "default_role #{inspect(role)} is not defined in roles"}
    end
  end

  defp optional_role(nil), do: {:ok, nil}
  defp optional_role(role), do: required_role(role)

  defp required_role(role) when is_binary(role) and role != "" do
    if Regex.match?(@role_pattern, role),
      do: {:ok, role},
      else: {:error, "invalid role #{inspect(role)}"}
  end

  defp required_role(role), do: {:error, "role must be a non-empty string, got: #{inspect(role)}"}

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

  defp string_set(:all, _label), do: {:ok, :all}

  defp string_set(values, label) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, MapSet.new()}, fn
      value, {:ok, acc} when is_binary(value) and value != "" ->
        {:cont, {:ok, MapSet.put(acc, value)}}

      value, {:ok, _acc} ->
        {:halt, {:error, "#{label} entries must be non-empty strings, got: #{inspect(value)}"}}
    end)
  end

  defp string_set(_value, label), do: {:error, "#{label} must be an array of strings"}

  defp upstream_tools(:all, _role), do: {:ok, :all}
  defp upstream_tools("all", _role), do: {:ok, :all}

  defp upstream_tools(values, role) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn {value, index}, {:ok, acc} ->
      case parse_upstream_tool_grant(value) do
        {:ok, id} ->
          {:cont, {:ok, MapSet.put(acc, id)}}

        {:error, message} ->
          {:halt, {:error, "roles.#{role}.upstream_tools[#{index}] #{message}"}}
      end
    end)
  end

  defp upstream_tools(_value, role),
    do:
      {:error,
       "roles.#{role}.upstream_tools must be \"all\" or an array of upstream:<server>/<tool> strings"}

  defp parse_upstream_tool_grant("upstream:" <> rest = id) do
    case String.split(rest, "/", parts: 2) do
      [server, tool] when server != "" and tool != "" -> {:ok, id}
      _ -> {:error, "must use upstream:<server>/<tool>"}
    end
  end

  defp parse_upstream_tool_grant(value) when is_binary(value),
    do: {:error, "must use upstream:<server>/<tool>, got: #{inspect(value)}"}

  defp parse_upstream_tool_grant(value),
    do: {:error, "must be a string, got: #{inspect(value)}"}

  defp prelude_store_level(value, _role) when value in ["none", :none], do: {:ok, :none}
  defp prelude_store_level(value, _role) when value in ["read", :read], do: {:ok, :read}
  defp prelude_store_level(value, _role) when value in ["write", :write], do: {:ok, :write}

  defp prelude_store_level(value, role),
    do:
      {:error, "roles.#{role}.prelude_store must be none, read, or write, got: #{inspect(value)}"}

  defp modes(values, role) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, MapSet.new()}, fn
      value, {:ok, acc} when value in ["read_only", :read_only] ->
        {:cont, {:ok, MapSet.put(acc, :read_only)}}

      value, {:ok, acc} when value in ["write_capable", :write_capable] ->
        {:cont, {:ok, MapSet.put(acc, :write_capable)}}

      value, {:ok, _acc} ->
        {:halt,
         {:error,
          "roles.#{role}.modes entries must be read_only or write_capable, got: #{inspect(value)}"}}
    end)
    |> case do
      {:ok, modes} ->
        if MapSet.size(modes) > 0 do
          {:ok, modes}
        else
          {:error, "roles.#{role}.modes must not be empty"}
        end

      error ->
        error
    end
  end

  defp modes(_values, role), do: {:error, "roles.#{role}.modes must be an array"}

  defp prelude_grants(:all, _role), do: {:ok, :all}

  defp prelude_grants(values, role) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {value, index}, {:ok, acc} ->
      case parse_prelude_grant(value) do
        {:ok, ref} ->
          {:cont, {:ok, Map.put(acc, {ref.id, ref.version}, ref)}}

        {:error, message} ->
          {:halt, {:error, "roles.#{role}.preludes[#{index}] #{message}"}}
      end
    end)
  end

  defp prelude_grants(_values, role), do: {:error, "roles.#{role}.preludes must be an array"}

  defp parse_prelude_grant(value) when is_binary(value),
    do: parse_prelude_ref(value, allow_bare?: false)

  defp parse_prelude_grant(value) when is_map(value) do
    with :ok <- validate_keys(value, ["id", "version", "checksum"], "prelude grant"),
         {:ok, id} <- non_empty_string(Map.get(value, "id")),
         {:ok, version} <- positive_int(Map.get(value, "version")),
         {:ok, checksum} <- optional_non_empty_string(Map.get(value, "checksum")) do
      valid_prelude_id(id, %{id: id, version: version, checksum: checksum})
    end
  end

  defp parse_prelude_grant(_value), do: {:error, "must be an exact prelude ref"}

  defp parse_prelude_ref(value, _opts) when is_binary(value) do
    case String.split(value, "@", parts: 2) do
      [id, version] ->
        with true <- valid_prelude_id?(id),
             {version, ""} when version > 0 <- Integer.parse(version) do
          {:ok, %{id: id, version: version, checksum: nil}}
        else
          _ -> {:error, "must be a valid id@version ref"}
        end

      _other ->
        {:error, "must be an exact id@version ref"}
    end
  end

  defp valid_prelude_id?(id), do: is_binary(id) and Regex.match?(@prelude_id_pattern, id)

  defp valid_prelude_id(id, ref) do
    if valid_prelude_id?(id), do: {:ok, ref}, else: {:error, "id must be a valid prelude id"}
  end

  defp non_empty_string(value) when is_binary(value) and value != "", do: {:ok, value}
  defp non_empty_string(value), do: {:error, "must be a non-empty string, got: #{inspect(value)}"}

  defp optional_non_empty_string(nil), do: {:ok, nil}
  defp optional_non_empty_string(value) when is_binary(value) and value != "", do: {:ok, value}
  defp optional_non_empty_string(_value), do: {:error, "checksum must be a non-empty string"}

  defp positive_int(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_int(value),
    do: {:error, "version must be a positive integer, got: #{inspect(value)}"}

  defp fingerprint(%Grant{} = grant) do
    data = %{
      "schema_version" => @grant_fingerprint_schema_version,
      "modes" => grant.modes |> MapSet.to_list() |> Enum.map(&Atom.to_string/1) |> Enum.sort(),
      "prelude_store" => Atom.to_string(grant.prelude_store),
      "preludes" => prelude_fingerprint(grant.preludes),
      "ptc_tools" => set_fingerprint(grant.ptc_tools),
      "credentials" => set_fingerprint(grant.credentials),
      "role" => grant.role,
      "upstream_tools" => set_fingerprint(grant.upstream_tools)
    }

    data
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("sha256:" <> &1))
  end

  defp set_fingerprint(:all), do: "all"
  defp set_fingerprint(set), do: set |> MapSet.to_list() |> Enum.sort()

  defp prelude_fingerprint(:all), do: "all"

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

  defp as_tool_map(nil), do: %{}
  defp as_tool_map(base) when is_map(base), do: base
  defp as_tool_map(base) when is_list(base), do: Map.new(base)
  defp as_tool_map(base), do: Map.new(base)
end
