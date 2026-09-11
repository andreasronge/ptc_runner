defmodule PtcRunner.Kernel.PrivateDirectoryTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.PrivateDirectory

  @moduletag :tmp_dir

  test "directory creation preserves a no-space filesystem cause", %{tmp_dir: directory} do
    real_id = System.find_executable("id")
    fake_bin = Path.join(directory, "bin")
    destination = Path.join(directory, "destination")
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

    assert {:error, :enospc} = PrivateDirectory.create(destination)
    refute File.exists?(destination)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
