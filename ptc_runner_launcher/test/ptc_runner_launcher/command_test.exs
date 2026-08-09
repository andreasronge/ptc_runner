defmodule PtcRunnerLauncher.CommandTest do
  use ExUnit.Case, async: true

  alias PtcRunnerLauncher.Command

  test "returns when an external command never reports an exit status" do
    shell = System.find_executable("sh")

    assert {:error, :timeout} =
             Command.run(shell, ["-c", "read blocked_forever"], 25)
  end

  test "returns output and status from a completed command" do
    shell = System.find_executable("sh")

    assert {:ok, {"published", 0}} =
             Command.run(shell, ["-c", "printf published"], 1_000)
  end
end
