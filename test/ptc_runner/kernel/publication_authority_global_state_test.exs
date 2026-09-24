defmodule PtcRunner.Kernel.PublicationAuthorityGlobalStateTest do
  # async: false — these cases rewrite PATH VM-wide so the publication primitives resolve to a
  # missing or failing mkdir (class D). The rest of PublicationAuthority coverage is async.
  use ExUnit.Case, async: false

  import PtcRunner.TestSupport.CommandEngineFixtures,
    only: [valid_manifest: 0, write_application: 3]

  alias PtcRunner.Kernel.CommandEngine

  @tag :tmp_dir
  test "missing publication primitives make the artifact destination unavailable", %{tmp_dir: dir} do
    application = write_application(dir, "missing-publication-primitives", valid_manifest())
    original_path = System.get_env("PATH")

    on_exit(fn -> restore_env("PATH", original_path) end)

    assert {:ok, preparation} =
             CommandEngine.prepare([
               "run",
               application,
               "--output",
               Path.join(dir, "result.json")
             ])

    System.put_env("PATH", "")

    assert {:error, outcome} = CommandEngine.preflight(preparation)
    assert outcome.envelope["error"]["phase"] == "destination"
    assert outcome.envelope["error"]["code"] == "result_destination_unavailable"
    assert outcome.envelope["error"]["provider_activity"] == false
    refute Jason.encode!(outcome.envelope) =~ dir
  end

  @tag :tmp_dir
  test "a no-space reservation keeps the artifact-specific destination diagnostic", %{
    tmp_dir: dir
  } do
    application = write_application(dir, "no-space-result", valid_manifest())
    real_id = System.find_executable("id")
    fake_bin = Path.join(dir, "bin")
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
    on_exit(fn -> restore_env("PATH", original_path) end)

    assert {:ok, preparation} =
             CommandEngine.prepare([
               "run",
               application,
               "--output",
               Path.join(dir, "result.json")
             ])

    System.put_env("PATH", fake_bin)

    assert {:error, outcome} = CommandEngine.preflight(preparation)
    assert outcome.envelope["error"]["phase"] == "destination"
    assert outcome.envelope["error"]["code"] == "result_destination_unavailable"
    assert outcome.envelope["error"]["provider_activity"] == false
    refute Jason.encode!(outcome.envelope) =~ dir
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
