defmodule PtcRunner.Kernel.InspectionPreflightTest do
  # The cases that rewrite PATH or change the VM's cwd live in InspectionPreflightGlobalStateTest;
  # these are :tmp_dir-only.
  use ExUnit.Case, async: true
  @moduletag :operator

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ResultArtifact
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.TestSupport.RunLifecycle
  alias PtcRunner.TestSupport.StreamingInspection
  alias PtcRunner.TestSupport.TestHelpers

  describe "InspectionArtifact.preflight_destination/1" do
    @tag :tmp_dir
    test "classifies invalid, occupied, unavailable, and free destinations", %{tmp_dir: dir} do
      assert {:error, :invalid_inspection_path} = InspectionArtifact.preflight_destination(42)

      assert {:error, :invalid_inspection_path} =
               InspectionArtifact.preflight_destination(Path.join(dir, "run.jsonl"))

      file = Path.join(dir, "file.ptcins")
      File.write!(file, "occupied")

      assert {:error, :inspection_destination_exists} =
               InspectionArtifact.preflight_destination(file)

      symlink = Path.join(dir, "link.ptcins")
      File.ln_s!(file, symlink)

      assert {:error, :inspection_destination_exists} =
               InspectionArtifact.preflight_destination(symlink)

      directory = Path.join(dir, "dir.ptcins")
      File.mkdir!(directory)

      assert {:error, :inspection_destination_exists} =
               InspectionArtifact.preflight_destination(directory)

      under_file = Path.join(file, "nested.ptcins")

      assert {:error, :inspection_destination_unavailable} =
               InspectionArtifact.preflight_destination(under_file)

      assert {:error, :inspection_destination_unavailable} =
               InspectionArtifact.preflight_destination(Path.join([dir, "missing", "run.ptcins"]))

      assert :ok =
               InspectionArtifact.preflight_destination(Path.join(dir, "free.ptcins"))
    end

    @tag :tmp_dir
    test "rejects publication through a replaceable parent directory", %{tmp_dir: dir} do
      replaceable = Path.join(dir, "replaceable")
      File.mkdir!(replaceable)
      File.chmod!(replaceable, 0o777)

      assert {:error, :inspection_destination_unsafe} =
               InspectionArtifact.preflight_destination(Path.join(replaceable, "run.ptcins"))
    end

    @tag :tmp_dir
    test "rejects a symlink that hides a replaceable physical ancestor", %{tmp_dir: dir} do
      replaceable = Path.join(dir, "replaceable")
      protected_child = Path.join(replaceable, "protected")
      alias_path = Path.join(dir, "alias")

      File.mkdir!(replaceable)
      File.chmod!(replaceable, 0o777)
      File.mkdir!(protected_child)
      File.chmod!(protected_child, 0o700)
      File.ln_s!(protected_child, alias_path)

      assert {:error, :inspection_destination_unsafe} =
               InspectionArtifact.preflight_destination(Path.join(alias_path, "run.ptcins"))
    end

    @tag :tmp_dir
    test "resolves parent components after following symlinks", %{tmp_dir: dir} do
      replaceable = Path.join(dir, "replaceable")
      protected_child = Path.join(replaceable, "protected")
      alias_path = Path.join(dir, "alias")

      File.mkdir!(replaceable)
      File.chmod!(replaceable, 0o777)
      File.mkdir!(protected_child)
      File.chmod!(protected_child, 0o700)
      File.ln_s!(protected_child, alias_path)

      assert {:error, :inspection_destination_unsafe} =
               InspectionArtifact.preflight_destination(
                 Path.join([alias_path, "..", "run.ptcins"])
               )
    end

    @tag :tmp_dir
    test "rejects every replaceable controller traversed by a symlink chain", %{tmp_dir: dir} do
      replaceable = Path.join(dir, "replaceable")
      protected_child = Path.join(dir, "protected")
      hop = Path.join(replaceable, "hop")
      alias_path = Path.join(dir, "alias")

      File.mkdir!(replaceable)
      File.chmod!(replaceable, 0o777)
      File.mkdir!(protected_child)
      File.chmod!(protected_child, 0o700)
      File.ln_s!(protected_child, hop)
      File.ln_s!(hop, alias_path)

      assert {:error, :inspection_destination_unsafe} =
               InspectionArtifact.preflight_destination(Path.join(alias_path, "run.ptcins"))
    end
  end

  describe "RunBuilder preflight ordering" do
    @tag :tmp_dir
    test "an occupied destination is rejected before any provider builder runs", %{tmp_dir: dir} do
      parent = self()

      builder = fn _config, _context ->
        send(parent, :provider_builder_invoked)
        {:error, :should_not_run}
      end

      {:ok, registry} = ProviderRegistry.new(%{"probe" => TestHelpers.staged_provider(builder)})

      manifest_path =
        write_manifest(dir, %{"workflow" => [%{"name" => "probe", "config" => %{}}]})

      occupied = Path.join(dir, "run.ptcins")
      File.write!(occupied, "occupied")

      assert {:error, {:inspection_preflight_failed, :inspection_destination_exists}} =
               manifest_path
               |> ApplicationPackage.request_directory(
                 request_options(registry, inspect: occupied)
               )
               |> RunLifecycle.build(registry,
                 trace_path: Path.join(dir, "run.jsonl"),
                 inspect: occupied
               )
               |> RunLifecycle.execute()

      refute_received :provider_builder_invoked
    end

    @tag :tmp_dir
    test "manifest and input errors take precedence over an occupied destination", %{
      tmp_dir: dir
    } do
      {:ok, registry} = ProviderRegistry.new()
      occupied = Path.join(dir, "run.ptcins")
      File.write!(occupied, "occupied")

      missing_manifest = Path.join(dir, "absent.json")

      assert {:error, reason} =
               missing_manifest
               |> ApplicationPackage.request_directory(
                 request_options(registry, inspect: occupied)
               )
               |> RunLifecycle.build(registry, inspect: occupied)
               |> RunLifecycle.execute()

      refute match?({:inspection_preflight_failed, _reason}, reason)

      manifest_path = write_manifest(dir, %{})

      assert {:error, reason} =
               manifest_path
               |> ApplicationPackage.request_directory(
                 request_options(registry,
                   input: "absent-override.json",
                   inspect: occupied
                 )
               )
               |> RunLifecycle.build(registry, inspect: occupied)
               |> RunLifecycle.execute()

      refute match?({:inspection_preflight_failed, _reason}, reason)
    end

    @tag :tmp_dir
    test "an occupied result destination is rejected before provider acquisition", %{tmp_dir: dir} do
      parent = self()

      builder = fn _config, _context ->
        send(parent, :provider_builder_invoked)
        {:error, :should_not_run}
      end

      {:ok, registry} = ProviderRegistry.new(%{"probe" => TestHelpers.staged_provider(builder)})

      manifest_path =
        write_manifest(dir, %{"workflow" => [%{"name" => "probe", "config" => %{}}]})

      occupied = Path.join(dir, "result.json")
      File.write!(occupied, "occupied")

      assert {:error, {:result_preflight_failed, :result_destination_exists}} =
               manifest_path
               |> ApplicationPackage.request_directory(
                 request_options(registry, output: occupied)
               )
               |> RunLifecycle.build(registry, output: occupied)
               |> RunLifecycle.execute()

      refute_received :provider_builder_invoked
      assert File.read!(occupied) == "occupied"
    end

    @tag :tmp_dir
    test "a result destination with a missing parent is rejected before provider acquisition", %{
      tmp_dir: dir
    } do
      parent = self()

      builder = fn _config, _context ->
        send(parent, :provider_builder_invoked)
        {:error, :should_not_run}
      end

      {:ok, registry} = ProviderRegistry.new(%{"probe" => TestHelpers.staged_provider(builder)})

      manifest_path =
        write_manifest(dir, %{"workflow" => [%{"name" => "probe", "config" => %{}}]})

      destination = Path.join([dir, "missing", "result.json"])

      assert {:error, {:result_preflight_failed, :invalid_result_destination}} =
               manifest_path
               |> ApplicationPackage.request_directory(
                 request_options(registry, output: destination)
               )
               |> RunLifecycle.build(registry, output: destination)
               |> RunLifecycle.execute()

      refute_received :provider_builder_invoked
    end

    @tag :tmp_dir
    test "colliding artifact destinations are rejected before provider acquisition", %{
      tmp_dir: dir
    } do
      parent = self()

      builder = fn _config, _context ->
        send(parent, :provider_builder_invoked)
        {:error, :should_not_run}
      end

      {:ok, registry} = ProviderRegistry.new(%{"probe" => TestHelpers.staged_provider(builder)})

      manifest_path =
        write_manifest(dir, %{"workflow" => [%{"name" => "probe", "config" => %{}}]})

      real_parent = Path.join(dir, "real")
      alias_parent = Path.join(dir, "alias")
      File.mkdir!(real_parent)
      File.ln_s!(real_parent, alias_parent)

      for options <- [
            [
              output: Path.join(dir, "same.jsonl"),
              trace_path: Path.join(dir, "same.jsonl")
            ],
            [
              output: Path.join(dir, "same.ptcins"),
              inspect: Path.join(dir, "same.ptcins")
            ],
            [
              output: Path.join(real_parent, "same.jsonl"),
              trace_path: Path.join(alias_parent, "same.jsonl")
            ],
            [
              output: Path.join(real_parent, "Case.jsonl"),
              trace_path: Path.join(real_parent, "case.jsonl")
            ],
            [
              output: Path.join(real_parent, "σ.jsonl"),
              trace_path: Path.join(real_parent, "ς.jsonl")
            ]
          ] do
        assert {:error, {:artifact_preflight_failed, :conflicting_destinations}} =
                 manifest_path
                 |> ApplicationPackage.request_directory(request_options(registry, options))
                 |> RunLifecycle.build(registry, options)
                 |> RunLifecycle.execute()

        refute_received :provider_builder_invoked
      end
    end

    @tag :tmp_dir
    test "an inspection destination with a missing parent is rejected before provider acquisition",
         %{tmp_dir: dir} do
      parent = self()

      builder = fn _config, _context ->
        send(parent, :provider_builder_invoked)
        {:error, :should_not_run}
      end

      {:ok, registry} = ProviderRegistry.new(%{"probe" => TestHelpers.staged_provider(builder)})

      manifest_path =
        write_manifest(dir, %{"workflow" => [%{"name" => "probe", "config" => %{}}]})

      destination = Path.join([dir, "missing", "run.ptcins"])

      assert {:error, {:inspection_preflight_failed, :inspection_destination_unavailable}} =
               manifest_path
               |> ApplicationPackage.request_directory(
                 request_options(registry, inspect: destination)
               )
               |> RunLifecycle.build(registry, inspect: destination)
               |> RunLifecycle.execute()

      refute_received :provider_builder_invoked
    end

    @tag :tmp_dir
    test "unwritable artifact parents are rejected before provider acquisition", %{tmp_dir: dir} do
      parent = self()

      builder = fn _config, _context ->
        send(parent, :provider_builder_invoked)
        {:error, :should_not_run}
      end

      {:ok, registry} = ProviderRegistry.new(%{"probe" => TestHelpers.staged_provider(builder)})

      manifest_path =
        write_manifest(dir, %{"workflow" => [%{"name" => "probe", "config" => %{}}]})

      unwritable = Path.join(dir, "unwritable")
      File.mkdir!(unwritable)
      File.chmod!(unwritable, 0o500)
      on_exit(fn -> File.chmod(unwritable, 0o700) end)

      cases = [
        {[output: Path.join(unwritable, "result.json")],
         {:result_preflight_failed, :invalid_result_destination}},
        {[inspect: Path.join(unwritable, "run.ptcins")],
         {:inspection_preflight_failed, :inspection_destination_unavailable}},
        {[trace_path: Path.join(unwritable, "run.jsonl")],
         {:trace_preflight_failed, :trace_destination_unavailable}}
      ]

      for {options, reason} <- cases do
        assert {:error, ^reason} =
                 manifest_path
                 |> ApplicationPackage.request_directory(request_options(registry, options))
                 |> RunLifecycle.build(registry, options)
                 |> RunLifecycle.execute()

        refute_received :provider_builder_invoked
      end
    end

    @tag :tmp_dir
    test "an invalid trace destination is rejected before provider acquisition", %{tmp_dir: dir} do
      parent = self()

      builder = fn _config, _context ->
        send(parent, :provider_builder_invoked)
        {:error, :should_not_run}
      end

      {:ok, registry} = ProviderRegistry.new(%{"probe" => TestHelpers.staged_provider(builder)})

      manifest_path =
        write_manifest(dir, %{"workflow" => [%{"name" => "probe", "config" => %{}}]})

      assert {:error, {:trace_preflight_failed, :normal_trace_requires_normal_suffix}} =
               manifest_path
               |> ApplicationPackage.request_directory(request_options(registry, []))
               |> RunLifecycle.build(registry,
                 trace_path: Path.join(dir, "run.private.jsonl")
               )
               |> RunLifecycle.execute()

      refute_received :provider_builder_invoked
    end

    @tag :tmp_dir
    test "filesystem-invalid trace destinations are rejected before provider acquisition", %{
      tmp_dir: dir
    } do
      parent = self()

      builder = fn _config, _context ->
        send(parent, :provider_builder_invoked)
        {:error, :should_not_run}
      end

      {:ok, registry} = ProviderRegistry.new(%{"probe" => TestHelpers.staged_provider(builder)})

      manifest_path =
        write_manifest(dir, %{"workflow" => [%{"name" => "probe", "config" => %{}}]})

      missing_parent = Path.join([dir, "missing", "run.jsonl"])
      directory = Path.join(dir, "directory.jsonl")
      target = Path.join(dir, "target.jsonl")
      symlink = Path.join(dir, "symlink.jsonl")
      File.mkdir!(directory)
      File.write!(target, "")
      File.ln_s!(target, symlink)

      assert {:error, {:trace_preflight_failed, :trace_destination_unavailable}} =
               manifest_path
               |> ApplicationPackage.request_directory(request_options(registry, []))
               |> RunLifecycle.build(registry, trace_path: missing_parent)
               |> RunLifecycle.execute()

      refute_received :provider_builder_invoked

      for destination <- [directory, symlink] do
        assert {:error, {:trace_preflight_failed, :invalid_trace_path}} =
                 manifest_path
                 |> ApplicationPackage.request_directory(request_options(registry, []))
                 |> RunLifecycle.build(registry, trace_path: destination)
                 |> RunLifecycle.execute()

        refute_received :provider_builder_invoked
      end
    end

    @tag :tmp_dir
    test "direct build applies inspection and cross-artifact preflights before providers", %{
      tmp_dir: dir
    } do
      parent = self()

      prepare = fn _config, _context ->
        send(parent, :provider_prepared)
        {:error, :should_not_run}
      end

      {:ok, registry} =
        ProviderRegistry.new(%{"probe" => ProviderRegistry.staged(prepare)})

      manifest_path =
        write_manifest(dir, %{"workflow" => [%{"name" => "probe", "config" => %{}}]})

      {:ok, request} =
        ApplicationPackage.request_directory(manifest_path,
          inspection_capture: true,
          result_projection: :native
        )

      occupied = Path.join(dir, "occupied.ptcins")
      File.write!(occupied, "occupied")

      assert {:error, {:inspection_preflight_failed, :inspection_destination_exists}} =
               RunBuilder.build(request, registry, inspect: occupied)

      refute_received :provider_prepared

      shared = Path.join(dir, "shared.ptcins")

      assert {:error, {:artifact_preflight_failed, :conflicting_destinations}} =
               RunBuilder.build(request, registry, inspect: shared, output: shared)

      refute_received :provider_prepared
    end
  end

  describe "TraceLog private destination ownership" do
    # Both classes report the untrusted ancestor rather than a bare
    # "unavailable": the private path carries the reason out of
    # PrivateDirectory.preflight/1, and the normal path out of
    # preflight_writable_parent/1, which previously flattened it.
    @tag :tmp_dir
    test "creation preflight names a replaceable ancestor for either class", %{tmp_dir: dir} do
      replaceable = Path.join(dir, "replaceable")
      File.mkdir!(replaceable)
      File.chmod!(replaceable, 0o777)

      assert {:error, :trace_destination_unsafe} =
               TraceLog.preflight_destination(
                 Path.join(replaceable, "run.private.jsonl"),
                 true
               )

      assert {:error, :trace_destination_unsafe} =
               TraceLog.preflight_destination(Path.join(replaceable, "run.jsonl"), false)
    end

    @tag :tmp_dir
    test "an existing private trace under a replaceable ancestor is unsafe", %{tmp_dir: dir} do
      replaceable = Path.join(dir, "replaceable")
      path = Path.join(replaceable, "existing.private.jsonl")

      File.mkdir!(replaceable)
      File.write!(path, "")
      File.chmod!(path, 0o600)
      File.chmod!(replaceable, 0o777)

      assert {:error, :trace_destination_unsafe} = TraceLog.preflight_destination(path, true)
    end

    # Only the untrusted ancestor is named apart here; an unavailable parent has
    # always been reported as the generic closed reason on this path.
    @tag :tmp_dir
    test "private creation reports an unavailable parent as source_unavailable", %{tmp_dir: dir} do
      parent = Path.join(dir, "uncreatable")
      File.mkdir!(parent)
      File.chmod!(parent, 0o500)
      on_exit(fn -> File.chmod(parent, 0o700) end)

      assert {:error, :source_unavailable} =
               TraceLog.preflight_destination(Path.join(parent, "run.private.jsonl"), true)
    end

    @tag :tmp_dir
    test "accepts an appendable existing private trace in a non-creatable parent", %{
      tmp_dir: dir
    } do
      parent = Path.join(dir, "read-only-parent")
      path = Path.join(parent, "existing.private.jsonl")

      File.mkdir!(parent)
      File.write!(path, "")
      File.chmod!(path, 0o600)
      File.chmod!(parent, 0o500)

      on_exit(fn -> File.chmod(parent, 0o700) end)

      assert :ok = TraceLog.preflight_destination(path, true)
    end

    @tag :tmp_dir
    test "file preflight rejects a trusted-owner trace without authority write access", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "root-owned.private.jsonl")
      File.write!(path, "")
      File.chmod!(path, 0o600)

      foreign_authority = %{
        uid: current_uid() + 1,
        groups: MapSet.new([File.stat!(path).gid + 1])
      }

      assert {:error, :private_directory_parent_unavailable} =
               PrivateDirectory.preflight_writable_file(path, foreign_authority)
    end

    @tag :tmp_dir
    test "rejects precreated append-lock roots without changing their targets", %{tmp_dir: dir} do
      uid = current_uid()
      victim = Path.join(dir, "victim")
      legacy_root = Path.join(dir, "ptc-runner-trace-append-locks")
      authority_root = Path.join(dir, "ptc-runner-trace-append-locks-#{uid}")

      File.mkdir!(victim)
      File.chmod!(victim, 0o755)
      File.ln_s!(victim, legacy_root)
      File.ln_s!(victim, authority_root)

      assert ":ok" =
               trace_preflight_in_fresh_runtime(dir, Path.join(dir, "run.jsonl"))

      assert Bitwise.band(File.stat!(victim).mode, 0o777) == 0o755
    end
  end

  describe "temporary sibling path bounds" do
    @tag :tmp_dir
    test "near-NAME_MAX destinations preflight and publish through every private path", %{
      tmp_dir: dir
    } do
      result_path = Path.join(dir, near_name_limit(".private.json"))
      inspection_path = Path.join(dir, near_name_limit(".ptcins"))
      trace_path = Path.join(dir, near_name_limit(".private.jsonl"))

      {:ok, inspection_sink} =
        StreamingInspection.start(
          run_id: "long-path-run",
          trace_id: "long-path-trace"
        )

      assert :ok =
               InspectionSink.emit(
                 inspection_sink,
                 "capability-input",
                 %{capability_id: "long-path-capability"},
                 %{
                   environment: :mission,
                   mission_name: "default",
                   name: "read",
                   arguments: %{}
                 }
               )

      assert {:ok, inspection_records} =
               StreamingInspection.records(inspection_sink)

      assert :ok = InspectionSink.stop(inspection_sink)

      _canonical_events = [
        %{
          run_id: "long-path-run",
          trace_id: "long-path-trace",
          type: "capability-started",
          data: %{
            capability_id: "long-path-capability",
            environment: :mission,
            mission_name: "default",
            name: "read"
          }
        }
      ]

      trace_events = [
        %{
          "schema_version" => 2,
          "run_id" => "long-path-run",
          "trace_id" => "long-path-trace",
          "sequence" => 1,
          "timestamp" => "2026-07-28T12:00:00Z",
          "type" => "run-started",
          "data" => %{"missions" => %{"default" => %{}}}
        }
      ]

      assert :ok =
               ResultArtifact.preflight_destination(
                 result_path,
                 :private,
                 :private
               )

      assert :ok =
               ResultArtifact.persist(
                 result_path,
                 %{"ok" => true},
                 :private,
                 :private
               )

      assert :ok = InspectionArtifact.preflight_destination(inspection_path)

      assert :ok =
               StreamingInspection.write_path(
                 inspection_path,
                 inspection_records
               )

      assert :ok = TraceLog.preflight_destination(trace_path, true)
      assert :ok = TraceLog.append_jsonl(trace_path, trace_events, private: true)

      assert Enum.all?([result_path, inspection_path, trace_path], &File.regular?/1)
    end
  end

  defp write_manifest(dir, providers) do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [input] (return 42))|
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}},
      "providers" => providers
    }

    path = Path.join(dir, "ptc.json")
    File.write!(path, Jason.encode!(manifest))
    path
  end

  defp request_options(registry, opts) do
    [
      installed_limits: registry.installed_limits,
      inspection_capture: is_binary(opts[:inspect])
    ] ++ Keyword.take(opts, [:input])
  end

  defp current_uid do
    {uid, 0} = System.cmd("id", ["-u"])
    uid |> String.trim() |> String.to_integer()
  end

  defp near_name_limit(suffix) do
    String.duplicate("x", 250 - byte_size(suffix)) <> suffix
  end

  defp trace_preflight_in_fresh_runtime(tmp_dir, path) do
    executable = System.find_executable("elixir") || flunk("elixir is required for this test")

    code =
      "IO.puts(inspect(PtcRunner.Kernel.TraceLog.preflight_destination(" <>
        inspect(path) <> ", false)))"

    code_paths =
      :code.get_path()
      |> Enum.flat_map(fn path -> ["-pa", List.to_string(path)] end)

    {output, 0} =
      System.cmd(executable, code_paths ++ ["-e", code],
        env: [{"TMPDIR", tmp_dir}],
        stderr_to_stdout: true
      )

    String.trim(output)
  end
end
