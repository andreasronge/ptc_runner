defmodule PtcRunnerLauncher.CommandTest do
  use ExUnit.Case, async: true

  alias PtcRunnerLauncher.Command

  @tag :tmp_dir
  test "returns when an external command never reports an exit status", %{tmp_dir: directory} do
    shell = System.find_executable("sh")
    ready = create_fifo!(directory, "timeout-ready")

    command =
      Task.async(fn ->
        Command.run(
          shell,
          ["-c", ~s[printf ready > "$1"; read blocked_forever], "ptc-command-test", ready],
          250
        )
      end)

    assert File.read!(ready) == "ready"
    assert {:error, :timeout} = Task.await(command, 1_000)
  end

  test "returns output and status from a completed command" do
    shell = System.find_executable("sh")

    assert {:ok, {"published", 0}} =
             Command.run(shell, ["-c", "printf published"], 1_000)
  end

  @tag :tmp_dir
  test "caller death terminates the command worker", %{tmp_dir: directory} do
    shell = System.find_executable("sh")
    ready = create_fifo!(directory, "caller-ready")

    caller =
      spawn(fn ->
        receive do
          :run ->
            Command.run(
              shell,
              ["-c", ~s[printf ready > "$1"; read blocked_forever], "ptc-command-test", ready],
              5_000
            )
        end
      end)

    :erlang.trace(caller, true, [:procs])
    send(caller, :run)

    assert_receive {:trace, ^caller, :spawn, worker, _initial_call}
    assert File.read!(ready) == "ready"
    worker_ref = Process.monitor(worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
  end

  defp create_fifo!(directory, name) do
    path = Path.join(directory, name)
    mkfifo = System.find_executable("mkfifo")
    assert {"", 0} = System.cmd(mkfifo, [path], stderr_to_stdout: true)
    path
  end
end
