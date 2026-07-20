defmodule PtcRunner.Lisp.Java.Surface do
  @moduledoc """
  Compile-time authority for the bounded PTC-Lisp Java compatibility surface.

  The surface is data, not reflection. `priv/java_interop.exs` owns admitted
  classes and references, JVM descriptors, temporary legacy Env routes, audit
  targets, and documentation projections. The separately owned
  `priv/java_interop_phase0_attestations.exs` baseline prevents coordinated
  manifest edits from silently weakening descriptor or divergence coverage.
  During the Phase-0 migration every overload still routes to a binding in the
  compile-independent builtin catalog; runtime parity tests ensure those
  bindings match `Env.initial/0`. Later phases replace the routes
  family-by-family with closed Java dispatch handlers.
  """

  alias PtcRunner.Lisp.BuiltinNames
  alias PtcRunner.Lisp.Java.Surface.Validator

  @manifest_path "priv/java_interop.exs"
  @external_resource @manifest_path
  @manifest Code.eval_file(@manifest_path) |> elem(0)
  @legacy_bindings BuiltinNames.env_binding_kinds()
  @phase0_attestations BuiltinNames.java_phase0_attestations()
  :ok = Validator.validate!(@manifest, @legacy_bindings, @phase0_attestations)

  @classes @manifest.classes
  @references @manifest.references
  @overloads @manifest.overloads
  @namespaces @manifest.namespaces
  @audit_specs @manifest.audit_specs
  @audits @manifest.audits
  @function_entries @manifest.function_entries
  @interop_entries @manifest.interop_entries
  @projected_function_entries Enum.map(@function_entries, &Map.delete(&1, :reference_ids))

  @namespace_table Map.new(@namespaces, &{&1.namespace, &1})
  @reference_table Map.new(@references, &{&1.reference_id, &1})
  @overload_table Map.new(@overloads, &{&1.overload_id, &1})
  @audit_spec_table Map.new(@audit_specs, &{&1.key, &1})
  @function_entry_table Map.new(@projected_function_entries, &{&1.name, &1})

  @doc "Returns the validated manifest version."
  @spec version() :: pos_integer()
  def version, do: @manifest.version

  @doc false
  @spec manifest() :: map()
  def manifest, do: @manifest

  @doc false
  @spec legacy_bindings() :: %{atom() => atom()}
  def legacy_bindings, do: @legacy_bindings

  @doc false
  @spec phase0_attestations() :: map()
  def phase0_attestations, do: @phase0_attestations

  @doc "Returns admitted and inventory-only Java class records."
  @spec classes() :: [map()]
  def classes, do: @classes

  @doc "Returns admitted Java reference records."
  @spec references() :: [map()]
  def references, do: @references

  @doc "Returns admitted overload records, all on validated legacy routes in Phase 0."
  @spec overloads() :: [map()]
  def overloads, do: @overloads

  @doc "Fetches one Java reference by stable ID."
  @spec fetch_reference(atom()) :: {:ok, map()} | :error
  def fetch_reference(reference_id), do: Map.fetch(@reference_table, reference_id)

  @doc "Fetches one Java overload by stable ID."
  @spec fetch_overload(atom()) :: {:ok, map()} | :error
  def fetch_overload(overload_id), do: Map.fetch(@overload_table, overload_id)

  @doc "Returns Java compatibility namespace categories for Env diagnostics."
  @spec namespace_categories() :: %{atom() => atom()}
  def namespace_categories, do: Map.new(@namespaces, &{&1.namespace, &1.category})

  @doc "Returns true when `namespace` is owned by the Java surface."
  @spec namespace?(atom()) :: boolean()
  def namespace?(namespace), do: Map.has_key?(@namespace_table, namespace)

  @doc "Returns the currently accepted source members of a Java namespace."
  @spec namespace_members(atom()) :: [atom() | String.t()]
  def namespace_members(namespace) do
    case Map.get(@namespace_table, namespace) do
      nil -> []
      entry -> Enum.map(entry.members, & &1.source_name)
    end
  end

  @doc "Resolves a current Java namespace/member spelling to its legacy Env binding."
  @spec legacy_binding(atom(), atom() | String.t()) :: {:ok, atom()} | :error
  def legacy_binding(namespace, member) do
    with %{members: members} <- Map.get(@namespace_table, namespace),
         %{legacy_binding: binding} <-
           Enum.find(members, &same_source_name?(&1.source_name, member)) do
      {:ok, binding}
    else
      _ -> :error
    end
  end

  @doc "Resolves only spellings whose source member differs from the Env binding name."
  @spec qualified_legacy_alias(atom(), atom() | String.t()) ::
          {:ok, atom()} | :unknown_member | :not_qualified
  def qualified_legacy_alias(namespace, member) do
    case legacy_binding(namespace, member) do
      {:ok, binding} ->
        if Atom.to_string(binding) == to_string(member), do: :not_qualified, else: {:ok, binding}

      :error ->
        case Map.get(@namespace_table, namespace) do
          %{legacy_lookup: :qualified_table} -> :unknown_member
          _ -> :not_qualified
        end
    end
  end

  @doc "Returns qualified legacy binding labels for compatibility diagnostics."
  @spec qualified_legacy_members(atom()) :: [String.t()]
  def qualified_legacy_members(namespace) do
    case Map.get(@namespace_table, namespace) do
      %{legacy_lookup: :qualified_table, members: members} ->
        Enum.map(members, &Atom.to_string(&1.legacy_binding))

      _ ->
        []
    end
  end

  @doc "Returns all Java namespace atoms admitted by the source vocabulary."
  @spec source_namespace_atoms() :: [atom()]
  def source_namespace_atoms, do: Map.keys(@namespace_table)

  @doc "Returns Java namespace labels for analyzer diagnostics."
  @spec available_namespace_labels() :: [String.t()]
  def available_namespace_labels do
    {short, qualified} =
      Enum.split_with(@namespaces, fn entry ->
        entry.namespace |> Atom.to_string() |> String.contains?(".") |> Kernel.not()
      end)

    Enum.map(short ++ qualified, &"#{&1.namespace}/")
  end

  @doc "Returns string-to-atom Java namespace mappings used by Registry documentation lookup."
  @spec doc_namespaces() :: %{String.t() => atom()}
  def doc_namespaces, do: Map.new(@namespaces, &{Atom.to_string(&1.namespace), &1.namespace})

  @doc "Returns the canonical implemented-function name for one accepted namespace member."
  @spec canonical_function_name(atom(), atom() | String.t()) :: String.t() | nil
  def canonical_function_name(namespace, member) do
    case legacy_binding(namespace, member) do
      {:ok, binding} -> Atom.to_string(binding)
      :error -> nil
    end
  end

  @doc "Returns all closed legacy Env binding IDs referenced by overloads."
  @spec legacy_binding_ids() :: [atom()]
  def legacy_binding_ids do
    @overloads
    |> Enum.map(fn %{route: {:legacy_env, binding}} -> binding end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Returns Java-owned implemented-function presentation rows."
  @spec function_entries() :: [map()]
  def function_entries, do: @projected_function_entries

  @doc "Appends manifest projections after rejecting legacy generic Java rows."
  @spec replace_function_entries([map()]) :: [map()]
  def replace_function_entries(entries) do
    stale_entries =
      Enum.filter(entries, fn entry ->
        entry[:category] == :interop or Map.has_key?(@function_entry_table, entry[:name])
      end)

    case stale_entries do
      [] ->
        entries ++ @projected_function_entries

      rows ->
        names = Enum.map_join(rows, ", ", &inspect(&1[:name]))

        raise ArgumentError,
              "legacy Java function metadata must be removed from priv/functions.exs: #{names}"
    end
  end

  @doc false
  @spec validate_legacy_sources!(map(), map()) :: :ok
  def validate_legacy_sources!(function_registry, audit_registry) do
    stale_function_keys = Map.keys(function_registry) -- [:implemented]

    stale_audit_keys =
      Map.keys(audit_registry) --
        [:clojure_core_audit, :clojure_string_audit, :clojure_set_audit, :clojure_walk_audit]

    case {stale_function_keys, stale_audit_keys} do
      {[], []} ->
        :ok

      _stale ->
        raise ArgumentError,
              "legacy Java top-level metadata must be removed: " <>
                "functions=#{inspect(stale_function_keys)}, audits=#{inspect(stale_audit_keys)}"
    end
  end

  @doc "Returns generated Java interop reference presentation rows."
  @spec interop_entries() :: [map()]
  def interop_entries, do: @interop_entries

  @doc "Returns Java audit specifications used by docs and upstream checks."
  @spec audit_specs() :: [map()]
  def audit_specs, do: @audit_specs

  @doc "Fetches a Java audit specification."
  @spec fetch_audit_spec(atom()) :: {:ok, map()} | :error
  def fetch_audit_spec(key), do: Map.fetch(@audit_spec_table, key)

  @doc "Returns sorted Java audit keys."
  @spec audit_keys() :: [atom()]
  def audit_keys, do: @audits |> Map.keys() |> Enum.sort()

  @doc "Returns one Java audit with stable manifest target/reference IDs removed for public compatibility."
  @spec audit(atom()) :: [map()]
  def audit(key) do
    @audits
    |> Map.fetch!(key)
    |> Enum.map(
      &Map.drop(&1, [
        :target_id,
        :reference_id,
        :upstream,
        :jvm_descriptor_attestations,
        :admitted_overload_divergences
      ])
    )
  end

  @doc "Returns one Java audit including stable manifest identities."
  @spec audit_targets(atom()) :: [map()]
  def audit_targets(key), do: Map.fetch!(@audits, key)

  defp same_source_name?(left, right), do: to_string(left) == to_string(right)
end
