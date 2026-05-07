defmodule PtcRunnerMcp.Integration.CrossLanguageTest do
  @moduledoc """
  Phase 6a — cross-language smoke test for the `ptc_runner_mcp`
  Mix release.

  Drives the release binary from a **Python 3** subprocess (no
  Elixir, no MCP SDK — just the CPython standard library) over
  NDJSON-framed JSON-RPC stdio, to satisfy
  `Plans/ptc-runner-mcp-server.md` § 15 Phase 6:

      "Send one full round-trip from a non-Elixir language ... to
       prove the server is consumable from outside the BEAM."

  The Python driver is `test/integration/scripts/smoke.py` and is
  self-contained — operators can run it by hand. This ExUnit case
  shells out to it, asserts exit code 0, and surfaces its per-case
  output as the failure message when something regresses.

  Tagged `:integration` and `:cross_language`. Excluded from the
  default `mix test` run; opt in with `mix test --only integration`
  or `--only cross_language`.

  Pre-requisites (matches the rest of `:integration`):

    1. `MIX_ENV=prod mix release --overwrite` from `mcp_server/`.
    2. `python3` on `$PATH`.
  """

  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Test.ReleaseRunner

  @moduletag :integration
  @moduletag :cross_language
  @moduletag timeout: 60_000

  @smoke_script Path.expand("scripts/smoke.py", __DIR__)

  setup_all do
    cond do
      not ReleaseRunner.release_built?() ->
        flunk(
          "release artifact not built at #{ReleaseRunner.release_bin()}. " <>
            "Run `MIX_ENV=prod mix release --overwrite` from `mcp_server/` first."
        )

      not python3_available?() ->
        flunk("python3 not on $PATH — required for cross-language smoke test")

      not File.exists?(@smoke_script) ->
        flunk("smoke driver missing at #{@smoke_script}")

      true ->
        :ok
    end
  end

  test "Python 3 driver completes the full round-trip against the release" do
    {output, exit_code} =
      System.cmd("python3", [@smoke_script, ReleaseRunner.release_bin()],
        env: [{"RELEASE_DISTRIBUTION", "none"}],
        stderr_to_stdout: true
      )

    assert exit_code == 0,
           "Python smoke driver exited with #{exit_code}; output:\n#{output}"

    # Sanity-check the human-readable output contains "X/Y passed".
    assert output =~ ~r/\d+\/\d+ passed/,
           "missing summary line in driver output:\n#{output}"

    # Each named case must report PASS.
    refute output =~ "[FAIL]",
           "Python smoke driver reported a failure:\n#{output}"
  end

  defp python3_available? do
    case System.find_executable("python3") do
      nil -> false
      _ -> true
    end
  end
end
