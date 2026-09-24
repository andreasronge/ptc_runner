defmodule PtcRunner.Kernel.InspectionPreflightGlobalStateTest do
  # async: false — these cases rewrite PATH or change the VM's cwd (File.cd!) to prove artifact
  # preflight fails closed and anchors relative destinations (class D). The rest of inspection
  # preflight coverage is async in InspectionPreflightTest.
  use ExUnit.Case, async: false
  @moduletag :operator

  import PtcRunner.TestSupport.CommandEngineFixtures,
    only: [valid_manifest: 1, write_application: 4]

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ResultArtifact
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.TestSupport.RunLifecycle
  alias PtcRunner.TestSupport.StreamingInspection
  alias PtcRunner.TestSupport.TestHelpers

  describe "RunBuilder preflight ordering" do
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

      {:ok, registry} = ProviderRegistry.new(%{"probe" => TestHelpers.staged_provider(builder)})

      manifest_path =
        write_probe_application(dir)

      assert {:error, {:trace_preflight_failed, :source_unavailable}} =
               manifest_path
               |> ApplicationPackage.request_directory(
                 installed_limits: registry.installed_limits,
                 inspection_capture: false
               )
               |> RunLifecycle.build(registry, trace_path: Path.join(dir, "run.jsonl"))
               |> RunLifecycle.execute()

      refute_received :provider_builder_invoked
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

      {:ok, registry} = ProviderRegistry.new(%{"probe" => TestHelpers.staged_provider(builder)})

      manifest_path =
        write_probe_application(dir)

      File.cd!(dir)

      assert {:ok, %{value: 42}} =
               manifest_path
               |> ApplicationPackage.request_directory(
                 installed_limits: registry.installed_limits,
                 inspection_capture: false
               )
               |> RunLifecycle.build(registry, output: "result.json")
               |> RunLifecycle.execute()

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

      {:ok, registry} = ProviderRegistry.new(%{"probe" => TestHelpers.staged_provider(builder)})

      manifest_path =
        write_probe_application(dir)

      File.cd!(dir)

      assert {:ok, %{value: 42}} =
               manifest_path
               |> ApplicationPackage.request_directory(
                 installed_limits: registry.installed_limits,
                 inspection_capture: true
               )
               |> RunLifecycle.build(registry,
                 output: "result.json",
                 trace_path: "trace.jsonl",
                 inspect: "run.ptcins"
               )
               |> RunLifecycle.execute()

      for name <- ["result.json", "trace.jsonl", "run.ptcins"] do
        assert File.regular?(Path.join(dir, name))
        refute File.exists?(Path.join(changed_cwd, name))
      end
    end
  end

  describe "TraceLog private destination ownership" do
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
    test "trace preflight does not require an append locking utility", %{
      tmp_dir: dir
    } do
      original_path = System.get_env("PATH")
      sh = System.find_executable("sh") || flunk("sh is required for this test")
      id = System.find_executable("id") || flunk("id is required for this test")
      mkdir = System.find_executable("mkdir") || flunk("mkdir is required for this test")
      fake_bin = Path.join(dir, "shell-only-bin")

      on_exit(fn ->
        System.put_env("PATH", original_path)
      end)

      File.mkdir!(fake_bin)
      File.ln_s!(sh, Path.join(fake_bin, "sh"))
      File.ln_s!(id, Path.join(fake_bin, "id"))
      File.ln_s!(mkdir, Path.join(fake_bin, "mkdir"))
      System.put_env("PATH", fake_bin)

      assert :ok =
               TraceLog.preflight_destination(Path.join(dir, "run.jsonl"), false)
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
               InspectionArtifact.preflight_destination(Path.join(dir, "run.ptcins"))

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
      actual_uid = current_uid!()

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

    @tag :tmp_dir
    test "a replaced authority binary at one path is not served a cached answer", %{
      tmp_dir: dir
    } do
      original_path = System.get_env("PATH")
      actual_uid = current_uid!()

      path =
        Path.join(
          "/tmp",
          "ptc-private-rebind-#{System.unique_integer([:positive])}.private.jsonl"
        )

      on_exit(fn ->
        System.put_env("PATH", original_path)
        File.rm(path)
      end)

      fake_bin = Path.join(dir, "bin")
      File.mkdir!(fake_bin)
      fake_id = Path.join(fake_bin, "id")
      owner_uid = if actual_uid == 0, do: 1, else: actual_uid

      write_fake_id = fn uid ->
        File.write!(fake_id, "#!/bin/sh\nprintf '%s\\n' '#{uid}'\n")
        File.chmod!(fake_id, 0o755)
      end

      write_fake_id.(owner_uid + 1)
      System.put_env("PATH", fake_bin <> ":" <> original_path)

      File.write!(path, "")
      File.chmod!(path, 0o600)
      if actual_uid == 0, do: :ok = :file.change_owner(String.to_charlist(path), owner_uid)

      # Populates any authority cache under this pathname with the mismatch.
      assert {:error, :trace_destination_unavailable} =
               TraceLog.preflight_destination(path, true)

      # The same pathname now answers with the owning uid. A cache keyed on the
      # pathname alone would keep refusing; the binary's identity has changed,
      # so the answer must be read again.
      write_fake_id.(owner_uid)

      assert :ok = TraceLog.preflight_destination(path, true)
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

      {:ok, inspection_sink} =
        StreamingInspection.start(
          run_id: "collision-run",
          trace_id: "collision-trace"
        )

      assert :ok =
               InspectionSink.emit(
                 inspection_sink,
                 "capability-input",
                 %{capability_id: "collision-capability"},
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
      System.put_env("PATH", fake_bin)

      _canonical_events = [
        %{
          run_id: "collision-run",
          trace_id: "collision-trace",
          type: "capability-started",
          data: %{
            capability_id: "collision-capability",
            environment: :mission,
            mission_name: "default",
            name: "read"
          }
        }
      ]

      trace_events = [
        %{
          "schema_version" => 2,
          "run_id" => "collision-run",
          "trace_id" => "collision-trace",
          "sequence" => 1,
          "timestamp" => "2026-07-28T12:00:00Z",
          "type" => "run-started",
          "data" => %{"missions" => %{"default" => %{}}}
        }
      ]

      cases = [
        {"result", "artifact",
         fn path ->
           ResultArtifact.persist(path, %{"ok" => true}, :private, :private)
         end},
        {"inspection", "artifact",
         fn path ->
           StreamingInspection.write_path(path, inspection_records)
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
              else: "#{name}.ptcins"
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

  defp write_probe_application(dir) do
    manifest =
      valid_manifest(%{
        "providers" => %{"workflow" => [%{"name" => "probe", "config" => %{}}], "mission" => []}
      })

    write_application(dir, "probe-application", manifest, [
      {"main.clj", "(ns app) (defn run [input] (return 42))"}
    ])
  end

  defp current_uid! do
    {uid, 0} = System.cmd("id", ["-u"])
    String.to_integer(String.trim(uid))
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
