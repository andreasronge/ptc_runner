defmodule PtcRunner.Kernel.ServingTemplateTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.EffectiveApplication
  alias PtcRunner.Kernel.ExecutionInput
  alias PtcRunner.Kernel.ExecutionPolicy
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.RunRequest
  alias PtcRunner.Kernel.ServingTemplate
  alias PtcRunner.Kernel.ValueContract

  @schema %{
    "type" => "object",
    "properties" => %{"answer" => %{"type" => "integer"}},
    "required" => ["answer"],
    "additionalProperties" => false
  }
  @source "(ns app) (defn run {:effect :read} [input] (return input))"

  @tag :tmp_dir
  test "captures compiled contracts and frozen policy without opening declared input", %{
    tmp_dir: dir
  } do
    path = fixture(dir)
    assert {:ok, template} = build(path)
    assert {:error, _reason} = ApplicationPackage.request_directory(path)
    assert {:ok, package, _input} = ApplicationPackage.acquire_directory(path, omit_input: true)
    assert ServingTemplate.input_schema(template) == package.contracts.input.schema
    assert ServingTemplate.output_schema(template) == package.contracts.result.schema
    assert ServingTemplate.effect(template) == :read
    assert ServingTemplate.installation_config_digests(template) == %{}

    assert ServingTemplate.policy(template) == %{
             input_authority_class: :normal,
             effective_event_policy: :normal,
             inspection_capture: false,
             result_projection: :json,
             publication: :artifact_free,
             deadline: :absolute_from_reservation
           }

    assert ServingTemplate.limits(template) == package.limits
    assert {:ok, encoded} = DeterministicJSON.encode(ServingTemplate.input_schema(template))
    assert Jason.decode!(encoded) == ServingTemplate.input_schema(template)
    refute owned?(template)
    refute inspect(template) =~ dir
    File.rm_rf!(dir)
    assert :ok = ServingTemplate.close(template)

    results =
      1..16
      |> Task.async_stream(fn _ ->
        assert ValueContract.valid?(template.package.contracts.input, %{"answer" => 1})
        refute ValueContract.valid?(template.package.contracts.input, %{"answer" => "bad"})
        assert :ok = ServingTemplate.close(template)
        DeterministicJSON.encode(ServingTemplate.input_schema(template))
      end)
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, {:ok, encoded}}))
    assert :ok = ServingTemplate.close(template)
  end

  @tag :tmp_dir
  test "content pin cannot be confused with existing effective identity", %{tmp_dir: dir} do
    path = fixture(dir)
    assert {:ok, template} = build(path)
    content = ServingTemplate.application_content_digest(template)
    effective = ServingTemplate.effective_application_digest(template)
    assert content =~ ~r/\Asha256:[0-9a-f]{64}\z/
    assert effective =~ ~r/\Asha256:[0-9a-f]{64}\z/
    refute content == effective
    assert {:ok, _template} = build(path, expected_application_content_digest: content)

    assert {:error, :application_content_digest_mismatch} =
             build(path, expected_application_content_digest: effective)

    assert {:error, :application_content_digest_mismatch} =
             build(path,
               expected_application_content_digest: "sha256:" <> String.duplicate("0", 64)
             )

    assert {:ok, input} = ExecutionInput.new(%{"answer" => 3}, :normal)
    assert {:ok, policy} = ExecutionPolicy.new(result_projection: :json)
    assert {:ok, request} = RunRequest.new(template.package, input, policy)
    bundles = Map.new(template.missions, fn {name, mission} -> {name, mission.bundle} end)

    assert {:ok, identity} =
             EffectiveApplication.build(
               request,
               template.workflow.bundle,
               bundles,
               %{workflow: [], mission: []},
               :normal
             )

    assert identity.digest == effective

    # Installed-only limits affect behavior, but never application content.
    {:ok, installed} = Limits.new(provider_cleanup_timeout_ms: 1_234)
    assert {:ok, changed} = ServingTemplate.from_directory(path, installed)
    assert ServingTemplate.application_content_digest(changed) == content
    refute ServingTemplate.effective_application_digest(changed) == effective
  end

  @tag :tmp_dir
  test "contracts, identities, providers and entry shape are rejected at the constructor", %{
    tmp_dir: dir
  } do
    for {change, code} <- [
          {%{"contracts" => %{}}, :contracts_required},
          {%{"contracts" => %{"input_schema" => %{"path" => "schema.json"}}},
           :contracts_required},
          {%{"events" => %{"run_id" => "owned"}}, :manifest_identity_forbidden},
          {%{"events" => %{"trace_id" => "owned"}}, :manifest_identity_forbidden},
          {%{"providers" => %{"workflow" => [%{"name" => "provider"}]}},
           :provider_runtime_required},
          {%{"providers" => %{"mission" => [%{"name" => "provider"}]}},
           :provider_runtime_required},
          {%{
             "workflow" => %{
               "components" => [%{"id" => "app", "path" => "workflow.clj"}],
               "entry" => "app/missing"
             }
           }, :entry_invalid},
          {%{"workflow" => %{"components" => [], "entry" => "app/run"}}, :entry_invalid},
          {%{"input" => %{"path" => 1}}, :invalid_application},
          {%{"input" => %{"path" => "missing.json", "value" => %{}}}, :invalid_application},
          {%{"input" => nil}, :invalid_application}
        ] do
      assert {:error, ^code} = build(fixture(dir, change))
    end

    for schema <- [
          %{"type" => "string"},
          %{"type" => "array"},
          %{"type" => "object", "$ref" => "private"}
        ] do
      path = fixture(dir)
      File.write!(Path.join(dir, "schema.json"), Jason.encode!(schema))
      assert {:error, :invalid_application} = build(path)
    end

    for source <- ["(ns app) (defn run {:effect :read} [] (return {}))", "(ns app) (def run 1)"] do
      assert {:error, :entry_invalid} = build(fixture(dir, %{}, source))
    end

    assert {:error, :compilation_failed} =
             build(fixture(dir, %{}, "(ns app) (defn run [input] missing)"))
  end

  @tag :tmp_dir
  test "the full declared and resolved entry matrix includes every selectable mission", %{
    tmp_dir: dir
  } do
    for declared <- [:read, :write, :unknown, nil], resolved <- [:read, :write, :unknown] do
      metadata = if declared, do: "{:effect :#{declared}}", else: ""
      workflow = "(ns app) (defn run #{metadata} [input] (return input))"
      mission = "(ns mission) (defn helper {:effect :#{resolved}} [x] x)"

      path =
        fixture(
          dir,
          %{
            "missions" => %{
              "worker" => %{"components" => [%{"id" => "mission", "path" => "mission.clj"}]}
            }
          },
          workflow
        )

      File.write!(Path.join(dir, "mission.clj"), mission)

      case {declared, resolved} do
        {:read, :read} -> assert {:ok, %{effect: :read}} = build(path)
        {:read, _} -> assert {:error, :declared_read_effect_violation} = build(path)
        {:write, _} -> assert {:ok, %{effect: :write}} = build(path)
        _ -> assert {:error, :effect_declaration_required} = build(path)
      end
    end
  end

  @tag :tmp_dir
  test "direct and transitive reserved routes resolve read and other invalid read exports reject",
       %{tmp_dir: dir} do
    source =
      "(ns app) (defn- helper [x] (tool/runtime-usage {})) (defn run {:effect :read} [x] (return (helper x)))"

    assert {:ok, %{effect: :read}} = build(fixture(dir, %{}, source))

    source =
      "(ns app) (defn helper {:effect :unknown} [x] x) (defn run {:effect :read} [x] (return (helper x)))"

    assert {:error, :declared_read_effect_violation} = build(fixture(dir, %{}, source))

    source =
      "(ns app) (defn helper {:effect :write} [x] x) (defn run {:effect :read} [x] (return (helper x)))"

    assert {:error, :declared_read_effect_violation} = build(fixture(dir, %{}, source))

    source =
      "(ns app) (defn helper {:effect :write} [x] x) (defn bad {:effect :read} [x] (helper x)) (defn run {:effect :write} [x] (return x))"

    assert {:error, :declared_read_effect_violation} = build(fixture(dir, %{}, source))
  end

  @tag :tmp_dir
  test "mission implicit inspection routes contribute their maintained read effects", %{
    tmp_dir: dir
  } do
    path =
      fixture(dir, %{
        "missions" => %{
          "worker" => %{"components" => [%{"id" => "mission", "path" => "mission.clj"}]}
        }
      })

    File.write!(
      Path.join(dir, "mission.clj"),
      "(ns mission) (defn helper {:effect :read} [x] (tool/runtime-usage {}))"
    )

    assert {:ok, %{effect: :read}} = build(path)
  end

  @tag :tmp_dir
  test "private events and narrowed limits are frozen without identities", %{tmp_dir: dir} do
    path =
      fixture(dir, %{
        "events" => %{"policy" => "private"},
        "limits" => %{"run_duration_ms" => 500}
      })

    assert {:ok, template} = build(path)
    assert ServingTemplate.policy(template).effective_event_policy == :private
    assert ServingTemplate.limits(template).run_duration_ms == 500
    assert template.package.events.run_id == nil
    assert template.package.events.trace_id == nil

    assert {:error, :invalid_application} =
             build(fixture(dir, %{"limits" => %{"run_duration_ms" => 9_999_999}}))
  end

  @tag :tmp_dir
  test "inline input is excluded and tagged object schemas retain their compiled normalization",
       %{tmp_dir: dir} do
    branch = fn tag ->
      %{
        "type" => "object",
        "properties" => %{"kind" => %{"type" => "string", "const" => tag}},
        "required" => ["kind"],
        "additionalProperties" => false
      }
    end

    schema = %{"oneOf" => [branch.("a"), branch.("b")], "title" => "Object alternatives"}
    path = fixture(dir, %{"input" => %{"value" => %{"wrong" => "not contract valid"}}})
    File.write!(Path.join(dir, "schema.json"), Jason.encode!(schema))
    assert {:ok, template} = build(path)
    assert {:error, _reason} = ApplicationPackage.request_directory(path)
    {:ok, compiled} = ValueContract.compile(schema)
    assert ServingTemplate.input_schema(template) == compiled.schema
    assert ServingTemplate.output_schema(template) == compiled.schema
    assert {:ok, encoded} = DeterministicJSON.encode(compiled.schema)
    assert {:ok, ^encoded} = DeterministicJSON.encode(ServingTemplate.input_schema(template))
    assert ValueContract.valid?(template.package.contracts.input, %{"kind" => "a"})
    refute ValueContract.valid?(template.package.contracts.input, %{"kind" => "c"})
    content = ServingTemplate.application_content_digest(template)
    path = fixture(dir, %{"input" => %{"path" => "missing.json"}})
    File.write!(Path.join(dir, "schema.json"), Jason.encode!(schema))
    assert {:ok, template} = build(path, expected_application_content_digest: content)
    File.write!(Path.join(dir, "missing.json"), Jason.encode!(%{"kind" => "b"}))
    assert {:ok, request} = ApplicationPackage.request_directory(path)
    assert request.input.value == %{"kind" => "b"}

    assert {:ok, _same} =
             build(path,
               expected_application_content_digest:
                 ServingTemplate.application_content_digest(template)
             )
  end

  test "closed pre-acquisition failures contain no private details" do
    path = "/private/nonexistent/payload"

    for opts <- [
          [unknown: true],
          [expected_application_content_digest: nil],
          [expected_application_content_digest: String.duplicate("a", 64)],
          [expected_application_content_digest: "sha256:" <> String.duplicate("A", 64)],
          [
            expected_application_content_digest: "sha256:" <> String.duplicate("a", 64),
            expected_application_content_digest: "sha256:" <> String.duplicate("a", 64)
          ],
          nil
        ] do
      assert {:error, :invalid_options} = build(path, opts)
    end

    assert {:error, :invalid_installed_limits} = ServingTemplate.from_directory(path, %{})
    assert {:error, :invalid_application} = build(path)
  end

  defp build(path, opts \\ []),
    do: ServingTemplate.from_directory(path, Limits.installed_defaults(), opts)

  defp fixture(dir, changes \\ %{}, source \\ @source) do
    File.mkdir_p!(dir)

    manifest =
      Map.merge(
        %{
          "version" => 1,
          "workflow" => %{
            "components" => [%{"id" => "app", "path" => "workflow.clj"}],
            "entry" => "app/run"
          },
          "input" => %{"path" => "missing.json"},
          "contracts" => %{
            "input_schema" => %{"path" => "schema.json"},
            "result_schema" => %{"path" => "schema.json"}
          }
        },
        changes
      )

    File.write!(Path.join(dir, "workflow.clj"), source)
    File.write!(Path.join(dir, "schema.json"), Jason.encode!(@schema))
    path = Path.join(dir, "app.json")
    File.write!(path, Jason.encode!(manifest))
    path
  end

  defp owned?(value)
       when is_pid(value) or is_reference(value) or is_function(value) or is_port(value), do: true

  defp owned?(%module{}) when module in [ExecutionInput, ExecutionPolicy], do: true
  defp owned?(map) when is_map(map), do: Enum.any?(Map.to_list(map), &owned?/1)
  defp owned?(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.any?(&owned?/1)
  defp owned?(list) when is_list(list), do: Enum.any?(list, &owned?/1)
  defp owned?(_value), do: false
end
