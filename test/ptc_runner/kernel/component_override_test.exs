defmodule PtcRunner.Kernel.ComponentOverrideTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Covers the trusted component override: descriptor decoding, confinement, hash
  verification, and the guarantee that candidate source reaches only the
  override path.
  """

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.ComponentOverride
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.TestSupport.RunLifecycle

  setup do
    {:ok, base} = Library.component("agent.retry")
    {:ok, registry} = ProviderRegistry.new()
    %{base: base, registry: registry}
  end

  describe "descriptor verification" do
    @tag :tmp_dir
    test "a verified candidate replaces the installed component", context do
      paths = write_application(context, context.base)

      # Without the override the marker does not exist, so a passing run is
      # proof the candidate source compiled rather than the shipped source.
      assert {:error, _reason} =
               paths.manifest
               |> ApplicationPackage.request_directory(
                 installed_limits: context.registry.installed_limits
               )
               |> RunLifecycle.build(context.registry)
               |> RunLifecycle.execute()

      assert {:ok, result} =
               paths.manifest
               |> ApplicationPackage.request_directory(
                 installed_limits: context.registry.installed_limits,
                 component_override_descriptor: paths.descriptor
               )
               |> RunLifecycle.build(context.registry)
               |> RunLifecycle.execute()

      assert result.value == "candidate"
    end

    @tag :tmp_dir
    test "a candidate whose bytes do not match its hash is rejected", context do
      paths = write_application(context, context.base, source_hash: hash("something else"))

      assert {:error, {:source_role, :component_override, :override_source_hash_mismatch}} =
               paths.manifest
               |> ApplicationPackage.request_directory(
                 installed_limits: context.registry.installed_limits,
                 component_override_descriptor: paths.descriptor
               )
               |> RunLifecycle.build(context.registry)
               |> RunLifecycle.execute()
    end

    @tag :tmp_dir
    test "a candidate written against a since-changed base is rejected", context do
      paths = write_application(context, context.base, base_source_hash: hash("stale base"))

      assert {:error, {:source_role, :component_override, :override_base_hash_mismatch}} =
               paths.manifest
               |> ApplicationPackage.request_directory(
                 installed_limits: context.registry.installed_limits,
                 component_override_descriptor: paths.descriptor
               )
               |> RunLifecycle.build(context.registry)
               |> RunLifecycle.execute()
    end

    @tag :tmp_dir
    test "an override for a component the manifest never selected is rejected", context do
      paths = write_application(context, context.base, component_id: "agent.core")

      assert {:error, {:source_role, :component_override, :override_component_not_selected}} =
               paths.manifest
               |> ApplicationPackage.request_directory(
                 installed_limits: context.registry.installed_limits,
                 component_override_descriptor: paths.descriptor
               )
               |> RunLifecycle.build(context.registry)
               |> RunLifecycle.execute()
    end

    @tag :tmp_dir
    test "candidate source may not live outside the descriptor's directory", context do
      paths = write_application(context, context.base, path: "../escape.clj")
      File.write!(Path.join(Path.dirname(paths.descriptor), "../escape.clj"), "(ns escape)")

      assert {:error, {:source_role, :component_override, :invalid_override_source}} =
               paths.manifest
               |> ApplicationPackage.request_directory(
                 installed_limits: context.registry.installed_limits,
                 component_override_descriptor: paths.descriptor
               )
               |> RunLifecycle.build(context.registry)
               |> RunLifecycle.execute()
    end

    @tag :tmp_dir
    test "candidate source uses the portable logical-name grammar", context do
      paths = write_application(context, context.base, path: "Candidate.clj")
      File.write!(Path.join(Path.dirname(paths.descriptor), "Candidate.clj"), context.base.source)

      assert {:error, {:source_role, :component_override, :invalid_override_source}} =
               paths.manifest
               |> ApplicationPackage.request_directory(
                 installed_limits: context.registry.installed_limits,
                 component_override_descriptor: paths.descriptor
               )
               |> RunLifecycle.build(context.registry)
               |> RunLifecycle.execute()
    end

    @tag :tmp_dir
    test "cached candidate symlink may not escape the descriptor directory", context do
      paths = write_application(context, context.base)
      override_directory = Path.join(paths.dir, "overrides")
      File.mkdir_p!(override_directory)

      descriptor =
        paths.descriptor
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("path", "candidate.clj")

      descriptor_path = Path.join(override_directory, "override.json")
      File.write!(descriptor_path, Jason.encode!(descriptor))

      File.ln_s!(
        "../agent.retry.candidate.clj",
        Path.join(override_directory, "candidate.clj")
      )

      assert {:error, {:source_role, :component_override, :invalid_override_source}} =
               paths.manifest
               |> ApplicationPackage.request_directory(
                 installed_limits: context.registry.installed_limits,
                 component_override_descriptor: descriptor_path
               )
               |> RunLifecycle.build(context.registry)
               |> RunLifecycle.execute()
    end

    @tag :tmp_dir
    test "the descriptor accepts exactly the five documented fields", context do
      for {mutation, expected_path} <- [
            {%{"extra" => true}, []},
            {%{"component_id" => nil}, [{:property, "component_id"}]},
            {%{"base_source_hash" => "not-a-hash"}, [{:property, "base_source_hash"}]},
            {%{"source_hash" => "sha256:short"}, [{:property, "source_hash"}]},
            {%{"path" => 42}, [{:property, "path"}]}
          ] do
        paths = write_application(context, context.base, raw: mutation)

        assert {:error,
                {:source_role, :component_override,
                 {:component_override_path, ^expected_path, :invalid_override_descriptor}}} =
                 paths.manifest
                 |> ApplicationPackage.request_directory(
                   installed_limits: context.registry.installed_limits,
                   component_override_descriptor: paths.descriptor
                 )
                 |> RunLifecycle.build(context.registry)
                 |> RunLifecycle.execute(),
               "accepted #{inspect(mutation)}"
      end
    end

    @tag :tmp_dir
    test "a missing descriptor fails before the run rather than silently skipping", context do
      paths = write_application(context, context.base)

      assert {:error, {:source_role, :component_override, :invalid_override_descriptor}} =
               paths.manifest
               |> ApplicationPackage.request_directory(
                 installed_limits: context.registry.installed_limits,
                 component_override_descriptor: Path.join(paths.dir, "absent.json")
               )
               |> RunLifecycle.build(context.registry)
               |> RunLifecycle.execute()
    end
  end

  describe "run identity" do
    @tag :tmp_dir
    test "the verified override identity is bound into run-started metadata", context do
      paths = write_application(context, context.base)

      assert {:ok, built} =
               paths.manifest
               |> ApplicationPackage.request_directory(
                 installed_limits: context.registry.installed_limits,
                 component_override_descriptor: paths.descriptor
               )
               |> RunLifecycle.build(context.registry)

      # The effective bundle hash changes whenever source changes, but it
      # cannot say which component was overridden or what base the candidate
      # was verified against. Without this an evaluation artifact could not
      # distinguish a candidate trial from an ordinary run.
      assert [identity] = built.config.run_started_metadata.component_overrides

      assert identity == %{
               "target" => %{"environment" => "workflow"},
               "component_id" => "agent.retry",
               "base_source_hash" => hash(context.base.source),
               "source_hash" => hash(File.read!(paths.candidate))
             }

      refute inspect(built.config.run_started_metadata) =~ "candidate-marker"
      assert :ok = RunBuilder.close(built)
    end

    @tag :tmp_dir
    test "an ordinary run records no override", context do
      paths = write_application(context, context.base)
      File.write!(Path.join(paths.dir, "w.clj"), ~S|(ns app) (defn run [_i] (return 1))|)

      assert {:ok, built} =
               paths.manifest
               |> ApplicationPackage.request_directory(
                 installed_limits: context.registry.installed_limits
               )
               |> RunLifecycle.build(context.registry)

      refute Map.has_key?(built.config.run_started_metadata, :component_overrides)
      assert :ok = RunBuilder.close(built)
    end

    @tag :tmp_dir
    test "an explicit target replaces only that qualified occurrence", context do
      paths = write_application(context, context.base, both_environments: true)

      assert {:ok, built} =
               paths.manifest
               |> ApplicationPackage.request_directory(
                 installed_limits: context.registry.installed_limits,
                 component_override_descriptor: paths.descriptor
               )
               |> RunLifecycle.build(context.registry)

      assert [identity] = built.config.run_started_metadata.component_overrides
      assert identity["target"] == %{"environment" => "workflow"}
      assert :ok = RunBuilder.close(built)
    end
  end

  describe "candidate confinement" do
    @tag :tmp_dir
    test "replacing the source file after verification cannot substitute bytes", context do
      paths = write_application(context, context.base)

      assert {:ok, override} = ComponentOverride.load(paths.descriptor)

      # The bytes that were hashed are the bytes that were retained. Reopening
      # the path is the failure mode this guards, so rewriting it afterwards
      # must not affect what compiles.
      File.write!(paths.candidate, "(ns agent.retry) (defn candidate-marker [] :swapped)")

      assert override.source =~ "candidate-marker"
      refute override.source =~ ":swapped"

      {:ok, components, true} =
        ComponentOverride.apply([context.base], override)

      assert Enum.find(components, &(&1.id == "agent.retry")).source == override.source
    end

    @tag :tmp_dir
    test "an override preserves the installed component's declared dependencies", context do
      paths = write_application(context, context.base)
      {:ok, override} = ComponentOverride.load(paths.descriptor)

      {:ok, [replaced], true} = ComponentOverride.apply([context.base], override)

      assert replaced.dependencies == context.base.dependencies
      assert replaced.origin == "component-override"
    end

    @tag :tmp_dir
    test "candidate source never becomes mission data or workflow input", context do
      paths = write_application(context, context.base)

      assert {:ok, built} =
               paths.manifest
               |> ApplicationPackage.request_directory(
                 installed_limits: context.registry.installed_limits,
                 component_override_descriptor: paths.descriptor
               )
               |> RunLifecycle.build(context.registry)

      # The candidate reaches the bundle and nothing else: a generated program
      # must not be able to read the source under evaluation.
      refute inspect(built.config.input) =~ "candidate-marker"
      assert built.config.missions == %{}

      refute Enum.any?(built.config.missions, fn {_name, mission} ->
               inspect(mission.environment.data) =~ "candidate-marker"
             end)

      assert :ok = RunBuilder.close(built)
    end

    @tag :tmp_dir
    test "the safe identity carries hashes and never the candidate source", context do
      paths = write_application(context, context.base)
      {:ok, override} = ComponentOverride.load(paths.descriptor)

      identity = ComponentOverride.identity(override)

      assert Map.keys(identity) |> Enum.sort() ==
               ["base_source_hash", "component_id", "source_hash", "target"]

      refute inspect(identity) =~ "candidate-marker"
    end
  end

  describe "authoring provenance" do
    @tag :tmp_dir
    test "a promoted candidate names the run that authored it", context do
      paths = write_application(context, context.base, raw: %{"provenance" => provenance()})

      assert {:ok, request} =
               ApplicationPackage.request_directory(paths.manifest,
                 component_override_descriptor: paths.descriptor,
                 result_projection: :native
               )

      assert [attribution] = request.package.component_overrides

      # Without this a promoted component is anonymous source with a hash: the
      # artifact could not say which run, or which prompt, produced it.
      assert attribution["run_id"] == "run-2026-08-03-0001"
      assert attribution["prompt_hash"] == hash("authoring prompt")
      assert attribution["authored_at"] == "2026-08-03T09:15:00Z"
      assert attribution["accept_widened_effect"] == true
      assert attribution["target"] == %{"environment" => "workflow"}
    end

    @tag :tmp_dir
    test "provenance never enters content identity", context do
      without = write_application(context, context.base)

      with_provenance =
        write_application(
          Map.put(context, :tmp_dir, Path.join(context.tmp_dir, "provenanced")),
          context.base,
          raw: %{"provenance" => provenance()}
        )

      assert {:ok, plain} =
               ApplicationPackage.request_directory(without.manifest,
                 component_override_descriptor: without.descriptor,
                 result_projection: :native
               )

      assert {:ok, provenanced} =
               ApplicationPackage.request_directory(with_provenance.manifest,
                 component_override_descriptor: with_provenance.descriptor,
                 result_projection: :native
               )

      # Content identity must answer "what is this application", not "who says
      # they wrote it". An asserted timestamp or acceptance flag changing the
      # digest would make identity depend on an operator's claim.
      assert provenanced.package.application_content_digest ==
               plain.package.application_content_digest
    end

    @tag :tmp_dir
    test "an unknown provenance key is refused", context do
      paths =
        write_application(context, context.base,
          raw: %{"provenance" => Map.put(provenance(), "model_id", "some/model")}
        )

      assert {:error, {:source_role, :component_override, reason}} =
               paths.manifest
               |> ApplicationPackage.request_directory(
                 installed_limits: context.registry.installed_limits,
                 component_override_descriptor: paths.descriptor
               )
               |> RunLifecycle.build(context.registry)
               |> RunLifecycle.execute()

      assert {:component_override_path, [{:property, "provenance"}], :invalid_override_descriptor} =
               reason
    end

    @tag :tmp_dir
    test "a non-UTC authored_at is refused", context do
      paths =
        write_application(context, context.base,
          raw: %{
            "provenance" => Map.put(provenance(), "authored_at", "2026-08-03T09:15:00+02:00")
          }
        )

      assert {:error, {:source_role, :component_override, reason}} =
               paths.manifest
               |> ApplicationPackage.request_directory(
                 installed_limits: context.registry.installed_limits,
                 component_override_descriptor: paths.descriptor
               )
               |> RunLifecycle.build(context.registry)
               |> RunLifecycle.execute()

      assert {:component_override_path, [{:property, "provenance"}], :invalid_override_descriptor} =
               reason
    end

    @tag :tmp_dir
    test "a descriptor without provenance still loads", context do
      paths = write_application(context, context.base)

      assert {:ok, request} =
               ApplicationPackage.request_directory(paths.manifest,
                 component_override_descriptor: paths.descriptor,
                 result_projection: :native
               )

      assert [attribution] = request.package.component_overrides

      assert Map.keys(attribution) |> Enum.sort() ==
               ~w(base_source_hash component_id source_hash target)
    end
  end

  defp provenance do
    %{
      "run_id" => "run-2026-08-03-0001",
      "prompt_hash" => hash("authoring prompt"),
      "authored_at" => "2026-08-03T09:15:00Z",
      "accept_widened_effect" => true
    }
  end

  defp hash(source), do: ComponentOverride.hash(source)

  defp write_application(%{tmp_dir: dir, base: base}, _base, opts \\ []) do
    File.mkdir_p!(dir)
    candidate = base.source <> "\n(defn candidate-marker [] :candidate)\n"
    candidate_path = Path.join(dir, "agent.retry.candidate.clj")
    File.write!(candidate_path, candidate)

    descriptor =
      %{
        "target" => Keyword.get(opts, :target, %{"environment" => "workflow"}),
        "component_id" => Keyword.get(opts, :component_id, base.id),
        "base_source_hash" => Keyword.get(opts, :base_source_hash, hash(base.source)),
        "source_hash" => Keyword.get(opts, :source_hash, hash(candidate)),
        "path" => Keyword.get(opts, :path, "agent.retry.candidate.clj")
      }
      |> Map.merge(Keyword.get(opts, :raw, %{}))

    descriptor_path = Path.join(dir, "override.json")
    File.write!(descriptor_path, Jason.encode!(descriptor))

    File.write!(
      Path.join(dir, "w.clj"),
      ~S|(ns app) (defn run [_i] (return (agent.retry/candidate-marker)))|
    )

    mission =
      if Keyword.get(opts, :both_environments, false),
        do: %{
          "missions" => %{
            "default" => %{"components" => [%{"library" => "agent.retry"}], "data" => %{}}
          }
        },
        else: %{}

    manifest =
      Map.merge(
        %{
          "version" => 1,
          "workflow" => %{
            "components" => [
              %{"library" => "agent.retry"},
              %{"id" => "app", "path" => "w.clj", "dependencies" => ["agent.retry"]}
            ],
            "entry" => "app/run"
          },
          "input" => %{"value" => %{}},
          "limits" => %{"run_duration_ms" => 30_000}
        },
        mission
      )

    manifest_path = Path.join(dir, "ptc.json")
    File.write!(manifest_path, Jason.encode!(manifest))

    %{
      dir: dir,
      manifest: manifest_path,
      descriptor: descriptor_path,
      candidate: candidate_path
    }
  end
end
