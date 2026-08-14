defmodule PtcRunnerLauncher.ConformanceTest do
  use ExUnit.Case, async: false

  alias PtcRunnerLauncher.TestSupport.LauncherPort, as: MCPStdioLauncher

  @fixture Path.expand("../fixtures/mcp_stdio_launcher_fixture.sh", __DIR__)
  @native_fixture Path.expand("../fixtures/mcp_stdio_native_fixture.c", __DIR__)

  # The identity hash is the only interval long enough to race a rename into, so
  # the target has to be large enough that hashing it is still in progress when
  # the swap lands: 64 MiB takes roughly a third of a second, and the rename
  # fires 40 ms in.
  #
  # The two ways to miss that interval are distinguishable rather than silent. A
  # rename landing before the launcher opens the target makes it hash the small
  # impostor and refuse within milliseconds, which the elapsed-time floor
  # rejects; one landing after the exec runs the authorized target, which the
  # output assertion accepts as the rename simply losing. Neither can report a
  # pass for the window itself.
  @race_target_mebibytes 64
  @race_rename_delay_ms 40
  @race_minimum_hash_ms 100

  setup_all do
    compiler = System.find_executable("cc") || flunk("C compiler is unavailable")

    environment_fixture =
      Path.join(
        System.tmp_dir!(),
        "ptc_mcp_environment_fixture_#{System.unique_integer([:positive])}"
      )

    assert {_output, 0} =
             System.cmd(
               compiler,
               [
                 "-std=c11",
                 "-Wall",
                 "-Wextra",
                 "-Werror",
                 "-Wpedantic",
                 "-o",
                 environment_fixture,
                 @native_fixture
               ],
               stderr_to_stdout: true
             )

    Application.put_env(
      :ptc_runner_launcher,
      :mcp_stdio_environment_fixture_path,
      environment_fixture
    )

    previous_unsafe = System.get_env("PTC_UNSAFE_CHILD_ENV")
    previous_second_unsafe = System.get_env("PTC_SECOND_UNSAFE_ENV")
    System.put_env("PTC_UNSAFE_CHILD_ENV", "must-not-be-inherited")
    System.put_env("PTC_SECOND_UNSAFE_ENV", "also-must-not-be-inherited")

    on_exit(fn ->
      Application.delete_env(:ptc_runner_launcher, :mcp_stdio_environment_fixture_path)
      File.rm(environment_fixture)

      if previous_unsafe,
        do: System.put_env("PTC_UNSAFE_CHILD_ENV", previous_unsafe),
        else: System.delete_env("PTC_UNSAFE_CHILD_ENV")

      if previous_second_unsafe,
        do: System.put_env("PTC_SECOND_UNSAFE_ENV", previous_second_unsafe),
        else: System.delete_env("PTC_SECOND_UNSAFE_ENV")
    end)

    :ok
  end

  test "launches exact argv in a canonical cwd with a clean environment and separate streams" do
    argument = "literal value; $(must-not-run)"

    launcher =
      open_launcher(["basic", argument],
        cwd: Path.join([File.cwd!(), "test", ".."]),
        env: %{"PTC_ALLOWED" => "visible"}
      )

    assert :ok = MCPStdioLauncher.send_bytes(launcher, "hello over stdio\n")

    assert %{stdout: stdout, stderr: stderr} =
             collect_until(launcher, fn output ->
               output.stdout =~ "echo=hello over stdio\n" and
                 output.stderr =~ "diagnostic-only\n"
             end)

    assert stdout =~ "cwd=#{File.cwd!()}\n"
    assert stdout =~ "home=#{System.get_env("HOME") || "unset"}\n"
    assert stdout =~ "allowed=visible\n"
    assert stdout =~ "unsafe=unset\n"
    assert stdout =~ "arg=#{argument}\n"
    refute stdout =~ "diagnostic-only"
    assert stderr == "diagnostic-only\n"
    refute stderr =~ "echo=hello over stdio"

    assert {:ok, %{reason: :close, stderr_truncated?: false}} =
             MCPStdioLauncher.close(launcher, 2_000)
  end

  test "supports a strict-empty base environment with explicit overlays" do
    launcher =
      open_launcher(["basic", "strict"],
        inherit_environment: false,
        env: %{"PTC_ALLOWED" => "visible"}
      )

    assert %{stdout: stdout} = collect_until(launcher, &(&1.stdout =~ "arg=strict\n"))
    assert stdout =~ "home=unset\n"
    assert stdout =~ "allowed=visible\n"
    assert stdout =~ "unsafe=unset\n"
    assert {:ok, %{exit_status: 0}} = MCPStdioLauncher.close(launcher)
  end

  test "inherits exactly the six compatibility names and permits explicit overlays" do
    launcher = open_environment_launcher(env: %{"PTC_ALLOWED" => "visible"})

    assert %{stdout: stdout} =
             collect_until(launcher, &(&1.stdout =~ "ENV_END\n"))

    for name <- ~w(HOME LOGNAME PATH SHELL TERM USER) do
      assert stdout =~ "#{name}=#{System.get_env(name) || "unset"}\n"
    end

    assert stdout =~ "PTC_UNSAFE_CHILD_ENV=unset\n"
    assert stdout =~ "PTC_SECOND_UNSAFE_ENV=unset\n"
    assert environment_names(stdout) == compatibility_environment_names(["PTC_ALLOWED"])
    assert {:ok, %{exit_status: 0}} = MCPStdioLauncher.close(launcher)
  end

  test "keeps every independently absent compatibility name absent" do
    for name <- ~w(HOME LOGNAME PATH SHELL TERM USER) do
      previous = System.get_env(name)
      System.delete_env(name)

      try do
        launcher = open_environment_launcher()

        assert %{stdout: stdout} =
                 collect_until(
                   launcher,
                   &(&1.stdout =~ "ENV_END\n")
                 )

        assert stdout =~ "#{name}=unset\n"
        assert environment_names(stdout) == compatibility_environment_names()
        assert {:ok, %{exit_status: 0}} = MCPStdioLauncher.close(launcher)
      after
        if previous, do: System.put_env(name, previous), else: System.delete_env(name)
      end
    end
  end

  test "rejects inherited shell-function values from the compatibility profile" do
    previous = System.get_env("LOGNAME")
    System.put_env("LOGNAME", "() { unsafe; }")

    try do
      launcher = open_environment_launcher()

      assert %{stdout: stdout} =
               collect_until(launcher, &(&1.stdout =~ "ENV_END\n"))

      assert stdout =~ "LOGNAME=unset\n"
      assert environment_names(stdout) == compatibility_environment_names()
      assert {:ok, %{exit_status: 0}} = MCPStdioLauncher.close(launcher)
    after
      if previous, do: System.put_env("LOGNAME", previous), else: System.delete_env("LOGNAME")
    end
  end

  test "validates environment limits after compatibility inheritance" do
    explicit =
      Map.new(1..256, fn index ->
        {"PTC_ENV_#{index}", "x"}
      end)

    assert {:error, :invalid_mcp_stdio_launch} =
             MCPStdioLauncher.open(
               executable: shell(),
               executable_sha256: executable_sha256(shell()),
               cwd: File.cwd!(),
               args: ["environment"],
               env: explicit
             )

    strict_launcher =
      open_environment_launcher(
        inherit_environment: false,
        env: explicit
      )

    assert %{stdout: stdout} =
             collect_until(strict_launcher, &(&1.stdout =~ "ENV_END\n"))

    assert stdout =~ "HOME=unset\n"
    assert environment_names(stdout) == MapSet.new(Map.keys(explicit))
    assert {:ok, %{exit_status: 0}} = MCPStdioLauncher.close(strict_launcher)
  end

  test "bounds stderr and reports truncation independently from stdout" do
    launcher = open_launcher(["stderr"], stderr_bytes: 32)

    assert %{stderr: stderr, truncated?: true, stdout: ""} =
             collect_until(launcher, & &1.truncated?)

    assert byte_size(stderr) == 32
    assert stderr == String.duplicate("x", 32)

    assert {:ok, %{reason: :close, stderr_truncated?: true}} =
             MCPStdioLauncher.close(launcher, 2_000)
  end

  test "keeps at most one stdout frame in flight for a stalled owner" do
    launcher = open_launcher(["stdout-flood"], grace_ms: 50)

    receive do
    after
      100 -> :ok
    end

    port_output =
      self()
      |> Process.info(:messages)
      |> elem(1)
      |> Enum.filter(fn
        {port, {:data, <<"O", _bytes::binary>>}} -> port == launcher.port
        _message -> false
      end)

    assert length(port_output) <= 1

    assert {:ok, %{reason: :close, exit_status: exit_status}} =
             MCPStdioLauncher.close(launcher)

    assert exit_status < 0
  end

  test "services bounded stdout while a large stdin write awaits acknowledgement" do
    launcher = open_launcher(["write-before-read"], grace_ms: 50)

    assert :ok =
             MCPStdioLauncher.send_bytes(
               launcher,
               :binary.copy(<<0>>, 1_000_000),
               5_000
             )

    expected_bytes = 4 * 65_536 + byte_size("after-read\n")

    assert %{stdout: stdout} =
             collect_until(launcher, &(byte_size(&1.stdout) == expected_bytes))

    assert stdout == :binary.copy(<<0>>, 4 * 65_536) <> "after-read\n"

    assert {:ok, {:finished, %{reason: :server_exit, exit_status: 0}}} =
             next_finished(launcher, 500)
  end

  test "close drains and discards output produced in response to EOF" do
    launcher = open_launcher(["trailing-output"], grace_ms: 500)

    assert {:ok, %{reason: :close, exit_status: 0}} =
             MCPStdioLauncher.close(launcher)

    assert {:error, :timeout} = MCPStdioLauncher.receive_event(launcher, 0)
  end

  test "a timed-out write closes the launcher instead of flushing queued input" do
    launcher = open_launcher(["no-read"], grace_ms: 50)
    assert %{stdout: "ready\n"} = collect_until(launcher, &(&1.stdout == "ready\n"))

    assert {:error, :timeout} =
             MCPStdioLauncher.send_bytes(launcher, :binary.copy(<<0>>, 1_000_000), 50)

    assert is_nil(Port.info(launcher.port))
    assert {:error, :closed} = MCPStdioLauncher.close(launcher)
  end

  @tag :tmp_dir
  test "a timed-out write does not deliver the complete queued request", %{tmp_dir: dir} do
    marker = Path.join(dir, "eof-observed")
    launcher = open_launcher(["slow-eof", marker], grace_ms: 300)
    assert %{stdout: "ready\n"} = collect_until(launcher, &(&1.stdout == "ready\n"))

    assert {:error, :timeout} =
             MCPStdioLauncher.send_bytes(
               launcher,
               :binary.copy(<<0>>, 1_000_000),
               50
             )

    assert is_nil(Port.info(launcher.port))
    assert_eventually(fn -> File.exists?(marker) end, 3_000)

    case File.read!(marker) do
      "term" ->
        :ok

      bytes_marker ->
        [delivered] =
          Regex.run(~r/^bytes=\s*(\d+)$/, bytes_marker, capture: :all_but_first)

        assert String.to_integer(delivered) < 1_000_000
    end
  end

  test "applies acknowledged backpressure across repeated writes" do
    launcher = open_launcher(["no-read"], grace_ms: 50)
    assert %{stdout: "ready\n"} = collect_until(launcher, &(&1.stdout == "ready\n"))

    delivered = send_until_backpressured(launcher, 512)
    assert delivered > 0
    assert delivered < 512

    assert is_nil(Port.info(launcher.port))
    assert {:error, :closed} = MCPStdioLauncher.close(launcher)
  end

  test "bounds command submission when the BEAM port is busy" do
    launcher = open_launcher(["no-read"], grace_ms: 50)
    assert %{stdout: "ready\n"} = collect_until(launcher, &(&1.stdout == "ready\n"))
    assert :busy = saturate_port(launcher.port, 16)

    started_at = System.monotonic_time(:millisecond)

    assert {:error, reason} = MCPStdioLauncher.send_bytes(launcher, "blocked", 50)
    assert reason in [:closed, :timeout]
    assert System.monotonic_time(:millisecond) - started_at < 500

    assert {:error, close_reason} = MCPStdioLauncher.close(launcher, 50)
    assert close_reason in [:closed, :timeout]
  end

  test "reports target exit while a write is awaiting acknowledgement" do
    launcher = open_launcher(["exit-no-read"], grace_ms: 50)
    started_at = System.monotonic_time(:millisecond)

    assert {:error, :closed} =
             MCPStdioLauncher.send_bytes(launcher, :binary.copy(<<0>>, 1_000_000), 3_000)

    assert System.monotonic_time(:millisecond) - started_at < 2_500

    assert {:ok, {:stderr, "request rejected\n"}} =
             MCPStdioLauncher.receive_event(launcher, 500)

    assert {:ok, {:finished, %{reason: :server_exit, exit_status: 23}}} =
             next_finished(launcher, 500)
  end

  test "preserves finish after delayed stdout consumption closes the acknowledgement path" do
    launcher = open_launcher(["final-output"], grace_ms: 50)

    receive do
    after
      1_200 -> :ok
    end

    assert {:ok, {:stdout, "final output\n"}} =
             MCPStdioLauncher.receive_event(launcher, 500)

    assert {:ok, {:finished, %{reason: reason, exit_status: 0}}} = next_finished(launcher, 500)
    assert reason in [:server_exit, :termination_timeout]
  end

  test "reports closed target stdin without waiting for the write deadline" do
    launcher = open_launcher(["close-stdin"], grace_ms: 50)
    assert %{stdout: "stdin closed\n"} = collect_until(launcher, &(&1.stdout == "stdin closed\n"))
    started_at = System.monotonic_time(:millisecond)

    assert {:error, :closed} =
             MCPStdioLauncher.send_bytes(launcher, :binary.copy(<<0>>, 1_000_000), 3_000)

    assert System.monotonic_time(:millisecond) - started_at < 2_500

    assert {:ok, {:finished, %{reason: :protocol_error}}} =
             next_finished(launcher, 500)
  end

  @tag :tmp_dir
  test "executes the validated symlink target while preserving argv zero", %{tmp_dir: dir} do
    executable_alias = Path.join(dir, "selected-name")

    File.ln_s!(shell(), executable_alias)

    {:ok, launcher} =
      MCPStdioLauncher.open(
        executable: executable_alias,
        executable_sha256: executable_sha256(executable_alias),
        cwd: dir,
        args: ["-c", "printf 'argv0=%s\\n' \"$0\""],
        env: %{}
      )

    assert %{stdout: stdout} = collect_until(launcher, &(&1.stdout != ""))
    assert stdout == "argv0=#{executable_alias}\n"

    assert {:ok, {:finished, %{reason: :server_exit, exit_status: 0}}} =
             next_finished(launcher, 500)
  end

  @tag :tmp_dir
  test "accepts a search-only working directory", %{tmp_dir: dir} do
    cwd = Path.join(dir, "search-only")
    File.mkdir!(cwd)
    File.chmod!(cwd, 0o111)
    on_exit(fn -> File.chmod(cwd, 0o700) end)
    expected_output = "cwd=#{cwd}\n"

    {:ok, launcher} =
      MCPStdioLauncher.open(
        executable: shell(),
        executable_sha256: executable_sha256(shell()),
        cwd: cwd,
        args: ["-c", "printf 'cwd=%s\\n' \"$PWD\""],
        env: %{}
      )

    assert %{stdout: ^expected_output} =
             collect_until(launcher, &(&1.stdout == expected_output))

    assert {:ok, {:finished, %{reason: :server_exit, exit_status: 0}}} =
             next_finished(launcher, 500)
  end

  test "does not leak the held descriptor into Linux native executables" do
    if :os.type() == {:unix, :linux} do
      {canonical_shell, 0} = System.cmd("realpath", [shell()])
      canonical_shell = String.trim(canonical_shell)

      command = """
      for fd in /proc/$$/fd/*; do
        target=$(readlink "$fd" 2>/dev/null || true)
        if [ "$target" = "$0" ]; then printf 'leaked=%s\\n' "$fd"; fi
      done
      printf 'checked\\n'
      """

      {:ok, launcher} =
        MCPStdioLauncher.open(
          executable: shell(),
          executable_sha256: executable_sha256(shell()),
          cwd: File.cwd!(),
          args: ["-c", command, canonical_shell],
          env: %{}
        )

      assert %{stdout: "checked\n"} = collect_until(launcher, &(&1.stdout =~ "checked\n"))

      assert {:ok, {:finished, %{reason: :server_exit, exit_status: 0}}} =
               next_finished(launcher, 500)
    end
  end

  test "restores the target's default SIGPIPE disposition" do
    launcher = open_launcher(["sigpipe"], [])

    assert {:ok, {:finished, %{reason: :server_exit, exit_status: -13}}} =
             next_finished(launcher, 2_000)
  end

  test "rejects operations outside the process that owns the launcher" do
    launcher = open_launcher(["basic", "owner"])

    task =
      Task.async(fn ->
        {
          MCPStdioLauncher.send_bytes(launcher, "not delivered\n"),
          MCPStdioLauncher.receive_event(launcher, 0),
          MCPStdioLauncher.close(launcher)
        }
      end)

    assert {
             {:error, :not_owner},
             {:error, :not_owner},
             {:error, :not_owner}
           } = Task.await(task)

    assert {:ok, %{reason: :close}} = MCPStdioLauncher.close(launcher)
  end

  @tag :tmp_dir
  test "EOF escalates through TERM and KILL for same-group descendants", %{tmp_dir: dir} do
    marker = Path.join(dir, "term-observed")
    launcher = open_launcher(["tree", marker], grace_ms: 1_000)
    descendant = descendant_pid(launcher)

    assert os_process_alive?(descendant)

    assert {:ok, %{reason: :close, exit_status: exit_status}} =
             MCPStdioLauncher.close(launcher, 5_000)

    assert exit_status < 0
    assert File.read!(marker) == "term"
    refute os_process_alive?(descendant)
  end

  @tag :tmp_dir
  test "losing the BEAM port owner terminates its process group", %{tmp_dir: dir} do
    marker = Path.join(dir, "owner-term-observed")
    parent = self()

    owner =
      spawn(fn ->
        launcher = open_launcher(["tree", marker], grace_ms: 100)
        send(parent, {:owned_descendant, descendant_pid(launcher)})

        receive do
          :keep_owner_alive -> :ok
        end
      end)

    owner_ref = Process.monitor(owner)
    assert_receive {:owned_descendant, descendant}, 2_000
    assert os_process_alive?(descendant)

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}

    assert_eventually(fn -> not os_process_alive?(descendant) end, 3_000)
  end

  @tag :tmp_dir
  test "a forcibly killed launcher still retires its server group", %{tmp_dir: dir} do
    marker = Path.join(dir, "orphan-term-observed")
    launcher = open_launcher(["tree", marker], grace_ms: 100)
    %{leader: leader, descendant: descendant} = tree_pids(launcher)

    # Nothing else reaps this group once its launcher is gone, so a regression
    # here must not leak a `sleep` loop into the rest of the run. The leader's
    # PID is also the group identifier and is released the moment it is reaped,
    # so confirm this is still our fixture before aiming a group kill at it.
    on_exit(fn -> kill_fixture_group(leader) end)

    assert os_process_running?(leader)
    assert os_process_running?(descendant)

    {:os_pid, launcher_pid} = Port.info(launcher.port, :os_pid)
    assert {_output, 0} = System.cmd(kill_executable(), ["-9", Integer.to_string(launcher_pid)])
    assert_eventually(fn -> not os_process_running?(launcher_pid) end, 2_000)

    assert_eventually(fn -> not os_process_running?(leader) end, 5_000)
    assert_eventually(fn -> not os_process_running?(descendant) end, 5_000)
  end

  @tag :tmp_dir
  test "close terminates an npx-shaped wrapper and its nested leaf", %{tmp_dir: dir} do
    marker = Path.join(dir, "nested-term-observed")
    launcher = open_launcher(["deep-tree", marker], grace_ms: 1_000)
    leaf = descendant_pid(launcher)

    assert os_process_alive?(leaf)
    assert {:ok, %{reason: :close}} = MCPStdioLauncher.close(launcher, 5_000)
    assert File.read!(marker) == "term"
    refute os_process_alive?(leaf)
  end

  test "rejects an executable whose frozen SHA-256 does not match" do
    assert {:error, :mcp_stdio_spawn_failed} =
             MCPStdioLauncher.open(
               executable: shell(),
               executable_sha256: :binary.copy(<<0>>, 32),
               cwd: File.cwd!(),
               args: [],
               env: %{}
             )
  end

  @tag :tmp_dir
  @tag :slow
  test "a replacement landing during the identity hash never reaches exec", %{tmp_dir: dir} do
    authorized = Path.join(dir, "server")
    impostor = Path.join(dir, "impostor")

    frozen = write_padded_script(authorized, "AUTHORIZED-EXECUTED", @race_target_mebibytes)
    _impostor_digest = write_padded_script(impostor, "IMPOSTOR-EXECUTED", 0)
    on_exit(fn -> File.rm_rf(dir) end)

    racer =
      Task.async(fn ->
        # Deliberate scaffolding rather than a wait: the window under test is
        # defined by wall-clock position inside the launcher's hash.
        Process.sleep(@race_rename_delay_ms)
        :file.rename(impostor, authorized)
      end)

    started_at = System.monotonic_time(:millisecond)

    result =
      MCPStdioLauncher.open(
        executable: authorized,
        executable_sha256: frozen,
        cwd: dir,
        args: [],
        env: %{},
        inherit_environment: false,
        start_timeout_ms: 30_000
      )

    elapsed = System.monotonic_time(:millisecond) - started_at
    assert :ok = Task.await(racer, 5_000)

    case result do
      {:error, reason} ->
        assert reason == :mcp_stdio_spawn_failed
        # Only a full pass over the authorized target takes this long, so the
        # refusal cannot have come from hashing the impostor instead.
        assert elapsed >= @race_minimum_hash_ms

      {:ok, launcher} ->
        output = collect_until(launcher, &(&1.stdout =~ ~r/-EXECUTED\n/))
        assert output.stdout =~ "AUTHORIZED-EXECUTED"
        refute output.stdout =~ "IMPOSTOR-EXECUTED"
        assert {:ok, %{reason: :close}} = MCPStdioLauncher.close(launcher, 2_000)
    end
  end

  @tag :tmp_dir
  test "matches SHA-256 padding-boundary known answers", %{tmp_dir: dir} do
    prefix = "#!/bin/sh\nread _ || true\nexit 0\n#"

    for byte_size <- [55, 56, 63, 64, 65] do
      executable = Path.join(dir, "sha256-#{byte_size}")
      contents = prefix <> String.duplicate("x", byte_size - byte_size(prefix))
      File.write!(executable, contents)
      File.chmod!(executable, 0o700)

      assert {:ok, launcher} =
               MCPStdioLauncher.open(
                 executable: executable,
                 executable_sha256: :crypto.hash(:sha256, contents),
                 cwd: dir,
                 args: [],
                 env: %{},
                 inherit_environment: false
               )

      assert {:ok, %{reason: :close}} = MCPStdioLauncher.close(launcher, 2_000)
    end
  end

  test "rejects invalid launch configuration before opening a target" do
    assert {:error, :invalid_mcp_stdio_launch} =
             MCPStdioLauncher.open(
               executable: "relative/sh",
               executable_sha256: :binary.copy(<<0>>, 32),
               cwd: File.cwd!(),
               args: [],
               env: %{}
             )

    assert {:error, :invalid_mcp_stdio_launch} =
             MCPStdioLauncher.open(
               executable: shell(),
               executable_sha256: executable_sha256(shell()),
               cwd: File.cwd!(),
               args: [],
               env: %{"BAD-NAME" => "secret"}
             )

    assert {:error, :invalid_mcp_stdio_launch} =
             MCPStdioLauncher.open(
               executable: shell(),
               executable_sha256: executable_sha256(shell()),
               cwd: File.cwd!(),
               args: [],
               env: %URI{}
             )

    assert {:error, :invalid_mcp_stdio_launch} =
             MCPStdioLauncher.open(
               executable: shell(),
               executable_sha256: executable_sha256(shell()),
               cwd: File.cwd!(),
               args: [],
               env: %{},
               start_timeout_ms: 60_001
             )

    assert {:error, :invalid_mcp_stdio_launch} =
             MCPStdioLauncher.open(
               executable: shell(),
               executable_sha256: <<0>>,
               cwd: File.cwd!(),
               args: [],
               env: %{}
             )

    large_argument = String.duplicate("x", 131_072)

    assert {:error, :invalid_mcp_stdio_launch} =
             MCPStdioLauncher.open(
               executable: shell(),
               executable_sha256: executable_sha256(shell()),
               cwd: File.cwd!(),
               args: List.duplicate(large_argument, 9),
               env: %{}
             )
  end

  test "failed startup leaves no dead-port messages in the owner mailbox" do
    messages_before = mailbox_messages()

    assert {:error, :mcp_stdio_spawn_failed} =
             MCPStdioLauncher.open(
               executable: "/definitely/not/a/real/executable",
               executable_sha256: :binary.copy(<<0>>, 32),
               cwd: File.cwd!(),
               args: [],
               env: %{}
             )

    assert mailbox_messages() == messages_before
  end

  @tag :tmp_dir
  test "directly executes a Linux shebang server through the held descriptor", %{tmp_dir: dir} do
    if :os.type() == {:unix, :linux} do
      executable = Path.join(dir, "stdio-server")
      File.cp!(@fixture, executable)
      File.chmod!(executable, 0o700)

      {:ok, launcher} =
        MCPStdioLauncher.open(
          executable: executable,
          executable_sha256: executable_sha256(executable),
          cwd: File.cwd!(),
          args: ["basic", "direct-script"],
          env: %{"PTC_ALLOWED" => "visible"},
          inherit_environment: false
        )

      assert %{stdout: stdout} = collect_until(launcher, &(&1.stdout =~ "arg=direct-script\n"))
      assert stdout =~ "home=unset\n"

      assert {:ok, %{reason: :close}} = MCPStdioLauncher.close(launcher)
    end
  end

  test "repeated completed launches close their ports and leave no port messages" do
    Enum.each(1..20, fn _iteration ->
      launcher = open_launcher(["basic", "repeated"])

      assert {:ok, %{reason: :close}} = MCPStdioLauncher.close(launcher)
      assert is_nil(Port.info(launcher.port))
      refute Enum.any?(mailbox_messages(), &port_message?(&1, launcher.port))
    end)
  end

  # Closing the BEAM port and releasing the OS pipe descriptors are separate
  # facts. A launcher that exits without closing its ends still satisfies the
  # port and mailbox assertions above while accumulating descriptors until the
  # VM hits EMFILE, so account for them directly across repeated cycles.
  test "repeated launches release their descriptors" do
    baseline = open_descriptor_count()

    Enum.each(1..20, fn _iteration ->
      launcher = open_launcher(["basic", "descriptors"])
      assert {:ok, %{reason: :close}} = MCPStdioLauncher.close(launcher)
    end)

    assert_eventually(fn -> open_descriptor_count() <= baseline + 8 end, 2_000)
  end

  test "failed close discards events preserved by an interrupted write" do
    launcher = open_launcher(["exit-no-read"], grace_ms: 50)

    assert {:error, :closed} =
             MCPStdioLauncher.send_bytes(launcher, :binary.copy(<<0>>, 1_000_000), 3_000)

    assert event_buffered?(launcher)
    assert {:error, :closed} = MCPStdioLauncher.close(launcher)
    refute event_buffered?(launcher)
  end

  test "timed-out close discards every message from its closed port" do
    launcher = open_launcher(["stdout-flood"], grace_ms: 50)

    receive do
    after
      50 -> :ok
    end

    started_at = System.monotonic_time(:millisecond)
    assert {:error, :timeout} = MCPStdioLauncher.close(launcher, 1)
    assert System.monotonic_time(:millisecond) - started_at < 500
    assert is_nil(Port.info(launcher.port))
    refute Enum.any?(mailbox_messages(), &port_message?(&1, launcher.port))
    refute event_buffered?(launcher)
  end

  defp open_launcher(args, opts \\ []) do
    executable =
      case Keyword.fetch(opts, :executable) do
        {:ok, configured} -> configured
        :error -> shell()
      end

    {:ok, launcher} =
      MCPStdioLauncher.open(
        Keyword.merge(
          [
            executable: executable,
            executable_sha256: executable_sha256(executable),
            cwd: File.cwd!(),
            args: [@fixture | args],
            env: %{},
            grace_ms: 50,
            stderr_bytes: 1_024
          ],
          opts
        )
      )

    launcher
  end

  defp open_environment_launcher(opts \\ []) do
    executable =
      Application.fetch_env!(:ptc_runner_launcher, :mcp_stdio_environment_fixture_path)

    {:ok, launcher} =
      MCPStdioLauncher.open(
        Keyword.merge(
          [
            executable: executable,
            executable_sha256: executable_sha256(executable),
            cwd: File.cwd!(),
            args: ["environment"],
            env: %{},
            grace_ms: 50,
            stderr_bytes: 1_024
          ],
          opts
        )
      )

    launcher
  end

  # Returns the SHA-256 of what was written, hashed as it goes: reading a target
  # this size back just to freeze its identity would cost more than the launch
  # under test.
  defp write_padded_script(path, marker, mebibytes) do
    header = "#!/bin/sh\nprintf '#{marker}\\n'\nexit 0\n#"
    padding = :binary.copy("x", 1024 * 1024)

    digest =
      File.open!(path, [:write, :binary], fn handle ->
        Enum.reduce([header | List.duplicate(padding, mebibytes)], :crypto.hash_init(:sha256), fn
          chunk, context ->
            IO.binwrite(handle, chunk)
            :crypto.hash_update(context, chunk)
        end)
      end)

    File.chmod!(path, 0o700)
    :crypto.hash_final(digest)
  end

  defp executable_sha256(executable) do
    executable
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp environment_names(stdout) do
    ~r/^ENV_HEX=([0-9A-F]*)$/m
    |> Regex.scan(stdout, capture: :all_but_first)
    |> Enum.map(fn [encoded] ->
      {:ok, name} = Base.decode16(encoded)
      name
    end)
    |> MapSet.new()
  end

  defp compatibility_environment_names(explicit_names \\ []) do
    inherited =
      ~w(HOME LOGNAME PATH SHELL TERM USER)
      |> Enum.filter(fn name ->
        case System.get_env(name) do
          nil -> false
          value -> String.valid?(value) and not String.starts_with?(value, "()")
        end
      end)

    MapSet.new(inherited ++ explicit_names)
  end

  defp shell do
    System.find_executable("sh") || flunk("POSIX sh is unavailable")
  end

  defp collect_until(launcher, predicate) do
    collect_until(
      launcher,
      predicate,
      %{stdout: "", stderr: "", truncated?: false},
      System.monotonic_time(:millisecond) + 2_000
    )
  end

  defp collect_until(launcher, predicate, output, deadline) do
    if predicate.(output) do
      output
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      case MCPStdioLauncher.receive_event(launcher, remaining) do
        {:ok, {:stdout, bytes}} ->
          collect_until(
            launcher,
            predicate,
            %{output | stdout: output.stdout <> bytes},
            deadline
          )

        {:ok, {:stderr, bytes}} ->
          collect_until(
            launcher,
            predicate,
            %{output | stderr: output.stderr <> bytes},
            deadline
          )

        {:ok, :stderr_truncated} ->
          collect_until(launcher, predicate, %{output | truncated?: true}, deadline)

        other ->
          flunk("launcher ended before expected output: #{inspect(other)}")
      end
    end
  end

  defp descendant_pid(launcher) do
    output = collect_until(launcher, &(&1.stdout =~ ~r/descendant=\d+\n/))
    [pid] = Regex.run(~r/descendant=(\d+)/, output.stdout, capture: :all_but_first)
    String.to_integer(pid)
  end

  defp tree_pids(launcher) do
    output =
      collect_until(
        launcher,
        &(&1.stdout =~ ~r/leader=\d+\n/ and &1.stdout =~ ~r/descendant=\d+\n/)
      )

    [leader] = Regex.run(~r/leader=(\d+)/, output.stdout, capture: :all_but_first)
    [descendant] = Regex.run(~r/descendant=(\d+)/, output.stdout, capture: :all_but_first)

    %{leader: String.to_integer(leader), descendant: String.to_integer(descendant)}
  end

  defp next_finished(launcher, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_next_finished(launcher, deadline)
  end

  defp send_until_backpressured(launcher, attempts) do
    Enum.reduce_while(1..attempts, 0, fn _attempt, delivered ->
      case MCPStdioLauncher.send_bytes(launcher, :binary.copy(<<0>>, 4_096), 50) do
        :ok -> {:cont, delivered + 1}
        {:error, :timeout} -> {:halt, delivered}
      end
    end)
  end

  defp saturate_port(port, attempts) do
    bytes = :binary.copy(<<0>>, 1_000_000)

    Enum.reduce_while(1..attempts, :open, fn attempt, _state ->
      payload = <<"D", attempt::unsigned-big-64, bytes::binary>>

      try do
        if Port.command(port, payload, [:nosuspend]),
          do: {:cont, :open},
          else: {:halt, :busy}
      rescue
        ArgumentError -> {:halt, :closed}
      end
    end)
  end

  defp do_next_finished(launcher, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case MCPStdioLauncher.receive_event(launcher, remaining) do
      {:ok, {:finished, _finish}} = finished -> finished
      {:ok, _event} -> do_next_finished(launcher, deadline)
      {:error, :timeout} = timeout -> timeout
    end
  end

  defp os_process_alive?(pid) do
    {_output, status} =
      System.cmd(kill_executable(), ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

    status == 0
  end

  # `kill -0` also succeeds for an un-reaped zombie, and nothing reaps the
  # server group once its launcher has been destroyed, so liveness after a
  # forced launcher kill has to be read from the process state instead.
  defp os_process_running?(pid) do
    {output, status} =
      System.cmd(ps_executable(), ["-o", "state=", "-p", Integer.to_string(pid)],
        stderr_to_stdout: true
      )

    state = String.trim(output)

    status == 0 and state != "" and not String.starts_with?(state, "Z")
  end

  defp kill_fixture_group(leader) do
    {command, status} =
      System.cmd(ps_executable(), ["-o", "command=", "-p", Integer.to_string(leader)],
        stderr_to_stdout: true
      )

    if status == 0 and command =~ @fixture do
      System.cmd(kill_executable(), ["-9", "-#{leader}"], stderr_to_stdout: true)
    end
  end

  defp kill_executable do
    System.find_executable("kill") || flunk("POSIX kill is unavailable")
  end

  defp ps_executable do
    System.find_executable("ps") || flunk("POSIX ps is unavailable")
  end

  defp mailbox_messages do
    {:messages, messages} = Process.info(self(), :messages)
    messages
  end

  defp open_descriptor_count do
    directory =
      case :os.type() do
        {:unix, :linux} -> "/proc/self/fd"
        {:unix, :darwin} -> "/dev/fd"
        platform -> flunk("unsupported descriptor-count platform: #{inspect(platform)}")
      end

    case File.ls(directory) do
      {:ok, entries} -> length(entries)
      {:error, reason} -> flunk("cannot enumerate #{directory}: #{inspect(reason)}")
    end
  end

  defp port_message?({port, _message}, expected_port), do: port == expected_port
  defp port_message?(_message, _expected_port), do: false

  defp event_buffered?(launcher) do
    {MCPStdioLauncher, :event_buffer, launcher.port} in Process.get_keys()
  end

  defp assert_eventually(predicate, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually(predicate, deadline)
  end

  defp do_assert_eventually(predicate, deadline) do
    cond do
      predicate.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition did not become true before the deadline")

      true ->
        receive do
        after
          10 -> do_assert_eventually(predicate, deadline)
        end
    end
  end
end
