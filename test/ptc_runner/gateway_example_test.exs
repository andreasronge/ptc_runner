defmodule PtcRunner.GatewayExampleTest do
  use ExUnit.Case, async: false
  @moduletag :operator
  @moduletag timeout: 600_000

  @root Path.expand("../..", __DIR__)

  @tag :scheduled_e2e
  test "gateway composition through the executable with a live model" do
    assert System.get_env("OPENROUTER_API_KEY") not in [nil, ""],
           "OPENROUTER_API_KEY is required for the scheduled gateway probe"

    release =
      System.get_env("PTC_RELEASE_ROOT") || Path.join(@root, "_build/gateway_example/release")

    unless System.get_env("PTC_RELEASE_ROOT") do
      {output, status} =
        System.cmd("mix", ["release", "ptc_runner", "--overwrite", "--path", release],
          cd: @root,
          env: [{"MIX_ENV", "prod"}],
          stderr_to_stdout: true
        )

      assert status == 0, output
    end

    {output, status} =
      System.cmd(
        "python3",
        [
          Path.join(@root, "scripts/verify_gateway_example.py"),
          Path.join(release, "bin/ptc"),
          "--model"
        ],
        cd: @root,
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "Gateway example passed with live model"
  end
end
