defmodule PtcRunner.Kernel.SystemCommandTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.SystemCommand

  test "bounds an external command that never reports an exit status" do
    shell = System.find_executable("sh")

    assert {:error, :timeout} =
             SystemCommand.run(shell, ["-c", "read blocked_forever"], 1_000)
  end

  test "returns output and status from a completed command" do
    shell = System.find_executable("sh")

    assert {:ok, {"ready", 0}} =
             SystemCommand.run(shell, ["-c", "printf ready"], 1_000)
  end
end
