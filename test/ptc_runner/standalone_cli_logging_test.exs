defmodule PtcRunner.StandaloneCLILoggingTest do
  use ExUnit.Case, async: false

  @moduletag :nightly
  @moduletag :operator
  @moduletag :tmp_dir

  test "standalone shutdown keeps a publication warning on stderr", %{tmp_dir: dir} do
    destination = Path.join(dir, "result.json")

    expression = """
    PtcRunner.CLILogger.install_stderr_handler()
    fault_hook = fn :staging_file -> {:error, :eio}; _ -> :ok end
    {:error, :destination_unavailable} =
      PtcRunner.Kernel.PublicationHandle.reserve_direct(
        #{inspect(destination)}, :result, 0o600, self(), fault_hook
      )
    PtcRunner.StandaloneCLI.main(["help"])
    """

    {output, 0} =
      System.cmd(System.find_executable("mix"), ["run", "--no-compile", "-e", expression],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    line = "destination unavailable: operation=reserve kind=result cause=reason:eio"
    assert output =~ line
    assert length(String.split(output, line)) == 2
    refute output =~ dir
  end
end
