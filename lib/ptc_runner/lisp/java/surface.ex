defmodule PtcRunner.Lisp.Java.Surface do
  @moduledoc """
  Compile-time authority for the bounded PTC-Lisp Java compatibility surface.

  The surface is data, not reflection. `priv/java_interop.exs` owns admitted
  classes and references, JVM descriptors, closed dispatch routes, audit
  targets, and documentation projections. Every admitted overload resolves to
  a code-owned Java handler. Pinned JVM oracle fixtures independently attest
  the executable descriptor inventory.
  """

  alias PtcRunner.Lisp.BuiltinNames
  alias PtcRunner.Lisp.Java.Surface.Validator

  @manifest_path "priv/java_interop.exs"
  @external_resource @manifest_path
  @manifest Code.eval_file(@manifest_path) |> elem(0)
  :ok = Validator.validate!(@manifest, BuiltinNames.env_names())

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
  @class_table Map.new(@classes, &{&1.class_id, &1})
  @class_spelling_table for(
                          class <- @classes,
                          spelling <- Enum.uniq([class.name | class.spellings]),
                          into: %{},
                          do: {spelling, class}
                        )
  @audit_spec_table Map.new(@audit_specs, &{&1.key, &1})
  @function_entry_table Map.new(@projected_function_entries, &{&1.name, &1})
  @member_family_table @references
                       |> Enum.filter(&(&1.kind == :instance))
                       |> Enum.group_by(fn reference ->
                         reference.member |> Macro.underscore() |> String.to_atom()
                       end)
  @plain_reference_table for(
                           reference <- @references,
                           reference.kind == :constructor,
                           spelling <- reference.spellings,
                           into: %{},
                           do: {spelling, reference}
                         )
  @member_source_table for(
                         {member_family_id, [reference | _]} <- @member_family_table,
                         into: %{},
                         do: {".#{reference.member}", member_family_id}
                       )

  @doc "Returns the validated manifest version."
  @spec version() :: pos_integer()
  def version, do: @manifest.version

  @doc false
  @spec manifest() :: map()
  def manifest, do: @manifest

  @doc "Returns admitted and inventory-only Java class records."
  @spec classes() :: [map()]
  def classes, do: @classes

  @doc "Returns every admitted source spelling owned by a Java class."
  @spec class_spellings() :: [String.t()]
  def class_spellings do
    @classes
    |> Enum.flat_map(&[&1.name | &1.spellings])
    |> Enum.uniq()
  end

  @doc "Returns admitted Java reference records."
  @spec references() :: [map()]
  def references, do: @references

  @doc "Returns admitted overload records on validated closed dispatch routes."
  @spec overloads() :: [map()]
  def overloads, do: @overloads

  @doc "Fetches one Java reference by stable ID."
  @spec fetch_reference(atom()) :: {:ok, map()} | :error
  def fetch_reference(reference_id), do: Map.fetch(@reference_table, reference_id)

  @doc "Fetches one Java overload by stable ID."
  @spec fetch_overload(atom()) :: {:ok, map()} | :error
  def fetch_overload(overload_id), do: Map.fetch(@overload_table, overload_id)

  @doc "Fetches one admitted or inventory Java class by stable ID."
  @spec fetch_class(atom()) :: {:ok, map()} | :error
  def fetch_class(class_id), do: Map.fetch(@class_table, class_id)

  @doc "Resolves a bounded Java class/member source identity."
  @spec resolve_reference(atom() | String.t(), atom() | String.t()) ::
          {:ok, map()} | :unknown_member | :not_java_class
  def resolve_reference(namespace, member) do
    class = Map.get(@class_spelling_table, to_string(namespace))

    case class do
      nil ->
        :not_java_class

      class ->
        case Enum.find(@references, fn reference ->
               reference.class_id == class.class_id and reference.member == to_string(member)
             end) do
          nil -> :unknown_member
          reference -> {:ok, reference}
        end
    end
  end

  @doc "Resolves a plain constructor source spelling to its admitted reference."
  @spec resolve_plain_reference(atom() | String.t()) :: {:ok, map()} | :error
  def resolve_plain_reference(spelling),
    do: Map.fetch(@plain_reference_table, to_string(spelling))

  @doc "Resolves a direct-dot source spelling to its finite instance member family."
  @spec resolve_member_family(atom() | String.t()) :: {:ok, atom()} | :error
  def resolve_member_family(spelling) do
    Map.fetch(@member_source_table, to_string(spelling))
  end

  @doc "Returns true when a direct-dot spelling names an admitted member family."
  @spec member_family_spelling?(atom() | String.t()) :: boolean()
  def member_family_spelling?(spelling) do
    case resolve_member_family(spelling) do
      {:ok, member_family_id} ->
        member_family_references(member_family_id) != []

      :error ->
        false
    end
  end

  @doc "Returns true when an ID names a finite manifest-derived instance member family."
  @spec member_family?(atom()) :: boolean()
  def member_family?(member_family_id), do: Map.has_key?(@member_family_table, member_family_id)

  @doc false
  @spec member_family_references(atom()) :: [map()]
  def member_family_references(member_family_id),
    do: Map.get(@member_family_table, member_family_id, [])

  @doc false
  @spec member_family_source(atom()) :: {:ok, String.t()} | :error
  def member_family_source(member_family_id) do
    case member_family_references(member_family_id) do
      [%{member: member} | _] -> {:ok, ".#{member}"}
      [] -> :error
    end
  end

  @doc "Returns the canonical inert label for a Java reference."
  @spec reference_label(atom()) :: {:ok, String.t()} | :error
  def reference_label(reference_id) do
    with %{class_id: class_id, member: member} <- Map.get(@reference_table, reference_id),
         %{name: class_name} <- Map.get(@class_table, class_id) do
      {:ok, "#java[#{class_name}/#{member}]"}
    else
      _ -> :error
    end
  end

  @doc "Returns Java compatibility namespace categories for Env diagnostics."
  @spec namespace_categories() :: %{atom() => atom()}
  def namespace_categories, do: Map.new(@namespaces, &{&1.namespace, &1.category})

  @doc "Returns true when `namespace` is owned by the Java surface."
  @spec namespace?(atom() | String.t()) :: boolean()
  def namespace?(namespace) do
    Map.has_key?(@namespace_table, namespace) or
      Map.has_key?(@class_spelling_table, to_string(namespace))
  end

  @doc "Returns the currently accepted source members of a Java namespace."
  @spec namespace_members(atom() | String.t()) :: [atom() | String.t()]
  def namespace_members(namespace) do
    case Map.get(@namespace_table, namespace) do
      nil ->
        case Map.get(@class_spelling_table, to_string(namespace)) do
          nil ->
            []

          class ->
            @references
            |> Enum.filter(&(&1.class_id == class.class_id))
            |> Enum.map(& &1.member)
            |> Enum.uniq()
            |> Enum.sort()
        end

      entry ->
        Enum.map(entry.members, & &1.source_name)
    end
  end

  @doc "Returns all Java namespace atoms admitted by the source vocabulary."
  @spec source_namespace_atoms() :: [atom()]
  def source_namespace_atoms do
    class_atoms =
      @classes
      |> Enum.flat_map(&[&1.name | &1.spellings])
      |> Enum.reject(&String.ends_with?(&1, "."))
      |> Enum.map(&String.to_atom/1)

    Enum.uniq(Map.keys(@namespace_table) ++ class_atoms)
  end

  @doc "Returns Java namespace labels for analyzer diagnostics."
  @spec available_namespace_labels() :: [String.t()]
  def available_namespace_labels do
    {short, qualified} =
      Enum.split_with(@namespaces, fn entry ->
        entry.namespace |> Atom.to_string() |> String.contains?(".") |> Kernel.not()
      end)

    namespace_labels = Enum.map(short ++ qualified, &"#{&1.namespace}/")

    class_labels =
      @classes
      |> Enum.flat_map(&[&1.name | &1.spellings])
      |> Enum.reject(&String.ends_with?(&1, "."))
      |> Enum.map(&"#{&1}/")

    Enum.uniq(namespace_labels ++ class_labels)
  end

  @doc "Returns string-to-atom Java namespace mappings used by Registry documentation lookup."
  @spec doc_namespaces() :: %{String.t() => atom()}
  def doc_namespaces do
    namespace_docs = Map.new(@namespaces, &{Atom.to_string(&1.namespace), &1.namespace})

    class_docs =
      @classes
      |> Enum.flat_map(fn class -> [class.name | class.spellings] end)
      |> Enum.reject(&String.ends_with?(&1, "."))
      |> Map.new(&{&1, String.to_atom(&1)})

    Map.merge(class_docs, namespace_docs)
  end

  @doc "Returns the canonical implemented-function name for one accepted namespace member."
  @spec canonical_function_name(atom() | String.t(), atom() | String.t()) :: String.t() | nil
  def canonical_function_name(namespace, member) do
    case resolve_reference(namespace, member) do
      {:ok, reference} -> List.first(reference.spellings)
      _ -> nil
    end
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
              "duplicate Java function metadata must be removed from priv/functions.exs: #{names}"
    end
  end

  @doc false
  @spec validate_authoritative_sources!(map(), map()) :: :ok
  def validate_authoritative_sources!(function_registry, audit_registry) do
    stale_function_keys = Map.keys(function_registry) -- [:implemented]

    stale_audit_keys =
      Map.keys(audit_registry) --
        [:clojure_core_audit, :clojure_string_audit, :clojure_set_audit, :clojure_walk_audit]

    case {stale_function_keys, stale_audit_keys} do
      {[], []} ->
        :ok

      _stale ->
        raise ArgumentError,
              "duplicate Java top-level metadata must be removed: " <>
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
end
