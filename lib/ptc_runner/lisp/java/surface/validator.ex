defmodule PtcRunner.Lisp.Java.Surface.Validator do
  @moduledoc false

  alias PtcRunner.Lisp.Java.Implementations

  @required_keys ~w(version projection_policy classes references overloads namespaces audit_specs audits function_entries interop_entries)a
  @reference_kinds ~w(static constructor instance field)a
  @audit_statuses ~w(supported candidate not_relevant not_classified)a
  @classifications ~w(exact intentional_ptc_alias ptc_extension)a
  @attestations ~w(jvm ptc_only)a
  @namespace_classifications ~w(admitted incorrect_non_java_alias)a
  @namespace_categories ~w(math interop)a
  @interop_presentation_kinds ~w(constructor method static constant)a
  @interop_kind_for_reference %{
    constructor: :constructor,
    field: :constant,
    instance: :method,
    static: :static
  }
  @argument_types ~w(char_sequence date double float instant int local_date long ptc_temporal string temporal)a
  @receiver_types ~w(string local_date instant duration date)a
  @return_types ~w(boolean double float int long string local_date instant duration date)a
  @error_types ~w(arithmetic_exception date_time_exception date_time_parse_exception illegal_argument_exception invalid_java_string null_pointer_exception number_format_exception string_index_out_of_bounds_exception)a
  @constructor_return_types %{java_util_date: :date}
  @divergence_id_pattern ~r/\A(?:GAP-[A-Z]\d+|DIV-\d+)\z/
  @reserved_non_java_namespaces [
    :tool,
    :data,
    :"ptc.core",
    :json,
    :"clojure.core",
    :core,
    :"clojure.string",
    :str,
    :string,
    :"clojure.set",
    :set,
    :"clojure.walk",
    :walk,
    :regex
  ]

  @spec validate(map(), %{atom() => atom()}, map()) :: :ok | {:error, [String.t()]}
  def validate(manifest, legacy_bindings, phase0_attestations) when is_map(manifest) do
    structural_errors = validate_structure(manifest, legacy_bindings, phase0_attestations)

    errors =
      if structural_errors == [] do
        validate_semantics(manifest, legacy_bindings, phase0_attestations)
      else
        structural_errors
      end

    case Enum.reverse(errors) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  def validate(_manifest, _legacy_bindings, _phase0_attestations),
    do: {:error, ["manifest must be a map"]}

  defp validate_semantics(manifest, legacy_bindings, phase0_attestations) do
    []
    |> validate_version(manifest)
    |> validate_ids(manifest)
    |> validate_classes(manifest)
    |> validate_references(manifest)
    |> validate_overloads(manifest, legacy_bindings)
    |> validate_namespaces(manifest, legacy_bindings)
    |> validate_audits(manifest)
    |> validate_phase0_attestations(manifest, phase0_attestations)
    |> validate_descriptor_audit_links(manifest)
    |> validate_divergence_audit_links(manifest)
    |> validate_presentations(manifest, legacy_bindings)
    |> validate_projection_coverage(manifest)
  end

  defp validate_structure(manifest, legacy_bindings, phase0_attestations) do
    errors =
      []
      |> require_keys(manifest)
      |> require_projection_policy(manifest[:projection_policy])
      |> require_row_collection(manifest[:classes], "classes")
      |> require_row_collection(manifest[:references], "references")
      |> require_row_collection(manifest[:overloads], "overloads")
      |> require_row_collection(manifest[:namespaces], "namespaces")
      |> require_row_collection(manifest[:audit_specs], "audit_specs")
      |> require_audit_collection(manifest[:audits])
      |> require_row_collection(manifest[:function_entries], "function_entries")
      |> require_row_collection(manifest[:interop_entries], "interop_entries")
      |> require_binding_map(legacy_bindings)
      |> require_phase0_attestation_catalog(phase0_attestations)

    errors
    |> validate_class_structure(manifest[:classes])
    |> validate_reference_structure(manifest[:references])
    |> validate_overload_structure(manifest[:overloads])
    |> validate_namespace_structure(manifest[:namespaces])
    |> validate_audit_spec_structure(manifest[:audit_specs])
    |> validate_audit_row_structure(manifest[:audits])
    |> validate_function_entry_structure(manifest[:function_entries])
    |> validate_interop_entry_structure(manifest[:interop_entries])
  end

  defp validate_class_structure(errors, rows) do
    validate_rows(errors, rows, fn row, index, acc ->
      acc
      |> require_fields(
        row,
        [:class_id, :name, :spellings, :receiver_profile],
        "class row #{index}"
      )
      |> require_id_field(row, :class_id, "class row #{index}")
      |> require_binary_field(row, :name, "class row #{index}")
      |> require_binary_list_field(row, :spellings, "class row #{index}")
    end)
  end

  defp validate_reference_structure(errors, rows) do
    validate_rows(errors, rows, fn row, index, acc ->
      acc
      |> require_fields(
        row,
        [:reference_id, :class_id, :member, :kind, :callable?, :spellings, :overload_ids],
        "reference row #{index}"
      )
      |> require_id_field(row, :reference_id, "reference row #{index}")
      |> require_id_field(row, :class_id, "reference row #{index}")
      |> require_binary_field(row, :member, "reference row #{index}")
      |> require_boolean_field(row, :callable?, "reference row #{index}")
      |> require_binary_list_field(row, :spellings, "reference row #{index}")
      |> require_id_list_field(row, :overload_ids, "reference row #{index}")
    end)
  end

  defp validate_overload_structure(errors, rows) do
    validate_rows(errors, rows, fn row, index, acc ->
      acc
      |> require_fields(
        row,
        [
          :overload_id,
          :reference_id,
          :route,
          :classification,
          :attestation,
          :arity,
          :arguments,
          :return,
          :receiver,
          :errors,
          :descriptor,
          :divergence_ids
        ],
        "overload row #{index}"
      )
      |> require_id_field(row, :overload_id, "overload row #{index}")
      |> require_id_field(row, :reference_id, "overload row #{index}")
      |> require_nonnegative_integer_field(row, :arity, "overload row #{index}")
      |> require_list_field(row, :arguments, "overload row #{index}")
      |> require_list_field(row, :errors, "overload row #{index}")
      |> require_optional_binary_field(row, :descriptor, "overload row #{index}")
      |> require_binary_list_field(row, :divergence_ids, "overload row #{index}")
    end)
  end

  defp validate_namespace_structure(errors, rows) do
    validate_rows(errors, rows, fn row, index, acc ->
      label = "namespace row #{index}"

      acc =
        acc
        |> require_fields(row, [:namespace, :class_id, :category, :members], label)
        |> require_id_field(row, :namespace, label)
        |> require_id_field(row, :class_id, label)
        |> require_row_field(row, :members, label)

      validate_rows(acc, row[:members], fn member, member_index, inner ->
        member_label = "#{label} member #{member_index}"

        inner
        |> require_fields(
          member,
          [:source_name, :classification, :reference_id],
          member_label
        )
        |> require_atom_or_binary_field(member, :source_name, member_label)
        |> require_optional_id_field(member, :reference_id, member_label)
        |> require_optional_id_field(member, :legacy_binding, member_label)
      end)
    end)
  end

  defp validate_audit_spec_structure(errors, rows) do
    validate_rows(errors, rows, fn row, index, acc ->
      label = "audit spec row #{index}"

      acc
      |> require_fields(
        row,
        [
          :key,
          :class_id,
          :namespace,
          :default_kind,
          :path,
          :title,
          :description,
          :scope,
          :target,
          :namespace_label
        ],
        label
      )
      |> require_id_field(row, :key, label)
      |> require_id_field(row, :class_id, label)
      |> require_binary_fields(
        row,
        [:namespace, :path, :title, :description, :scope, :target, :namespace_label],
        label
      )
    end)
  end

  defp validate_audit_row_structure(errors, audits) when is_map(audits) do
    Enum.reduce(audits, errors, fn {key, rows}, acc ->
      validate_rows(acc, rows, fn row, index, inner ->
        label = "audit #{inspect(key)} row #{index}"

        inner =
          if row[:status] == :supported do
            require_fields(
              inner,
              row,
              [:jvm_descriptor_attestations, :admitted_overload_divergences],
              label
            )
          else
            inner
          end

        inner
        |> require_fields(
          row,
          [:target_id, :name, :status, :reference_id, :description, :notes],
          label
        )
        |> require_id_field(row, :target_id, label)
        |> require_optional_id_field(row, :reference_id, label)
        |> require_binary_fields(row, [:name, :description, :notes], label)
        |> require_optional_descriptor_map_field(row, :jvm_descriptor_attestations, label)
        |> require_optional_divergence_map_field(row, :admitted_overload_divergences, label)
      end)
    end)
  end

  defp validate_audit_row_structure(errors, _audits), do: errors

  defp validate_function_entry_structure(errors, rows) do
    validate_rows(errors, rows, fn row, index, acc ->
      label = "function entry row #{index}"

      acc
      |> require_fields(
        row,
        [
          :name,
          :description,
          :category,
          :dispatch,
          :binding,
          :reference_ids,
          :signatures,
          :since,
          :examples,
          :notes,
          :section,
          :ptc_extension?,
          :see_also,
          :clojure_var,
          :divergences
        ],
        label
      )
      |> require_binary_fields(row, [:name, :description, :section], label)
      |> require_id_list_field(row, :reference_ids, label)
      |> require_binary_list_field(row, :signatures, label)
      |> require_example_list_field(row, :examples, label)
      |> require_binary_list_field(row, :see_also, label)
      |> require_boolean_field(row, :ptc_extension?, label)
      |> require_optional_binary_field(row, :notes, label)
      |> require_optional_binary_field(row, :since, label)
      |> require_optional_binary_field(row, :clojure_var, label)
      |> require_optional_binary_field(row, :divergences, label)
    end)
  end

  defp validate_interop_entry_structure(errors, rows) do
    validate_rows(errors, rows, fn row, index, acc ->
      label = "interop entry row #{index}"

      acc
      |> require_fields(
        row,
        [:name, :description, :kind, :class, :reference_ids, :signatures, :notes],
        label
      )
      |> require_binary_fields(row, [:name, :description, :class, :notes], label)
      |> require_id_list_field(row, :reference_ids, label)
      |> require_binary_list_field(row, :signatures, label)
    end)
  end

  @spec validate!(map(), %{atom() => atom()}, map()) :: :ok
  def validate!(manifest, legacy_bindings, phase0_attestations) do
    case validate(manifest, legacy_bindings, phase0_attestations) do
      :ok ->
        :ok

      {:error, errors} ->
        raise ArgumentError,
              "invalid priv/java_interop.exs:\n" <>
                Enum.map_join(errors, "\n", &"  - #{&1}")
    end
  end

  defp require_phase0_attestation_catalog(errors, %{overloads: overloads})
       when is_map(overloads) do
    Enum.reduce(overloads, errors, fn {overload_id, attestation}, acc ->
      label = "independent Phase-0 attestation #{inspect(overload_id)}"

      acc =
        if valid_atom_id?(overload_id),
          do: acc,
          else: ["#{label} overload ID must be a non-nil atom" | acc]

      if is_map(attestation) do
        acc
        |> require_fields(attestation, [:attestation, :descriptor, :divergence_ids], label)
        |> require_enum(attestation[:attestation], @attestations, "#{label} kind")
        |> require_optional_binary_field(attestation, :descriptor, label)
        |> require_binary_list_field(attestation, :divergence_ids, label)
      else
        ["#{label} must be a map" | acc]
      end
    end)
  end

  defp require_phase0_attestation_catalog(errors, _attestations),
    do: ["independent Phase-0 attestation catalog must contain an overload map" | errors]

  defp require_keys(errors, manifest) do
    Enum.reduce(@required_keys, errors, fn key, acc ->
      if Map.has_key?(manifest, key), do: acc, else: ["missing top-level #{inspect(key)}" | acc]
    end)
  end

  defp validate_version(errors, %{version: 1}), do: errors

  defp validate_version(errors, manifest),
    do: ["version must be 1, got #{inspect(manifest[:version])}" | errors]

  defp validate_ids(errors, manifest) do
    errors
    |> unique_ids(manifest[:classes], :class_id, "class")
    |> unique_ids(manifest[:references], :reference_id, "reference")
    |> unique_ids(manifest[:overloads], :overload_id, "overload")
    |> unique_ids(manifest[:audit_specs], :key, "audit spec")
    |> unique_ids(
      Enum.flat_map(manifest[:audits] || %{}, fn {_key, rows} -> rows end),
      :target_id,
      "audit target"
    )
    |> unique_ids(manifest[:function_entries], :name, "function entry")
    |> unique_ids(manifest[:interop_entries], :name, "interop entry")
  end

  defp unique_ids(errors, rows, field, label) when is_list(rows) do
    ids = Enum.map(rows, &Map.get(&1, field))

    errors =
      ids
      |> Enum.reject(&valid_id?/1)
      |> Enum.reduce(errors, fn id, acc ->
        ["#{label} has invalid #{field}: #{inspect(id)}" | acc]
      end)

    ids
    |> Enum.frequencies()
    |> Enum.filter(fn {_id, count} -> count > 1 end)
    |> Enum.reduce(errors, fn {id, _count}, acc -> ["duplicate #{label} #{inspect(id)}" | acc] end)
  end

  defp unique_ids(errors, rows, _field, label),
    do: ["#{label} collection must be a list, got #{inspect(rows)}" | errors]

  defp validate_classes(errors, manifest) do
    classes = manifest[:classes] || []

    errors =
      Enum.reduce(classes, errors, fn class, acc ->
        acc
        |> require_nonempty_string(class[:name], "class #{inspect(class[:class_id])} name")
        |> require_string_list(class[:spellings], "class #{inspect(class[:class_id])} spellings")
        |> require_receiver_profile(class)
      end)

    errors
    |> unique_values(Enum.map(classes, & &1.name), "class name")
    |> unique_values(Enum.flat_map(classes, & &1.spellings), "class spelling")
  end

  defp validate_references(errors, manifest) do
    class_ids = id_set(manifest[:classes], :class_id)
    overload_ids = id_set(manifest[:overloads], :overload_id)

    Enum.reduce(manifest[:references] || [], errors, fn reference, acc ->
      id = reference[:reference_id]

      acc
      |> require_member(class_ids, reference[:class_id], "reference #{inspect(id)} class")
      |> require_nonempty_string(reference[:member], "reference #{inspect(id)} member")
      |> require_enum(reference[:kind], @reference_kinds, "reference #{inspect(id)} kind")
      |> require_boolean(reference[:callable?], "reference #{inspect(id)} callable?")
      |> require_nonempty_strings(reference[:spellings], "reference #{inspect(id)} spellings")
      |> require_nonempty_ids(
        reference[:overload_ids],
        overload_ids,
        "reference #{inspect(id)} overload"
      )
      |> validate_callable_policy(reference)
      |> validate_reference_member(reference)
    end)
    |> validate_qualified_spelling_uniqueness(manifest[:references] || [])
    |> validate_java_member_spelling_uniqueness(manifest[:references] || [])
    |> validate_java_member_identity_uniqueness(manifest[:references] || [])
  end

  defp validate_reference_member(errors, %{kind: :constructor, member: "<init>"}), do: errors

  defp validate_reference_member(errors, %{kind: :constructor, reference_id: id, member: member}) do
    [
      "constructor member for reference #{inspect(id)} must be \"<init>\", got #{inspect(member)}"
      | errors
    ]
  end

  defp validate_reference_member(errors, _reference), do: errors

  defp validate_callable_policy(errors, %{kind: kind, callable?: callable?, reference_id: id})
       when kind in @reference_kinds do
    expected = kind != :field

    if callable? == expected,
      do: errors,
      else: [
        "reference #{inspect(id)} callable policy must be #{inspect(expected)} for #{inspect(kind)}"
        | errors
      ]
  end

  defp validate_callable_policy(errors, _reference), do: errors

  defp validate_qualified_spelling_uniqueness(errors, references) do
    references
    |> Enum.flat_map(fn reference ->
      reference.spellings
      |> Enum.reject(&String.starts_with?(&1, "."))
      |> Enum.map(&{&1, reference.reference_id})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_spelling, ids} -> length(Enum.uniq(ids)) > 1 end)
    |> Enum.reduce(errors, fn {spelling, ids}, acc ->
      [
        "qualified spelling #{inspect(spelling)} belongs to multiple references #{inspect(Enum.uniq(ids))}"
        | acc
      ]
    end)
  end

  defp validate_java_member_spelling_uniqueness(errors, references) do
    references
    |> Enum.flat_map(fn reference ->
      Enum.map(reference.spellings, fn spelling ->
        {{reference.class_id, reference.kind, spelling}, reference.reference_id}
      end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_identity, reference_ids} -> length(reference_ids) > 1 end)
    |> Enum.reduce(errors, fn {{class_id, kind, spelling}, reference_ids}, acc ->
      [
        "duplicate Java member spelling #{inspect(spelling)} for #{inspect({class_id, kind})}: #{inspect(reference_ids)}"
        | acc
      ]
    end)
  end

  defp validate_java_member_identity_uniqueness(errors, references) do
    references
    |> Enum.map(fn reference ->
      {{reference.class_id, reference.kind, reference.member}, reference.reference_id}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_identity, reference_ids} -> length(reference_ids) > 1 end)
    |> Enum.reduce(errors, fn {{class_id, kind, member}, reference_ids}, acc ->
      [
        "duplicate Java member identity #{inspect(member)} for #{inspect({class_id, kind})}: #{inspect(reference_ids)}"
        | acc
      ]
    end)
  end

  defp validate_overloads(errors, manifest, legacy_bindings) do
    references = Map.new(manifest[:references] || [], &{&1.reference_id, &1})
    classes = Map.new(manifest[:classes] || [], &{&1.class_id, &1})

    errors =
      Enum.reduce(manifest[:overloads] || [], errors, fn overload, acc ->
        id = overload[:overload_id]
        reference = Map.get(references, overload[:reference_id])
        class = reference && Map.get(classes, reference.class_id)

        acc
        |> require_reference_link(reference, overload)
        |> require_route(overload[:route], id, legacy_bindings)
        |> require_enum(
          overload[:classification],
          @classifications,
          "overload #{inspect(id)} classification"
        )
        |> require_enum(
          overload[:attestation],
          @attestations,
          "overload #{inspect(id)} attestation"
        )
        |> validate_attestation(overload)
        |> validate_signature_metadata(overload, reference, class)
        |> validate_divergence_ids(overload)
        |> validate_descriptor(overload, reference)
      end)

    errors = validate_java_overload_identity_uniqueness(errors, manifest[:overloads] || [])

    Enum.reduce(manifest[:references] || [], errors, fn reference, acc ->
      actual =
        manifest[:overloads]
        |> Enum.filter(&(&1.reference_id == reference.reference_id))
        |> MapSet.new(& &1.overload_id)

      expected = MapSet.new(reference.overload_ids)

      acc =
        if actual == expected do
          acc
        else
          [
            "reference #{inspect(reference.reference_id)} overload links disagree with overload rows"
            | acc
          ]
        end

      route_kinds =
        manifest[:overloads]
        |> Enum.filter(&(&1.reference_id == reference.reference_id))
        |> MapSet.new(fn overload -> route_kind(overload.route) end)

      if MapSet.size(route_kinds) <= 1 do
        acc
      else
        [
          "reference #{inspect(reference.reference_id)} overload route kinds disagree: #{inspect(MapSet.to_list(route_kinds))}"
          | acc
        ]
      end
    end)
  end

  defp route_kind({kind, _target}) when kind in [:dispatch, :legacy_env], do: kind
  defp route_kind(route), do: {:invalid, route}

  defp validate_attestation(errors, %{classification: :exact, attestation: :jvm}), do: errors

  defp validate_attestation(errors, %{
         classification: classification,
         attestation: :ptc_only
       })
       when classification in [:intentional_ptc_alias, :ptc_extension],
       do: errors

  defp validate_attestation(errors, overload),
    do: [
      "overload #{inspect(overload[:overload_id])} classification and JVM descriptor attestation disagree"
      | errors
    ]

  defp validate_divergence_ids(errors, %{
         divergence_ids: [],
         classification: classification,
         overload_id: id
       })
       when classification in [:intentional_ptc_alias, :ptc_extension],
       do: [
         "overload #{inspect(id)} classification #{inspect(classification)} requires divergence IDs"
         | errors
       ]

  defp validate_divergence_ids(errors, %{divergence_ids: divergence_ids, overload_id: id}) do
    errors =
      Enum.reduce(divergence_ids, errors, fn divergence_id, acc ->
        if Regex.match?(@divergence_id_pattern, divergence_id),
          do: acc,
          else: [
            "overload #{inspect(id)} has invalid divergence ID #{inspect(divergence_id)}" | acc
          ]
      end)

    if length(divergence_ids) == length(Enum.uniq(divergence_ids)),
      do: errors,
      else: ["overload #{inspect(id)} has duplicate divergence IDs" | errors]
  end

  defp validate_java_overload_identity_uniqueness(errors, overloads) do
    overloads
    |> Enum.group_by(&overload_identity/1, & &1.overload_id)
    |> Enum.filter(fn {_identity, overload_ids} -> length(overload_ids) > 1 end)
    |> Enum.reduce(errors, fn {identity, overload_ids}, acc ->
      [
        "duplicate Java overload identity #{inspect(identity)}: #{inspect(overload_ids)}"
        | acc
      ]
    end)
  end

  defp overload_identity(%{attestation: :jvm} = overload),
    do: {:jvm, overload.reference_id, overload.descriptor}

  defp overload_identity(%{attestation: :ptc_only} = overload),
    do: {:ptc_only, overload.reference_id, overload.receiver, overload.arity, overload.arguments}

  defp overload_identity(overload), do: {:invalid, overload.overload_id}

  defp require_reference_link(errors, nil, overload),
    do: [
      "overload #{inspect(overload[:overload_id])} has unknown reference #{inspect(overload[:reference_id])}"
      | errors
    ]

  defp require_reference_link(errors, reference, overload) do
    if overload.overload_id in reference.overload_ids,
      do: errors,
      else: ["overload #{inspect(overload.overload_id)} is missing from its reference" | errors]
  end

  defp require_route(errors, {:legacy_env, binding}, _id, legacy_bindings)
       when is_atom(binding) do
    require_member(errors, legacy_bindings, binding, "legacy Env binding")
  end

  defp require_route(errors, {:dispatch, implementation_key}, _id, _legacy_bindings)
       when is_atom(implementation_key) do
    require_member(errors, Implementations.keys(), implementation_key, "Java implementation")
  end

  defp require_route(errors, route, id, _legacy_bindings),
    do: ["overload #{inspect(id)} has invalid Java route #{inspect(route)}" | errors]

  defp validate_signature_metadata(errors, overload, reference, class) do
    id = overload[:overload_id]
    arguments = overload[:arguments]

    errors =
      if is_integer(overload[:arity]) and overload.arity >= 0,
        do: errors,
        else: ["overload #{inspect(id)} arity must be a non-negative integer" | errors]

    errors =
      if is_list(arguments) and length(arguments) == overload[:arity],
        do: errors,
        else: ["overload #{inspect(id)} argument metadata must match arity" | errors]

    errors =
      Enum.reduce(if(is_list(arguments), do: arguments, else: []), errors, fn argument, acc ->
        require_enum(acc, argument, @argument_types, "overload #{inspect(id)} argument")
      end)

    errors =
      require_enum(errors, overload[:return], @return_types, "overload #{inspect(id)} return")

    errors =
      case {reference && reference.kind, overload[:receiver]} do
        {:instance, receiver} ->
          errors
          |> require_enum(receiver, @receiver_types, "overload #{inspect(id)} receiver")
          |> require_class_receiver_profile(id, receiver, class)

        {kind, nil} when kind in [:static, :constructor, :field] ->
          errors

        {kind, receiver} ->
          [
            "overload #{inspect(id)} has invalid #{inspect(kind)} receiver #{inspect(receiver)}"
            | errors
          ]
      end

    if is_list(overload[:errors]) do
      Enum.reduce(overload.errors, errors, fn error, acc ->
        require_enum(acc, error, @error_types, "overload #{inspect(id)} error")
      end)
    else
      ["overload #{inspect(id)} errors must be a list" | errors]
    end
  end

  defp require_receiver_profile(errors, %{receiver_profile: nil}), do: errors

  defp require_receiver_profile(errors, class) do
    require_enum(
      errors,
      class[:receiver_profile],
      @receiver_types,
      "class #{inspect(class[:class_id])} receiver profile"
    )
  end

  defp require_class_receiver_profile(errors, _id, receiver, %{receiver_profile: receiver}),
    do: errors

  defp require_class_receiver_profile(errors, id, receiver, class) do
    expected = class && class[:receiver_profile]

    [
      "overload #{inspect(id)} receiver #{inspect(receiver)} does not match class receiver profile #{inspect(expected)}"
      | errors
    ]
  end

  defp validate_descriptor(errors, %{descriptor: nil, attestation: :ptc_only}, _reference),
    do: errors

  defp validate_descriptor(
         errors,
         %{descriptor: descriptor, attestation: :ptc_only, overload_id: id},
         _reference
       )
       when not is_nil(descriptor),
       do: [
         "overload #{inspect(id)} PTC-only attestation cannot have a JVM descriptor" | errors
       ]

  defp validate_descriptor(
         errors,
         %{descriptor: nil, attestation: :jvm, overload_id: id},
         _reference
       ),
       do: ["overload #{inspect(id)} requires JVM descriptor attestation" | errors]

  defp validate_descriptor(errors, _overload, nil), do: errors

  defp validate_descriptor(errors, overload, %{kind: :field}) do
    case field_descriptor_type(overload.descriptor) do
      {:ok, descriptor_type}
      when overload.arity == 0 ->
        if descriptor_type_matches?(overload.return, descriptor_type) do
          errors
        else
          [descriptor_type_error(overload, [], descriptor_type) | errors]
        end

      _invalid ->
        [
          "field overload #{inspect(overload.overload_id)} must have arity 0 and a field descriptor"
          | errors
        ]
    end
  end

  defp validate_descriptor(errors, overload, reference) do
    case method_descriptor_types(overload.descriptor) do
      {:ok, argument_types, return_type} when length(argument_types) == overload.arity ->
        if descriptor_signature_matches?(overload, reference, argument_types, return_type) do
          errors
        else
          [descriptor_type_error(overload, argument_types, return_type) | errors]
        end

      {:ok, argument_types, _return_type} ->
        [
          "overload #{inspect(overload.overload_id)} descriptor arity #{length(argument_types)} != #{inspect(overload.arity)}"
          | errors
        ]

      :error ->
        [
          "overload #{inspect(overload.overload_id)} has invalid descriptor #{inspect(overload.descriptor)}"
          | errors
        ]
    end
  end

  defp descriptor_signature_matches?(overload, reference, argument_types, return_type) do
    arguments_match? =
      overload.arguments
      |> Enum.zip(argument_types)
      |> Enum.all?(fn {semantic_type, descriptor_type} ->
        descriptor_type_matches?(semantic_type, descriptor_type)
      end)

    return_matches? =
      case reference.kind do
        :constructor ->
          return_type == :void and
            Map.get(@constructor_return_types, reference.class_id) == overload.return

        _kind ->
          descriptor_type_matches?(overload.return, return_type)
      end

    arguments_match? and return_matches?
  end

  defp descriptor_type_error(overload, argument_types, return_type) do
    "overload #{inspect(overload.overload_id)} descriptor types " <>
      "#{inspect({argument_types, return_type})} do not match semantic types " <>
      "#{inspect({overload.arguments, overload.return})}"
  end

  defp descriptor_type_matches?(type, type)
       when type in [:boolean, :double, :float, :int, :long],
       do: true

  defp descriptor_type_matches?(:string, {:object, "java/lang/String"}), do: true

  defp descriptor_type_matches?(:char_sequence, {:object, "java/lang/CharSequence"}),
    do: true

  defp descriptor_type_matches?(:date, {:object, "java/util/Date"}), do: true

  defp descriptor_type_matches?(:local_date, {:object, class_name})
       when class_name in ["java/time/LocalDate", "java/time/chrono/ChronoLocalDate"],
       do: true

  defp descriptor_type_matches?(:instant, {:object, "java/time/Instant"}), do: true

  # Duration.between is admitted for Instant values only even though the JVM
  # declaration accepts the wider Temporal interface.
  defp descriptor_type_matches?(:instant, {:object, "java/time/temporal/Temporal"}), do: true

  defp descriptor_type_matches?(:duration, {:object, "java/time/Duration"}), do: true

  defp descriptor_type_matches?(:temporal, {:object, "java/time/temporal/Temporal"}),
    do: true

  defp descriptor_type_matches?(_semantic_type, _descriptor_type), do: false

  defp field_descriptor_type(descriptor) when is_binary(descriptor) do
    case consume_descriptor_type(descriptor) do
      {:ok, type, ""} -> {:ok, type}
      _invalid -> :error
    end
  end

  defp field_descriptor_type(_descriptor), do: :error

  defp method_descriptor_types("(" <> rest), do: consume_argument_types(rest, [])
  defp method_descriptor_types(_descriptor), do: :error

  defp consume_argument_types(")" <> return_descriptor, argument_types) do
    case consume_return_descriptor_type(return_descriptor) do
      {:ok, return_type, ""} -> {:ok, Enum.reverse(argument_types), return_type}
      _ -> :error
    end
  end

  defp consume_argument_types(descriptor, argument_types) do
    case consume_descriptor_type(descriptor) do
      {:ok, type, rest} -> consume_argument_types(rest, [type | argument_types])
      :error -> :error
    end
  end

  defp consume_return_descriptor_type("V"), do: {:ok, :void, ""}
  defp consume_return_descriptor_type(descriptor), do: consume_descriptor_type(descriptor)

  defp consume_descriptor_type(<<type, rest::binary>>) when type in ~c"BCDFIJSZ" do
    semantic_type =
      Map.fetch!(
        %{
          ?B => :byte,
          ?C => :char,
          ?D => :double,
          ?F => :float,
          ?I => :int,
          ?J => :long,
          ?S => :short,
          ?Z => :boolean
        },
        type
      )

    {:ok, semantic_type, rest}
  end

  defp consume_descriptor_type("[" <> rest) do
    case consume_descriptor_type(rest) do
      {:ok, type, remainder} -> {:ok, {:array, type}, remainder}
      :error -> :error
    end
  end

  defp consume_descriptor_type("L" <> rest) do
    case :binary.match(rest, ";") do
      {index, 1} when index > 0 ->
        class_name = binary_part(rest, 0, index)
        remainder = binary_part(rest, index + 1, byte_size(rest) - index - 1)

        if valid_internal_class_name?(class_name),
          do: {:ok, {:object, class_name}, remainder},
          else: :error

      :nomatch ->
        :error

      _ ->
        :error
    end
  end

  defp consume_descriptor_type(_descriptor), do: :error

  defp valid_internal_class_name?(class_name) do
    not String.contains?(class_name, [".", "[", ";"]) and
      class_name |> String.split("/") |> Enum.all?(&(&1 != ""))
  end

  defp validate_namespaces(errors, manifest, legacy_bindings) do
    references = Map.new(manifest[:references] || [], &{&1.reference_id, &1})

    routes =
      Enum.reduce(manifest[:overloads] || [], %{}, fn
        %{reference_id: reference_id, route: route}, acc ->
          Map.update(acc, reference_id, MapSet.new([route]), &MapSet.put(&1, route))

        _overload, acc ->
          acc
      end)

    class_ids = id_set(manifest[:classes], :class_id)
    namespaces = manifest[:namespaces] || []

    errors = unique_ids(errors, namespaces, :namespace, "namespace")

    Enum.reduce(namespaces, errors, fn namespace, acc ->
      members = namespace[:members]
      namespace_id = namespace[:namespace]

      acc =
        acc
        |> require_member(
          class_ids,
          namespace[:class_id],
          "namespace #{inspect(namespace_id)} class"
        )
        |> require_enum(
          namespace[:category],
          @namespace_categories,
          "namespace #{inspect(namespace_id)} category"
        )
        |> validate_reserved_namespace(namespace_id)
        |> validate_namespace_spelling(namespace, manifest[:classes] || [])

      acc =
        if is_list(members) do
          unique_ids(acc, members, :source_name, "#{inspect(namespace_id)} member")
        else
          ["namespace #{inspect(namespace_id)} members must be a list" | acc]
        end

      acc =
        require_enum(
          acc,
          Map.get(namespace, :legacy_lookup, :aliases),
          [:aliases, :qualified_table],
          "namespace #{inspect(namespace_id)} legacy lookup"
        )

      Enum.reduce(members || [], acc, fn member, inner ->
        inner
        |> require_enum(
          member[:classification],
          @namespace_classifications,
          "namespace member classification"
        )
        |> validate_namespace_runtime_route(namespace, member, legacy_bindings, routes)
        |> validate_namespace_reference(namespace, member, references)
      end)
    end)
  end

  defp validate_namespace_runtime_route(
         errors,
         namespace,
         %{classification: :admitted, reference_id: reference_id} = member,
         legacy_bindings,
         routes
       ) do
    qualified = "#{namespace.namespace}/#{member.source_name}"

    reference_routes = routes |> Map.get(reference_id, MapSet.new()) |> MapSet.to_list()

    case reference_routes do
      [{:legacy_env, binding}] ->
        errors
        |> require_member(
          legacy_bindings,
          member[:legacy_binding],
          "namespace #{inspect(namespace.namespace)} legacy binding"
        )
        |> require_value(
          member[:legacy_binding],
          binding,
          "namespace member #{qualified} reference route"
        )

      [_ | _] = dispatch_routes ->
        if Enum.all?(dispatch_routes, &match?({:dispatch, _implementation_key}, &1)) do
          if Map.has_key?(member, :legacy_binding) do
            [
              "closed-dispatch namespace member #{qualified} cannot retain a legacy binding"
              | errors
            ]
          else
            errors
          end
        else
          [
            "namespace member #{qualified} has invalid reference routes #{inspect(reference_routes)}"
            | errors
          ]
        end

      [] ->
        ["namespace member #{qualified} has invalid reference routes []" | errors]
    end
  end

  defp validate_namespace_runtime_route(
         errors,
         namespace,
         %{classification: :incorrect_non_java_alias} = member,
         legacy_bindings,
         _routes
       ) do
    require_member(
      errors,
      legacy_bindings,
      member[:legacy_binding],
      "namespace #{inspect(namespace.namespace)} legacy binding"
    )
  end

  defp validate_namespace_runtime_route(errors, _namespace, _member, _legacy_bindings, _routes),
    do: errors

  defp validate_reserved_namespace(errors, namespace)
       when namespace in @reserved_non_java_namespaces do
    ["namespace #{inspect(namespace)} is a reserved non-Java namespace" | errors]
  end

  defp validate_reserved_namespace(errors, _namespace), do: errors

  defp validate_namespace_spelling(errors, namespace, classes) do
    class = Enum.find(classes, &(&1[:class_id] == namespace[:class_id]))
    spelling = to_string(namespace[:namespace])

    if class && spelling in class.spellings,
      do: errors,
      else: [
        "namespace #{inspect(namespace[:namespace])} is not a spelling of its class" | errors
      ]
  end

  defp validate_namespace_reference(errors, namespace, member, references) do
    case {member[:classification], Map.get(references, member[:reference_id])} do
      {:admitted, %{class_id: class_id} = reference} ->
        qualified = "#{namespace.namespace}/#{member.source_name}"

        errors
        |> require_value(
          class_id,
          namespace[:class_id],
          "namespace member #{qualified} reference class"
        )
        |> require_member(
          Map.new(reference.spellings, &{&1, true}),
          qualified,
          "namespace member spelling"
        )

      {:admitted, nil} ->
        [
          "admitted namespace member #{namespace.namespace}/#{member.source_name} has no reference"
          | errors
        ]

      {:incorrect_non_java_alias, nil} ->
        errors

      {:incorrect_non_java_alias, _reference} ->
        [
          "incorrect Java alias #{namespace.namespace}/#{member.source_name} must not link a reference"
          | errors
        ]

      {_classification, _reference} ->
        errors
    end
  end

  defp validate_audits(errors, manifest) do
    specs = manifest[:audit_specs] || []
    audits = manifest[:audits] || %{}
    spec_keys = MapSet.new(specs, & &1.key)
    audit_keys = MapSet.new(Map.keys(audits))
    references = Map.new(manifest[:references] || [], &{&1.reference_id, &1})
    classes = Map.new(manifest[:classes] || [], &{&1.class_id, &1})
    spec_table = Map.new(specs, &{&1.key, &1})

    errors =
      if spec_keys == audit_keys,
        do: errors,
        else: ["audit spec keys and audit data keys disagree" | errors]

    errors = unique_values(errors, Enum.map(specs, & &1.path), "audit spec path")

    errors =
      Enum.reduce(specs, errors, fn spec, acc ->
        class = Map.get(classes, spec[:class_id])

        acc
        |> require_member(classes, spec[:class_id], "audit spec #{inspect(spec[:key])} class")
        |> require_value(
          spec[:namespace],
          class && class.name,
          "audit spec #{inspect(spec[:key])} namespace"
        )
        |> require_enum(
          spec[:default_kind],
          [:static, :instance],
          "audit spec #{inspect(spec[:key])} default kind"
        )
        |> validate_conformance_prefix(spec)
      end)

    supported_reference_ids =
      audits
      |> Enum.flat_map(fn {_key, rows} -> rows end)
      |> Enum.filter(&(&1[:status] == :supported and not is_nil(&1[:reference_id])))
      |> Enum.map(& &1.reference_id)

    errors = unique_values(errors, supported_reference_ids, "supported audit reference")

    Enum.reduce(audits, errors, fn {key, rows}, acc ->
      spec = Map.get(spec_table, key)

      Enum.reduce(rows, acc, fn row, inner ->
        inner
        |> require_enum(
          row[:status],
          @audit_statuses,
          "audit target #{inspect(row[:target_id])} status"
        )
        |> validate_upstream(row)
        |> validate_admitted_divergence_ids(row)
        |> validate_audit_reference(key, spec, row, references)
      end)
    end)
  end

  defp validate_conformance_prefix(errors, spec) do
    case Map.fetch(spec, :conformance_prefix) do
      :error ->
        errors

      {:ok, prefix} when is_binary(prefix) and prefix != "" ->
        if String.valid?(prefix),
          do: errors,
          else: invalid_conformance_prefix(errors, spec, prefix)

      {:ok, invalid} ->
        invalid_conformance_prefix(errors, spec, invalid)
    end
  end

  defp invalid_conformance_prefix(errors, spec, invalid),
    do: [
      "audit spec #{inspect(spec[:key])} has invalid conformance prefix #{inspect(invalid)}"
      | errors
    ]

  defp validate_upstream(errors, %{upstream: upstream, target_id: target_id})
       when is_list(upstream) and upstream != [] do
    Enum.reduce(upstream, errors, fn
      {class, kind, member} = invalid, acc
      when is_binary(class) and kind in [:static, :instance, :constructor] and
             is_binary(member) ->
        if String.valid?(class) and String.valid?(member),
          do: acc,
          else: invalid_upstream_identity(acc, target_id, invalid)

      invalid, acc ->
        invalid_upstream_identity(acc, target_id, invalid)
    end)
  end

  defp validate_upstream(errors, %{upstream: upstream, target_id: target_id}),
    do: [
      "audit target #{inspect(target_id)} upstream must be a non-empty list, got #{inspect(upstream)}"
      | errors
    ]

  defp validate_upstream(errors, _row), do: errors

  defp validate_admitted_divergence_ids(errors, %{status: :supported} = row) do
    divergence_lists = row |> Map.get(:admitted_overload_divergences, %{}) |> Map.values()
    divergence_ids = List.flatten(divergence_lists)

    errors =
      Enum.reduce(divergence_ids, errors, fn divergence_id, acc ->
        if Regex.match?(@divergence_id_pattern, divergence_id),
          do: acc,
          else: [
            "audit target #{inspect(row[:target_id])} has invalid admitted divergence ID #{inspect(divergence_id)}"
            | acc
          ]
      end)

    if Enum.all?(divergence_lists, &(length(&1) == length(Enum.uniq(&1)))),
      do: errors,
      else: [
        "audit target #{inspect(row[:target_id])} has duplicate admitted divergence IDs" | errors
      ]
  end

  defp validate_admitted_divergence_ids(errors, row) do
    if Map.has_key?(row, :admitted_overload_divergences),
      do: [
        "non-supported audit target #{inspect(row[:target_id])} cannot attest admitted divergences"
        | errors
      ],
      else: errors
  end

  defp invalid_upstream_identity(errors, target_id, invalid),
    do: [
      "audit target #{inspect(target_id)} has invalid upstream identity #{inspect(invalid)}"
      | errors
    ]

  defp validate_audit_reference(
         errors,
         _key,
         spec,
         %{status: :supported, reference_id: reference_id} = row,
         references
       ) do
    case Map.get(references, reference_id) do
      nil ->
        [
          "supported audit target #{inspect(row[:target_id])} reference #{inspect(reference_id)} does not exist"
          | errors
        ]

      reference ->
        errors
        |> require_value(
          reference.class_id,
          spec && spec.class_id,
          "supported audit target #{inspect(row[:target_id])} reference class"
        )
        |> validate_audit_spelling(row, reference)
    end
  end

  defp validate_audit_reference(errors, _key, _spec, %{reference_id: nil}, _references),
    do: errors

  defp validate_audit_reference(errors, key, _spec, row, _references),
    do: [
      "non-supported audit target #{inspect({key, row[:target_id]})} must not link a reference"
      | errors
    ]

  defp validate_audit_spelling(errors, row, reference) do
    if row.name == reference.member or row.name in reference.spellings,
      do: errors,
      else: ["audit target #{inspect(row.target_id)} does not name its linked reference" | errors]
  end

  defp validate_phase0_attestations(errors, manifest, phase0_attestations) do
    actual =
      Map.new(manifest.overloads, fn overload ->
        {overload.overload_id, Map.take(overload, [:attestation, :descriptor, :divergence_ids])}
      end)

    expected = phase0_attestations.overloads

    (Map.keys(actual) ++ Map.keys(expected))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce(errors, fn overload_id, acc ->
      case {Map.fetch(expected, overload_id), Map.fetch(actual, overload_id)} do
        {{:ok, expected_attestation}, {:ok, actual_attestation}}
        when expected_attestation == actual_attestation ->
          acc

        {{:ok, expected_attestation}, {:ok, actual_attestation}} ->
          [
            "overload #{inspect(overload_id)} disagrees with its independent Phase-0 attestation: " <>
              "expected #{inspect(expected_attestation)}, got #{inspect(actual_attestation)}"
            | acc
          ]

        {:error, {:ok, _actual_attestation}} ->
          [
            "overload #{inspect(overload_id)} has no independent Phase-0 attestation"
            | acc
          ]

        {{:ok, _expected_attestation}, :error} ->
          [
            "independent Phase-0 attestation #{inspect(overload_id)} has no manifest overload"
            | acc
          ]
      end
    end)
  end

  defp validate_descriptor_audit_links(errors, manifest) do
    admitted_by_reference =
      manifest.overloads
      |> Enum.group_by(& &1.reference_id)
      |> Map.new(fn {reference_id, overloads} ->
        descriptors =
          overloads
          |> Enum.filter(&(&1.attestation == :jvm))
          |> Map.new(&{&1.overload_id, &1.descriptor})

        {reference_id, descriptors}
      end)

    manifest.audits
    |> Enum.flat_map(fn {_key, rows} -> rows end)
    |> Enum.filter(&(&1.status == :supported and not is_nil(&1.reference_id)))
    |> Enum.reduce(errors, fn audit_row, acc ->
      admitted = Map.get(admitted_by_reference, audit_row.reference_id, %{})

      if admitted == audit_row.jvm_descriptor_attestations do
        acc
      else
        [
          "reference #{inspect(audit_row.reference_id)} JVM descriptor coverage disagrees between admitted overloads and audit attestation"
          | acc
        ]
      end
    end)
  end

  defp validate_divergence_audit_links(errors, manifest) do
    audit_rows_by_reference =
      manifest.audits
      |> Enum.flat_map(fn {_key, rows} -> rows end)
      |> Enum.filter(&(&1.status == :supported and not is_nil(&1.reference_id)))
      |> Map.new(&{&1.reference_id, &1})

    admitted_by_reference =
      manifest.overloads
      |> Enum.group_by(& &1.reference_id)
      |> Map.new(fn {reference_id, overloads} ->
        {reference_id, Map.new(overloads, &{&1.overload_id, &1.divergence_ids})}
      end)

    Enum.reduce(audit_rows_by_reference, errors, fn {reference_id, audit_row}, acc ->
      admitted = Map.get(admitted_by_reference, reference_id, %{})
      audited = audit_row.admitted_overload_divergences

      acc =
        if admitted == audited do
          acc
        else
          [
            "reference #{inspect(reference_id)} divergence coverage disagrees between admitted overloads and audit attestation"
            | acc
          ]
        end

      [Map.values(admitted), Map.values(audited)]
      |> List.flatten()
      |> MapSet.new()
      |> Enum.reduce(acc, fn divergence_id, inner ->
        if String.contains?(audit_row.notes, divergence_id) do
          inner
        else
          [
            "reference #{inspect(reference_id)} divergence #{divergence_id} is missing from its supported audit rationale"
            | inner
          ]
        end
      end)
    end)
  end

  defp validate_presentations(errors, manifest, legacy_bindings) do
    reference_ids = id_set(manifest[:references], :reference_id)
    references = Map.new(manifest[:references] || [], &{&1.reference_id, &1})
    classes = Map.new(manifest[:classes] || [], &{&1.class_id, &1.name})
    overloads = Map.new(manifest[:overloads] || [], &{&1.overload_id, &1})
    see_also_targets = presentation_target_names(manifest, legacy_bindings)

    legacy_bindings_by_name =
      Map.new(legacy_bindings, fn {name, binding_kind} ->
        {Atom.to_string(name), binding_kind}
      end)

    errors =
      Enum.reduce(manifest[:function_entries] || [], errors, fn entry, acc ->
        acc
        |> require_value(
          entry[:category],
          :interop,
          "function entry #{inspect(entry[:name])} category"
        )
        |> validate_function_dispatch(entry, legacy_bindings_by_name)
        |> require_nonempty_ids(
          entry[:reference_ids],
          reference_ids,
          "function entry #{inspect(entry[:name])} reference"
        )
        |> validate_function_identity(entry, references, overloads)
        |> validate_see_also(entry, see_also_targets)
      end)

    Enum.reduce(manifest[:interop_entries] || [], errors, fn entry, acc ->
      acc
      |> require_nonempty_ids(
        entry[:reference_ids],
        reference_ids,
        "interop entry #{inspect(entry[:name])} reference"
      )
      |> validate_interop_identity(entry, references, classes)
      |> validate_interop_kind(entry, references)
      |> validate_presentation_signatures(entry, references, overloads)
      |> require_enum(
        entry[:kind],
        @interop_presentation_kinds,
        "interop entry #{inspect(entry[:name])} kind"
      )
    end)
  end

  defp validate_function_dispatch(errors, %{dispatch: :env} = entry, legacy_bindings_by_name) do
    binding_name = entry[:name]

    errors
    |> require_member(
      legacy_bindings_by_name,
      binding_name,
      "function entry #{inspect(binding_name)} Env binding"
    )
    |> require_value(
      entry[:binding],
      Map.get(legacy_bindings_by_name, binding_name),
      "function entry #{inspect(binding_name)} binding kind"
    )
  end

  defp validate_function_dispatch(errors, %{dispatch: :java} = entry, _legacy_bindings_by_name) do
    require_value(
      errors,
      entry[:binding],
      :normal,
      "function entry #{inspect(entry[:name])} binding kind"
    )
  end

  defp validate_function_dispatch(errors, entry, _legacy_bindings_by_name),
    do: [
      "function entry #{inspect(entry[:name])} has invalid dispatch #{inspect(entry[:dispatch])}"
      | errors
    ]

  defp validate_interop_kind(errors, entry, references) do
    Enum.reduce(entry[:reference_ids] || [], errors, fn reference_id, acc ->
      case Map.get(references, reference_id) do
        nil ->
          acc

        reference ->
          case Map.fetch(@interop_kind_for_reference, reference.kind) do
            {:ok, expected_kind} ->
              require_value(
                acc,
                entry[:kind],
                expected_kind,
                "interop entry #{inspect(entry[:name])} presentation kind"
              )

            :error ->
              acc
          end
      end
    end)
  end

  defp validate_function_identity(errors, entry, references, overloads) do
    linked = Enum.map(entry[:reference_ids] || [], &Map.get(references, &1))

    errors =
      Enum.reduce(linked, errors, fn
        nil, acc ->
          acc

        reference, acc ->
          if reference_matches_function_entry?(reference, entry, overloads) do
            acc
          else
            [
              "function entry #{inspect(entry[:name])} reference route does not match dispatch"
              | acc
            ]
          end
      end)

    expected_reference_ids =
      references
      |> Enum.filter(fn {_reference_id, reference} ->
        reference_matches_function_entry?(reference, entry, overloads)
      end)
      |> MapSet.new(&elem(&1, 0))

    errors
    |> require_reference_coverage(
      entry[:reference_ids],
      expected_reference_ids,
      "function entry #{inspect(entry[:name])}"
    )
    |> validate_presentation_signatures(entry, references, overloads)
  end

  defp reference_matches_function_entry?(reference, %{dispatch: :env, name: name}, overloads) do
    Enum.any?(reference.overload_ids, fn overload_id ->
      case Map.get(overloads, overload_id) do
        %{route: {:legacy_env, binding}} -> Atom.to_string(binding) == name
        _overload -> false
      end
    end)
  end

  defp reference_matches_function_entry?(reference, %{dispatch: :java, name: name}, overloads) do
    name in reference.spellings and
      Enum.all?(reference.overload_ids, fn overload_id ->
        match?(%{route: {:dispatch, _}}, Map.get(overloads, overload_id))
      end)
  end

  defp reference_matches_function_entry?(_reference, _entry, _overloads), do: false

  defp validate_interop_identity(errors, entry, references, classes) do
    linked = Enum.map(entry[:reference_ids] || [], &Map.get(references, &1))

    errors =
      if Enum.any?(linked, &is_nil/1) do
        errors
      else
        expected_class =
          linked
          |> Enum.map(&Map.get(classes, &1.class_id))
          |> Enum.uniq()
          |> Enum.join(" / ")

        errors =
          require_value(
            errors,
            entry[:class],
            expected_class,
            "interop entry #{inspect(entry[:name])} class"
          )

        Enum.reduce(linked, errors, fn reference, acc ->
          require_member(
            acc,
            Map.new(reference.spellings, &{&1, true}),
            entry[:name],
            "interop entry #{inspect(entry[:name])} spelling"
          )
        end)
      end

    expected_reference_ids =
      references
      |> Enum.filter(fn {_reference_id, reference} -> entry[:name] in reference.spellings end)
      |> MapSet.new(&elem(&1, 0))

    require_reference_coverage(
      errors,
      entry[:reference_ids],
      expected_reference_ids,
      "interop entry #{inspect(entry[:name])}"
    )
  end

  defp presentation_target_names(manifest, legacy_bindings) do
    legacy_names = Enum.map(Map.keys(legacy_bindings), &Atom.to_string/1)
    function_names = Enum.map(manifest[:function_entries], & &1.name)
    interop_names = Enum.map(manifest[:interop_entries], & &1.name)
    reference_spellings = Enum.flat_map(manifest[:references], & &1.spellings)

    Map.new(legacy_names ++ function_names ++ interop_names ++ reference_spellings, &{&1, true})
  end

  defp validate_see_also(errors, entry, targets) do
    Enum.reduce(entry[:see_also], errors, fn target, acc ->
      require_member(
        acc,
        targets,
        target,
        "function entry #{inspect(entry[:name])} see_also target"
      )
    end)
  end

  defp require_reference_coverage(errors, actual_ids, expected_ids, label) do
    actual_ids = MapSet.new(actual_ids)

    if actual_ids == expected_ids do
      errors
    else
      [
        "#{label} reference coverage must be #{inspect(MapSet.to_list(expected_ids))}, got #{inspect(MapSet.to_list(actual_ids))}"
        | errors
      ]
    end
  end

  defp validate_projection_coverage(errors, manifest) do
    policy = manifest.projection_policy
    reference_ids = MapSet.new(manifest.references, & &1.reference_id)

    audit_reference_ids =
      manifest.audits
      |> Enum.flat_map(fn {_key, rows} -> rows end)
      |> Enum.reject(&is_nil(&1.reference_id))
      |> MapSet.new(& &1.reference_id)

    interop_reference_ids =
      manifest.interop_entries
      |> Enum.flat_map(& &1.reference_ids)
      |> MapSet.new()

    omitted_interop_ids = MapSet.new(policy.interop_omitted_reference_ids)
    expected_interop_ids = MapSet.difference(reference_ids, omitted_interop_ids)

    errors
    |> require_value(
      policy.audit_reference_coverage,
      :all,
      "projection policy audit reference coverage"
    )
    |> require_reference_coverage(
      audit_reference_ids,
      reference_ids,
      "audit reference coverage"
    )
    |> require_reference_coverage(
      interop_reference_ids,
      expected_interop_ids,
      "interop reference coverage"
    )
    |> require_reference_coverage(
      policy.interop_omitted_reference_ids,
      MapSet.difference(reference_ids, interop_reference_ids),
      "interop omission policy"
    )
    |> validate_runtime_spelling_coverage(manifest)
    |> validate_interop_spelling_coverage(manifest)
  end

  defp validate_runtime_spelling_coverage(errors, manifest) do
    namespace_routes =
      for namespace <- manifest.namespaces,
          member <- namespace.members,
          member.classification == :admitted,
          into: MapSet.new() do
        {"#{namespace.namespace}/#{member.source_name}", member.reference_id}
      end

    legacy_routes =
      manifest.overloads
      |> Enum.flat_map(fn
        %{route: {:legacy_env, binding}, reference_id: reference_id} ->
          [{Atom.to_string(binding), reference_id}]

        _overload ->
          []
      end)
      |> MapSet.new()

    closed_source_routes =
      manifest.references
      |> Enum.filter(fn reference ->
        Enum.all?(reference.overload_ids, fn overload_id ->
          Enum.any?(manifest.overloads, fn overload ->
            overload.overload_id == overload_id and match?({:dispatch, _}, overload.route)
          end)
        end)
      end)
      |> Enum.flat_map(fn
        %{kind: :instance, member: member, reference_id: reference_id} ->
          [{".#{member}", reference_id}]

        %{kind: :constructor, spellings: spellings, reference_id: reference_id} ->
          Enum.map(spellings, &{&1, reference_id})

        _reference ->
          []
      end)
      |> MapSet.new()

    Enum.reduce(manifest.references, errors, fn reference, acc ->
      Enum.reduce(reference.spellings, acc, fn spelling, inner ->
        routes = if String.contains?(spelling, "/"), do: namespace_routes, else: legacy_routes

        if MapSet.member?(routes, {spelling, reference.reference_id}) or
             MapSet.member?(closed_source_routes, {spelling, reference.reference_id}) do
          inner
        else
          [
            "reference #{inspect(reference.reference_id)} runtime spelling #{inspect(spelling)} has no matching namespace or legacy route"
            | inner
          ]
        end
      end)
    end)
  end

  defp validate_interop_spelling_coverage(errors, manifest) do
    omitted_reference_ids = MapSet.new(manifest.projection_policy.interop_omitted_reference_ids)

    heads_by_reference =
      Enum.reduce(manifest.interop_entries, %{}, fn entry, acc ->
        heads =
          case presentation_signatures(entry.signatures) do
            {:ok, signatures} -> Enum.map(signatures, &elem(&1, 0))
            :error -> []
          end

        Enum.reduce(entry.reference_ids, acc, fn reference_id, inner ->
          Map.update(inner, reference_id, MapSet.new(heads), &MapSet.union(&1, MapSet.new(heads)))
        end)
      end)

    manifest.references
    |> Enum.reject(&MapSet.member?(omitted_reference_ids, &1.reference_id))
    |> Enum.reduce(errors, fn reference, acc ->
      documented_heads = Map.get(heads_by_reference, reference.reference_id, MapSet.new())

      reference.spellings
      |> Enum.reject(&MapSet.member?(documented_heads, &1))
      |> Enum.reduce(acc, fn spelling, inner ->
        [
          "reference #{inspect(reference.reference_id)} interop presentation spelling #{inspect(spelling)} is missing"
          | inner
        ]
      end)
    end)
  end

  defp validate_presentation_signatures(errors, entry, references, overloads) do
    linked =
      entry[:reference_ids]
      |> List.wrap()
      |> Enum.map(&Map.get(references, &1))
      |> Enum.reject(&is_nil/1)

    expected =
      linked
      |> Enum.flat_map(fn reference ->
        receiver_arity = if reference.kind == :instance, do: 1, else: 0

        reference.overload_ids
        |> Enum.map(&Map.get(overloads, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&(&1.arity + receiver_arity))
      end)
      |> MapSet.new()

    case presentation_signatures(entry[:signatures]) do
      {:ok, signatures} ->
        actual = MapSet.new(signatures, &elem(&1, 1))

        errors =
          if actual == expected do
            errors
          else
            [
              "presentation #{inspect(entry[:name])} signature arities #{inspect(MapSet.to_list(actual))} do not match overload arities #{inspect(MapSet.to_list(expected))}"
              | errors
            ]
          end

        validate_presentation_signature_heads(errors, entry, signatures, linked, overloads)

      :error ->
        ["presentation #{inspect(entry[:name])} has invalid signatures" | errors]
    end
  end

  defp validate_presentation_signature_heads(errors, entry, signatures, linked, overloads) do
    heads = MapSet.new(signatures, &elem(&1, 0))

    allowed_by_reference =
      Map.new(linked, fn reference ->
        route_heads =
          reference.overload_ids
          |> Enum.map(&Map.get(overloads, &1))
          |> Enum.flat_map(fn
            %{route: {:legacy_env, binding}} -> [Atom.to_string(binding)]
            _overload -> []
          end)

        {reference.reference_id, MapSet.new(reference.spellings ++ route_heads)}
      end)

    allowed_heads =
      allowed_by_reference
      |> Map.values()
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    errors =
      heads
      |> MapSet.difference(allowed_heads)
      |> Enum.reduce(errors, fn head, acc ->
        [
          "presentation #{inspect(entry[:name])} signature head #{inspect(head)} is not a linked Java spelling or route"
          | acc
        ]
      end)

    Enum.reduce(allowed_by_reference, errors, fn {reference_id, allowed}, acc ->
      if MapSet.disjoint?(heads, allowed) do
        [
          "presentation #{inspect(entry[:name])} signatures do not cover reference #{inspect(reference_id)}"
          | acc
        ]
      else
        acc
      end
    end)
  end

  defp presentation_signatures(signatures) when is_list(signatures) and signatures != [] do
    Enum.reduce_while(signatures, {:ok, []}, fn signature, {:ok, parsed} ->
      case presentation_signature(signature) do
        {:ok, head, arity} -> {:cont, {:ok, [{head, arity} | parsed]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp presentation_signatures(_signatures), do: :error

  defp presentation_signature(signature) when is_binary(signature) do
    trimmed = String.trim(signature)

    cond do
      String.starts_with?(trimmed, "(") and String.ends_with?(trimmed, ")") ->
        terms =
          trimmed
          |> String.slice(1, byte_size(trimmed) - 2)
          |> String.split(~r/\s+/, trim: true)

        case terms do
          [head | arguments] -> {:ok, head, length(arguments)}
          [] -> :error
        end

      trimmed != "" and not String.contains?(trimmed, ["(", ")", " "]) ->
        {:ok, trimmed, 0}

      true ->
        :error
    end
  end

  defp presentation_signature(_signature), do: :error

  defp require_row_collection(errors, rows, label) when is_list(rows) do
    Enum.with_index(rows)
    |> Enum.reduce(errors, fn
      {%{}, _index}, acc -> acc
      {row, index}, acc -> ["#{label} row #{index} must be a map, got #{inspect(row)}" | acc]
    end)
  end

  defp require_row_collection(errors, rows, label),
    do: ["#{label} must be a list of maps, got #{inspect(rows)}" | errors]

  defp require_audit_collection(errors, audits) when is_map(audits) do
    Enum.reduce(audits, errors, fn {key, rows}, acc ->
      acc =
        if valid_atom_id?(key),
          do: acc,
          else: ["audit key must be a non-nil atom, got #{inspect(key)}" | acc]

      require_row_collection(acc, rows, "audit #{inspect(key)}")
    end)
  end

  defp require_audit_collection(errors, audits),
    do: ["audits must be a map of row lists, got #{inspect(audits)}" | errors]

  defp require_projection_policy(errors, policy) when is_map(policy) do
    errors
    |> require_fields(
      policy,
      [:audit_reference_coverage, :interop_omitted_reference_ids, :interop_omission_reason],
      "projection policy"
    )
    |> require_id_list_field(policy, :interop_omitted_reference_ids, "projection policy")
    |> require_binary_field(policy, :interop_omission_reason, "projection policy")
  end

  defp require_projection_policy(errors, policy),
    do: ["projection policy must be a map, got #{inspect(policy)}" | errors]

  defp require_binding_map(errors, bindings) when is_map(bindings), do: errors

  defp require_binding_map(errors, bindings),
    do: ["legacy bindings must be a map, got #{inspect(bindings)}" | errors]

  defp validate_rows(errors, rows, validate) when is_list(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce(errors, fn
      {%{} = row, index}, acc -> validate.(row, index, acc)
      {_row, _index}, acc -> acc
    end)
  end

  defp validate_rows(errors, _rows, _validate), do: errors

  defp require_fields(errors, row, fields, label) do
    Enum.reduce(fields, errors, fn field, acc ->
      if Map.has_key?(row, field),
        do: acc,
        else: ["#{label} is missing #{inspect(field)}" | acc]
    end)
  end

  defp require_row_field(errors, row, field, label) do
    require_row_collection(errors, row[field], "#{label} #{field}")
  end

  defp require_list_field(errors, row, field, label) do
    case Map.get(row, field) do
      values when is_list(values) -> errors
      value -> ["#{label} #{field} must be a list, got #{inspect(value)}" | errors]
    end
  end

  defp require_id_list_field(errors, row, field, label) do
    case Map.get(row, field) do
      values when is_list(values) ->
        if Enum.all?(values, &valid_atom_id?/1),
          do: errors,
          else: ["#{label} #{field} must contain only non-nil atoms" | errors]

      value ->
        ["#{label} #{field} must be a list, got #{inspect(value)}" | errors]
    end
  end

  defp require_binary_list_field(errors, row, field, label) do
    case row[field] do
      values when is_list(values) ->
        if Enum.all?(values, &valid_string?/1),
          do: errors,
          else: ["#{label} #{field} must contain only valid UTF-8 strings" | errors]

      value ->
        ["#{label} #{field} must be a list, got #{inspect(value)}" | errors]
    end
  end

  defp require_optional_divergence_map_field(errors, row, field, label) do
    case Map.fetch(row, field) do
      :error ->
        errors

      {:ok, values} when is_map(values) ->
        if Enum.all?(values, fn {overload_id, ids} ->
             valid_atom_id?(overload_id) and is_list(ids) and
               Enum.all?(ids, &valid_string?/1)
           end),
           do: errors,
           else: [
             "#{label} #{field} must map non-nil overload atoms to valid UTF-8 string lists"
             | errors
           ]

      {:ok, value} ->
        ["#{label} #{field} must be a map, got #{inspect(value)}" | errors]
    end
  end

  defp require_optional_descriptor_map_field(errors, row, field, label) do
    case Map.fetch(row, field) do
      :error ->
        errors

      {:ok, values} when is_map(values) ->
        if Enum.all?(values, fn {overload_id, descriptor} ->
             valid_atom_id?(overload_id) and valid_string?(descriptor)
           end),
           do: errors,
           else: [
             "#{label} #{field} must map non-nil overload atoms to valid UTF-8 descriptors"
             | errors
           ]

      {:ok, value} ->
        ["#{label} #{field} must be a map, got #{inspect(value)}" | errors]
    end
  end

  defp require_example_list_field(errors, row, field, label) do
    case row[field] do
      examples when is_list(examples) ->
        if Enum.all?(examples, fn
             {code, result} -> valid_string?(code) and valid_string?(result)
             _invalid -> false
           end),
           do: errors,
           else: [
             "#{label} #{inspect(field)} must contain {code, result} valid UTF-8 string tuples"
             | errors
           ]

      value ->
        ["#{label} #{inspect(field)} must be a list, got #{inspect(value)}" | errors]
    end
  end

  defp require_binary_field(errors, row, field, label) do
    case Map.get(row, field) do
      value when is_binary(value) ->
        if String.valid?(value),
          do: errors,
          else: ["#{label} #{field} must be valid UTF-8, got #{inspect(value)}" | errors]

      value ->
        ["#{label} #{field} must be a string, got #{inspect(value)}" | errors]
    end
  end

  defp require_binary_fields(errors, row, fields, label) do
    Enum.reduce(fields, errors, fn field, acc ->
      require_binary_field(acc, row, field, label)
    end)
  end

  defp require_boolean_field(errors, row, field, label) do
    require_boolean(errors, Map.get(row, field), "#{label} #{field}")
  end

  defp require_optional_binary_field(errors, row, field, label) do
    case Map.get(row, field) do
      nil ->
        errors

      value when is_binary(value) ->
        if String.valid?(value),
          do: errors,
          else: ["#{label} #{field} must be valid UTF-8, got #{inspect(value)}" | errors]

      value ->
        ["#{label} #{field} must be a string or nil, got #{inspect(value)}" | errors]
    end
  end

  defp require_id_field(errors, row, field, label) do
    case Map.get(row, field) do
      value when is_atom(value) and not is_nil(value) ->
        errors

      value ->
        ["#{label} #{field} must be a non-nil atom, got #{inspect(value)}" | errors]
    end
  end

  defp require_optional_id_field(errors, row, field, label) do
    case Map.get(row, field) do
      nil ->
        errors

      value when is_atom(value) ->
        errors

      value ->
        ["#{label} #{field} must be nil or a non-nil atom, got #{inspect(value)}" | errors]
    end
  end

  defp require_atom_or_binary_field(errors, row, field, label) do
    case Map.get(row, field) do
      value when is_atom(value) ->
        errors

      value when is_binary(value) ->
        if String.valid?(value),
          do: errors,
          else: ["#{label} #{field} must be valid UTF-8, got #{inspect(value)}" | errors]

      value ->
        ["#{label} #{field} must be an atom or string, got #{inspect(value)}" | errors]
    end
  end

  defp require_nonnegative_integer_field(errors, row, field, label) do
    case Map.get(row, field) do
      value when is_integer(value) and value >= 0 ->
        errors

      value ->
        ["#{label} #{field} must be a non-negative integer, got #{inspect(value)}" | errors]
    end
  end

  defp id_set(rows, field) when is_list(rows), do: Map.new(rows, &{Map.get(&1, field), true})
  defp id_set(_rows, _field), do: %{}

  defp require_member(errors, set, value, label) do
    if Map.has_key?(set, value),
      do: errors,
      else: ["#{label} #{inspect(value)} does not exist" | errors]
  end

  defp require_enum(errors, value, allowed, label) do
    if value in allowed,
      do: errors,
      else: ["#{label} must be one of #{inspect(allowed)}, got #{inspect(value)}" | errors]
  end

  defp require_boolean(errors, value, _label) when is_boolean(value), do: errors

  defp require_boolean(errors, value, label),
    do: ["#{label} must be boolean, got #{inspect(value)}" | errors]

  defp require_value(errors, value, value, _label), do: errors

  defp require_value(errors, actual, expected, label),
    do: ["#{label} must be #{inspect(expected)}, got #{inspect(actual)}" | errors]

  defp require_nonempty_strings(errors, values, _label)
       when is_list(values) and values != [] and is_binary(hd(values)),
       do:
         if(Enum.all?(values, &valid_string?/1),
           do: errors,
           else: ["spelling must be a valid UTF-8 string" | errors]
         )

  defp require_nonempty_strings(errors, values, label),
    do: ["#{label} must be a non-empty string list, got #{inspect(values)}" | errors]

  defp require_string_list(errors, values, _label) when is_list(values) do
    if Enum.all?(values, &valid_string?/1),
      do: errors,
      else: ["spelling must be a valid UTF-8 string" | errors]
  end

  defp require_string_list(errors, values, label),
    do: ["#{label} must be a string list, got #{inspect(values)}" | errors]

  defp valid_string?(value), do: is_binary(value) and String.valid?(value)
  defp valid_atom_id?(value), do: is_atom(value) and not is_nil(value)

  defp valid_id?(value) when is_atom(value), do: valid_atom_id?(value)
  defp valid_id?(value) when is_binary(value), do: value != "" and valid_string?(value)
  defp valid_id?(_value), do: false

  defp require_nonempty_string(errors, value, _label) when is_binary(value) and value != "",
    do: errors

  defp require_nonempty_string(errors, value, label),
    do: ["#{label} must be a non-empty string, got #{inspect(value)}" | errors]

  defp unique_values(errors, values, label) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.reduce(errors, fn {value, _count}, acc ->
      ["duplicate #{label} #{inspect(value)}" | acc]
    end)
  end

  defp require_nonempty_ids(errors, values, ids, label) when is_list(values) and values != [] do
    Enum.reduce(values, errors, &require_member(&2, ids, &1, label))
  end

  defp require_nonempty_ids(errors, values, _ids, label),
    do: ["#{label} list must be non-empty, got #{inspect(values)}" | errors]
end
