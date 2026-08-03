defmodule PtcRunner.Kernel.ComponentOverrideTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Covers the trusted component override: descriptor decoding, confinement, hash
  verification, and the guarantee that candidate source reaches only the
  override path.
  """

  alias PtcRunner.Kernel.ComponentOverride
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunBuilder

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
      assert {:error, _reason} = RunBuilder.run(paths.manifest, context.registry)

      assert {:ok, result} =
               RunBuilder.run(paths.manifest, context.registry,
                 component_override_descriptor: paths.descriptor
               )

      assert result.value == "candidate"
    end

    @tag :tmp_dir
    test "a candidate whose bytes do not match its hash is rejected", context do
      paths = write_application(context, context.base, source_hash: hash("something else"))

      assert {:error, {:source_role, :component_override, :override_source_hash_mismatch}} =
               RunBuilder.run(paths.manifest, context.registry,
                 component_override_descriptor: paths.descriptor
               )
    end

    @tag :tmp_dir
    test "a candidate written against a since-changed base is rejected", context do
      paths = write_application(context, context.base, base_source_hash: hash("stale base"))

      assert {:error, {:source_role, :component_override, :override_base_hash_mismatch}} =
               RunBuilder.run(paths.manifest, context.registry,
                 component_override_descriptor: paths.descriptor
               )
    end

    @tag :tmp_dir
    test "an override for a component the manifest never selected is rejected", context do
      paths = write_application(context, context.base, component_id: "agent.core")

      assert {:error, {:source_role, :component_override, :override_component_not_selected}} =
               RunBuilder.run(paths.manifest, context.registry,
                 component_override_descriptor: paths.descriptor
               )
    end

    @tag :tmp_dir
    test "candidate source may not live outside the descriptor's directory", context do
      paths = write_application(context, context.base, path: "../escape.clj")
      File.write!(Path.join(Path.dirname(paths.descriptor), "../escape.clj"), "(ns escape)")

      assert {:error, {:source_role, :component_override, :invalid_override_source}} =
               RunBuilder.run(paths.manifest, context.registry,
                 component_override_descriptor: paths.descriptor
               )
    end

    @tag :tmp_dir
    test "candidate source uses the portable logical-name grammar", context do
      paths = write_application(context, context.base, path: "Candidate.clj")
      File.write!(Path.join(Path.dirname(paths.descriptor), "Candidate.clj"), context.base.source)

      assert {:error, {:source_role, :component_override, :invalid_override_source}} =
               RunBuilder.run(paths.manifest, context.registry,
                 component_override_descriptor: paths.descriptor
               )
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
               RunBuilder.run(paths.manifest, context.registry,
                 component_override_descriptor: descriptor_path
               )
    end

    @tag :tmp_dir
    test "the descriptor accepts exactly the four documented fields", context do
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
                 RunBuilder.run(paths.manifest, context.registry,
                   component_override_descriptor: paths.descriptor
                 ),
               "accepted #{inspect(mutation)}"
      end
    end

    @tag :tmp_dir
    test "a missing descriptor fails before the run rather than silently skipping", context do
      paths = write_application(context, context.base)

      assert {:error, {:source_role, :component_override, :invalid_override_descriptor}} =
               RunBuilder.run(paths.manifest, context.registry,
                 component_override_descriptor: Path.join(paths.dir, "absent.json")
               )
    end
  end

  describe "run identity" do
    @tag :tmp_dir
    test "the verified override identity is bound into run-started metadata", context do
      paths = write_application(context, context.base)

      assert {:ok, built} =
               RunBuilder.load_and_build(paths.manifest, context.registry,
                 component_override_descriptor: paths.descriptor
               )

      # The effective bundle hash changes whenever source changes, but it
      # cannot say which component was overridden or what base the candidate
      # was verified against. Without this an evaluation artifact could not
      # distinguish a candidate trial from an ordinary run.
      assert [identity] = built.config.run_started_metadata.component_overrides

      assert identity == %{
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

      assert {:ok, built} = RunBuilder.load_and_build(paths.manifest, context.registry)
      refute Map.has_key?(built.config.run_started_metadata, :component_overrides)
      assert :ok = RunBuilder.close(built)
    end

    @tag :tmp_dir
    test "one descriptor may not replace the same id in two environments", context do
      paths = write_application(context, context.base, both_environments: true)

      assert {:error, {:source_role, :component_override, :ambiguous_override_target}} =
               RunBuilder.load_and_build(paths.manifest, context.registry,
                 component_override_descriptor: paths.descriptor
               )
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
               RunBuilder.load_and_build(paths.manifest, context.registry,
                 component_override_descriptor: paths.descriptor
               )

      # The candidate reaches the bundle and nothing else: a generated program
      # must not be able to read the source under evaluation.
      refute inspect(built.config.input) =~ "candidate-marker"
      refute inspect(built.config.mission_environment.data) =~ "candidate-marker"

      assert :ok = RunBuilder.close(built)
    end

    @tag :tmp_dir
    test "the safe identity carries hashes and never the candidate source", context do
      paths = write_application(context, context.base)
      {:ok, override} = ComponentOverride.load(paths.descriptor)

      identity = ComponentOverride.identity(override)

      assert Map.keys(identity) |> Enum.sort() ==
               ["base_source_hash", "component_id", "source_hash"]

      refute inspect(identity) =~ "candidate-marker"
    end
  end

  defp hash(source), do: ComponentOverride.hash(source)

  defp write_application(%{tmp_dir: dir, base: base}, _base, opts \\ []) do
    File.mkdir_p!(dir)
    candidate = base.source <> "\n(defn candidate-marker [] :candidate)\n"
    candidate_path = Path.join(dir, "agent.retry.candidate.clj")
    File.write!(candidate_path, candidate)

    descriptor =
      %{
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
        do: %{"mission" => %{"components" => [%{"library" => "agent.retry"}], "data" => %{}}},
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
