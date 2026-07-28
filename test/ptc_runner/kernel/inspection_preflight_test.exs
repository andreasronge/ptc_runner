defmodule PtcRunner.Kernel.InspectionPreflightTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.Manifest
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ResultArtifact
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.TraceLog

  describe "InspectionArtifact.preflight_destination/1" do
    @tag :tmp_dir
    test "classifies invalid, occupied, unavailable, and free destinations", %{tmp_dir: dir} do
      assert {:error, :invalid_inspection_path} = InspectionArtifact.preflight_destination(42)

      assert {:error, :invalid_inspection_path} =
               InspectionArtifact.preflight_destination(Path.join(dir, "run.jsonl"))

      file = Path.join(dir, "file.inspection.jsonl")
      File.write!(file, "occupied")

      assert {:error, :inspection_destination_exists} =
               InspectionArtifact.preflight_destination(file)

      symlink = Path.join(dir, "link.inspection.jsonl")
      File.ln_s!(file, symlink)

      assert {:error, :inspection_destination_exists} =
               InspectionArtifact.preflight_destination(symlink)

      directory = Path.join(dir, "dir.inspection.jsonl")
      File.mkdir!(directory)

      assert {:error, :inspection_destination_exists} =
               InspectionArtifact.preflight_destination(directory)

      under_file = Path.join(file, "nested.inspection.jsonl")

      assert {:error, :inspection_destination_unavailable} =
               InspectionArtifact.preflight_destination(under_file)

      assert {:error, :inspection_destination_unavailable} =
               InspectionArtifact.preflight_destination(
                 Path.join([dir, "missing", "run.inspection.jsonl"])
               )

      assert :ok =
               InspectionArtifact.preflight_destination(Path.join(dir, "free.inspection.jsonl"))
    end

    @tag :tmp_dir
    test "rejects publication through a replaceable parent directory", %{tmp_dir: dir} do
      replaceable = Path.join(dir, "replaceable")
      File.mkdir!(replaceable)
      File.chmod!(replaceable, 0o777)

      assert {:error, :inspection_persistence_failed} =
               InspectionArtifact.preflight_destination(
                 Path.join(replaceable, "run.inspection.jsonl")
               )
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

      assert {:error, :inspection_persistence_failed} =
               InspectionArtifact.preflight_destination(
                 Path.join(alias_path, "run.inspection.jsonl")
               )
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

      assert {:error, :inspection_persistence_failed} =
               InspectionArtifact.preflight_destination(
                 Path.join([alias_path, "..", "run.inspection.jsonl"])
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

      assert {:error, :inspection_persistence_failed} =
               InspectionArtifact.preflight_destination(
                 Path.join(alias_path, "run.inspection.jsonl")
               )
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

      {:ok, registry} = ProviderRegistry.new(%{"probe" => builder})

      manifest_path =
        write_manifest(dir, %{"workflow" => [%{"name" => "probe", "config" => %{}}]})

      occupied = Path.join(dir, "run.inspection.jsonl")
      File.write!(occupied, "occupied")

      assert {:error, {:inspection_preflight_failed, :inspection_destination_exists}} =
               RunBuilder.run(manifest_path, registry,
                 trace: Path.join(dir, "run.jsonl"),
                 inspect: occupied
               )

      refute_received :provider_builder_invoked
    end

    @tag :tmp_dir
    test "manifest and input errors take precedence over an occupied destination", %{
      tmp_dir: dir
    } do
      {:ok, registry} = ProviderRegistry.new()
      occupied = Path.join(dir, "run.inspection.jsonl")
      File.write!(occupied, "occupied")

      missing_manifest = Path.join(dir, "absent.json")

      assert {:error, reason} =
               RunBuilder.run(missing_manifest, registry, inspect: occupied)

      refute match?({:inspection_preflight_failed, _reason}, reason)

      manifest_path = write_manifest(dir, %{})

      assert {:error, reason} =
               RunBuilder.run(manifest_path, registry,
                 mission: "absent-override.json",
                 inspect: occupied
               )

      refute match?({:inspection_preflight_failed, _reason}, reason)
    end

    @tag :tmp_dir
    test "an occupied result destination is rejected before provider acquisition", %{tmp_dir: dir} do
      parent = self()

      builder = fn _config, _context ->
        send(parent, :provider_builder_invoked)
        {:error, :should_not_run}
      end

      {:ok, registry} = ProviderRegistry.new(%{"probe" => builder})

      manifest_path =
        write_manifest(dir, %{"workflow" => [%{"name" => "probe", "config" => %{}}]})

      occupied = Path.join(dir, "result.json")
      File.write!(occupied, "occupied")

      assert {:error, {:result_preflight_failed, :result_destination_exists}} =
               RunBuilder.run(manifest_path, registry, output: occupied)

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

      {:ok, registry} = ProviderRegistry.new(%{"probe" => builder})

      manifest_path =
        write_manifest(dir, %{"workflow" => [%{"name" => "probe", "config" => %{}}]})

      destination = Path.join([dir, "missing", "result.json"])

      assert {:error, {:result_preflight_failed, :invalid_result_destination}} =
               RunBuilder.run(manifest_path, registry, output: destination)

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

      {:ok, registry} = ProviderRegistry.new(%{"probe" => builder})

      manifest_path =
        write_manifest(dir, %{"workflow" => [%{"name" => "probe", "config" => %{}}]})

      real_parent = Path.join(dir, "real")
      alias_parent = Path.join(dir, "alias")
      File.mkdir!(real_parent)
      File.ln_s!(real_parent, alias_parent)

      for options <- [
            [
              output: Path.join(dir, "same.jsonl"),
              trace: Path.join(dir, "same.jsonl")
            ],
            [
              output: Path.join(dir, "same.inspection.jsonl"),
              inspect: Path.join(dir, "same.inspection.jsonl")
            ],
            [
              output: Path.join(real_parent, "same.jsonl"),
              trace: Path.join(alias_parent, "same.jsonl")
            ],
            [
              output: Path.join(real_parent, "Case.jsonl"),
              trace: Path.join(real_parent, "case.jsonl")
            ],
            [
              output: Path.join(real_parent, "σ.jsonl"),
              trace: Path.join(real_parent, "ς.jsonl")
            ]
          ] do
        assert {:error, {:artifact_preflight_failed, :conflicting_destinations}} =
                 RunBuilder.run(manifest_path, registry, options)

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

      {:ok, registry} = ProviderRegistry.new(%{"probe" => builder})

      manifest_path =
        write_manifest(dir, %{"workflow" => [%{"name" => "probe", "config" => %{}}]})

      destination = Path.join([dir, "missing", "run.inspection.jsonl"])

      assert {:error, {:inspection_preflight_failed, :inspection_destination_unavailable}} =
               RunBuilder.run(manifest_path, registry, inspect: destination)

      refute_received :provider_builder_invoked
    end

    @tag :tmp_dir
    test "unwritable artifact parents are rejected before provider acquisition", %{tmp_dir: dir} do
      parent = self()

      builder = fn _config, _context ->
        send(parent, :provider_builder_invoked)
        {:error, :should_not_run}
      end

      {:ok, registry} = ProviderRegistry.new(%{"probe" => builder})

      manifest_path =
        write_manifest(dir, %{"workflow" => [%{"name" => "probe", "config" => %{}}]})

      unwritable = Path.join(dir, "unwritable")
      File.mkdir!(unwritable)
      File.chmod!(unwritable, 0o500)
      on_exit(fn -> File.chmod(unwritable, 0o700) end)

      cases = [
        {[output: Path.join(unwritable, "result.json")],
         {:result_preflight_failed, :invalid_result_destination}},
        {[inspect: Path.join(unwritable, "run.inspection.jsonl")],
         {:inspection_preflight_failed, :inspection_destination_unavailable}},
        {[trace: Path.join(unwritable, "run.jsonl")],
         {:trace_preflight_failed, :trace_destination_unavailable}}
      ]

      for {options, reason} <- cases do
        assert {:error, ^reason} = RunBuilder.run(manifest_path, registry, options)
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

      {:ok, registry} = ProviderRegistry.new(%{"probe" => builder})

      manifest_path =
        write_manifest(dir, %{"workflow" => [%{"name" => "probe", "config" => %{}}]})

      assert {:error, {:trace_preflight_failed, :normal_trace_requires_normal_suffix}} =
               RunBuilder.run(manifest_path, registry, trace: Path.join(dir, "run.private.jsonl"))

      refute_received :provider_builder_invoked
    end

    @tag :tmp_dir
    test "missing trace lock dependencies are rejected before provider acquisition", %{
      tmp_dir: dir
    } do
      parent = self()
      original_path = System.get_env("PATH")
      sh = System.find_executable("sh") || flunk("sh is required for this test")
      fake_bin = Path.join(dir, "trace-shell-only-bin")

      on_exit(fn ->
        System.put_env("PATH", original_path)
      end)

      File.mkdir!(fake_bin)
      File.ln_s!(sh, Path.join(fake_bin, "sh"))
      System.put_env("PATH", fake_bin)

      builder = fn _config, _context ->
        send(parent, :provider_builder_invoked)
        {:error, :should_not_run}
      end

      {:ok, registry} = ProviderRegistry.new(%{"probe" => builder})

      manifest_path =
        write_manifest(dir, %{"workflow" => [%{"name" => "probe", "config" => %{}}]})

      assert {:error, {:trace_preflight_failed, :source_unavailable}} =
               RunBuilder.run(manifest_path, registry, trace: Path.join(dir, "run.jsonl"))

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

      {:ok, registry} = ProviderRegistry.new(%{"probe" => builder})

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
               RunBuilder.run(manifest_path, registry, trace: missing_parent)

      refute_received :provider_builder_invoked

      for destination <- [directory, symlink] do
        assert {:error, {:trace_preflight_failed, :invalid_trace_path}} =
                 RunBuilder.run(manifest_path, registry, trace: destination)

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

      {:ok, manifest} = Manifest.load(manifest_path)
      occupied = Path.join(dir, "occupied.inspection.jsonl")
      File.write!(occupied, "occupied")

      assert {:error, {:inspection_preflight_failed, :inspection_destination_exists}} =
               RunBuilder.build(manifest, registry, inspect: occupied)

      refute_received :provider_prepared

      shared = Path.join(dir, "shared.inspection.jsonl")

      assert {:error, {:artifact_preflight_failed, :conflicting_destinations}} =
               RunBuilder.build(manifest, registry, inspect: shared, output: shared)

      refute_received :provider_prepared
    end

    @tag :tmp_dir
    test "a relative result destination keeps its preflight working directory", %{tmp_dir: dir} do
      original_cwd = File.cwd!()
      changed_cwd = Path.join(dir, "changed")
      File.mkdir!(changed_cwd)
      on_exit(fn -> File.cd!(original_cwd) end)

      {:ok, capability} =
        Capability.new(
          name: "probe.unused",
          input_schema: %{"type" => "object", "additionalProperties" => false},
          callback: fn _arguments -> {:ok, %{}} end
        )

      builder = fn _config, _context ->
        File.cd!(changed_cwd)
        {:ok, %{capabilities: [capability], snapshot: nil, close: nil}}
      end

      {:ok, registry} = ProviderRegistry.new(%{"probe" => builder})

      manifest_path =
        write_manifest(dir, %{"workflow" => [%{"name" => "probe", "config" => %{}}]})

      File.cd!(dir)

      assert {:ok, %{value: 42}} =
               RunBuilder.run(manifest_path, registry, output: "result.json")

      assert File.regular?(Path.join(dir, "result.json"))
      refute File.exists?(Path.join(changed_cwd, "result.json"))
    end

    @tag :tmp_dir
    test "relative artifact destinations share one captured working directory", %{tmp_dir: dir} do
      original_cwd = File.cwd!()
      changed_cwd = Path.join(dir, "changed")
      File.mkdir!(changed_cwd)
      on_exit(fn -> File.cd!(original_cwd) end)

      {:ok, capability} =
        Capability.new(
          name: "probe.unused",
          input_schema: %{"type" => "object", "additionalProperties" => false},
          callback: fn _arguments -> {:ok, %{}} end
        )

      builder = fn _config, _context ->
        File.cd!(changed_cwd)
        {:ok, %{capabilities: [capability], snapshot: nil, close: nil}}
      end

      {:ok, registry} = ProviderRegistry.new(%{"probe" => builder})

      manifest_path =
        write_manifest(dir, %{"workflow" => [%{"name" => "probe", "config" => %{}}]})

      File.cd!(dir)

      assert {:ok, %{value: 42}} =
               RunBuilder.run(manifest_path, registry,
                 output: "result.json",
                 trace: "trace.jsonl",
                 inspect: "run.inspection.jsonl"
               )

      for name <- ["result.json", "trace.jsonl", "run.inspection.jsonl"] do
        assert File.regular?(Path.join(dir, name))
        refute File.exists?(Path.join(changed_cwd, name))
      end
    end
  end

  describe "TraceLog private destination ownership" do
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
    test "preflights an existing private trace without the creation executable", %{
      tmp_dir: dir
    } do
      original_path = System.get_env("PATH")
      id = System.find_executable("id") || flunk("id is required for this test")
      sh = System.find_executable("sh") || flunk("sh is required for this test")
      lock = System.find_executable("lockf") || System.find_executable("flock")
      lock = lock || flunk("lockf or flock is required for this test")
      fake_bin = Path.join(dir, "trace-runtime-bin")
      path = Path.join(dir, "existing.private.jsonl")

      on_exit(fn ->
        System.put_env("PATH", original_path)
      end)

      File.mkdir!(fake_bin)
      File.ln_s!(id, Path.join(fake_bin, "id"))
      File.ln_s!(sh, Path.join(fake_bin, "sh"))
      File.ln_s!(lock, Path.join(fake_bin, Path.basename(lock)))
      File.write!(path, "")
      File.chmod!(path, 0o600)

      # Initialize and validate the per-authority append-lock directory while
      # the first-creation executable is still available. The assertion below
      # then proves that an existing trace and lease root do not need it.
      assert :ok = TraceLog.preflight_destination(path, true)

      System.put_env("PATH", fake_bin)

      assert :ok = TraceLog.preflight_destination(path, true)
    end

    @tag :tmp_dir
    test "rejects a trace destination when no append locking utility is available", %{
      tmp_dir: dir
    } do
      original_path = System.get_env("PATH")
      sh = System.find_executable("sh") || flunk("sh is required for this test")
      fake_bin = Path.join(dir, "shell-only-bin")

      on_exit(fn ->
        System.put_env("PATH", original_path)
      end)

      File.mkdir!(fake_bin)
      File.ln_s!(sh, Path.join(fake_bin, "sh"))
      System.put_env("PATH", fake_bin)

      assert {:error, :source_unavailable} =
               TraceLog.preflight_destination(Path.join(dir, "run.jsonl"), false)
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

      assert "{:error, :source_unavailable}" =
               trace_preflight_in_fresh_runtime(dir, Path.join(dir, "run.jsonl"))

      assert Bitwise.band(File.stat!(victim).mode, 0o777) == 0o755
    end

    @tag :tmp_dir
    test "missing artifact destinations still require the creation executable", %{
      tmp_dir: dir
    } do
      original_path = System.get_env("PATH")
      id = System.find_executable("id") || flunk("id is required for this test")
      fake_bin = Path.join(dir, "id-only-creation-bin")

      on_exit(fn ->
        System.put_env("PATH", original_path)
      end)

      File.mkdir!(fake_bin)
      File.ln_s!(id, Path.join(fake_bin, "id"))
      System.put_env("PATH", fake_bin)

      assert {:error, :result_persistence_failed} =
               ResultArtifact.preflight_destination(
                 Path.join(dir, "result.json"),
                 :normal,
                 :normal
               )

      assert {:error, :inspection_persistence_failed} =
               InspectionArtifact.preflight_destination(Path.join(dir, "run.inspection.jsonl"))

      assert {:error, :source_unavailable} =
               TraceLog.preflight_destination(
                 Path.join(dir, "run.private.jsonl"),
                 true
               )
    end

    @tag :tmp_dir
    test "rejects a mode-0600 trace owned outside the validated process authority", %{
      tmp_dir: dir
    } do
      original_path = System.get_env("PATH")
      actual_uid = current_uid()

      path =
        Path.join(
          "/tmp",
          "ptc-private-owner-#{System.unique_integer([:positive])}.private.jsonl"
        )

      on_exit(fn ->
        System.put_env("PATH", original_path)
        File.rm(path)
      end)

      fake_bin = Path.join(dir, "bin")
      File.mkdir!(fake_bin)
      fake_id = Path.join(fake_bin, "id")
      owner_uid = if actual_uid == 0, do: 1, else: actual_uid
      authority_uid = owner_uid + 1
      File.write!(fake_id, "#!/bin/sh\nprintf '%s\\n' '#{authority_uid}'\n")
      File.chmod!(fake_id, 0o755)
      System.put_env("PATH", fake_bin <> ":" <> original_path)

      File.write!(path, "")
      File.chmod!(path, 0o600)
      if actual_uid == 0, do: :ok = :file.change_owner(String.to_charlist(path), owner_uid)

      assert {:error, :trace_destination_unavailable} =
               TraceLog.preflight_destination(path, true)

      assert {:error, :source_unavailable} =
               TraceLog.append_jsonl(path, [], private: true)
    end
  end

  describe "temporary sibling path bounds" do
    @tag :tmp_dir
    test "near-NAME_MAX destinations preflight and publish through every private path", %{
      tmp_dir: dir
    } do
      result_path = Path.join(dir, near_name_limit(".private.json"))
      inspection_path = Path.join(dir, near_name_limit(".inspection.jsonl"))
      trace_path = Path.join(dir, near_name_limit(".private.jsonl"))

      {:ok, inspection_sink} =
        InspectionSink.start(run_id: "long-path-run", trace_id: "long-path-trace")

      assert :ok =
               InspectionSink.emit(
                 inspection_sink,
                 "capability-input",
                 %{capability_id: "long-path-capability"},
                 %{environment: :mission, name: "read", arguments: %{}}
               )

      assert {:ok, inspection_records} = InspectionSink.records(inspection_sink)
      assert :ok = InspectionSink.stop(inspection_sink)

      canonical_events = [
        %{
          run_id: "long-path-run",
          trace_id: "long-path-trace",
          type: "capability-started",
          data: %{
            capability_id: "long-path-capability",
            environment: :mission,
            name: "read"
          }
        }
      ]

      trace_events = [
        %{
          "schema_version" => 1,
          "run_id" => "long-path-run",
          "trace_id" => "long-path-trace",
          "sequence" => 1,
          "timestamp" => "2026-07-28T12:00:00Z",
          "type" => "run-started",
          "data" => %{}
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
               InspectionArtifact.persist(
                 inspection_path,
                 inspection_records,
                 canonical_events
               )

      assert :ok = TraceLog.preflight_destination(trace_path, true)
      assert :ok = TraceLog.append_jsonl(trace_path, trace_events, private: true)

      assert Enum.all?([result_path, inspection_path, trace_path], &File.regular?/1)
    end
  end

  describe "temporary-directory cleanup authority" do
    @tag :tmp_dir
    test "a failed symlink collision cannot delete through any persistence path", %{tmp_dir: dir} do
      original_path = System.get_env("PATH")
      original_ln = System.get_env("PTC_TEST_REAL_LN")
      fake_bin = install_collision_bin!(dir)

      on_exit(fn ->
        System.put_env("PATH", original_path)
        System.delete_env("PTC_TEST_COLLISION_TARGET")
        restore_env("PTC_TEST_REAL_LN", original_ln)
      end)

      System.put_env("PATH", fake_bin)

      {:ok, inspection_sink} =
        InspectionSink.start(run_id: "collision-run", trace_id: "collision-trace")

      assert :ok =
               InspectionSink.emit(
                 inspection_sink,
                 "capability-input",
                 %{capability_id: "collision-capability"},
                 %{environment: :mission, name: "read", arguments: %{}}
               )

      assert {:ok, inspection_records} = InspectionSink.records(inspection_sink)
      assert :ok = InspectionSink.stop(inspection_sink)

      canonical_events = [
        %{
          run_id: "collision-run",
          trace_id: "collision-trace",
          type: "capability-started",
          data: %{
            capability_id: "collision-capability",
            environment: :mission,
            name: "read"
          }
        }
      ]

      trace_events = [
        %{
          "schema_version" => 1,
          "run_id" => "collision-run",
          "trace_id" => "collision-trace",
          "sequence" => 1,
          "timestamp" => "2026-07-28T12:00:00Z",
          "type" => "run-started",
          "data" => %{}
        }
      ]

      cases = [
        {"result", "artifact",
         fn path ->
           ResultArtifact.persist(path, %{"ok" => true}, :private, :private)
         end},
        {"inspection", "artifact",
         fn path ->
           InspectionArtifact.persist(path, inspection_records, canonical_events)
         end},
        {"trace", "trace",
         fn path ->
           TraceLog.append_jsonl(path, trace_events, private: true)
         end}
      ]

      for {name, leaf, persist} <- cases do
        target = Path.join(dir, "#{name}-collision-target")

        destination =
          Path.join(
            dir,
            if(name == "trace",
              do: "#{name}.private.jsonl",
              else: "#{name}.inspection.jsonl"
            )
          )

        File.mkdir!(target)
        protected = Path.join(target, leaf)
        File.write!(protected, "must-survive")
        System.put_env("PTC_TEST_COLLISION_TARGET", target)

        assert {:error, _reason} = persist.(destination)
        assert File.read!(protected) == "must-survive"
      end
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

  defp install_collision_bin!(dir) do
    id = System.find_executable("id") || flunk("id is required for this test")
    sh = System.find_executable("sh") || flunk("sh is required for this test")
    ln = System.find_executable("ln") || flunk("ln is required for this test")
    lock = System.find_executable("lockf") || System.find_executable("flock")
    lock = lock || flunk("lockf or flock is required for this test")
    bin = Path.join(dir, "collision-bin")

    File.mkdir!(bin)
    File.ln_s!(id, Path.join(bin, "id"))
    File.ln_s!(sh, Path.join(bin, "sh"))
    File.ln_s!(lock, Path.join(bin, Path.basename(lock)))

    mkdir = Path.join(bin, "mkdir")

    File.write!(
      mkdir,
      """
      #!/bin/sh
      "$PTC_TEST_REAL_LN" -s "$PTC_TEST_COLLISION_TARGET" "$3"
      exit 1
      """
    )

    File.chmod!(mkdir, 0o700)
    System.put_env("PTC_TEST_REAL_LN", ln)
    bin
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
