defmodule PtcRunner.Kernel.PrivateDirectoryTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.CommandFrontend
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.TestSupport.CommandEngineFixtures

  @moduletag :tmp_dir

  test "envelope admission preserves a no-space filesystem cause", %{tmp_dir: directory} do
    real_id = System.find_executable("id")
    fake_bin = Path.join(directory, "bin")
    destination = Path.join(directory, "destination")
    envelope = Path.join(directory, "envelope.json")
    original_path = System.get_env("PATH")

    assert is_binary(real_id)
    File.mkdir!(fake_bin)
    File.ln_s!(real_id, Path.join(fake_bin, "id"))

    fake_mkdir = Path.join(fake_bin, "mkdir")

    File.write!(
      fake_mkdir,
      "#!/bin/sh\nprintf '%s\\n' 'mkdir: destination: No space left on device' >&2\nexit 1\n"
    )

    File.chmod!(fake_mkdir, 0o700)
    System.put_env("PATH", fake_bin)
    on_exit(fn -> restore_env("PATH", original_path) end)

    presentation =
      CommandFrontend.execute(
        ["init", destination, "--envelope", envelope],
        :standalone,
        fn _arguments -> flunk("must not bootstrap") end
      )

    assert presentation.exit_status == 7
    assert presentation.stderr =~ "destination/envelope_destination_unavailable"
    assert presentation.stderr =~ inspect(envelope)
    assert presentation.stderr =~ "no space left on device (enospc)"
    refute File.exists?(destination)
    refute File.exists?(envelope)
  end

  test "run skips staging cleanup and recovers reservations without the launcher companion", %{
    tmp_dir: directory
  } do
    launcher = :code.which(PtcRunnerLauncher) |> List.to_string() |> Path.dirname()
    assert :code.del_path(String.to_charlist(launcher))
    :code.purge(PtcRunnerLauncher)
    :code.delete(PtcRunnerLauncher)

    on_exit(fn -> :code.add_patha(String.to_charlist(launcher)) end)
    refute Code.ensure_loaded?(PtcRunnerLauncher)

    manifest =
      CommandEngineFixtures.write_application(
        directory,
        "application",
        CommandEngineFixtures.valid_manifest()
      )

    root = Path.join(directory, ".ptc")
    staging = Path.join(root, ".ptc-private-012345abcdef")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    File.mkdir!(staging)
    File.chmod!(staging, 0o700)
    File.write!(Path.join(staging, "owner"), "2147483647")
    File.chmod!(Path.join(staging, "owner"), 0o600)
    File.write!(Path.join(staging, "artifact"), "interrupted")

    project = Path.join(directory, "ptc-project.json")

    File.write!(
      project,
      Jason.encode!(%{
        "kind" => "ptc-project",
        "version" => 1,
        "application" => %{"path" => Path.relative_to(manifest, directory)},
        "artifacts" => %{
          "root" => ".ptc",
          "trace" => false,
          "inspection" => false,
          "result" => false,
          "envelope" => false
        }
      })
    )

    for {name, owner, expected} <- [
          {"dead", "2147483647", 0},
          {"live", System.pid(), 7},
          {"malformed", "not-a-pid", 7},
          {"oversized", String.duplicate("1", 11), 7}
        ] do
      output = Path.join(directory, name <> ".json")
      stat = File.stat!(directory)
      key = {{stat.major_device, stat.minor_device, stat.inode}, name <> ".json"}

      digest =
        :crypto.hash(:sha256, :erlang.term_to_binary(key, [:deterministic]))
        |> Base.encode16(case: :lower)

      reservation = Path.join(directory, "." <> digest <> ".ptc-reservation")
      File.mkdir!(reservation)
      File.chmod!(reservation, 0o700)
      File.write!(Path.join(reservation, "owner"), owner)
      File.chmod!(Path.join(reservation, "owner"), 0o600)
      File.touch!(Path.join(reservation, "owner"), System.os_time(:second) - 120)

      presentation =
        CommandFrontend.execute(["run", project, "--output", output], :standalone, fn _ ->
          {:ok, CommandRuntime.standalone()}
        end)

      assert presentation.exit_status == expected
      assert File.exists?(reservation) == (expected == 7)
      assert File.read!(Path.join(staging, "artifact")) == "interrupted"
      assert Enum.sort(File.ls!(staging)) == ["artifact", "owner"]
      assert File.ls!(root) == [Path.basename(staging)]
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
