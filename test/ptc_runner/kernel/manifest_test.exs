defmodule PtcRunner.Kernel.ManifestTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ApplicationSource
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.Manifest
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.ValueContract
  alias PtcRunner.Lisp.Format

  @input_schema %{"type" => "object", "additionalProperties" => true}

  @tag :tmp_dir
  test "one strict manifest deterministically builds and runs the shared Kernel path", %{
    tmp_dir: dir
  } do
    File.mkdir_p!(Path.join(dir, "workflow"))

    File.write!(
      Path.join(dir, "workflow/main.clj"),
      ~S|(ns workflow.main) (defn run [input] (return (get input "value")))|
    )

    File.write!(Path.join(dir, "input.json"), Jason.encode!(%{"value" => 42}))
    File.ln_s!("main.clj", Path.join(dir, "workflow/link.clj"))

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "workflow.main", "path" => "workflow/link.clj"}],
        "entry" => "workflow.main/run"
      },
      "input" => %{"path" => "input.json"},
      "events" => %{"policy" => "normal", "run_id" => "manifest-run"}
    }

    path = Path.join(dir, "ptc.json")
    File.write!(path, Jason.encode!(manifest))
    linked_path = Path.join(dir, "linked.json")
    File.ln_s!("ptc.json", linked_path)
    {:ok, registry} = ProviderRegistry.new()

    assert {:ok, first} = RunBuilder.load_and_build(linked_path, registry)
    assert {:ok, second} = RunBuilder.load_and_build(path, registry)
    assert first.entry_source == "(workflow.main/run data/input)"

    assert first.config.workflow_environment.bundle.hash ==
             second.config.workflow_environment.bundle.hash

    assert {:ok, %{value: 42}} = RunBuilder.run(path, registry)
  end

  @tag :tmp_dir
  test "one-shot manifest runs stop their owned event sink", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "main.clj"), "(ns main) (defn run [_] (return 42))")

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}},
      "events" => %{"run_id" => "owned-one-shot-sink"}
    }

    path = Path.join(dir, "owned.json")
    File.write!(path, Jason.encode!(manifest))
    {:ok, registry} = ProviderRegistry.new()

    assert {:ok, %{value: 42}} = RunBuilder.run(path, registry)
    assert event_sink_pids("owned-one-shot-sink") == []
  end

  @tag :tmp_dir
  test "manifest rejects unknown keys, duplicate JSON keys, versions, and path escape", %{
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, "source.clj"), "(ns safe) (defn run [_] (return 1))")
    outside = dir <> "-outside.clj"
    File.write!(outside, "(ns outside) (defn run [_] (return 1))")
    on_exit(fn -> File.rm(outside) end)

    base = fn path ->
      %{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "safe", "path" => path}],
          "entry" => "safe/run"
        },
        "input" => %{"value" => %{}}
      }
    end

    for manifest <- [
          Map.put(base.("source.clj"), "unknown", true),
          Map.put(base.("source.clj"), "version", 2),
          base.("../#{Path.basename(outside)}")
        ] do
      path = Path.join(dir, "invalid-#{System.unique_integer([:positive])}.json")
      File.write!(path, Jason.encode!(manifest))
      assert {:error, _reason} = Manifest.load(path)
    end

    duplicate =
      ~S|{"version":1,"version":1,"workflow":{"components":[],"entry":"safe/run"},"input":{"value":{}}}|

    duplicate_path = Path.join(dir, "duplicate.json")
    File.write!(duplicate_path, duplicate)

    assert {:error, {:manifest_path, [], :duplicate_json_key}} =
             Manifest.load(duplicate_path)
  end

  @tag :tmp_dir
  test "directory and memory manifests reject non-object JSON roots without raising", %{
    tmp_dir: dir
  } do
    for {name, raw} <- [{"array", "[]"}, {"null", "null"}, {"number", "1"}] do
      path = Path.join(dir, "#{name}.json")
      File.write!(path, raw)

      assert {:error, :invalid_manifest} = Manifest.load(path)

      assert {:error, :invalid_manifest} =
               Manifest.load_memory("#{name}.json", %{"#{name}.json" => raw})
    end
  end

  @tag :tmp_dir
  test "manifest contracts compile once and validate initial and overridden input before providers",
       %{tmp_dir: dir} do
    File.write!(Path.join(dir, "main.clj"), "(ns main) (defn run [input] (return input))")

    schema = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["question"],
      "properties" => %{"question" => %{"type" => "string", "maxLength" => 100}}
    }

    File.write!(Path.join(dir, "input.schema.json"), Jason.encode!(schema))
    File.write!(Path.join(dir, "valid.json"), Jason.encode!(%{"question" => "valid"}))
    File.write!(Path.join(dir, "invalid.json"), Jason.encode!(%{"other" => "invalid"}))

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{"question" => "initial"}},
      "contracts" => %{"input_schema" => %{"path" => "input.schema.json"}},
      "providers" => %{"workflow" => [%{"name" => "probe"}]}
    }

    path = Path.join(dir, "contracts.json")
    File.write!(path, Jason.encode!(manifest))
    parent = self()

    {:ok, registry} =
      ProviderRegistry.new(%{
        "probe" => fn _config, _context ->
          send(parent, :provider_prepared)

          Capability.new(
            name: "probe",
            input_schema: @input_schema,
            callback: fn _arguments -> {:ok, true} end
          )
        end
      })

    assert {:ok, loaded} = Manifest.load(path)
    assert %ValueContract{} = loaded.contracts.input
    assert nil == loaded.contracts.result

    assert {:error,
            {:source_role, :external_input,
             {:input_contract_failed, %{missing_required: ["question"]}}}} =
             RunBuilder.load_and_build(path, registry, input: "invalid.json")

    refute_receive :provider_prepared

    assert {:ok, built} = RunBuilder.load_and_build(path, registry, input: "valid.json")
    assert_receive :provider_prepared
    assert :ok = RunBuilder.close(built)

    invalid_initial = put_in(manifest, ["input", "value"], %{"other" => "invalid"})
    File.write!(path, Jason.encode!(invalid_initial))

    assert {:error, {:input_contract_failed, %{missing_required: ["question"]}}} =
             RunBuilder.load_and_build(path, registry)

    refute_receive :provider_prepared
  end

  @tag :tmp_dir
  test "contract files reject duplicate keys and remain manifest-confined", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "main.clj"), "(ns main) (defn run [input] (return input))")

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}},
      "contracts" => %{"input_schema" => %{"path" => "input.schema.json"}}
    }

    path = Path.join(dir, "contracts.json")
    File.write!(path, Jason.encode!(manifest))
    File.write!(Path.join(dir, "input.schema.json"), ~S|{"type":"object","type":"object"}|)

    assert {:error, {:source_role, :input_contract, "input.schema.json", :duplicate_json_key}} =
             Manifest.load(path)

    File.write!(
      Path.join(dir, "input.schema.json"),
      Jason.encode!(%{"type" => "object", "additionalProperties" => false})
    )

    escaped = put_in(manifest, ["contracts", "input_schema", "path"], "../input.schema.json")
    File.write!(path, Jason.encode!(escaped))

    assert {:error,
            {:manifest_path,
             [
               {:property, "contracts"},
               {:property, "input_schema"},
               {:property, "path"}
             ], :invalid_contract_reference}} = Manifest.load(path)
  end

  @tag :tmp_dir
  test "result contracts allow a tagged decision and fail closed after provider activity",
       %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [input] (do (tool/probe {}) (return input)))|
    )

    result_schema = %{
      "oneOf" => [
        %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["decision", "reason"],
          "properties" => %{
            "decision" => %{"type" => "string", "const" => "no-change"},
            "reason" => %{"type" => "string", "maxLength" => 100}
          }
        },
        %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["decision", "content"],
          "properties" => %{
            "decision" => %{"type" => "string", "const" => "propose-change"},
            "content" => %{"type" => "string", "maxLength" => 100}
          }
        }
      ]
    }

    File.write!(Path.join(dir, "result.schema.json"), Jason.encode!(result_schema))
    parent = self()

    {:ok, registry} =
      ProviderRegistry.new(%{
        "probe" => fn _config, _context ->
          Capability.new(
            name: "probe",
            input_schema: @input_schema,
            callback: fn _arguments ->
              send(parent, :provider_called)
              {:ok, true}
            end
          )
        end
      })

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{"decision" => "no-change", "reason" => "stable"}},
      "contracts" => %{"result_schema" => %{"path" => "result.schema.json"}},
      "providers" => %{"workflow" => [%{"name" => "probe"}]}
    }

    path = Path.join(dir, "contracts.json")
    File.write!(path, Jason.encode!(manifest))
    valid_output = Path.join(dir, "valid.json")

    assert {:ok, %{value: %{"decision" => "no-change"}}} =
             RunBuilder.run(path, registry, output: valid_output)

    assert_receive :provider_called
    assert %{"decision" => "no-change"} = valid_output |> File.read!() |> Jason.decode!()

    secret = "must-not-escape"
    invalid = put_in(manifest, ["input", "value"], %{"decision" => "unknown", "secret" => secret})
    File.write!(path, Jason.encode!(invalid))
    invalid_output = Path.join(dir, "invalid.json")
    trace = Path.join(dir, "invalid.jsonl")

    error = RunBuilder.run(path, registry, output: invalid_output, trace_path: trace)

    # The rejected value stays withheld, but the rejection now says enough to
    # act on: an operator learns the discriminator was unrecognised without
    # re-running the whole thing under private inspection.
    assert {:error,
            {:result_contract_failed,
             %{value_kind: :object, discriminator: "decision", matched_branch: nil} = details}} =
             error

    assert "no-change" in details.expected_branches

    assert_receive :provider_called
    assert File.exists?(trace)
    refute File.exists?(invalid_output)
    refute inspect(error) =~ secret
    refute inspect(error) =~ "unknown"
  end

  @tag :tmp_dir
  test "manifest result contracts and artifacts use quoted-symbol display strings", %{
    tmp_dir: dir
  } do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [_] (return {"ref" 'foo "nested" ['bar] 'key "quoted-key"}))|
    )

    result_schema = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["ref", "nested", "'key"],
      "properties" => %{
        "ref" => %{"type" => "string", "const" => "'foo"},
        "nested" => %{
          "type" => "array",
          "items" => %{"type" => "string", "const" => "'bar"}
        },
        "'key" => %{"type" => "string", "const" => "quoted-key"}
      }
    }

    File.write!(Path.join(dir, "result.schema.json"), Jason.encode!(result_schema))

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}},
      "contracts" => %{"result_schema" => %{"path" => "result.schema.json"}}
    }

    manifest_path = Path.join(dir, "ptc.json")
    output_path = Path.join(dir, "result.json")
    File.write!(manifest_path, Jason.encode!(manifest))
    {:ok, registry} = ProviderRegistry.new()

    assert {:ok,
            %{
              value: %{
                "ref" => %Format.SymbolRef{name: "foo"},
                "nested" => [%Format.SymbolRef{name: "bar"}],
                %Format.SymbolRef{name: "key"} => "quoted-key"
              }
            }} = RunBuilder.run(manifest_path, registry, output: output_path)

    assert Jason.decode!(File.read!(output_path)) == %{
             "ref" => "'foo",
             "nested" => ["'bar"],
             "'key" => "quoted-key"
           }
  end

  @tag :tmp_dir
  test "manifest runs reject quoted-symbol artifact key collisions before persistence", %{
    tmp_dir: dir
  } do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [_] (return {'foo 1 "'foo" 2}))|
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}}
    }

    manifest_path = Path.join(dir, "ptc.json")
    output_path = Path.join(dir, "result.json")
    File.write!(manifest_path, Jason.encode!(manifest))
    {:ok, registry} = ProviderRegistry.new()

    assert {:error, %{kind: :workflow_failed, reason: :public_projection_collision}} =
             RunBuilder.run(manifest_path, registry, output: output_path)

    refute File.exists?(output_path)
  end

  @tag :tmp_dir
  test "manifest labels accept only bounded safe metadata", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "main.clj"), "(ns main) (defn run [_] (return 1))")

    base = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}}
    }

    path = Path.join(dir, "labels.json")

    valid =
      Map.put(base, "labels", %{
        "name" => "safe-run",
        "model" => "provider:model-v1",
        "provider" => "provider",
        "tags" => %{"suite" => "privacy"}
      })

    File.write!(path, Jason.encode!(valid))
    assert {:ok, loaded} = Manifest.load(path)

    assert loaded.labels == %{
             "name" => SafeMetadata.fingerprint("safe-run"),
             "model" => SafeMetadata.fingerprint("provider:model-v1"),
             "provider" => SafeMetadata.fingerprint("provider"),
             "tags" => %{"suite" => "privacy"}
           }

    credential = "sk-secret"

    credential_labels =
      Map.put(base, "labels", %{"tags" => %{"credential" => credential}})

    File.write!(path, Jason.encode!(credential_labels))

    assert {:error,
            {:manifest_path, [{:property, "labels"}, {:property, "tags"}], :unknown_properties}} =
             Manifest.load(path)

    private = "PRIVATE GENERATED SOURCE (return 42)"
    File.write!(path, Jason.encode!(Map.put(base, "labels", %{"name" => private})))

    assert {:error,
            {:manifest_path, [{:property, "labels"}, {:property, "name"}], :invalid_manifest}} =
             Manifest.load(path)
  end

  @tag :tmp_dir
  test "inspection capture cannot be enabled by manifest data", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "main.clj"), "(ns main) (defn run [_] (return 1))")

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{"inspect" => "requested.inspection.jsonl"}},
      "inspect" => "requested.inspection.jsonl"
    }

    path = Path.join(dir, "inspection.json")
    File.write!(path, Jason.encode!(manifest))

    assert {:error, :unknown_properties} = Manifest.load(path)

    manifest = Map.delete(manifest, "inspect")
    File.write!(path, Jason.encode!(manifest))
    {:ok, registry} = ProviderRegistry.new()

    assert {:ok, %{value: 1}} = RunBuilder.run(path, registry)
    refute File.exists?(Path.join(dir, "requested.inspection.jsonl"))
  end

  @tag :tmp_dir
  test "manifest limits are narrowed independently from host-installed ceilings", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "main.clj"), "(ns main) (defn run [_] (return 1))")

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}},
      "limits" => %{"run_duration_ms" => 60_000, "evaluation_timeout_ms" => 20_000}
    }

    path = Path.join(dir, "limits.json")
    File.write!(path, Jason.encode!(manifest))

    assert {:ok, loaded} = Manifest.load(path)
    assert loaded.limits.run_duration_ms == 60_000
    assert loaded.limits.evaluation_timeout_ms == 20_000
    assert loaded.installed_limits == Limits.installed_defaults()

    for malformed_limits <- [
          Map.delete(Limits.installed_defaults(), :run_duration_ms),
          Map.put(Limits.installed_defaults(), :unexpected_limit, 1)
        ] do
      assert {:error, :invalid_manifest} = Manifest.load(path, malformed_limits)

      assert {:error, :invalid_manifest} =
               Manifest.load_memory(
                 "ptc.json",
                 %{
                   "ptc.json" => File.read!(path),
                   "main.clj" => "(ns main) (defn run [_] (return 1))"
                 },
                 malformed_limits
               )
    end

    {:ok, lower_ceiling} =
      Limits.new(run_duration_ms: 45_000, evaluation_timeout_ms: 500)

    assert {:error,
            {:manifest_path, [{:property, "limits"}, {:property, "evaluation_timeout_ms"}],
             :invalid_limits}} = Manifest.load(path, lower_ceiling)

    manifest = put_in(manifest, ["limits"], %{})
    File.write!(path, Jason.encode!(manifest))
    assert {:ok, lowered_defaults} = Manifest.load(path, lower_ceiling)
    assert lowered_defaults.limits.run_duration_ms == 30_000
    assert lowered_defaults.limits.evaluation_timeout_ms == 500
  end

  @tag :tmp_dir
  test "manifest selects the shipped agent.core dependency closure without source copies", %{
    tmp_dir: dir
  } do
    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"library" => "agent.main"}],
        "entry" => "agent.main/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{"workflow" => [%{"name" => "fixture"}]}
    }

    path = Path.join(dir, "installed-agent.json")
    File.write!(path, Jason.encode!(manifest))

    builder = fn _config, _context ->
      Capability.new(
        name: "llm-request",
        input_schema: @input_schema,
        callback: fn _request -> {:error, ProviderError.new(:unavailable)} end
      )
    end

    {:ok, registry} = ProviderRegistry.new(%{"fixture" => builder})
    assert {:ok, built} = RunBuilder.load_and_build(path, registry)

    assert built.config.workflow_environment.bundle.component_ids == [
             "agent.feedback",
             "agent.native",
             "agent.retry",
             "kernel",
             "agent.prompt",
             "llm",
             "result",
             "workflow.event",
             "agent.core",
             "agent.main"
           ]
  end

  @tag :tmp_dir
  test "manifest component union rejects duplicates, collisions, and ambiguous entries", %{
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, "kernel.clj"), "(ns local.kernel)")

    base = %{
      "version" => 1,
      "workflow" => %{"components" => [], "entry" => "agent.core/run"},
      "input" => %{"value" => %{}}
    }

    invalid_component_lists = [
      [%{"library" => "agent.core"}, %{"library" => "agent.core"}],
      [%{"library" => "missing"}],
      [%{"library" => "kernel"}, %{"id" => "kernel", "path" => "kernel.clj"}],
      [%{"library" => "kernel", "path" => "kernel.clj"}],
      [%{"id" => "kernel", "path" => "kernel.clj", "extra" => true}]
    ]

    for {components, index} <- Enum.with_index(invalid_component_lists) do
      manifest = put_in(base, ["workflow", "components"], components)
      path = Path.join(dir, "invalid-components-#{index}.json")
      File.write!(path, Jason.encode!(manifest))
      assert {:error, _reason} = Manifest.load(path)
    end
  end

  @tag :tmp_dir
  test "manifest schema annotation is inert and the generated schema is closed", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "main.clj"), "(ns main) (defn run [_] (return 1))")

    manifest = %{
      "$schema" => "./ptc-application-manifest.schema.json",
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}}
    }

    path = Path.join(dir, "schema.json")
    File.write!(path, Jason.encode!(manifest))
    assert {:ok, _loaded} = Manifest.load(path)

    root = JSV.build!(Manifest.schema(), atoms: false, formats: false, warnings: :silent)
    assert {:ok, _validated} = JSV.validate(manifest, root, cast: false)

    refute match?(
             {:ok, _validated},
             manifest
             |> Map.put("unknown", true)
             |> JSV.validate(root, cast: false)
           )

    refute match?(
             {:ok, _validated},
             manifest
             |> put_in(["workflow", "components", Access.at(0), "path"], "Main.clj")
             |> JSV.validate(root, cast: false)
           )

    for invalid_name <- ["main.clj\n", "main.clj\r\n"] do
      refute ApplicationSource.valid_name?(invalid_name)

      refute match?(
               {:ok, _validated},
               manifest
               |> put_in(["workflow", "components", Access.at(0), "path"], invalid_name)
               |> JSV.validate(root, cast: false)
             )
    end
  end

  @tag :tmp_dir
  test "provider registry rejects authority expansion and only calls host builders", %{
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, "main.clj"), "(ns main) (defn run [_] (return 1))")

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{
        "workflow" => [%{"name" => "evil", "config" => %{}}]
      }
    }

    path = Path.join(dir, "provider.json")
    File.write!(path, Jason.encode!(manifest))
    {:ok, registry} = ProviderRegistry.new()
    assert {:error, :unknown_provider} = RunBuilder.load_and_build(path, registry)

    assert {:ok, _explicit_registry} =
             ProviderRegistry.new(%{"llm" => fn _config, _context -> :ok end})

    parent = self()

    builder = fn config, context ->
      send(parent, {:provider_built, config, context.destination})

      Capability.new(
        name: "fixture",
        input_schema: @input_schema,
        callback: fn _arguments -> {:ok, true} end
      )
    end

    {:ok, custom_registry} = ProviderRegistry.new(%{"fixture" => builder})

    custom_manifest =
      put_in(manifest, ["providers", "workflow"], [
        %{"name" => "fixture", "config" => %{"mode" => "read"}}
      ])

    File.write!(path, Jason.encode!(custom_manifest))
    assert {:ok, _built} = RunBuilder.load_and_build(path, custom_registry)
    assert_receive {:provider_built, %{"mode" => "read"}, :workflow}

    denied_manifest =
      put_in(manifest, ["providers", "workflow"], [
        %{"name" => "file-read", "config" => %{"root" => "fixtures"}}
      ])

    File.write!(path, Jason.encode!(denied_manifest))
    assert {:error, :unknown_provider} = RunBuilder.load_and_build(path, registry)
  end

  defp event_sink_pids(run_id) do
    Enum.filter(Process.list(), fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} ->
          if dictionary[:"$initial_call"] == {PtcRunner.Kernel.EventSink, :init, 1} do
            try do
              :sys.get_state(pid, 10).run_id == run_id
            catch
              :exit, _reason -> false
            end
          else
            false
          end

        nil ->
          false
      end
    end)
  end
end
