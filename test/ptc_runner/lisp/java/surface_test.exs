defmodule PtcRunner.Lisp.Java.SurfaceTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Ptc.AuditUpstream
  alias Mix.Tasks.Ptc.GenDocs
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Analyze
  alias PtcRunner.Lisp.BuiltinNames
  alias PtcRunner.Lisp.CoreToSource
  alias PtcRunner.Lisp.Java.Surface
  alias PtcRunner.Lisp.Java.Surface.Validator
  alias PtcRunner.Lisp.Parser
  alias PtcRunner.Lisp.Registry
  alias PtcRunner.Lisp.SourceAtoms
  alias PtcRunner.TestSupport.LispConformanceCases.Manual

  @namespace_members %{
    :Math => [
      :abs,
      :ceil,
      :floor,
      :max,
      :min,
      :pow,
      :round,
      :sqrt
    ],
    :System => [:currentTimeMillis],
    :Boolean => ["parseBoolean"],
    :Double => ["parseDouble", :POSITIVE_INFINITY, :NEGATIVE_INFINITY, :NaN],
    :Float => ["parseFloat"],
    :Integer => ["parseInt"],
    :Long => ["parseLong"],
    :LocalDate => [:parse],
    :"java.time.LocalDate" => [:parse],
    :Instant => [:parse],
    :"java.time.Instant" => [:parse],
    :Duration => [:between],
    :"java.time.Duration" => [:between]
  }

  test "the checked-in manifest validates with one route per overload" do
    assert :ok = validate(Surface.manifest())
    assert Enum.all?(Surface.overloads(), &match?({:dispatch, _}, &1.route))
    assert length(Surface.overloads()) == 56

    assert %{route: {:dispatch, :boolean_parse_boolean}} =
             Enum.find(Surface.overloads(), &(&1.overload_id == :boolean_parse_boolean_string))
  end

  test "namespace projection contains only admitted Java references" do
    expected_categories =
      Map.new(@namespace_members, fn
        {:Math, _members} -> {:Math, :math}
        {namespace, _members} -> {namespace, :interop}
      end)

    assert Surface.namespace_categories() == expected_categories

    for {namespace, members} <- @namespace_members do
      assert Surface.namespace_members(namespace) == members
      assert Registry.builtins_by_namespace(namespace) == members

      for member <- members do
        assert {:ok, %{reference_id: reference_id}} =
                 Surface.resolve_reference(namespace, member)

        assert is_atom(reference_id)
      end
    end
  end

  test "resolves constructor and direct-dot source spellings through closed dispatch" do
    assert {:ok, %{reference_id: :date_new, kind: :constructor}} =
             Surface.resolve_plain_reference(:"java.util.Date.")

    assert {:ok, :contains} = Surface.resolve_member_family(:".contains")

    assert Enum.any?(
             Surface.member_family_references(:contains),
             &(&1.reference_id == :string_contains)
           )

    for source <- ["(java.util.Date. 1)", ~S|(.contains text "x")|] do
      assert {:ok, raw} = Parser.parse(source)
      assert {:ok, core} = Analyze.analyze(raw)
      assert CoreToSource.format(core) == source
    end
  end

  test "registry Java projections come only from the validated surface" do
    assert Registry.implemented()
           |> Enum.filter(&(&1.category == :interop)) == Surface.function_entries()

    assert Registry.java_interop() == Surface.interop_entries()
    assert Registry.java_math_audit() == Surface.audit(:java_math_audit)

    for spec <- Surface.audit_specs() do
      assert Registry.java_audit_targets(spec.key) == Surface.audit_targets(spec.key)
    end

    stale_generic_entry =
      Surface.function_entries()
      |> hd()
      |> Map.put(:name, "stale-generic-java-entry")

    ordinary_entry = %{stale_generic_entry | name: "ordinary", category: :core}

    assert_raise ArgumentError, ~r/duplicate Java function metadata/, fn ->
      Surface.replace_function_entries([ordinary_entry, stale_generic_entry])
    end

    assert Surface.replace_function_entries([ordinary_entry]) ==
             [ordinary_entry | Surface.function_entries()]

    assert_raise ArgumentError, ~r/duplicate Java top-level metadata/, fn ->
      Surface.validate_authoritative_sources!(%{implemented: [], java_interop: []}, %{
        clojure_core_audit: [],
        clojure_string_audit: [],
        clojure_set_audit: [],
        clojure_walk_audit: []
      })
    end

    assert_raise ArgumentError, ~r/duplicate Java top-level metadata/, fn ->
      Surface.validate_authoritative_sources!(%{implemented: []}, %{
        clojure_core_audit: [],
        clojure_string_audit: [],
        clojure_set_audit: [],
        clojure_walk_audit: [],
        java_math_audit: []
      })
    end
  end

  test "supported audit targets resolve to an admitted reference and overload" do
    overload_ids = MapSet.new(Surface.overloads(), & &1.overload_id)

    for spec <- Surface.audit_specs(),
        target <- Surface.audit_targets(spec.key),
        target.status == :supported do
      assert {:ok, reference} = Surface.fetch_reference(target.reference_id)
      assert [_ | _] = reference.overload_ids
      assert Enum.all?(reference.overload_ids, &MapSet.member?(overload_ids, &1))
    end
  end

  test "every supported Java target has an explicit conformance case" do
    covered =
      Manual.all()
      |> Enum.reject(&(&1.policy == :unsupported))
      |> Enum.flat_map(fn case_data ->
        Enum.map(Map.get(case_data, :vars, []), &{case_data.namespace, &1})
      end)
      |> MapSet.new()

    for spec <- Surface.audit_specs(),
        target <- Surface.audit_targets(spec.key),
        target.status == :supported do
      symbol = Map.get(spec, :conformance_prefix, "") <> target.name

      assert MapSet.member?(covered, {spec.namespace, symbol}),
             "supported Java target #{spec.namespace}/#{symbol} has no explicit conformance case"
    end
  end

  test "validator rejects a dispatch route without a code-owned implementation" do
    manifest = Surface.manifest()
    [first | rest] = manifest.overloads
    invalid = %{manifest | overloads: [%{first | route: {:dispatch, :open_host_call}} | rest]}

    assert {:error, errors} = validate(invalid)

    assert Enum.any?(
             errors,
             &String.contains?(&1, "implementation :open_host_call does not exist")
           )
  end

  test "validator permits distinct closed implementations per overload" do
    manifest = Surface.manifest()
    reference = Enum.find(manifest.references, &(&1.reference_id == :boolean_parse_boolean))
    overload = Enum.find(manifest.overloads, &(&1.overload_id == :boolean_parse_boolean_string))

    second = %{
      overload
      | overload_id: :boolean_parse_boolean_second,
        route: {:dispatch, :missing_second_handler}
    }

    references =
      Enum.map(manifest.references, fn
        %{reference_id: :boolean_parse_boolean} = row ->
          %{row | overload_ids: reference.overload_ids ++ [second.overload_id]}

        row ->
          row
      end)

    assert {:error, errors} =
             validate(%{
               manifest
               | references: references,
                 overloads: manifest.overloads ++ [second]
             })

    assert Enum.any?(errors, &String.contains?(&1, "implementation :missing_second_handler"))
    refute Enum.any?(errors, &String.contains?(&1, "overload routes disagree"))
    refute Enum.any?(errors, &String.contains?(&1, "invalid reference routes"))
  end

  test "instance receiver profiles must belong to their Java class" do
    manifest = Surface.manifest()

    invalid =
      replace_overload(manifest, :string_length_0, &%{&1 | receiver: :date})

    assert {:error, errors} = validate(invalid)
    assert Enum.any?(errors, &String.contains?(&1, "class receiver profile"))
  end

  test "validator rejects migration-only routes and namespace metadata" do
    manifest = Surface.manifest()

    invalid_route =
      replace_overload(manifest, :string_contains_char_sequence, fn overload ->
        %{overload | route: {:legacy_env, :missing}}
      end)

    assert {:error, errors} = validate(invalid_route)
    assert Enum.any?(errors, &String.contains?(&1, "must use closed Java dispatch"))

    [math | namespaces] = manifest.namespaces

    members =
      Enum.map(math.members, fn member ->
        if member.source_name == :abs,
          do: Map.put(member, :legacy_binding, :abs),
          else: member
      end)

    invalid_namespace = %{
      manifest
      | namespaces: [
          %{math | members: members} | namespaces
        ]
    }

    assert {:error, errors} = validate(invalid_namespace)
    assert Enum.any?(errors, &String.contains?(&1, "cannot contain legacy binding metadata"))
  end

  test "validator rejects cross-class audit and presentation links" do
    manifest = Surface.manifest()
    [boolean_target | boolean_rows] = manifest.audits.java_lang_boolean_audit

    audits =
      Map.put(
        manifest.audits,
        :java_lang_boolean_audit,
        [%{boolean_target | reference_id: :date_get_time} | boolean_rows]
      )

    assert {:error, errors} = validate(%{manifest | audits: audits})
    assert Enum.any?(errors, &String.contains?(&1, "reference class"))

    date_entry = Enum.find(manifest.interop_entries, &(&1.class == "java.util.Date"))
    entries = List.delete(manifest.interop_entries, date_entry)
    invalid_entry = %{date_entry | reference_ids: [:math_abs]}

    assert {:error, errors} = validate(%{manifest | interop_entries: [invalid_entry | entries]})
    assert Enum.any?(errors, &String.contains?(&1, "interop entry"))

    invalid_class = %{date_entry | class: "java.time.Instant"}

    assert {:error, errors} = validate(%{manifest | interop_entries: [invalid_class | entries]})
    assert Enum.any?(errors, &String.contains?(&1, "class must be"))
  end

  test "validator rejects duplicate Java member spellings within one class" do
    manifest = Surface.manifest()
    reference = Enum.find(manifest.references, &(&1.reference_id == :string_length))
    overload = Enum.find(manifest.overloads, &(&1.overload_id == :string_length_0))

    duplicate_reference = %{
      reference
      | reference_id: :duplicate_string_length,
        overload_ids: [:duplicate_string_length_0]
    }

    duplicate_overload = %{
      overload
      | overload_id: :duplicate_string_length_0,
        reference_id: :duplicate_string_length
    }

    add_duplicate = fn entries ->
      replace_entry(entries, ".length", fn entry ->
        %{entry | reference_ids: entry.reference_ids ++ [:duplicate_string_length]}
      end)
    end

    invalid = %{
      manifest
      | references: manifest.references ++ [duplicate_reference],
        overloads: manifest.overloads ++ [duplicate_overload],
        function_entries: add_duplicate.(manifest.function_entries),
        interop_entries: add_duplicate.(manifest.interop_entries)
    }

    assert {:error, errors} = validate(invalid)
    assert Enum.any?(errors, &String.contains?(&1, "duplicate Java member spelling"))
  end

  test "validator rejects duplicate Java member identities hidden behind different spellings" do
    manifest = Surface.manifest()
    reference = Enum.find(manifest.references, &(&1.reference_id == :string_length))
    overload = Enum.find(manifest.overloads, &(&1.overload_id == :string_length_0))

    duplicate_reference = %{
      reference
      | reference_id: :string_length_alias,
        spellings: [".len"],
        overload_ids: [:string_length_alias_0]
    }

    duplicate_overload = %{
      overload
      | overload_id: :string_length_alias_0,
        reference_id: :string_length_alias
    }

    function_entries =
      replace_entry(manifest.function_entries, ".length", fn entry ->
        %{entry | reference_ids: entry.reference_ids ++ [:string_length_alias]}
      end)

    invalid = %{
      manifest
      | references: manifest.references ++ [duplicate_reference],
        overloads: manifest.overloads ++ [duplicate_overload],
        function_entries: function_entries
    }

    assert {:error, errors} = validate(invalid)
    assert Enum.any?(errors, &String.contains?(&1, "duplicate Java member identity"))
  end

  test "validator rejects admitted references omitted from audit and documentation policy" do
    manifest = Surface.manifest()
    reference = Enum.find(manifest.references, &(&1.reference_id == :string_length))
    overload = Enum.find(manifest.overloads, &(&1.overload_id == :string_length_0))

    undocumented_reference = %{
      reference
      | reference_id: :string_is_empty,
        member: "isEmpty",
        spellings: [".isEmpty"],
        overload_ids: [:string_is_empty_0]
    }

    undocumented_overload = %{
      overload
      | overload_id: :string_is_empty_0,
        reference_id: :string_is_empty,
        descriptor: "()Z",
        return: :boolean
    }

    function_entries =
      replace_entry(manifest.function_entries, ".length", fn entry ->
        %{entry | reference_ids: entry.reference_ids ++ [:string_is_empty]}
      end)

    invalid = %{
      manifest
      | references: manifest.references ++ [undocumented_reference],
        overloads: manifest.overloads ++ [undocumented_overload],
        function_entries: function_entries
    }

    assert {:error, errors} = validate(invalid)
    assert Enum.any?(errors, &String.contains?(&1, "audit reference coverage"))
    assert Enum.any?(errors, &String.contains?(&1, "interop reference coverage"))
  end

  test "validator rejects duplicate overload identities hidden behind different IDs" do
    manifest = Surface.manifest()
    overload = Enum.find(manifest.overloads, &(&1.overload_id == :math_abs_int))
    duplicate = %{overload | overload_id: :math_abs_int_duplicate}

    references =
      Enum.map(manifest.references, fn reference ->
        if reference.reference_id == :math_abs do
          %{reference | overload_ids: reference.overload_ids ++ [:math_abs_int_duplicate]}
        else
          reference
        end
      end)

    invalid = %{
      manifest
      | references: references,
        overloads: manifest.overloads ++ [duplicate]
    }

    assert {:error, errors} = validate(invalid)
    assert Enum.any?(errors, &String.contains?(&1, "duplicate Java overload identity"))
  end

  test "validator requires every admitted spelling to have runtime and documentation coverage" do
    manifest = Surface.manifest()

    references =
      Enum.map(manifest.references, fn reference ->
        if reference.reference_id == :boolean_parse_boolean do
          %{reference | spellings: reference.spellings ++ ["Boolean/alsoParse"]}
        else
          reference
        end
      end)

    assert {:error, errors} = validate(%{manifest | references: references})
    assert Enum.any?(errors, &String.contains?(&1, "runtime spelling"))
    assert Enum.any?(errors, &String.contains?(&1, "interop presentation spelling"))

    interop_entries =
      replace_entry(manifest.interop_entries, "LocalDate/parse", fn entry ->
        %{entry | signatures: ["(LocalDate/parse date-string)", "(parse date-string)"]}
      end)

    assert {:error, errors} = validate(%{manifest | interop_entries: interop_entries})

    assert Enum.any?(errors, fn error ->
             String.contains?(error, "interop presentation spelling") and
               String.contains?(error, "java.time.LocalDate/parse")
           end)
  end

  test "validator enforces JVM field, argument, array, object, and return descriptor grammar" do
    manifest = Surface.manifest()

    invalid_descriptors = [
      {:boolean_parse_boolean_string, "(V)Z"},
      {:double_positive_infinity_field, "V"},
      {:double_positive_infinity_field, "[V"},
      {:double_positive_infinity_field, "L;"},
      {:boolean_parse_boolean_string, "(Ljava/lang/String;)VV"}
    ]

    for {overload_id, descriptor} <- invalid_descriptors do
      invalid = replace_overload(manifest, overload_id, &%{&1 | descriptor: descriptor})
      assert {:error, errors} = validate(invalid)
      assert Enum.any?(errors, &String.contains?(&1, "descriptor"))
    end

    semantic_mismatches = [
      &%{&1 | descriptor: "(J)J"},
      &%{&1 | arguments: [:string]},
      &%{&1 | return: :double}
    ]

    for mutate <- semantic_mismatches do
      invalid = replace_overload(manifest, :math_abs_int, mutate)
      assert {:error, errors} = validate(invalid)
      assert Enum.any?(errors, &String.contains?(&1, "descriptor types"))
    end
  end

  test "validator enforces the declared Java error vocabulary" do
    invalid =
      replace_overload(Surface.manifest(), :double_parse_double_string, fn overload ->
        %{overload | errors: [:open_host_exception]}
      end)

    assert {:error, errors} = validate(invalid)
    assert Enum.any?(errors, &String.contains?(&1, "open_host_exception"))
  end

  test "callable metadata preserves current value-position Java behavior" do
    for reference <- Surface.references() do
      assert reference.callable? == (reference.kind != :field)
    end

    manifest = Surface.manifest()

    invalid_references =
      Enum.map(manifest.references, fn reference ->
        if reference.reference_id == :boolean_parse_boolean,
          do: %{reference | callable?: false},
          else: reference
      end)

    assert {:error, errors} = validate(%{manifest | references: invalid_references})
    assert Enum.any?(errors, &String.contains?(&1, "callable policy"))

    assert {:ok, %{return: [1.5, 2.5]}} =
             Lisp.run(~S|(map Double/parseDouble ["1.5" "2.5"])|)

    assert {:ok, %{return: [1, 2]}} = Lisp.run(~S|(map .length ["a" "bb"])|)
  end

  test "presentation signatures and function binding kinds match linked overloads" do
    manifest = Surface.manifest()
    [date_entry | interop_entries] = manifest.interop_entries
    invalid_interop = %{date_entry | signatures: ["(java.util.Date. a b)"]}

    assert {:error, errors} =
             validate(%{manifest | interop_entries: [invalid_interop | interop_entries]})

    assert Enum.any?(errors, &String.contains?(&1, "signature arities"))

    duration_index = Enum.find_index(manifest.function_entries, &(&1.name == "Duration/between"))
    duration = Enum.at(manifest.function_entries, duration_index)
    invalid_duration = %{duration | signatures: ["(Duration/between start)"]}

    invalid_functions =
      List.replace_at(manifest.function_entries, duration_index, invalid_duration)

    assert {:error, errors} = validate(%{manifest | function_entries: invalid_functions})
    assert Enum.any?(errors, &String.contains?(&1, "signature arities"))

    wrong_kind = %{duration | binding: :multi_arity}
    invalid_functions = List.replace_at(manifest.function_entries, duration_index, wrong_kind)

    assert {:error, errors} = validate(%{manifest | function_entries: invalid_functions})
    assert Enum.any?(errors, &String.contains?(&1, "binding kind"))

    local_date_index =
      Enum.find_index(manifest.interop_entries, &(&1.name == "LocalDate/parse"))

    local_date = Enum.at(manifest.interop_entries, local_date_index)

    invalid_interop_entries =
      List.replace_at(manifest.interop_entries, local_date_index, %{
        local_date
        | signatures: ["(Bogus x)"]
      })

    assert {:error, errors} =
             validate(%{manifest | interop_entries: invalid_interop_entries})

    assert Enum.any?(errors, &String.contains?(&1, "signature head"))
  end

  test "interop presentation kinds match their linked Java reference kinds" do
    manifest = Surface.manifest()

    invalid_entries =
      replace_entry(manifest.interop_entries, "Boolean/parseBoolean", fn entry ->
        %{entry | kind: :constructor}
      end)

    assert {:error, errors} = validate(%{manifest | interop_entries: invalid_entries})
    assert Enum.any?(errors, &String.contains?(&1, "presentation kind"))
  end

  test "constructor references use the JVM constructor member name" do
    manifest = Surface.manifest()

    references =
      Enum.map(manifest.references, fn reference ->
        if reference.reference_id == :date_new,
          do: %{reference | member: "not-init"},
          else: reference
      end)

    assert {:error, errors} = validate(%{manifest | references: references})
    assert Enum.any?(errors, &String.contains?(&1, "constructor member"))
  end

  test "validator reports malformed manifest fields instead of raising" do
    manifest = Surface.manifest()
    [function | functions] = manifest.function_entries
    [reference | references] = manifest.references
    [class | classes] = manifest.classes

    malformed_manifests = [
      %{manifest | function_entries: [Map.delete(function, :name) | functions]},
      %{manifest | function_entries: [%{function | examples: [1]} | functions]},
      %{manifest | audits: []},
      %{manifest | classes: [Map.delete(class, :receiver_profile) | classes]},
      %{manifest | references: [Map.delete(reference, :spellings) | references]},
      %{
        manifest
        | references: [
            %{reference | kind: :bogus}
            | references
          ]
      },
      replace_overload(manifest, :math_abs_int, &%{&1 | reference_id: :missing}),
      replace_overload(manifest, :math_abs_int, &%{&1 | arguments: :bad}),
      replace_overload(manifest, :math_abs_int, &Map.delete(&1, :divergence_ids)),
      replace_overload(manifest, :math_abs_int, &%{&1 | divergence_ids: %{}})
    ]

    for malformed <- malformed_manifests do
      assert {:error, errors} = validate(malformed)
      assert [_ | _] = errors
    end
  end

  test "stable manifest IDs and links must be non-nil atoms" do
    manifest = Surface.manifest()
    [class | classes] = manifest.classes

    nil_class_id =
      manifest
      |> Map.put(:classes, [%{class | class_id: nil} | classes])
      |> Map.update!(:references, fn references ->
        Enum.map(references, fn reference ->
          if reference.class_id == class.class_id,
            do: %{reference | class_id: nil},
            else: reference
        end)
      end)
      |> Map.update!(:audit_specs, fn specs ->
        Enum.map(specs, fn spec ->
          if spec.class_id == class.class_id, do: %{spec | class_id: nil}, else: spec
        end)
      end)
      |> Map.update!(:namespaces, fn namespaces ->
        Enum.map(namespaces, fn namespace ->
          if namespace.class_id == class.class_id,
            do: %{namespace | class_id: nil},
            else: namespace
        end)
      end)

    assert {:error, errors} = validate(nil_class_id)
    assert Enum.any?(errors, &String.contains?(&1, "class_id must be a non-nil atom"))

    reference_id = :boolean_parse_boolean
    invalid_reference_id = "boolean_parse_boolean"

    string_reference_id =
      manifest
      |> Map.update!(:references, fn references ->
        Enum.map(references, fn reference ->
          if reference.reference_id == reference_id,
            do: %{reference | reference_id: invalid_reference_id},
            else: reference
        end)
      end)
      |> replace_reference_links(reference_id, invalid_reference_id)

    assert {:error, errors} = validate(string_reference_id)
    assert Enum.any?(errors, &String.contains?(&1, "reference_id must be a non-nil atom"))

    [audit_spec | audit_specs] = manifest.audit_specs
    audit_rows = Map.fetch!(manifest.audits, audit_spec.key)
    invalid_audit_key = Atom.to_string(audit_spec.key)

    string_audit_key = %{
      manifest
      | audit_specs: [%{audit_spec | key: invalid_audit_key} | audit_specs],
        audits:
          manifest.audits
          |> Map.delete(audit_spec.key)
          |> Map.put(invalid_audit_key, audit_rows)
    }

    assert {:error, errors} = validate(string_audit_key)
    assert Enum.any?(errors, &String.contains?(&1, "key must be a non-nil atom"))

    [target | targets] = audit_rows

    invalid_audits =
      Map.put(manifest.audits, audit_spec.key, [%{target | target_id: ""} | targets])

    assert {:error, errors} = validate(%{manifest | audits: invalid_audits})
    assert Enum.any?(errors, &String.contains?(&1, "target_id must be a non-nil atom"))
  end

  test "validator rejects invalid UTF-8 before semantic processing" do
    manifest = Surface.manifest()
    [function | functions] = manifest.function_entries

    invalid_name = %{manifest | function_entries: [%{function | name: <<255>>} | functions]}

    assert {:error, errors} = validate(invalid_name)
    assert Enum.any?(errors, &String.contains?(&1, "valid UTF-8"))

    invalid_example = %{
      manifest
      | function_entries: [%{function | examples: [{<<255>>, "result"}]} | functions]
    }

    assert {:error, errors} = validate(invalid_example)
    assert Enum.any?(errors, &String.contains?(&1, "valid UTF-8"))
  end

  test "classification cannot disable JVM descriptor or divergence attestation" do
    manifest = Surface.manifest()

    downgraded_exact =
      replace_overload(manifest, :boolean_parse_boolean_string, fn overload ->
        %{overload | classification: :intentional_ptc_alias}
      end)

    assert {:error, errors} = validate(downgraded_exact)
    assert Enum.any?(errors, &String.contains?(&1, "attestation disagree"))

    coordinated_downgrade =
      replace_overload(manifest, :double_parse_double_string, fn overload ->
        %{
          overload
          | classification: :intentional_ptc_alias,
            attestation: :ptc_only,
            descriptor: nil
        }
      end)

    assert {:error, errors} = validate(coordinated_downgrade)
    assert Enum.any?(errors, &String.contains?(&1, "JVM descriptor coverage"))
  end

  test "overload divergence IDs are durable and linked to audit rationale" do
    manifest = Surface.manifest()

    invalid =
      replace_overload(manifest, :double_parse_double_string, fn overload ->
        %{overload | divergence_ids: ["GAP-J999"]}
      end)

    assert {:error, errors} = validate(invalid)
    assert Enum.any?(errors, &String.contains?(&1, "audit rationale"))

    removed_known_divergence =
      replace_overload(manifest, :date_new_string, fn overload ->
        %{overload | divergence_ids: []}
      end)

    assert {:error, errors} = validate(removed_known_divergence)
    assert Enum.any?(errors, &String.contains?(&1, "divergence coverage"))

    removed_secondary_divergence =
      replace_overload(manifest, :string_contains_char_sequence, fn overload ->
        %{overload | divergence_ids: ["DIV-40"]}
      end)

    assert {:error, errors} = validate(removed_secondary_divergence)
    assert Enum.any?(errors, &String.contains?(&1, "divergence coverage"))

    [boolean_target | boolean_rows] = manifest.audits.java_lang_boolean_audit

    contradictory_target = %{
      boolean_target
      | target_id: :duplicate_boolean_target,
        admitted_overload_divergences: %{
          boolean_parse_boolean_string: ["GAP-J999"]
        },
        notes: boolean_target.notes <> " GAP-J999"
    }

    for rows <- [
          [contradictory_target, boolean_target | boolean_rows],
          [boolean_target, contradictory_target | boolean_rows]
        ] do
      invalid_audits = Map.put(manifest.audits, :java_lang_boolean_audit, rows)
      assert {:error, errors} = validate(%{manifest | audits: invalid_audits})
      assert Enum.any?(errors, &String.contains?(&1, "supported audit reference"))
    end

    documented_ids =
      ~r/(?:GAP-[A-Z]\d+|DIV-\d+)/
      |> Regex.scan(File.read!("docs/clojure-conformance-gaps.md"), capture: :first)
      |> List.flatten()
      |> MapSet.new()

    for overload <- manifest.overloads, divergence_id <- overload.divergence_ids do
      assert MapSet.member?(documented_ids, divergence_id),
             "#{overload.overload_id} references undocumented #{divergence_id}"
    end
  end

  test "upstream audit includes exact JVM overload descriptors" do
    checks = MapSet.new(AuditUpstream.java_checks())
    references = Map.new(Surface.references(), &{&1.reference_id, &1})
    classes = Map.new(Surface.classes(), &{&1.class_id, &1})

    for overload <- Surface.overloads(), overload.attestation == :jvm do
      reference = Map.fetch!(references, overload.reference_id)
      class = Map.fetch!(classes, reference.class_id)

      assert MapSet.member?(checks, {
               class.name,
               reference.kind,
               reference.member,
               overload.descriptor,
               Atom.to_string(overload.overload_id)
             })
    end
  end

  @tag :tmp_dir
  test "precommit's shared quality gate discovers generated Java audit orphans recursively", %{
    tmp_dir: dir
  } do
    precommit = Mix.Project.config() |> Keyword.fetch!(:aliases) |> Keyword.fetch!(:precommit)
    quality_gate = File.read!("scripts/ci/core-quality.sh")

    assert "cmd scripts/ci/core-quality.sh" in precommit
    assert quality_gate =~ "mix ptc.gen_docs --check"
    assert quality_gate =~ "mix ptc.conformance_report --check-inventory"

    current = Path.join(dir, "docs/conformance/current.md")
    orphan = Path.join(dir, "docs/conformance/nested/orphan.md")
    unrelated = Path.join(dir, "docs/conformance/unrelated.md")

    File.mkdir_p!(Path.dirname(orphan))

    File.write!(
      current,
      "<!-- Auto-generated — do not edit by hand -->\nfrom `priv/java_interop.exs`\n"
    )

    File.write!(
      orphan,
      "<!-- Auto-generated — do not edit by hand -->\nfrom `priv/java_interop.exs`\n"
    )

    File.write!(
      unrelated,
      "<!-- Auto-generated — do not edit by hand -->\nfrom `priv/function_audit.exs`\n"
    )

    discovered = GenDocs.generated_java_audit_paths(dir)

    assert discovered == [current, orphan]

    assert GenDocs.java_audit_path_drift([current], discovered) == %{
             missing: [],
             orphaned: [orphan]
           }

    assert GenDocs.java_audit_path_drift(
             ["docs/conformance/java-audit.md"],
             ["docs/conformance/java-audit.md", "docs/conformance/orphaned-java-audit.md"]
           ) == %{
             missing: [],
             orphaned: ["docs/conformance/orphaned-java-audit.md"]
           }
  end

  test "upstream audit recognizes Java versions that can launch source files" do
    assert {:ok, 8} =
             AuditUpstream.java_major_version(
               ~s|java version "1.8.0_402"\nJava(TM) SE Runtime Environment|
             )

    assert {:ok, 11} =
             AuditUpstream.java_major_version(~s|openjdk version "11.0.24" 2024-07-16|)

    assert {:ok, 21} =
             AuditUpstream.java_major_version(~s|openjdk version "21.0.9" 2025-10-21 LTS|)

    assert :error = AuditUpstream.java_major_version("unknown runtime")
  end

  test "upstream audit allocates exclusive temporary probe directories" do
    directories = for _ <- 1..20, do: AuditUpstream.temporary_probe_directory()

    try do
      assert length(Enum.uniq(directories)) == length(directories)
      assert Enum.all?(directories, &File.dir?/1)
    after
      Enum.each(directories, &File.rm_rf!/1)
    end
  end

  test "interop documentation identifies class-owned temporal methods" do
    get_time = Enum.find(Surface.interop_entries(), &(&1.name == ".getTime"))
    is_before = Enum.find(Surface.interop_entries(), &(&1.name == ".isBefore"))
    is_after = Enum.find(Surface.interop_entries(), &(&1.name == ".isAfter"))

    assert get_time.notes == "Owned only by java.util.Date."
    assert is_before.notes =~ "LocalDate and Instant"
    assert is_after.notes =~ "LocalDate and Instant"
  end

  test "presentation rows cannot omit references from a shared Java spelling or route" do
    manifest = Surface.manifest()

    function_entries =
      replace_entry(manifest.function_entries, ".isBefore", fn entry ->
        %{entry | reference_ids: List.delete(entry.reference_ids, :instant_is_before)}
      end)

    interop_entries =
      replace_entry(manifest.interop_entries, ".isBefore", fn entry ->
        %{
          entry
          | reference_ids: List.delete(entry.reference_ids, :instant_is_before),
            class: "java.time.LocalDate / java.util.Date"
        }
      end)

    assert {:error, errors} =
             validate(%{
               manifest
               | function_entries: function_entries,
                 interop_entries: interop_entries
             })

    assert Enum.any?(errors, &String.contains?(&1, "reference coverage"))
  end

  test "validator covers documentation fields and see-also targets consumed by generators" do
    manifest = Surface.manifest()
    [audit_spec | audit_specs] = manifest.audit_specs

    assert {:error, errors} =
             validate(%{manifest | audit_specs: [Map.delete(audit_spec, :path) | audit_specs]})

    assert Enum.any?(errors, &String.contains?(&1, "is missing :path"))

    function_entries =
      replace_entry(manifest.function_entries, ".getTime", fn entry ->
        %{entry | see_also: ["does-not-exist"]}
      end)

    assert {:error, errors} = validate(%{manifest | function_entries: function_entries})
    assert Enum.any?(errors, &String.contains?(&1, "see_also target"))

    explicit_nil_prefix = %{audit_spec | conformance_prefix: nil}

    assert {:error, errors} =
             validate(%{manifest | audit_specs: [explicit_nil_prefix | audit_specs]})

    assert Enum.any?(errors, &String.contains?(&1, "conformance prefix"))
  end

  test "namespace categories are required and bounded" do
    manifest = Surface.manifest()
    [namespace | namespaces] = manifest.namespaces

    invalid_namespaces = [
      [Map.delete(namespace, :category) | namespaces],
      [%{namespace | category: :bogus} | namespaces]
    ]

    for invalid <- invalid_namespaces do
      assert {:error, errors} = validate(%{manifest | namespaces: invalid})
      assert Enum.any?(errors, &String.contains?(&1, "category"))
    end
  end

  test "Java namespaces cannot shadow protected or fixed non-Java namespaces" do
    manifest = Surface.manifest()

    for reserved <- [
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
        ] do
      classes =
        Enum.map(manifest.classes, fn class ->
          if class.class_id == :java_lang_math,
            do: %{class | spellings: class.spellings ++ [Atom.to_string(reserved)]},
            else: class
        end)

      namespace = %{
        namespace: reserved,
        class_id: :java_lang_math,
        category: :math,
        members: [
          %{
            source_name: :abs,
            reference_id: :math_abs
          }
        ]
      }

      assert {:error, errors} =
               validate(%{
                 manifest
                 | classes: classes,
                   namespaces: manifest.namespaces ++ [namespace]
               })

      assert Enum.any?(errors, &String.contains?(&1, "reserved non-Java namespace"))
    end
  end

  test "Java atom-named namespace members come from the manifest vocabulary" do
    assert :between in BuiltinNames.java_member_atoms()
    assert SourceAtoms.intern("between") == :between
  end

  defp validate(manifest), do: Validator.validate(manifest, BuiltinNames.env_names())

  defp replace_overload(manifest, overload_id, update) do
    overloads =
      Enum.map(manifest.overloads, fn overload ->
        if overload.overload_id == overload_id, do: update.(overload), else: overload
      end)

    %{manifest | overloads: overloads}
  end

  defp replace_entry(entries, name, update) do
    Enum.map(entries, fn entry -> if entry.name == name, do: update.(entry), else: entry end)
  end

  defp replace_reference_links(manifest, old_reference_id, new_reference_id) do
    replace = fn reference_id ->
      if reference_id == old_reference_id, do: new_reference_id, else: reference_id
    end

    namespaces =
      Enum.map(manifest.namespaces, fn namespace ->
        members =
          Enum.map(namespace.members, fn member ->
            %{member | reference_id: replace.(member.reference_id)}
          end)

        %{namespace | members: members}
      end)

    audits =
      Map.new(manifest.audits, fn {key, targets} ->
        {key,
         Enum.map(targets, fn target ->
           %{target | reference_id: replace.(target.reference_id)}
         end)}
      end)

    replace_entries = fn entries ->
      Enum.map(entries, fn entry ->
        %{entry | reference_ids: Enum.map(entry.reference_ids, replace)}
      end)
    end

    %{
      manifest
      | overloads:
          Enum.map(manifest.overloads, fn overload ->
            %{overload | reference_id: replace.(overload.reference_id)}
          end),
        namespaces: namespaces,
        audits: audits,
        function_entries: replace_entries.(manifest.function_entries),
        interop_entries: replace_entries.(manifest.interop_entries)
    }
  end
end
