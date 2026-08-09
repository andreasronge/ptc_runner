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

  @tag :tmp_dir
  test "publishes a directory atomically without replacing a directory or symlink", %{
    tmp_dir: directory
  } do
    first_staging = private_directory!(directory, "first")
    target = Path.join(directory, "target")

    assert :ok = PtcRunnerLauncher.publish_directory_noreplace(first_staging, target)
    assert File.read!(Path.join(target, "value")) == "first"

    collision = private_directory!(directory, "collision")

    assert {:error, :collision} =
             PtcRunnerLauncher.publish_directory_noreplace(collision, target)

    assert File.dir?(collision)
    assert File.read!(Path.join(target, "value")) == "first"

    destination = Path.join(directory, "destination")
    File.mkdir!(destination)
    linked_target = Path.join(directory, "linked-target")
    File.ln_s!(destination, linked_target)
    symlink_collision = private_directory!(directory, "symlink-collision")

    assert {:error, :collision} =
             PtcRunnerLauncher.publish_directory_noreplace(symlink_collision, linked_target)

    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(linked_target)
    assert File.dir?(symlink_collision)
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

  defp private_directory!(parent, name) do
    path = Path.join(parent, name)
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    File.write!(Path.join(path, "value"), name)
    path
  end
end
