defmodule PtcRunnerMcp.ReleaseEnvTest do
  use ExUnit.Case, async: false

  @env_sh Path.expand("../../rel/env.sh.eex", __DIR__)

  test "release env shim defaults Erlang distribution off" do
    assert {distribution, 0} =
             System.cmd(
               "/bin/sh",
               [
                 "-c",
                 """
                 unset RELEASE_DISTRIBUTION
                 . "#{@env_sh}"
                 printf '%s' "$RELEASE_DISTRIBUTION"
                 """
               ]
             )

    assert distribution == "none"
  end

  test "release env shim preserves explicit Erlang distribution override" do
    assert {distribution, 0} =
             System.cmd(
               "/bin/sh",
               [
                 "-c",
                 """
                 . "#{@env_sh}"
                 printf '%s' "$RELEASE_DISTRIBUTION"
                 """
               ],
               env: [{"RELEASE_DISTRIBUTION", "sname"}]
             )

    assert distribution == "sname"
  end

  test "release env shim preserves repeated --http-allowed-origin flags" do
    assert {origins, 0} =
             System.cmd("/bin/sh", [
               "-c",
               """
               . "#{@env_sh}"
               unset PTC_RUNNER_MCP_HTTP_ALLOWED_ORIGIN
               ptc_runner_mcp_export_cli_env start \
                 --http-allowed-origin http://a.test \
                 --http-allowed-origin=http://b.test \
                 --http-allowed-origin http://c.test
               printf '%s' "$PTC_RUNNER_MCP_HTTP_ALLOWED_ORIGIN"
               """
             ])

    assert origins == "http://a.test,http://b.test,http://c.test"
  end

  test "first CLI allowed-origin overrides an inherited env value" do
    assert {origins, 0} =
             System.cmd(
               "/bin/sh",
               [
                 "-c",
                 """
                 . "#{@env_sh}"
                 ptc_runner_mcp_export_cli_env start \
                   --http-allowed-origin http://cli-a.test \
                   --http-allowed-origin http://cli-b.test
                 printf '%s' "$PTC_RUNNER_MCP_HTTP_ALLOWED_ORIGIN"
                 """
               ],
               env: [{"PTC_RUNNER_MCP_HTTP_ALLOWED_ORIGIN", "http://env.test"}]
             )

    assert origins == "http://cli-a.test,http://cli-b.test"
  end
end
