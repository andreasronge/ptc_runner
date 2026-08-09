defmodule PtcRunner.Kernel.SystemCommandTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.SystemCommand

  test "bounds an external command that never reports an exit status" do
    shell = System.find_executable("sh")

    assert {:error, :timeout} =
             SystemCommand.run(shell, ["-c", "read blocked_forever"], 25)
  end

  test "returns output and status from a completed command" do
    shell = System.find_executable("sh")

    assert {:ok, {"ready", 0}} =
             SystemCommand.run(shell, ["-c", "printf ready"], 1_000)
  end

  test "caller death terminates the external command worker" do
    shell = System.find_executable("sh")

    caller =
      spawn(fn ->
        receive do
          :run -> SystemCommand.run(shell, ["-c", "read blocked_forever"], 5_000)
        end
      end)

    :erlang.trace(caller, true, [:procs])
    send(caller, :run)

    assert_receive {:trace, ^caller, :spawn, worker, _initial_call}
    worker_ref = Process.monitor(worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
  end
end
