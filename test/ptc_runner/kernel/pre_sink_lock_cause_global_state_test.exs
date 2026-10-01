defmodule PtcRunner.Kernel.PreSinkLockCauseGlobalStateTest do
  use ExUnit.Case, async: false
  @moduletag :operator

  import PtcRunner.TestSupport.CommandEngineFixtures

  alias PtcRunner.Kernel.CommandEngine

  @tag :tmp_dir
  test "append lock timeout and subprocess failure survive command projection", %{
    tmp_dir: dir
  } do
    application = write_application(dir, "lock", valid_manifest())
    shell = System.find_executable("sh")
    original_path = System.get_env("PATH")
    bin = Path.join(dir, "bin")
    File.mkdir!(bin)
    File.ln_s!(shell, Path.join(bin, "sh"))

    # Both supported lock helpers report EX_TEMPFAIL (75) on contention.
    # Prepend PATH so the command exercises the real port protocol without
    # waiting thirty seconds for an OS lock or depending on the host platform.
    try do
      System.put_env("PATH", bin <> ":" <> (original_path || ""))

      for {status, cause} <- [{75, "lock_timeout"}, {99, "subprocess_failed"}] do
        for command <- ["lockf", "flock"] do
          path = Path.join(bin, command)
          File.write!(path, "#!#{shell}\nexit #{status}\n")
          File.chmod!(path, 0o700)
        end

        output = Path.join(dir, "result-#{status}.json")

        assert {:error, outcome} =
                 CommandEngine.dispatch(["run", application, "--output", output])

        assert outcome.envelope["error"]["code"] == "result_destination_unavailable"
        assert outcome.envelope["error"]["cause"] == cause
        assert_schema_valid(outcome.envelope)
        refute Jason.encode!(outcome.envelope) =~ dir
      end
    after
      if original_path, do: System.put_env("PATH", original_path), else: System.delete_env("PATH")
    end
  end
end
