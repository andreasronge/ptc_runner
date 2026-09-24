defmodule PtcRunner.Kernel.ProjectCommandTest do
  use ExUnit.Case, async: true
  @moduletag :operator

  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandEntry
  alias PtcRunner.Kernel.CommandFrontend
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandParser
  alias PtcRunner.Kernel.CommandPreparation
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.PublicationHandle
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.TestSupport.Eventually

  @tag :tmp_dir
  test "a staging reservation failure reaches the default V5 ledger with its cause", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    output = Path.join(directory, "result.json")
    event = [:ptc_runner, :publication, :destination_unavailable]
    ref = :telemetry_test.attach_event_handlers(self(), [event])
    on_exit(fn -> :telemetry.detach(ref) end)

    presentation =
      PublicationHandle.with_fault_hook(
        fn path, stage ->
          if path == output and stage == :staging_file, do: {:error, :eio}, else: :ok
        end,
        fn ->
          CommandFrontend.execute(["run", project, "--output", output], :standalone, fn _ ->
            {:ok, CommandRuntime.standalone()}
          end)
        end
      )

    assert presentation.exit_status != 0
    envelope = CommandOutcome.to_map(presentation.outcome)
    assert envelope["schema_version"] == 5
    assert envelope["error"]["code"] == "result_destination_unavailable"
    assert envelope["error"]["cause"] == "filesystem_error"
    assert Jason.decode!(presentation.stdout) == envelope
    assert {:ok, schema} = JSV.build(CommandContract.published_schema(), atoms: false)
    assert {:ok, _validated} = JSV.validate(envelope, schema, cast: false)
    refute Jason.encode!(envelope) =~ directory
    run_ref = envelope["run_ref"]
    ledger = Path.join([target, ".ptc", "envelopes", run_ref <> ".json"])
    assert Jason.decode!(File.read!(ledger)) == envelope
    assert_receive {^event, ^ref, %{}, %{run_ref: ^run_ref, cause: {:reason, :eio}}}
  end

  @tag :tmp_dir
  test "a missing host before sink creation reaches the default V5 ledger", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")

    document = project |> File.read!() |> Jason.decode!()

    File.write!(
      project,
      Jason.encode!(Map.put(document, "host", %{"path" => "missing-host.json"}))
    )

    presentation =
      CommandFrontend.execute(["run", project], :standalone, fn _ ->
        {:ok, CommandRuntime.standalone()}
      end)

    assert presentation.exit_status != 0
    envelope = CommandOutcome.to_map(presentation.outcome)
    assert envelope["schema_version"] == 5
    assert envelope["error"]["code"] == "host_unavailable"
    assert envelope["error"]["cause"] == "resource_unavailable"
    assert Jason.decode!(presentation.stdout) == envelope
    refute Jason.encode!(envelope) =~ directory
    ledger = Path.join([target, ".ptc", "envelopes", envelope["run_ref"] <> ".json"])
    assert Jason.decode!(File.read!(ledger)) == envelope
  end

  @tag :tmp_dir
  test "run admission reclaims interrupted staging with a dead owner", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project])
    staging = Path.join([target, ".ptc", "traces", ".ptc-private-012345abcdef"])
    File.mkdir!(staging)
    File.chmod!(staging, 0o700)
    File.write!(Path.join(staging, "artifact"), "interrupted trace")
    File.write!(Path.join(staging, "owner"), "2147483647")
    File.chmod!(Path.join(staging, "owner"), 0o600)
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project])
    refute File.exists?(staging)
  end

  @tag :tmp_dir
  test "stale staging is reclaimed before the runtime bootstrap starts", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project])
    staging = Path.join([target, ".ptc", "traces", ".ptc-private-012345abcdef"])
    File.mkdir!(staging)
    File.chmod!(staging, 0o700)
    File.write!(Path.join(staging, "owner"), "2147483647")
    File.chmod!(Path.join(staging, "owner"), 0o600)

    parent = self()

    CommandFrontend.execute(["run", project], :standalone, fn _arguments ->
      send(parent, {:staging_at_bootstrap, File.exists?(staging)})
      {:error, :command_bootstrap_failed}
    end)

    assert_receive {:staging_at_bootstrap, false}
  end

  @tag :tmp_dir
  test "admission preserves live, uncertain, unrelated and outside-root staging",
       %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project])
    root = Path.join(target, ".ptc")

    cases = [
      live: System.pid(),
      fresh: nil,
      malformed: "not-a-pid",
      uncertain: "2147483648",
      unreadable: "2147483647"
    ]

    paths =
      for {{kind, pid}, index} <- Enum.with_index(cases) do
        path =
          Path.join([root, "traces", ".ptc-private-" <> String.pad_leading("#{index}", 12, "0")])

        File.mkdir!(path)
        File.chmod!(path, 0o700)
        File.write!(Path.join(path, "artifact"), "keep")

        if pid do
          File.write!(Path.join(path, "owner"), pid)
          File.chmod!(Path.join(path, "owner"), if(kind == :unreadable, do: 0, else: 0o600))
        end

        path
      end

    unrelated = Path.join(root, "unrelated")
    File.write!(unrelated, "keep")
    outside = Path.join(directory, ".ptc-private-ffffffffffff")
    File.mkdir!(outside)
    File.chmod!(outside, 0o700)
    File.write!(Path.join(outside, "owner"), "2147483647")
    reservation = Path.join([root, "traces", ".unrelated.ptc-reservation"])
    File.mkdir!(reservation)
    File.write!(Path.join(reservation, "owner"), "2147483647")
    old = Path.join([root, "results", ".ptc-private-aaaaaaaaaaaa"])
    File.mkdir!(old)
    File.chmod!(old, 0o700)
    File.write!(Path.join(old, "artifact"), "old")
    File.touch!(old, System.os_time(:second) - 61)
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project])
    refute File.exists?(old)
    for path <- paths ++ [outside, reservation], do: assert(File.dir?(path))
    assert File.read!(unrelated) == "keep"
  end

  @tag :tmp_dir
  test "admission bounds staging cleanup and never descends into contents", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project])
    parent = Path.join([target, ".ptc", "traces"])

    paths =
      for index <- 1..20 do
        path = Path.join(parent, ".ptc-private-" <> String.pad_leading("#{index}", 12, "0"))
        File.mkdir!(path)
        File.chmod!(path, 0o700)
        File.write!(Path.join(path, "owner"), "2147483647")
        File.chmod!(Path.join(path, "owner"), 0o600)
        File.write!(Path.join(path, "artifact"), "stale")
        path
      end

    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project])
    assert Enum.count(paths, &File.dir?/1) >= 4
    assert Enum.count(paths, &File.dir?/1) < 20
    # Deletion changes the consumed prefix; the portable count cursor may
    # wrap before reaching entries shifted behind it.
    Enum.reduce_while(1..10, Enum.count(paths, &File.dir?/1), fn _, before ->
      assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project])
      remaining = Enum.count(paths, &File.dir?/1)
      assert (before - remaining) in 0..16
      if remaining == 0, do: {:halt, 0}, else: {:cont, remaining}
    end)

    refute Enum.any?(paths, &File.dir?/1)
    path = hd(paths)
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    File.write!(Path.join(path, "owner"), "2147483647")
    File.chmod!(Path.join(path, "owner"), 0o600)
    File.mkdir!(Path.join(path, "artifact"))
    File.write!(Path.join([path, "artifact", "keep"]), "nested")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project])
    assert File.read!(Path.join([path, "artifact", "keep"])) == "nested"
  end

  @tag :tmp_dir
  test "the inspection budget includes unrelated entries in the configured root", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    document = Jason.decode!(File.read!(project))
    File.write!(project, Jason.encode!(put_in(document, ["artifacts", "root"], "custom")))
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project])
    root = Path.join(target, "custom")
    for index <- 1..300, do: File.write!(Path.join(root, "unrelated-#{index}"), "keep")
    staging = Path.join([root, "traces", ".ptc-private-aaaaaaaaaaaa"])
    File.mkdir!(staging)
    File.chmod!(staging, 0o700)
    File.write!(Path.join(staging, "owner"), "2147483647")
    File.chmod!(Path.join(staging, "owner"), 0o600)
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project])
    refute File.exists?(staging)
    for index <- 1..300, do: assert(File.read!(Path.join(root, "unrelated-#{index}")) == "keep")
    root_staging = Path.join(root, ".ptc-private-bbbbbbbbbbbb")
    File.mkdir!(root_staging)
    File.chmod!(root_staging, 0o700)
    File.write!(Path.join(root_staging, "owner"), "2147483647")
    File.chmod!(Path.join(root_staging, "owner"), 0o600)

    for _ <- 1..10 do
      CommandFrontend.execute(["run", project], :standalone, fn _arguments ->
        {:error, :command_bootstrap_failed}
      end)
    end

    refute File.exists?(root_staging)
  end

  @tag :tmp_dir
  test "later admissions progress past large ledgers and preserved candidates", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project])
    root = Path.join(target, ".ptc")

    for index <- 1..280,
        do: File.write!(Path.join([root, "envelopes", "existing-#{index}.json"]), "keep")

    paths =
      for index <- 1..20 do
        path =
          Path.join([root, "traces", ".ptc-private-" <> String.pad_leading("#{index}", 12, "0")])

        File.mkdir!(path)
        File.chmod!(path, 0o700)

        File.write!(
          Path.join(path, "owner"),
          if(index <= 16, do: System.pid(), else: "2147483647")
        )

        File.chmod!(Path.join(path, "owner"), 0o600)
        path
      end

    for _ <- 1..20 do
      CommandFrontend.execute(["run", project], :standalone, fn _arguments ->
        {:error, :command_bootstrap_failed}
      end)
    end

    for path <- Enum.take(paths, 16), do: assert(File.dir?(path))
    for path <- Enum.drop(paths, 16), do: refute(File.exists?(path))
    assert File.read!(Path.join([root, "envelopes", "existing-1.json"])) == "keep"
  end

  @tag :tmp_dir
  test "root staging follows the grace policy and symlink staging is preserved", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project])
    root = Path.join(target, ".ptc")
    old = Path.join(root, ".ptc-private-aaaaaaaaaaaa")
    File.mkdir!(old)
    File.chmod!(old, 0o700)
    File.touch!(old, System.os_time(:second) - 61)
    outside = Path.join(directory, "outside")
    File.mkdir!(outside)
    File.chmod!(outside, 0o700)
    File.write!(Path.join(outside, "owner"), "2147483647")
    File.write!(Path.join(outside, "artifact"), "keep")
    link = Path.join([root, "traces", ".ptc-private-bbbbbbbbbbbb"])
    File.ln_s!(outside, link)
    marker_link = Path.join([root, "results", ".ptc-private-cccccccccccc"])
    File.mkdir!(marker_link)
    File.chmod!(marker_link, 0o700)
    File.ln_s!(Path.join(outside, "owner"), Path.join(marker_link, "owner"))
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project])
    refute File.exists?(old)
    assert {:ok, %{type: :symlink}} = File.lstat(link)
    assert File.read!(Path.join(outside, "artifact")) == "keep"
    assert File.dir?(marker_link)
  end

  @tag :tmp_dir
  test "concurrent admissions preserve a live replacement of stale staging", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project])
    staging = Path.join([target, ".ptc", "traces", ".ptc-private-aaaaaaaaaaaa"])
    File.mkdir!(staging)
    File.chmod!(staging, 0o700)
    File.write!(Path.join(staging, "owner"), "2147483647")
    File.chmod!(Path.join(staging, "owner"), 0o600)
    parent = self()

    lock =
      Task.async(fn ->
        TraceLog.with_append_authority_lock(
          PrivateDirectory.staging_lock_path(staging),
          fn ->
            send(parent, :locked)

            receive do
              :release -> :ok
            end
          end
        )
      end)

    assert_receive :locked, 5_000

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          send(parent, :admitting)
          CommandEngine.dispatch(["run", project])
        end)
      end

    for _ <- tasks, do: assert_receive(:admitting, 5_000)
    File.rename!(staging, staging <> "-original")
    File.mkdir!(staging)
    File.chmod!(staging, 0o700)
    File.write!(Path.join(staging, "owner"), System.pid())
    File.chmod!(Path.join(staging, "owner"), 0o600)
    File.write!(Path.join(staging, "artifact"), "live replacement")
    send(lock.pid, :release)
    assert Task.await(lock, 10_000) == :ok
    for task <- tasks, do: assert({:ok, %CommandOutcome{}} = Task.await(task, 30_000))
    assert File.read!(Path.join(staging, "artifact")) == "live replacement"
    assert File.read!(Path.join(staging, "owner")) == System.pid()
  end

  @tag :tmp_dir
  @tag :nightly
  test "a VM killed during ptc run leaves staging reclaimed by the next admission", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    child = Path.join(directory, "interrupted.exs")
    envelope = Path.join([target, ".ptc", "envelopes", "interrupted.json"])
    staged = Path.join([target, ".ptc", "envelopes", ".ptc-private-*", "artifact"])

    File.write!(child, """
    {:ok, _apps} = Application.ensure_all_started(:ptc_runner)
    presentation = PtcRunner.Kernel.CommandFrontend.execute(
      ["run", #{inspect(project)}, "--envelope", #{inspect(envelope)}],
      :standalone, fn _arguments ->
        IO.puts("STAGING_READY")
        receive do
          :never -> {:ok, PtcRunner.Kernel.CommandRuntime.standalone()}
        end
      end)
    IO.puts("EARLY_EXIT: " <> Integer.to_string(presentation.exit_status))
    """)

    port =
      Port.open(
        {:spawn_executable, System.find_executable("elixir")},
        [
          :binary,
          :exit_status,
          {:line, 1024},
          {:args, Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)]) ++ [child]}
        ]
      )

    monitor = :erlang.monitor(:port, port)
    {:os_pid, pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      if Port.info(port), do: Port.close(port)
    end)

    Eventually.assert_eventually(fn ->
      receive do
        {^port, {:data, {:eol, "STAGING_READY"}}} -> true
        {^port, {:data, {:eol, "EARLY_EXIT: " <> status}}} -> flunk("admission failed: #{status}")
        {^port, {:data, _other}} -> false
        {^port, {:exit_status, status}} -> flunk("child exited early: #{status}")
      after
        0 -> false
      end
    end)

    [artifact] = Path.wildcard(staged, match_dot: true)
    staging = Path.dirname(artifact)
    assert File.read!(Path.join(staging, "owner")) == Integer.to_string(pid)
    assert Bitwise.band(File.stat!(Path.join(staging, "owner")).mode, 0o777) == 0o600
    assert {_, 0} = System.cmd(System.find_executable("kill"), ["-KILL", Integer.to_string(pid)])
    assert_receive {:DOWN, ^monitor, :port, ^port, _reason}, 10_000
    assert File.dir?(staging)
    refute File.exists?(envelope)
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project])
    refute File.exists?(staging)

    assert Path.wildcard(Path.join([target, ".ptc", "*", ".ptc-private-*"]), match_dot: true) ==
             []
  end

  @tag :tmp_dir
  test "an initialized project runs through its single project document", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")

    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")

    assert {:ok, %CommandOutcome{envelope: %{"status" => "ok", "run_ref" => run_ref} = envelope}} =
             CommandEngine.dispatch(["run", project])

    assert envelope["result"]["value"] == %{"greeting" => "hello world"}

    assert [trace] = Path.wildcard(Path.join([target, ".ptc", "traces", "*.jsonl"]))
    assert File.regular?(trace)

    envelope = Path.join([target, ".ptc", "envelopes", run_ref <> ".json"])
    persisted_envelope = Jason.decode!(File.read!(envelope))
    assert persisted_envelope["run_ref"] == run_ref
    assert persisted_envelope["artifact_state"]["result"] == "not_requested"
    refute Map.has_key?(persisted_envelope["result"], "value")
  end

  @tag :tmp_dir
  test "preparation remains read-only and creates the project artifact layout only at dispatch",
       %{
         tmp_dir: directory
       } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    artifact_root = Path.join(target, ".ptc")

    assert {:ok, preparation} = CommandEngine.prepare(["run", project])
    refute File.exists?(artifact_root)
    assert :ok = CommandPreparation.close(preparation)

    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project])
    assert File.dir?(artifact_root)
  end

  @tag :tmp_dir
  test "a first-run application failure still publishes its project envelope", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    project = Jason.decode!(File.read!(project_path))
    project = put_in(project, ["application", "path"], "missing.json")
    File.write!(project_path, Jason.encode!(project))

    assert {:error, %CommandOutcome{envelope: outcome}} =
             CommandEngine.dispatch(["run", project_path])

    assert outcome["error"]["phase"] == "application"
    envelope_path = Path.join([target, ".ptc", "envelopes", outcome["run_ref"] <> ".json"])
    assert Jason.decode!(File.read!(envelope_path))["error"]["phase"] == "application"
  end

  @tag :tmp_dir
  test "the frontend publishes a first-run failure envelope from project defaults", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    project = Jason.decode!(File.read!(project_path))
    project = put_in(project, ["application", "path"], "missing.json")
    File.write!(project_path, Jason.encode!(project))

    presentation =
      CommandFrontend.execute(["run", project_path], :standalone, fn _arguments ->
        {:ok, CommandRuntime.standalone()}
      end)

    assert presentation.outcome.envelope["error"]["phase"] == "application"
    assert File.regular?(presentation.envelope_path)
  end

  @tag :tmp_dir
  test "project defaults are merged and explicit command values win", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    explicit_traces = Path.join(target, "explicit-traces")
    File.mkdir!(explicit_traces)
    run_ref = "cmd-00000000000000000000000000"

    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               ["run", project, "--trace-dir", explicit_traces],
               :mix,
               run_ref
             )

    assert entry.arguments.application == Path.join(target, "ptc.json")
    assert entry.arguments.options.trace_dir == explicit_traces
    assert entry.envelope_path == Path.join([target, ".ptc", "envelopes", run_ref <> ".json"])
  end

  @tag :tmp_dir
  test "explicit --envelope still writes the project ledger envelope", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    copy = Path.join(directory, "one.json")

    presentation =
      CommandFrontend.execute(
        ["run", project, "--envelope", copy],
        :standalone,
        fn _arguments -> {:ok, CommandRuntime.standalone()} end
      )

    assert presentation.exit_status == 0
    assert presentation.envelope_path == copy
    assert File.regular?(copy)

    run_ref = presentation.outcome.envelope["run_ref"]
    ledger = Path.join([target, ".ptc", "envelopes", run_ref <> ".json"])
    assert File.regular?(ledger)

    for envelope_path <- [ledger, copy] do
      envelope = Jason.decode!(File.read!(envelope_path))
      assert envelope["run_ref"] == run_ref
      assert envelope["artifact_state"]["result"] == "not_requested"
      assert envelope["result"] == %{"result_class" => "normal"}
    end
  end

  @tag :tmp_dir
  test "project ledger policy does not make an explicit envelope direct-engine authority", %{
    tmp_dir: directory
  } do
    for {name, operation} <- [
          prepare: &CommandEngine.prepare/1,
          dispatch: &CommandEngine.dispatch/1
        ] do
      target = Path.join(directory, Atom.to_string(name))
      assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
      project = Path.join(target, "ptc-project.json")
      copy = Path.join(directory, "#{name}-explicit.json")

      assert {:error, %CommandOutcome{} = outcome} =
               operation.(["run", project, "--envelope", copy])

      assert outcome.envelope["error"]["phase"] == "arguments"
      assert outcome.envelope["error"]["code"] == "invalid_arguments"
      refute File.exists?(copy)
      refute File.exists?(Path.join(target, ".ptc"))
    end
  end

  @tag :tmp_dir
  test "validate --envelope does not write the project run ledger", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    copy = Path.join(directory, "validate.json")

    presentation =
      CommandFrontend.execute(
        ["validate", project, "--envelope", copy],
        :standalone,
        fn _arguments -> {:ok, CommandRuntime.standalone()} end
      )

    assert presentation.exit_status == 0
    assert File.regular?(copy)
    assert Path.wildcard(Path.join([target, ".ptc", "envelopes", "*.json"])) == []
  end

  @tag :tmp_dir
  test "a permissive pre-existing artifact root names the directory and owner-only rule", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    root = Path.join(target, ".ptc")
    File.mkdir!(root)
    File.chmod!(root, 0o755)

    for child <- ~w(envelopes inspection results traces) do
      path = Path.join(root, child)
      File.mkdir!(path)
      File.chmod!(path, 0o700)
    end

    presentation =
      CommandFrontend.execute(
        ["run", project],
        :standalone,
        fn _arguments -> {:ok, CommandRuntime.standalone()} end
      )

    assert presentation.exit_status == CommandFrontend.envelope_failure_exit_status()
    assert presentation.stderr =~ "envelope/publication_failed"
    assert presentation.stderr =~ root
    assert presentation.stderr =~ "owner-only (0700)"
    assert presentation.stderr =~ "chmod 700"
  end

  @tag :tmp_dir
  test "an incomplete permissive artifact root offers the single-step removal remedy", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    root = Path.join(target, ".ptc")
    File.mkdir!(root)
    File.chmod!(root, 0o755)

    presentation = run_project(project)

    assert presentation.stderr =~ "#{inspect(root)} is incomplete"
    assert presentation.stderr =~ "remove it"
    refute presentation.stderr =~ "chmod 700"
  end

  @tag :tmp_dir
  test "an invalid pre-existing artifact root releases its reserved ledger", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    root = Path.join(target, ".ptc")
    File.mkdir_p!(Path.join(root, "envelopes"))
    File.chmod!(Path.join(root, "envelopes"), 0o700)
    File.chmod!(root, 0o755)
    on_exit(fn -> File.chmod(root, 0o700) end)

    assert {:ok, entry} = CommandEntry.open(["run", project], :standalone)
    owner = entry.envelope_handle.owner
    assert Process.alive?(owner)

    presentation =
      CommandFrontend.present_entry(entry, fn _arguments ->
        {:ok, CommandRuntime.standalone()}
      end)

    assert presentation.exit_status == CommandFrontend.envelope_failure_exit_status()
    refute Process.alive?(owner)
    assert File.ls!(Path.join(root, "envelopes")) == []
  end

  @tag :tmp_dir
  test "a permissive artifact child names that directory and the owner-only rule", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    root = Path.join(target, ".ptc")
    File.mkdir!(root)
    File.chmod!(root, 0o700)

    for child <- ~w(envelopes inspection results traces) do
      path = Path.join(root, child)
      File.mkdir!(path)
      File.chmod!(path, 0o755)
    end

    presentation =
      CommandFrontend.execute(
        ["run", project],
        :standalone,
        fn _arguments -> {:ok, CommandRuntime.standalone()} end
      )

    assert presentation.exit_status == CommandFrontend.envelope_failure_exit_status()
    assert presentation.stderr =~ "envelope/publication_failed"
    assert presentation.stderr =~ Path.join(root, "envelopes")
    assert presentation.stderr =~ "owner-only (0700)"
    assert presentation.stderr =~ "chmod 700"
  end

  @tag :tmp_dir
  test "a missing artifact-root ancestor names the directory and the mkdir remedy", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    project_path = project_with_artifact_root(target, "missing-artifact-parent/.ptc")
    missing = Path.join(target, "missing-artifact-parent")

    presentation = run_project(project_path)

    assert presentation.exit_status == CommandFrontend.envelope_failure_exit_status()
    assert presentation.stderr =~ "envelope/destination_parent_unavailable"
    assert presentation.stderr =~ missing
    assert presentation.stderr =~ "mkdir -p '#{missing}'"
    assert presentation.outcome.envelope["error"]["cause"] == "filesystem_error"
    assert Jason.decode!(presentation.stdout) == presentation.outcome.envelope
    refute presentation.stderr =~ "owner-only (0700)"
    refute File.exists?(missing)
  end

  @tag :tmp_dir
  test "an explicit envelope survives an unavailable project ledger", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    project_path = project_with_artifact_root(target, "missing-artifact-parent/.ptc")
    explicit = Path.join(directory, "rescue.json")

    presentation =
      CommandFrontend.execute(
        ["run", project_path, "--envelope", explicit],
        :standalone,
        fn _arguments -> {:ok, CommandRuntime.standalone()} end
      )

    assert presentation.exit_status == 7
    assert presentation.envelope_path == explicit
    assert Jason.decode!(File.read!(explicit)) == presentation.outcome.envelope
    assert presentation.outcome.envelope["error"]["cause"] == "filesystem_error"
    assert presentation.stderr =~ "destination/invalid_destination"
    assert presentation.stderr =~ "envelope/destination_parent_unavailable"
    assert presentation.stderr =~ "missing-artifact-parent"
  end

  @tag :tmp_dir
  test "final ledger reservation reports the command run reference", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    copy = Path.join(directory, "copy.json")
    event = [:ptc_runner, :publication, :destination_unavailable]
    ref = :telemetry_test.attach_event_handlers(self(), [event])
    on_exit(fn -> :telemetry.detach(ref) end)

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        presentation =
          PublicationHandle.with_fault_hook(
            fn path, stage ->
              if Path.dirname(path) == Path.join([target, ".ptc", "envelopes"]) and
                   stage == :staging_file,
                 do: {:error, :eio},
                 else: :ok
            end,
            fn ->
              CommandFrontend.execute(["run", project, "--envelope", copy], :standalone, fn _ ->
                {:ok, CommandRuntime.standalone()}
              end)
            end
          )

        send(self(), {:presentation, presentation})
      end)

    assert_receive {:presentation, presentation}
    run_ref = presentation.outcome.envelope["run_ref"]
    assert Jason.decode!(File.read!(copy))["run_ref"] == run_ref
    assert stderr =~ "run_ref=#{run_ref}"
    assert_receive {^event, ^ref, %{}, %{run_ref: ^run_ref, cause: {:reason, :eio}}}
  end

  @tag :tmp_dir
  test "an explicit envelope survives an unavailable artifact root when its ledger is disabled",
       %{
         tmp_dir: directory
       } do
    target = Path.join(directory, "demo")
    project_path = project_with_artifact_root(target, "missing-artifact-parent/.ptc")
    project = project_path |> File.read!() |> Jason.decode!()

    File.write!(
      project_path,
      project |> put_in(["artifacts", "envelope"], false) |> Jason.encode!()
    )

    explicit = Path.join(directory, "rescue.json")

    presentation =
      CommandFrontend.execute(
        ["run", project_path, "--envelope", explicit],
        :standalone,
        fn _arguments -> {:ok, CommandRuntime.standalone()} end
      )

    assert presentation.exit_status == 7
    assert presentation.envelope_path == explicit
    assert Jason.decode!(File.read!(explicit)) == presentation.outcome.envelope
    assert presentation.stderr =~ "destination/invalid_destination"
    refute presentation.stderr =~ "envelope/publication_failed"
  end

  # The shallowest missing ancestor is what failed, but creating only it fails
  # again on the next level; the remedy has to name the whole parent.
  @tag :tmp_dir
  test "several missing artifact-root levels still yield a remedy that works", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    project_path = project_with_artifact_root(target, "outer/inner/.ptc")
    outer = Path.join(target, "outer")
    inner = Path.join(outer, "inner")

    presentation = run_project(project_path)

    assert presentation.exit_status == CommandFrontend.envelope_failure_exit_status()
    assert presentation.stderr =~ "#{inspect(outer)} does not exist"
    assert presentation.stderr =~ "mkdir -p '#{inner}'"

    File.mkdir_p!(inner)
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project_path])
    assert File.dir?(Path.join(inner, ".ptc"))
  end

  @tag :tmp_dir
  test "an artifact-root parent other users can replace names the mode remedy", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    project_path = project_with_artifact_root(target, "permissive-parent/.ptc")
    parent = Path.join(target, "permissive-parent")
    File.mkdir!(parent)
    File.chmod!(parent, 0o777)

    presentation = run_project(project_path)

    assert presentation.exit_status == CommandFrontend.envelope_failure_exit_status()
    assert presentation.stderr =~ "envelope/destination_parent_unsafe"
    assert presentation.stderr =~ "#{inspect(parent)} is writable by group or other"
    assert presentation.stderr =~ "chmod go-w '#{parent}'"
    refute presentation.stderr =~ "mkdir -p"
  end

  # The embedding entry point must report an unusable artifact root, not raise:
  # `publication` has no `invalid_destination` row for it to name. The root is
  # also where the envelope would go, so the ledger is lost with it.
  @tag :tmp_dir
  test "dispatch reports an unusable artifact root instead of raising", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    project_path = project_with_artifact_root(target, "missing-artifact-parent/.ptc")

    assert {:envelope_publication_failed, %CommandOutcome{envelope: envelope}} =
             CommandEngine.dispatch(["run", project_path])

    assert envelope["error"]["phase"] == "destination"
    assert envelope["error"]["code"] == "invalid_destination"
  end

  # A run that already finished must not be reported as never started: an
  # embedding caller would retry effects that already happened.
  @tag :tmp_dir
  test "an unpublishable envelope keeps the finished run's evidence", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project_path])

    # Owner-only but not writable: the layout still passes every artifact-root
    # check, so the ledger fails only after the run has already finished.
    ledger = Path.join([target, ".ptc", "envelopes"])
    File.chmod!(ledger, 0o500)
    on_exit(fn -> File.chmod(ledger, 0o700) end)

    assert {:envelope_publication_failed, %CommandOutcome{envelope: envelope}} =
             CommandEngine.dispatch(["run", project_path])

    assert envelope["artifact_class"] != "unclassified"
    assert envelope["execution"]["state"] == "finished"
    assert envelope["execution"]["outcome"] == "ok"
  end

  # A run that failed for its own reason must still say the audit envelope was
  # lost, or the two failures are indistinguishable to an embedding caller.
  @tag :tmp_dir
  test "a failed run whose envelope is also lost reports both", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project_path])

    project = Jason.decode!(File.read!(project_path))
    project = put_in(project, ["application", "path"], "missing.json")
    File.write!(project_path, Jason.encode!(project))

    ledger = Path.join([target, ".ptc", "envelopes"])
    File.chmod!(ledger, 0o500)
    on_exit(fn -> File.chmod(ledger, 0o700) end)

    assert {:envelope_publication_failed, %CommandOutcome{envelope: envelope}} =
             CommandEngine.dispatch(["run", project_path])

    assert envelope["status"] == "error"
  end

  @tag :tmp_dir
  test "a project without an envelope names a missing artifact-root ancestor", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    project = Jason.decode!(File.read!(project_path))

    project =
      project
      |> put_in(["artifacts", "root"], "missing-artifact-parent/.ptc")
      |> put_in(["artifacts", "envelope"], false)

    File.write!(project_path, Jason.encode!(project))

    presentation = run_project(project_path)

    assert presentation.exit_status == 7
    assert presentation.stderr =~ "destination/invalid_destination"

    assert presentation.stderr =~
             "#{inspect(Path.join(target, "missing-artifact-parent"))} does not exist"

    assert presentation.stderr =~ "mkdir -p"
    refute File.exists?(Path.join(target, "missing-artifact-parent"))
  end

  @tag :tmp_dir
  test "a project without an envelope names a permissive artifact root", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    project = Jason.decode!(File.read!(project_path))
    root = Path.join(target, ".ptc")

    project = put_in(project, ["artifacts", "envelope"], false)
    File.write!(project_path, Jason.encode!(project))
    File.mkdir!(root)
    File.chmod!(root, 0o755)

    for child <- ~w(envelopes inspection results traces) do
      path = Path.join(root, child)
      File.mkdir!(path)
      File.chmod!(path, 0o700)
    end

    presentation = run_project(project_path)

    assert presentation.exit_status == 7
    assert presentation.stderr =~ "destination/invalid_destination"
    assert presentation.stderr =~ inspect(root)
    assert presentation.stderr =~ "owner-only (0700)"
    assert presentation.stderr =~ "chmod 700"
  end

  @tag :tmp_dir
  test "an unwritable artifact-root parent names the directory and writable-parent rule", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    project_path = project_with_artifact_root(target, "unwritable-parent/.ptc")
    parent = Path.join(target, "unwritable-parent")
    File.mkdir!(parent)
    File.chmod!(parent, 0o500)
    on_exit(fn -> File.chmod(parent, 0o700) end)

    presentation = run_project(project_path)

    assert presentation.exit_status == CommandFrontend.envelope_failure_exit_status()
    assert presentation.stderr =~ "envelope/publication_failed"
    assert presentation.stderr =~ "#{inspect(parent)} is not writable by its owner"
    assert presentation.stderr =~ "artifact root's parent must be writable"
    assert presentation.stderr =~ "chmod u+wx '#{parent}'"
  end

  @tag :tmp_dir
  test "an unwritable artifact-root parent stays named without an envelope", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    project_path = project_with_artifact_root(target, "unwritable-parent/.ptc")
    project = Jason.decode!(File.read!(project_path))
    parent = Path.join(target, "unwritable-parent")

    File.write!(project_path, Jason.encode!(put_in(project, ["artifacts", "envelope"], false)))
    File.mkdir!(parent)
    File.chmod!(parent, 0o500)
    on_exit(fn -> File.chmod(parent, 0o700) end)

    presentation = run_project(project_path)

    assert presentation.exit_status == 7
    assert presentation.stderr =~ "destination/invalid_destination"
    assert presentation.stderr =~ "#{inspect(parent)} is not writable by its owner"
    assert presentation.stderr =~ "chmod u+wx '#{parent}'"
  end

  # Past a dangling symlink the shallowest missing path is the link's target,
  # not the link: `mkdir -p` on the link's own name fails, because the link
  # already exists.
  @tag :tmp_dir
  test "a missing ancestor behind a symlink offers the target as the remedy", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    project_path = project_with_artifact_root(target, "alias/.ptc")
    resolved = Path.join(target, "missing-target")
    File.ln_s!("missing-target", Path.join(target, "alias"))

    presentation = run_project(project_path)

    assert presentation.exit_status == CommandFrontend.envelope_failure_exit_status()
    assert presentation.stderr =~ "#{inspect(resolved)} does not exist"
    assert presentation.stderr =~ "mkdir -p '#{resolved}'"
    refute presentation.stderr =~ "mkdir -p '#{Path.join(target, "alias")}'"

    File.mkdir_p!(resolved)
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project_path])
    assert File.dir?(Path.join(resolved, ".ptc"))
  end

  # A symlink target is filesystem content, not something the operator typed,
  # and stderr is a terminal. The bytes must be shown, never obeyed, and a
  # command a reader cannot safely paste is not offered at all. C1 controls and
  # bidirectional overrides are valid UTF-8, so escaping only the ASCII range
  # would leave both a terminal injection and a visual spoof.
  @tag :tmp_dir
  test "a hostile symlink target is escaped and offers no pasteable command", %{
    tmp_dir: directory
  } do
    for {name, hostile} <- [
          {"esc", "gone\e[31m;rm -rf $HOME"},
          {"c1", "gone" <> <<0x9B::utf8>> <> "31m"},
          {"bidi", "gone" <> <<0x202E::utf8>> <> "txt.sh"}
        ] do
      File.mkdir_p!(Path.join(directory, name))
      target = Path.join([directory, name, "demo"])
      project_path = project_with_artifact_root(target, "alias/.ptc")
      File.ln_s!(hostile, Path.join(target, "alias"))

      presentation = run_project(project_path)

      assert presentation.exit_status == CommandFrontend.envelope_failure_exit_status()
      refute presentation.stderr =~ hostile
      refute presentation.stderr =~ "mkdir -p"
      assert presentation.stderr =~ "does not exist"
      # The remedy degrades to words; `inspect/1` renders a path holding a C1
      # control as a byte list rather than a quoted string, which is equally
      # safe and equally unusable as a command.
      assert presentation.stderr =~ "create "
    end
  end

  # A sticky world-writable directory — /tmp is the everyday one — is accepted,
  # so it must not be reported as an unsafe ancestor.
  @tag :tmp_dir
  test "a sticky world-writable artifact-root parent is accepted", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    project_path = project_with_artifact_root(target, "sticky-parent/.ptc")
    parent = Path.join(target, "sticky-parent")
    File.mkdir!(parent)
    # Erlang's change_mode carries only the low nine bits, so the sticky bit
    # this case is about has to be set through chmod itself.
    assert {_output, 0} = System.cmd("chmod", ["1777", parent])

    presentation = run_project(project_path)

    assert presentation.stderr == ""
    assert presentation.exit_status == 0
    assert File.dir?(Path.join(parent, ".ptc"))
  end

  @tag :tmp_dir
  test "a failed convenience copy reports its path and retains the ledger", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    copy = Path.join(directory, "copy.json")

    presentation =
      CommandFrontend.execute(
        ["run", Path.join(target, "ptc-project.json"), "--envelope", copy],
        :standalone,
        fn _ ->
          File.write!(copy, "concurrent writer")
          {:ok, CommandRuntime.standalone()}
        end
      )

    assert presentation.exit_status == 0
    assert presentation.stderr =~ "envelope/publication_failed"
    assert presentation.stderr =~ copy
    assert presentation.envelope_path != copy

    assert Jason.decode!(File.read!(presentation.envelope_path))["run_ref"] ==
             presentation.outcome.envelope["run_ref"]

    assert File.read!(copy) == "concurrent writer"
  end

  @tag :tmp_dir
  test "a missing explicit envelope parent is rejected before bootstrap", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    missing_parent = Path.join(directory, "missing")
    copy = Path.join(missing_parent, "out.json")

    presentation =
      CommandFrontend.execute(
        ["run", project, "--envelope", copy],
        :standalone,
        fn _arguments -> flunk("must not bootstrap") end
      )

    assert presentation.exit_status == 7
    assert presentation.stderr =~ "destination/envelope_destination_unavailable"
    assert presentation.stderr =~ "--envelope"
    assert presentation.stderr =~ inspect(copy)
    assert presentation.stderr =~ "parent directory is missing (enoent)"
    assert presentation.outcome.envelope["error"]["phase"] == "destination"
    assert presentation.outcome.envelope["error"]["code"] == "envelope_destination_unavailable"
    assert presentation.outcome.envelope["error"]["cause"] == "filesystem_error"
    assert Jason.decode!(presentation.stdout) == presentation.outcome.envelope

    ledger =
      Path.join([
        target,
        ".ptc",
        "envelopes",
        presentation.outcome.envelope["run_ref"] <> ".json"
      ])

    assert Jason.decode!(File.read!(ledger)) == presentation.outcome.envelope
    refute File.exists?(copy)
  end

  @tag :tmp_dir
  test "an explicit envelope in a read-only directory reports the filesystem cause", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    read_only = Path.join(directory, "read-only")
    copy = Path.join(read_only, "out.json")
    File.mkdir!(read_only)
    File.chmod!(read_only, 0o500)
    on_exit(fn -> File.chmod(read_only, 0o700) end)

    presentation =
      CommandFrontend.execute(
        ["run", project, "--envelope", copy],
        :standalone,
        fn _arguments -> flunk("must not bootstrap") end
      )

    assert presentation.exit_status == 7
    assert presentation.stderr =~ "destination/envelope_destination_unavailable"
    assert presentation.stderr =~ "--envelope"
    assert presentation.stderr =~ inspect(copy)
    assert presentation.stderr =~ "permission denied (eacces)"
    assert presentation.outcome.envelope["error"]["phase"] == "destination"
    assert presentation.outcome.envelope["error"]["code"] == "envelope_destination_unavailable"
    assert presentation.outcome.envelope["error"]["cause"] == "permission"
    assert Jason.decode!(presentation.stdout) == presentation.outcome.envelope

    ledger =
      Path.join([
        target,
        ".ptc",
        "envelopes",
        presentation.outcome.envelope["run_ref"] <> ".json"
      ])

    assert Jason.decode!(File.read!(ledger)) == presentation.outcome.envelope
    refute File.exists?(copy)
  end

  @tag :tmp_dir
  test "project-backed repl preserves the manifest grammar", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")

    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               ["repl", "--project", project, "--eval", "(+ 1 2)"],
               :mix,
               "cmd-00000000000000000000000000"
             )

    assert entry.arguments.options.manifest == Path.join(target, "ptc.json")

    assert Keyword.get(entry.arguments.ordered_options, :manifest) ==
             Path.join(target, "ptc.json")

    assert Keyword.get(entry.arguments.ordered_options, :eval) == "(+ 1 2)"
  end

  @tag :tmp_dir
  test "project-backed repl preserves an explicit mission selector", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")

    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               ["repl", "--project", project, "--mission", "review", "--eval", "42"],
               :mix,
               "cmd-00000000000000000000000000"
             )

    assert entry.arguments.options.manifest == Path.join(target, "ptc.json")
    assert entry.arguments.options.mission == "review"
    assert Keyword.get(entry.arguments.ordered_options, :mission) == "review"
  end

  @tag :tmp_dir
  test "inspect-only project repl injects only the application manifest", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    project = Jason.decode!(File.read!(project_path))

    project =
      Map.put(project, "host", %{
        "path" => "ptc-host.json",
        "env_file" => %{"path" => "missing.env"}
      })

    File.write!(project_path, Jason.encode!(project))

    File.write!(
      Path.join(target, "ptc-host.json"),
      Jason.encode!(%{
        "credentials" => %{"key" => %{"env" => "PTC_INSPECT_ONLY_ABSENT_KEY"}},
        "install" => %{}
      })
    )

    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               ["repl", "--project", project_path, "--inspect-only", "--eval", "(+ 1 2)"],
               :mix,
               "cmd-00000000000000000000000000"
             )

    assert entry.arguments.options.manifest == Path.join(target, "ptc.json")
    assert entry.arguments.options.inspect_only == true
    refute Map.has_key?(entry.arguments.options, :host_config)
    refute Keyword.has_key?(entry.arguments.frontend_options, :env_file)
  end

  @tag :tmp_dir
  test "inspect-only project repl rejects analysis profiles", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")

    assert {:error, entry} =
             CommandEntry.open_with_ref(
               [
                 "repl",
                 "--project",
                 project,
                 "--inspect-only",
                 "--profile",
                 "run-analysis-v1"
               ],
               :mix,
               "cmd-00000000000000000000000000"
             )

    assert entry.rejection.command == :repl
    assert entry.rejection.code == :conflicting_arguments
  end

  @tag :tmp_dir
  test "project-backed analysis derives artifact resources and preserves overrides", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")

    project =
      project_path
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["artifacts", "inspection"], true)

    File.write!(project_path, Jason.encode!(project))

    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               [
                 "repl",
                 "--project",
                 project_path,
                 "--profile",
                 "private-run-analysis-v2",
                 "--private-unattended",
                 "--eval",
                 "(analysis/runs {})"
               ],
               :mix,
               "cmd-00000000000000000000000000"
             )

    assert Keyword.get_values(entry.arguments.ordered_options, :resource) == [
             "traces=#{Path.join([target, ".ptc", "traces"])}",
             "inspection=#{Path.join([target, ".ptc", "inspection"])}"
           ]

    assert {:ok, catalog_entry} =
             CommandEntry.open_with_ref(
               [
                 "repl",
                 "--project",
                 project_path,
                 "--profile",
                 "private-run-catalog-v1",
                 "--private-unattended",
                 "--eval",
                 "(analysis/catalog {})"
               ],
               :mix,
               "cmd-00000000000000000000000000"
             )

    assert Keyword.get_values(catalog_entry.arguments.ordered_options, :resource) == [
             "traces=#{Path.join([target, ".ptc", "traces"])}",
             "inspection=#{Path.join([target, ".ptc", "inspection"])}"
           ]

    explicit = Path.join(target, "captured-traces")

    assert {:ok, overridden} =
             CommandEntry.open_with_ref(
               [
                 "repl",
                 "--project",
                 project_path,
                 "--profile",
                 "run-analysis-v1",
                 "--resource",
                 "traces=#{explicit}",
                 "--eval",
                 "(analysis/runs {})"
               ],
               :mix,
               "cmd-00000000000000000000000000"
             )

    assert Keyword.get_values(overridden.arguments.ordered_options, :resource) == [
             "traces=#{explicit}"
           ]
  end

  test "the repl option terminator leaves project-looking script arguments positional" do
    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               ["repl", "--", "--project=missing.json"],
               :mix,
               "cmd-00000000000000000000000000"
             )

    assert entry.arguments.application == "--project=missing.json"
    assert entry.arguments.project == nil
  end

  @tag :tmp_dir
  test "project-backed repl inserts defaults before the option terminator", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")

    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               ["repl", "--project", project, "--", "--manifest"],
               :mix,
               "cmd-00000000000000000000000000"
             )

    assert entry.arguments.application == "--manifest"
    assert entry.arguments.options.manifest == Path.join(target, "ptc.json")
    assert entry.arguments.project.config.path == project
  end

  @tag :tmp_dir
  test "passive doctor accepts a project and does not require its missing environment file", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    project = Jason.decode!(File.read!(project_path))

    project =
      Map.put(project, "host", %{
        "path" => "missing-host.json",
        "env_file" => %{"path" => "missing.env"}
      })

    File.write!(project_path, Jason.encode!(project))

    assert {:ok, entry} =
             CommandEntry.open_with_ref(
               ["doctor", project_path, "--"],
               :mix,
               "cmd-00000000000000000000000000"
             )

    refute Keyword.has_key?(entry.arguments.frontend_options, :env_file)
    assert entry.arguments.options.host_config == Path.join(target, "missing-host.json")
  end

  @tag :tmp_dir
  test "invalid project documents retain their schema diagnostic for every project command", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    base = target |> Path.join("ptc-project.json") |> File.read!() |> Jason.decode!()

    documents = [
      {"wrong-type", put_in(base, ["artifacts", "trace"], "yes"), "/artifacts/trace",
       "type schema rule"},
      {"unknown-key", Map.put(base, "artifactz", %{}), "", "unknown property"},
      {"missing-required", Map.delete(base, "application"), "/application",
       "missing a required property"}
    ]

    for {name, document, expected_path, message_fragment} <- documents,
        {command, suffix} <- [
          {"validate", []},
          {"run", []},
          {"doctor", []},
          {"doctor", ["--connect"]},
          {"models", []}
        ] do
      path = Path.join(target, "#{name}.json")
      File.write!(path, Jason.encode!(document))

      assert {:error, %CommandOutcome{} = outcome} =
               CommandEngine.dispatch([command, path | suffix])

      assert outcome.envelope["error"]["code"] == "project_schema_invalid",
             "#{command} #{name}"

      assert outcome.envelope["error"]["phase"] == "project"
      assert outcome.envelope["error"]["path"] == expected_path
      assert outcome.envelope["error"]["message"] =~ message_fragment

      assert outcome.envelope["error"]["source"] == %{
               "kind" => "project",
               "name" => "ptc-project.json"
             }

      refute Jason.encode!(outcome.envelope) =~ directory
    end

    duplicate_path = Path.join(target, "duplicate-key.json")

    File.write!(
      duplicate_path,
      ~s({"kind":"ptc-project","version":1,"application":{"path":"ptc.json","path":"other.json"}})
    )

    for {command, suffix} <- [
          {"validate", []},
          {"run", []},
          {"doctor", []},
          {"doctor", ["--connect"]},
          {"models", []}
        ] do
      assert {:error, %CommandOutcome{} = outcome} =
               CommandEngine.dispatch([command, duplicate_path | suffix])

      assert outcome.envelope["error"]["phase"] == "project"
      assert outcome.envelope["error"]["code"] == "project_schema_invalid"
      assert outcome.envelope["error"]["path"] == "/application"
      assert outcome.envelope["error"]["message"] =~ "duplicate property"
      refute Jason.encode!(outcome.envelope) =~ directory
    end
  end

  @tag :tmp_dir
  test "oversized project documents publish envelopes without bootstrapping", %{
    tmp_dir: directory
  } do
    project_path = Path.join(directory, "oversized-project.json")

    File.write!(
      project_path,
      ~s({"kind":"ptc-project","version":1,"application":{"path":"ptc.json"},"padding":") <>
        String.duplicate("x", 300_000) <> ~s("})
    )

    parent = self()

    for command <- ~w(validate run doctor models) do
      envelope_path = Path.join(directory, "#{command}-oversized-envelope.json")

      presentation =
        CommandFrontend.execute(
          [command, project_path, "--envelope", envelope_path],
          :standalone,
          fn _arguments ->
            send(parent, :unexpected_bootstrap)
            {:ok, CommandRuntime.standalone()}
          end
        )

      assert presentation.exit_status == 3
      assert presentation.envelope_path == envelope_path
      assert presentation.outcome.envelope["error"]["phase"] == "project"
      assert presentation.outcome.envelope["error"]["code"] == "project_schema_invalid"
      assert Jason.decode!(File.read!(envelope_path)) == presentation.outcome.envelope
      refute_received :unexpected_bootstrap
    end
  end

  @tag :tmp_dir
  test "invalid host-requiring projects publish envelopes before a trailing terminator", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    project = project_path |> File.read!() |> Jason.decode!()
    File.write!(project_path, project |> put_in(["artifacts", "trace"], "yes") |> Jason.encode!())
    parent = self()

    for {name, argv} <- [
          {"models", ["models", project_path]},
          {"doctor", ["doctor", project_path, "--connect"]}
        ] do
      envelope_path = Path.join(directory, "#{name}-invalid-project-envelope.json")

      presentation =
        CommandFrontend.execute(
          argv ++ ["--envelope", envelope_path, "--"],
          :standalone,
          fn _arguments ->
            send(parent, :unexpected_bootstrap)
            {:ok, CommandRuntime.standalone()}
          end
        )

      assert presentation.exit_status == 3
      assert presentation.envelope_path == envelope_path
      assert presentation.outcome.envelope["error"]["phase"] == "project"
      assert Jason.decode!(File.read!(envelope_path)) == presentation.outcome.envelope
      refute_received :unexpected_bootstrap
    end
  end

  @tag :tmp_dir
  test "an invalid project is admitted far enough to publish an explicit envelope", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    project = project_path |> File.read!() |> Jason.decode!()
    File.write!(project_path, project |> put_in(["artifacts", "trace"], "yes") |> Jason.encode!())

    for argv <- [["models", project_path], ["doctor", project_path, "--connect"]] do
      assert {:ok, entry} =
               CommandEntry.open_with_ref(
                 argv,
                 :standalone,
                 "cmd-00000000000000000000000000"
               )

      assert entry.diagnostic.phase == :project
      refute Map.has_key?(entry.arguments.options, :host_config)
    end

    envelope_path = Path.join(directory, "invalid-project-envelope.json")
    parent = self()

    assert {:error, %CommandOutcome{} = direct} =
             CommandEngine.prepare(["run", project_path, "--envelope", envelope_path])

    assert direct.envelope["error"]["phase"] == "arguments"
    assert direct.envelope["error"]["code"] == "invalid_arguments"
    refute File.exists?(envelope_path)

    presentation =
      CommandFrontend.execute(
        ["run", project_path, "--envelope", envelope_path],
        :standalone,
        fn _arguments ->
          send(parent, :unexpected_bootstrap)
          {:ok, CommandRuntime.standalone()}
        end
      )

    assert presentation.exit_status == 3
    assert presentation.envelope_path == envelope_path
    assert presentation.outcome.envelope["error"]["phase"] == "project"
    assert presentation.outcome.envelope["error"]["path"] == "/artifacts/trace"
    assert Jason.decode!(File.read!(envelope_path)) == presentation.outcome.envelope
    refute_received :unexpected_bootstrap

    published = File.read!(envelope_path)

    refused =
      CommandFrontend.execute(
        ["run", project_path, "--envelope", envelope_path],
        :standalone,
        fn _arguments ->
          send(parent, :unexpected_bootstrap)
          {:ok, CommandRuntime.standalone()}
        end
      )

    assert refused.exit_status == 2
    assert refused.envelope_path == nil
    assert refused.outcome.envelope["error"]["code"] == "envelope_destination_exists"
    assert File.read!(envelope_path) == published
    refute_received :unexpected_bootstrap
  end

  @tag :tmp_dir
  test "invalid project content does not turn malformed argv into an admitted failure", %{
    tmp_dir: directory
  } do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    project = project_path |> File.read!() |> Jason.decode!()
    File.write!(project_path, project |> put_in(["artifacts", "trace"], "yes") |> Jason.encode!())

    envelope_path = Path.join(directory, "must-not-exist.json")
    parent = self()

    presentation =
      CommandFrontend.execute(
        ["run", project_path, "--unknown", "value", "--envelope", envelope_path],
        :standalone,
        fn _arguments ->
          send(parent, :unexpected_bootstrap)
          {:ok, CommandRuntime.standalone()}
        end
      )

    assert presentation.exit_status == 2
    assert presentation.envelope_path == nil
    assert presentation.outcome.envelope["error"]["phase"] == "arguments"
    assert presentation.stderr =~ "; unknown switch; accepted:"
    refute File.exists?(envelope_path)
    refute_received :unexpected_bootstrap

    for rest <- [
          ["--host-config", "host.json", "--bogus"],
          ["--host-config", "first.json", "--host-config", "second.json"]
        ] do
      assert {:error, expected} = CommandParser.parse(["models" | rest], :standalone)

      assert {:error, entry} =
               CommandEntry.open_with_ref(
                 ["models", project_path | rest],
                 :standalone,
                 "cmd-00000000000000000000000000"
               )

      assert entry.rejection == expected
    end
  end

  @tag :tmp_dir
  test "a project declaring no host says so rather than blaming the arguments", %{
    tmp_dir: directory
  } do
    # `ptc init` scaffolds no host block, so the two commands that need one are
    # reached with exactly the argument form their own --help prints. Blaming
    # the command line sends the reader back to the syntax, which was correct.
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")

    for argv <- [["models", project], ["doctor", project, "--connect"]] do
      assert {:error, %CommandOutcome{} = outcome} = CommandEngine.dispatch(argv)

      assert outcome.envelope["error"]["code"] == "project_host_undeclared"
      assert outcome.envelope["error"]["phase"] == "arguments"
      assert outcome.envelope["error"]["message"] =~ "declares no host block"
    end
  end

  @tag :tmp_dir
  test "an explicit --host-config still serves a project that declares no host", %{
    tmp_dir: directory
  } do
    # The rejection must name a missing declaration, not forbid the command, so
    # the documented alternative in `ptc models --help` keeps working.
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")
    host_path = Path.join(target, "ptc-host.json")

    File.write!(
      host_path,
      Jason.encode!(%{
        "credentials" => %{"key" => %{"env" => "PTC_PROJECT_ABSENT_KEY"}},
        "install" => %{
          "model" => %{
            "source" => "llm",
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
            "installation_revision" => "model-v1",
            "model" => "openrouter:test/model",
            "credential" => "key"
          }
        }
      })
    )

    assert {:ok, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["models", "--host-config", host_path])

    assert [%{"alias" => "model"}] = outcome.envelope["result"]["installations"]

    # A project and a --host-config are documented alternatives, so combining
    # them stays an argument fault rather than silently ignoring the project.
    assert {:error, %CommandOutcome{} = combined} =
             CommandEngine.dispatch(["models", project, "--host-config", host_path])

    assert combined.envelope["error"]["code"] == "invalid_arguments"
  end

  @tag :tmp_dir
  test "a real argument fault is not reported as the missing host", %{tmp_dir: directory} do
    # The parser decides before the missing declaration is considered, so a
    # switch fault still reports itself instead of being explained away by the
    # project — which would send the reader to edit a file over a typo.
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")

    for argv <- [
          ["models", project, "--bogus"],
          ["doctor", project, "--connect", "--bogus"],
          ["models", project, "--", "extra"],
          ["doctor", project, "--", "extra"],
          ["models", project, "--", "--host-config", "host.json"]
        ] do
      assert {:error, %CommandOutcome{} = outcome} = CommandEngine.dispatch(argv)
      assert outcome.envelope["error"]["code"] == "invalid_arguments"
    end
  end

  @tag :tmp_dir
  test "repl rejects ambiguous project authority modes", %{tmp_dir: directory} do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project = Path.join(target, "ptc-project.json")

    assert {:error, entry} =
             CommandEntry.open_with_ref(
               ["repl", "--project", project, "--manifest", "other.json"],
               :mix,
               "cmd-00000000000000000000000000"
             )

    assert entry.rejection.code == :conflicting_arguments
  end

  defp project_with_artifact_root(target, root) do
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    project = Jason.decode!(File.read!(project_path))
    File.write!(project_path, Jason.encode!(put_in(project, ["artifacts", "root"], root)))
    project_path
  end

  defp run_project(project_path) do
    CommandFrontend.execute(
      ["run", project_path],
      :standalone,
      fn _arguments -> {:ok, CommandRuntime.standalone()} end
    )
  end
end
