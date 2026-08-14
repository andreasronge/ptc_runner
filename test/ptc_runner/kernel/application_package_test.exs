defmodule PtcRunner.Kernel.ApplicationPackageTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.ApplicationSource
  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.ComponentOverride
  alias PtcRunner.Kernel.ExecutionInput
  alias PtcRunner.Kernel.ExecutionPolicy
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.RunRequest
  alias PtcRunner.Kernel.TypedCanonicalJSON
  alias PtcRunner.TestSupport.RunLifecycle
  alias PtcRunner.TestSupport.TestHelpers

  @source "(ns app) (defn run [input] (return input))"
  @schema ~S({"type":"object","properties":{"answer":{"type":"integer"}},"additionalProperties":false})

  test "concurrent first attestations share one secret" do
    owner = __MODULE__.ConcurrentAttestation
    storage_key = {Attestation, owner}
    previous = :persistent_term.get(storage_key, :missing)
    :persistent_term.erase(storage_key)

    on_exit(fn ->
      case previous do
        :missing -> :persistent_term.erase(storage_key)
        secret -> :persistent_term.put(storage_key, secret)
      end
    end)

    parent = self()
    payload = {:payload, 1}

    tasks =
      for _index <- 1..64 do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:attest -> Attestation.attest(owner, payload))
        end)
      end

    pids =
      for _index <- tasks do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(pids, &send(&1, :attest))
    attestations = Enum.map(tasks, &Task.await(&1, 30_000))

    assert Enum.all?(attestations, &Attestation.valid?(owner, payload, &1))
  end

  @tag :tmp_dir
  test "directory and memory adapters produce one path-free package and compiled bundle", %{
    tmp_dir: directory
  } do
    documents = fixture_documents()
    manifest_path = write_documents(directory, documents)

    assert {:ok, directory_request} =
             ApplicationPackage.request_directory(manifest_path, result_projection: :native)

    assert {:ok, memory_request} =
             ApplicationPackage.request_memory("app.json", documents, result_projection: :native)

    assert package_projection(directory_request.package) ==
             package_projection(memory_request.package)

    assert directory_request.package.application_content_digest ==
             "abe6d9622bbb77dd2ed6f66c6878b96e2a3b51daac35bf6beb62b3c99c2da9ee"

    assert directory_request.package.contract_behavior_hashes.input ==
             "7dfe6c77fe7a1360821e8848da675d1d869cc8fe5d7cf38313c749c40cc49ed3"

    assert directory_request.package.ptc_semantic_revision =~ ~r/\Asem1-[0-9a-f]{64}\z/

    refute Map.has_key?(Map.from_struct(directory_request.package), :directory)
    refute inspect(directory_request.package) =~ directory

    {:ok, registry} = ProviderRegistry.new()
    assert {:ok, directory_build} = RunBuilder.build(directory_request, registry)
    assert {:ok, memory_build} = RunBuilder.build(memory_request, registry)

    assert directory_build.config.workflow_environment.bundle.hash ==
             memory_build.config.workflow_environment.bundle.hash

    assert :ok = RunBuilder.close(directory_build)
    assert :ok = RunBuilder.close(memory_build)
  end

  @tag :tmp_dir
  test "directory manifest filenames are transport paths, not portable logical names", %{
    tmp_dir: directory
  } do
    documents = fixture_documents()
    baseline_path = write_documents(Path.join(directory, "baseline"), documents)

    assert {:ok, baseline} =
             ApplicationPackage.request_directory(baseline_path, result_projection: :native)

    for {filename, index} <-
          Enum.with_index([
            "_app.json",
            ".app.json",
            "-app.json",
            "Manifest.json",
            "manifest copy.json"
          ]) do
      manifest_path = write_documents(Path.join(directory, "variant-#{index}"), documents)
      renamed_path = Path.join(Path.dirname(manifest_path), filename)
      File.rename!(manifest_path, renamed_path)

      assert {:ok, request} =
               ApplicationPackage.request_directory(renamed_path, result_projection: :native)

      assert package_projection(request.package) == package_projection(baseline.package)
      assert request.input == baseline.input
    end
  end

  @tag :tmp_dir
  test "nested memory manifests resolve references like directory manifests", %{
    tmp_dir: directory
  } do
    documents = fixture_documents()
    nested_directory = Path.join([directory, "apps", "fixture"])
    manifest_path = write_documents(nested_directory, documents)

    memory_documents =
      Map.new(documents, fn {name, bytes} ->
        {Path.join(["apps", "fixture", name]), bytes}
      end)

    assert {:ok, directory_request} =
             ApplicationPackage.request_directory(manifest_path, result_projection: :native)

    assert {:ok, memory_request} =
             ApplicationPackage.request_memory(
               "apps/fixture/app.json",
               memory_documents,
               result_projection: :native
             )

    assert package_projection(directory_request.package) ==
             package_projection(memory_request.package)

    assert directory_request.input.value == memory_request.input.value
  end

  @tag :tmp_dir
  test "memory manifest transport prefixes do not consume logical-name depth", %{
    tmp_dir: directory
  } do
    prefix = Enum.map_join(1..15, "/", &"root#{&1}")

    documents = fixture_documents()
    manifest = documents |> Map.fetch!("app.json") |> Jason.decode!()

    documents =
      documents
      |> Map.put(
        "app.json",
        manifest
        |> put_in(["workflow", "components", Access.at(0), "path"], "nested/workflow.clj")
        |> Jason.encode!()
      )
      |> Map.put("nested/workflow.clj", Map.fetch!(documents, "workflow.clj"))
      |> Map.delete("workflow.clj")

    manifest_path = write_documents(Path.join(directory, prefix), documents)

    memory_documents =
      Map.new(documents, fn {name, bytes} ->
        {Path.join(prefix, name), bytes}
      end)

    assert {:ok, directory_request} =
             ApplicationPackage.request_directory(manifest_path, result_projection: :native)

    assert {:ok, memory_request} =
             ApplicationPackage.request_memory(
               Path.join(prefix, "app.json"),
               memory_documents,
               result_projection: :native
             )

    assert package_projection(directory_request.package) ==
             package_projection(memory_request.package)
  end

  test "input declaration form, logical name, and value do not enter content identity" do
    inline_a = fixture_documents(input: %{"value" => %{"answer" => 1}})
    inline_b = fixture_documents(input: %{"value" => %{"answer" => 2}})

    path_a =
      fixture_documents(input: %{"path" => "first.json"})
      |> Map.put("first.json", ~S({"answer":3}))

    path_b =
      fixture_documents(input: %{"path" => "renamed.json"})
      |> Map.put("renamed.json", ~S({"answer":4}))

    digests =
      for documents <- [inline_a, inline_b, path_a, path_b] do
        {:ok, request} =
          ApplicationPackage.request_memory("app.json", documents, result_projection: :native)

        request.package.application_content_digest
      end

    assert length(Enum.uniq(digests)) == 1
  end

  test "RunBuilder cannot change inspection-owner selection after request sealing" do
    documents = fixture_documents()

    assert {:ok, request} =
             ApplicationPackage.request_memory("app.json", documents,
               inspection_capture: true,
               result_projection: :native
             )

    {:ok, registry} = ProviderRegistry.new()
    assert {:error, :invalid_execution_policy} = RunBuilder.build(request, registry)
  end

  test "RunBuilder binds separately acquired requests to registry-installed ceilings" do
    assert {:ok, request} =
             ApplicationPackage.request_memory("app.json", fixture_documents(),
               result_projection: :native
             )

    {:ok, lower_ceiling} = Limits.new(evaluation_timeout_ms: 500)
    {:ok, registry} = ProviderRegistry.new(%{}, installed_limits: lower_ceiling)

    assert {:error, :installed_limits_mismatch} = RunBuilder.build(request, registry)

    assert {:ok, built} =
             RunBuilder.build(request, registry,
               installed_limits: request.package.installed_limits
             )

    assert :ok = RunBuilder.close(built)
  end

  test "RunRequest revalidates an independently sealed input against the package contract" do
    assert {:ok, request} =
             ApplicationPackage.request_memory("app.json", fixture_documents())

    assert {:ok, mismatched_input} =
             ExecutionInput.new(%{"not_answer" => true}, :normal)

    assert {:error, :invalid_run_request} =
             RunRequest.new(request.package, mismatched_input, request.policy)
  end

  test "sealed result projection reaches the Kernel and rejects non-JSON terminal values" do
    documents = fixture_documents(source: ~S|(ns app) (defn run [input] (return #{1 2}))|)
    {:ok, registry} = ProviderRegistry.new()

    assert {:ok, native_request} =
             ApplicationPackage.request_memory("app.json", documents, result_projection: :native)

    assert {:ok, native_build} = RunBuilder.build(native_request, registry)
    assert native_build.result_projection == :native
    assert native_build.config.result_projection == :native

    assert {:ok, %{value: %MapSet{}}} =
             PtcRunner.Kernel.run(native_build.entry_source, native_build.config)

    assert :ok = RunBuilder.close(native_build)

    assert {:ok, json_request} =
             ApplicationPackage.request_memory("app.json", documents, result_projection: :json)

    assert {:ok, json_build} = RunBuilder.build(json_request, registry)
    assert json_build.result_projection == :json
    assert json_build.config.result_projection == :json

    assert {:error, %{kind: :workflow_failed, reason: :invalid_result_projection}} =
             PtcRunner.Kernel.run(json_build.entry_source, json_build.config)

    assert :ok = RunBuilder.close(json_build)
  end

  @tag :tmp_dir
  test "sealed and filesystem request paths share the native embedding default", %{
    tmp_dir: directory
  } do
    documents = fixture_documents(source: ~S|(ns app) (defn run [_input] (return #{1 2}))|)
    manifest_path = write_documents(directory, documents)
    {:ok, registry} = ProviderRegistry.new()

    assert {:ok, sealed_request} =
             ApplicationPackage.request_memory("app.json", documents)

    assert sealed_request.policy.result_projection == :native
    assert {:ok, sealed_build} = RunBuilder.build(sealed_request, registry)

    assert {:ok, %{value: %MapSet{}}} =
             PtcRunner.Kernel.run(sealed_build.entry_source, sealed_build.config)

    assert :ok = RunBuilder.close(sealed_build)

    assert {:ok, filesystem_build} =
             manifest_path
             |> ApplicationPackage.request_directory(installed_limits: registry.installed_limits)
             |> RunLifecycle.build(registry)

    assert filesystem_build.result_projection == :native

    assert {:ok, %{value: %MapSet{}}} =
             PtcRunner.Kernel.run(filesystem_build.entry_source, filesystem_build.config)

    assert :ok = RunBuilder.close(filesystem_build)
  end

  test "execution policy rejects malformed lists without raising" do
    assert {:error, :invalid_execution_policy} = ExecutionPolicy.new([:invalid])
  end

  @tag :tmp_dir
  test "application adapters reject unknown and duplicate options before reading documents", %{
    tmp_dir: directory
  } do
    missing = Path.join(directory, "missing.json")
    invalid_memory = %{}

    invalid_limits = [
      %{Limits.installed_defaults() | run_duration_ms: :invalid},
      Map.delete(Limits.installed_defaults(), :run_duration_ms),
      Map.put(Limits.installed_defaults(), :unexpected_limit, 1)
    ]

    Enum.each(invalid_limits, &refute(Limits.valid?(&1)))
    assert Limits.valid?(Limits.installed_defaults())

    assert {:error, :invalid_application_options} =
             ApplicationPackage.acquire_directory(missing, result_projecton: :json)

    assert {:error, :invalid_application_options} =
             ApplicationPackage.acquire_memory("app.json", invalid_memory,
               result_projecton: :json
             )

    assert {:error, :invalid_application_options} =
             ApplicationPackage.request_directory(missing, result_projecton: :json)

    assert {:error, :invalid_application_options} =
             ApplicationPackage.request_memory("app.json", invalid_memory,
               result_projecton: :json
             )

    for limits <- invalid_limits do
      for adapter <- [
            fn ->
              ApplicationPackage.acquire_directory(missing, installed_limits: limits)
            end,
            fn ->
              ApplicationPackage.acquire_memory("app.json", invalid_memory,
                installed_limits: limits
              )
            end,
            fn ->
              ApplicationPackage.request_directory(missing, installed_limits: limits)
            end,
            fn ->
              ApplicationPackage.request_memory("app.json", invalid_memory,
                installed_limits: limits
              )
            end
          ] do
        assert {:error, :invalid_installed_limits} = adapter.()
      end
    end

    documents = fixture_documents()
    manifest_path = write_documents(directory, documents)
    duplicate = [result_projection: :json, result_projection: :native]

    assert {:error, :invalid_application_options} =
             ApplicationPackage.request_directory(manifest_path, duplicate)

    assert {:error, :invalid_application_options} =
             ApplicationPackage.request_memory("app.json", documents, duplicate)
  end

  test "sealed Kernel runs ignore the ambient default compile heap" do
    previous = Application.get_env(:ptc_runner, :default_max_heap)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:ptc_runner, :default_max_heap),
        else: Application.put_env(:ptc_runner, :default_max_heap, previous)
    end)

    Application.put_env(:ptc_runner, :default_max_heap, 1)

    assert {:ok, request} =
             ApplicationPackage.request_memory("app.json", fixture_documents(),
               result_projection: :native
             )

    {:ok, registry} = ProviderRegistry.new()
    assert {:ok, built} = RunBuilder.build(request, registry)

    assert {:ok, %{value: %{"answer" => 1}}} =
             PtcRunner.Kernel.run(built.entry_source, built.config)

    assert :ok = RunBuilder.close(built)
  end

  test "selected override input bypasses the unselected manifest-path input" do
    documents =
      fixture_documents(input: %{"path" => "not-supplied.json"})
      |> Map.put("selected.json", ~S({"answer":7}))

    assert {:ok, request} =
             ApplicationPackage.request_memory("app.json", documents,
               input: "selected.json",
               result_projection: :native
             )

    assert request.input.value == %{"answer" => 7}
  end

  test "memory acquisition rejects caller-built override structs" do
    forged = %ComponentOverride{
      target: %{"environment" => "workflow"},
      component_id: "app",
      base_source_hash: ComponentOverride.hash(@source),
      source_hash: ComponentOverride.hash("different bytes"),
      source: @source,
      origin: "component-override",
      provenance: nil,
      descriptor_bytes: :not_a_byte_count
    }

    assert {:error, {:source_role, :component_override, :invalid_override_descriptor}} =
             ApplicationPackage.request_memory("app.json", fixture_documents(),
               component_override: forged
             )
  end

  test "memory override candidate name must match the descriptor path" do
    candidate = @source <> "\n(def candidate true)"

    documents =
      fixture_documents()
      |> Map.put("override.json", override_descriptor(@source, candidate))
      |> Map.put("different.clj", candidate)

    assert {:error, {:source_role, :component_override, :invalid_override_descriptor}} =
             ApplicationPackage.request_memory("app.json", documents,
               component_override: {"override.json", "different.clj"}
             )
  end

  test "source, dependency, and exact contract bytes each change content identity" do
    base = fixture_documents()

    changed_source =
      Map.put(base, "workflow.clj", @source <> "\n(def extra 1)")

    changed_dependency =
      fixture_documents(dependencies: ["agent.core"], libraries: ["agent.core"])

    annotated_contract =
      Map.put(
        base,
        "input.schema.json",
        ~S({"description":"annotation","type":"object","properties":{"answer":{"type":"integer"}},"additionalProperties":false})
      )

    packages =
      for documents <- [base, changed_source, changed_dependency, annotated_contract] do
        {:ok, package, _input} = ApplicationPackage.acquire_memory("app.json", documents)
        package
      end

    assert packages |> Enum.map(& &1.application_content_digest) |> Enum.uniq() |> length() == 4

    [base_package, _source_package, _dependency_package, annotated_package] = packages

    assert base_package.contract_behavior_hashes.input ==
             annotated_package.contract_behavior_hashes.input
  end

  test "document accounting deduplicates shipped libraries across environments" do
    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"library" => "kernel"}],
        "entry" => "kernel/return-value"
      },
      "missions" => %{"default" => %{"components" => [%{"library" => "kernel"}]}},
      "input" => %{"value" => %{}}
    }

    documents = %{"app.json" => Jason.encode!(manifest)}

    assert {:ok, package, _input} =
             ApplicationPackage.acquire_memory("app.json", documents)

    assert package.document_count == 3
  end

  test "expanded component records cannot amplify one captured source past the package bound" do
    components =
      for index <- 0..127 do
        %{"id" => "component#{index}", "path" => "shared.clj"}
      end

    manifest = %{
      "version" => 1,
      "workflow" => %{"components" => components, "entry" => "component0/run"},
      "missions" => %{"default" => %{"components" => components}},
      "input" => %{"value" => %{}}
    }

    documents = %{
      "app.json" => Jason.encode!(manifest),
      "shared.clj" => String.duplicate(" ", 40_000)
    }

    assert {:error, {:manifest_path, _, :mission_aggregate_limit_exceeded}} =
             ApplicationPackage.acquire_memory("app.json", documents)
  end

  test "overridden shipped-library accounting retains original and override documents" do
    {:ok, library} = Library.component("kernel")
    candidate = library.source <> "\n"
    descriptor = override_descriptor("kernel", library.source, candidate)

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"library" => "kernel"}],
        "entry" => "kernel/return-value"
      },
      "input" => %{"value" => %{}}
    }

    documents = %{
      "app.json" => Jason.encode!(manifest),
      "override.json" => descriptor,
      "candidate.clj" => candidate
    }

    assert {:ok, package, _input} =
             ApplicationPackage.acquire_memory("app.json", documents,
               component_override: {"override.json", "candidate.clj"}
             )

    {:ok, encoded_input} = TypedCanonicalJSON.encode(%{})

    expected_bytes =
      Enum.reduce(documents, 0, fn {_name, bytes}, total -> total + byte_size(bytes) end) +
        byte_size(encoded_input) + byte_size(library.source)

    assert package.document_count == 5
    assert package.document_bytes == expected_bytes
  end

  @tag :tmp_dir
  test "override candidate overlapping a component document has adapter-parity accounting", %{
    tmp_dir: directory
  } do
    descriptor =
      Jason.encode!(%{
        "target" => %{"environment" => "workflow"},
        "component_id" => "app",
        "base_source_hash" => ComponentOverride.hash(@source),
        "source_hash" => ComponentOverride.hash(@source),
        "path" => "workflow.clj"
      })

    documents =
      fixture_documents()
      |> Map.put("override.json", descriptor)

    manifest_path = write_documents(directory, documents)

    assert {:ok, directory_package, _input} =
             ApplicationPackage.acquire_directory(manifest_path,
               component_override_descriptor: Path.join(directory, "override.json")
             )

    assert {:ok, memory_package, _input} =
             ApplicationPackage.acquire_memory("app.json", documents,
               component_override: {"override.json", "workflow.clj"}
             )

    assert directory_package.document_count == memory_package.document_count
    assert directory_package.document_bytes == memory_package.document_bytes
  end

  @tag :tmp_dir
  test "nested override references resolve identically in both adapters", %{tmp_dir: directory} do
    descriptor =
      Jason.encode!(%{
        "target" => %{"environment" => "workflow"},
        "component_id" => "app",
        "base_source_hash" => ComponentOverride.hash(@source),
        "source_hash" => ComponentOverride.hash(@source),
        "path" => "candidate.clj"
      })

    documents =
      fixture_documents()
      |> Map.put("overrides/override.json", descriptor)
      |> Map.put("overrides/candidate.clj", @source)

    manifest_path = write_documents(directory, documents)

    assert {:ok, directory_package, _input} =
             ApplicationPackage.acquire_directory(manifest_path,
               component_override_descriptor: Path.join(directory, "overrides/override.json")
             )

    assert {:ok, memory_package, _input} =
             ApplicationPackage.acquire_memory("app.json", documents,
               component_override: {"overrides/override.json", "overrides/candidate.clj"}
             )

    assert package_projection(directory_package) == package_projection(memory_package)
  end

  @tag :tmp_dir
  test "safe candidate symlink aliases retain adapter-parity accounting", %{tmp_dir: directory} do
    descriptor =
      Jason.encode!(%{
        "target" => %{"environment" => "workflow"},
        "component_id" => "app",
        "base_source_hash" => ComponentOverride.hash(@source),
        "source_hash" => ComponentOverride.hash(@source),
        "path" => "candidate.clj"
      })

    directory_documents =
      fixture_documents()
      |> Map.put("override.json", descriptor)

    manifest_path = write_documents(directory, directory_documents)
    File.ln_s!("workflow.clj", Path.join(directory, "candidate.clj"))

    memory_documents =
      directory_documents
      |> Map.put("candidate.clj", @source)

    assert {:ok, directory_package, _input} =
             ApplicationPackage.acquire_directory(manifest_path,
               component_override_descriptor: Path.join(directory, "override.json")
             )

    assert {:ok, memory_package, _input} =
             ApplicationPackage.acquire_memory("app.json", memory_documents,
               component_override: {"override.json", "candidate.clj"}
             )

    assert directory_package.document_count == memory_package.document_count
    assert directory_package.document_bytes == memory_package.document_bytes
  end

  @tag :tmp_dir
  test "one verified override has adapter-parity metadata and binds its verified base", %{
    tmp_dir: directory
  } do
    base_source = @source
    candidate = @source <> "\n(def candidate true)"
    descriptor = override_descriptor(base_source, candidate)

    documents =
      fixture_documents()
      |> Map.put("override.json", descriptor)
      |> Map.put("candidate.clj", candidate)

    manifest_path = write_documents(directory, documents)

    assert {:ok, directory_request} =
             ApplicationPackage.request_directory(manifest_path,
               component_override_descriptor: Path.join(directory, "override.json"),
               result_projection: :native
             )

    assert {:ok, memory_request} =
             ApplicationPackage.request_memory("app.json", documents,
               component_override: {"override.json", "candidate.clj"},
               result_projection: :native
             )

    assert directory_request.package.component_overrides ==
             memory_request.package.component_overrides

    assert directory_request.package.application_content_digest ==
             memory_request.package.application_content_digest

    {:ok, registry} = ProviderRegistry.new()
    assert {:ok, directory_build} = RunBuilder.build(directory_request, registry)
    assert {:ok, memory_build} = RunBuilder.build(memory_request, registry)

    assert directory_build.config.run_started_metadata.component_overrides ==
             memory_build.config.run_started_metadata.component_overrides

    assert :ok = RunBuilder.close(directory_build)
    assert :ok = RunBuilder.close(memory_build)

    other_base = @source <> "\n; behaviorally replaced base"

    other_documents =
      fixture_documents(source: other_base)
      |> Map.put("override.json", override_descriptor(other_base, candidate))
      |> Map.put("candidate.clj", candidate)

    assert {:ok, other_request} =
             ApplicationPackage.request_memory("app.json", other_documents,
               component_override: {"override.json", "candidate.clj"},
               result_projection: :native
             )

    refute other_request.package.application_content_digest ==
             memory_request.package.application_content_digest

    assert Enum.map(other_request.package.workflow_components, & &1.source) ==
             Enum.map(memory_request.package.workflow_components, & &1.source)
  end

  @tag :tmp_dir
  test "directory source caches a captured document and never reopens it", %{tmp_dir: directory} do
    documents = fixture_documents()
    manifest_path = write_documents(directory, documents)
    {:ok, source} = ApplicationSource.open_directory(manifest_path)

    assert {:ok, original} = ApplicationSource.read(source, "workflow.clj", 2_000_000)
    File.write!(Path.join(directory, "workflow.clj"), "(ns swapped)")
    assert {:ok, ^original} = ApplicationSource.read(source, "workflow.clj", 2_000_000)

    ApplicationSource.close(source)
  end

  test "memory source preserves a per-document limit failure" do
    documents = %{"app.json" => "{}", "large.json" => String.duplicate("a", 65)}
    assert {:ok, source} = ApplicationSource.open_memory("app.json", documents)
    assert {:error, :document_limit_exceeded} = ApplicationSource.read(source, "large.json", 64)
    ApplicationSource.close(source)
  end

  test "memory source enforces aggregate bytes before scanning document UTF-8" do
    oversized = String.duplicate("a", 8_388_609)
    documents = %{"app.json" => "{}", "oversized.txt" => oversized}
    {:reductions, before} = Process.info(self(), :reductions)

    assert {:error, :invalid_application_source} =
             ApplicationSource.open_memory("app.json", documents)

    {:reductions, after_rejection} = Process.info(self(), :reductions)
    assert after_rejection - before < 100_000
  end

  @tag :tmp_dir
  test "directory source preserves a per-document limit failure", %{tmp_dir: directory} do
    File.write!(Path.join(directory, "app.json"), "{}")
    File.write!(Path.join(directory, "large.json"), String.duplicate("a", 65))
    assert {:ok, source} = ApplicationSource.open_directory(Path.join(directory, "app.json"))
    assert {:error, :document_limit_exceeded} = ApplicationSource.read(source, "large.json", 64)
    ApplicationSource.close(source)
  end

  @tag :tmp_dir
  test "provider selection context contains content identity but no application directory", %{
    tmp_dir: directory
  } do
    parent = self()

    documents =
      fixture_documents(
        providers: %{
          "workflow" => [%{"name" => "capture", "config" => %{}}],
          "mission" => []
        }
      )

    manifest_path = write_documents(directory, documents)

    builder = fn _config, context ->
      send(parent, {:context, context})
      {:error, :stop_after_context}
    end

    {:ok, registry} =
      ProviderRegistry.new(%{"capture" => TestHelpers.staged_provider(builder)})

    assert {:error, :stop_after_context} =
             manifest_path
             |> ApplicationPackage.request_directory(installed_limits: registry.installed_limits)
             |> RunLifecycle.build(registry)
             |> RunLifecycle.execute()

    assert_receive {:context, context}
    refute Map.has_key?(context, :directory)
    assert context.application_content_digest =~ ~r/\A[0-9a-f]{64}\z/
  end

  defp fixture_documents(opts \\ []) do
    source = Keyword.get(opts, :source, @source)
    dependencies = Keyword.get(opts, :dependencies, [])
    libraries = Keyword.get(opts, :libraries, [])
    input = Keyword.get(opts, :input, %{"value" => %{"answer" => 1}})
    providers = Keyword.get(opts, :providers, %{"workflow" => [], "mission" => []})

    components =
      Enum.map(libraries, &%{"library" => &1}) ++
        [
          %{
            "id" => "app",
            "path" => "workflow.clj",
            "dependencies" => dependencies
          }
        ]

    manifest = %{
      "version" => 1,
      "workflow" => %{"components" => components, "entry" => "app/run"},
      "input" => input,
      "contracts" => %{"input_schema" => %{"path" => "input.schema.json"}},
      "providers" => providers
    }

    %{
      "app.json" => Jason.encode!(manifest),
      "workflow.clj" => source,
      "input.schema.json" => @schema
    }
  end

  defp override_descriptor(base, candidate) do
    override_descriptor("app", base, candidate)
  end

  defp override_descriptor(component_id, base, candidate) do
    Jason.encode!(%{
      "target" => %{"environment" => "workflow"},
      "component_id" => component_id,
      "base_source_hash" => ComponentOverride.hash(base),
      "source_hash" => ComponentOverride.hash(candidate),
      "path" => "candidate.clj"
    })
  end

  defp write_documents(directory, documents) do
    Enum.each(documents, fn {name, bytes} ->
      path = Path.join(directory, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end)

    Path.join(directory, "app.json")
  end

  defp package_projection(package) do
    package
    |> Map.from_struct()
    |> Map.drop([:attestation])
  end
end
