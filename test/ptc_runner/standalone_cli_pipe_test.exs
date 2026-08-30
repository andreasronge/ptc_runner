defmodule PtcRunner.StandaloneCLIPipeTest do
  @moduledoc """
  Packaged-CLI regression for a closed stdout pipe (#1498).

  `elixir -e` does not dump; the release wrapper is
  `exec "$release_root/bin/ptc_runner" eval 'PtcRunner.StandaloneCLI.main(System.argv())'`,
  and that is the only entry that crash-dumps 3/3 today.
  """

  use ExUnit.Case, async: false

  @root Path.expand("../..", __DIR__)
  @release_root Path.join(@root, "_build/ptc_packaged_cli_pipe/release")
  @moduletag :nightly
  @moduletag timeout: 600_000

  @tag :tmp_dir
  test "packaged ptc docs piped through head exits 141 with empty stderr", %{tmp_dir: directory} do
    ptc = packaged_ptc!()
    dump = Path.join(directory, "erl_crash.dump")
    stderr_path = Path.join(directory, "stderr.txt")
    script = Path.join(directory, "pipe.sh")

    File.write!(script, """
    #!/usr/bin/env bash
    set +e
    export ERL_CRASH_DUMP=#{inspect(dump)}
    unset ERL_CRASH_DUMP_SECONDS
    "#{ptc}" docs ptc-lisp 2>#{inspect(stderr_path)} | head -c 5 >/dev/null
    printf '%s' "${PIPESTATUS[0]}"
    """)

    File.chmod!(script, 0o755)

    {status_text, 0} =
      System.cmd("bash", [script], cd: directory, stderr_to_stdout: true)

    assert status_text == "141"
    assert File.read!(stderr_path) == ""
    refute File.exists?(dump)
  end

  defp packaged_ptc! do
    case System.get_env("PTC_RELEASE_ROOT") do
      root when is_binary(root) and root != "" ->
        ptc = Path.join(root, "bin/ptc")
        assert File.regular?(ptc), "PTC_RELEASE_ROOT has no bin/ptc: #{root}"
        ptc

      _ ->
        File.mkdir_p!(@release_root)

        {output, status} =
          System.cmd(
            System.find_executable("mix"),
            ["release", "ptc_runner", "--overwrite", "--path", @release_root],
            cd: @root,
            env: [{"MIX_ENV", "prod"}],
            stderr_to_stdout: true
          )

        assert status == 0, output
        ptc = Path.join(@release_root, "bin/ptc")
        assert File.regular?(ptc), output
        ptc
    end
  end
end
