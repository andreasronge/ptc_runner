defmodule PtcRunnerLauncherTest do
  use ExUnit.Case, async: true

  test "locates the executable that implements the public protocol version" do
    assert PtcRunnerLauncher.protocol_version() == 1
    assert {:ok, path} = PtcRunnerLauncher.executable_path()
    assert Path.type(path) == :absolute
    assert File.regular?(path)

    assert {:ok, stat} = File.stat(path)
    assert Bitwise.band(stat.mode, 0o111) != 0
  end
end
