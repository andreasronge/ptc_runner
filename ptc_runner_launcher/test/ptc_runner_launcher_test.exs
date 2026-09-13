defmodule PtcRunnerLauncherTest do
  use ExUnit.Case, async: true

  test "locates the executable that implements the public protocol version" do
    assert PtcRunnerLauncher.protocol_version() == 2
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

  @tag :tmp_dir
  test "bounded staging removal preserves replacements, changed markers and symlinks", %{
    tmp_dir: directory
  } do
    File.chmod!(directory, 0o700)
    staging = private_directory!(directory, "staging")
    File.rm!(Path.join(staging, "value"))
    File.write!(Path.join(staging, "artifact"), "stale")
    File.write!(Path.join(staging, "owner"), "2147483647")
    File.chmod!(Path.join(staging, "owner"), 0o600)
    parent_stat = File.stat!(directory)
    stat = File.stat!(staging)
    File.write!(Path.join(staging, "owner"), System.pid())

    assert {:error, :staging_preserved} =
             PtcRunnerLauncher.remove_staging_bounded(staging, parent_stat, stat, "2147483647")

    assert File.read!(Path.join(staging, "artifact")) == "stale"
    File.rename!(staging, staging <> "-original")
    replacement = private_directory!(directory, "staging")

    assert {:error, :staging_preserved} =
             PtcRunnerLauncher.remove_staging_bounded(staging, parent_stat, stat, "2147483647")

    assert File.read!(Path.join(replacement, "value")) == "staging"
    File.rename!(replacement, replacement <> "-replacement")
    File.ln_s!(staging <> "-original", staging)

    assert {:error, :directory_unavailable} =
             PtcRunnerLauncher.list_directory_bounded(staging, 5, 16)

    assert {:error, :staging_preserved} =
             PtcRunnerLauncher.remove_staging_bounded(staging, parent_stat, stat, "2147483647")

    assert {:ok, %{type: :symlink}} = File.lstat(staging)
    ancestor = Path.join(directory, "linked-parent")
    File.ln_s!(directory, ancestor)
    redirected = Path.join(ancestor, "staging-original")

    assert {:error, :directory_unavailable} =
             PtcRunnerLauncher.list_directory_bounded(redirected, 5, 16)

    assert {:error, :staging_preserved} =
             PtcRunnerLauncher.remove_staging_bounded(redirected, parent_stat, stat, "2147483647")
  end

  @tag :tmp_dir
  test "bounded directory enumeration caps physical entries and preserves filename framing", %{
    tmp_dir: directory
  } do
    File.chmod!(directory, 0o700)
    for index <- 1..300, do: File.write!(Path.join(directory, "entry-#{index}"), "")
    File.write!(Path.join(directory, "line\nbreak"), "")
    assert {:ok, first, 256} = PtcRunnerLauncher.list_directory_bounded(directory, 256, 16)
    assert length(first) <= 256
    assert {:ok, second, count} = PtcRunnerLauncher.list_directory_bounded(directory, 256, 16)
    assert "line\nbreak" in (first ++ second)
    assert count < 256
    assert length(Enum.uniq(first ++ second)) == 302
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
