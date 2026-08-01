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

  test "precommit cannot be scoped to a partial test suite" do
    precommit = Mix.Project.config() |> Keyword.fetch!(:aliases) |> Keyword.fetch!(:precommit)

    assert_raise Mix.Error, ~r/accepts only the optional --max-cases/, fn ->
      precommit.(["test/ptc_runner_launcher_test.exs"])
    end

    assert_raise Mix.Error, ~r/requires --max-cases to be a positive integer/, fn ->
      precommit.(["--max-cases", "0"])
    end
  end
end
