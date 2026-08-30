defmodule PtcRunner.CLIReferenceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The exit-status catalog in the CLI reference is the contract a CI author
  branches on. It is generated from `PtcRunner.Kernel.DiagnosticCatalog`, and
  this asserts the page the executable serves is exhaustive against that
  catalog rather than merely self-consistent with the last generator run.
  """

  alias PtcRunner.Kernel.CommandFrontend
  alias PtcRunner.Kernel.DiagnosticCatalog
  alias PtcRunner.Kernel.DocumentationLibrary

  test "the served CLI page lists every diagnostic against the status it exits with" do
    {:ok, page} = DocumentationLibrary.fetch("cli")

    for row <- DiagnosticCatalog.rows() do
      anchor = "| #{row.exit_status} | `#{row.phase}` | `#{row.code}` |"
      assert String.contains?(page, anchor), "missing row: #{anchor}"
    end
  end

  test "the served CLI page names the two statuses that are not catalog rows" do
    {:ok, page} = DocumentationLibrary.fetch("cli")

    assert page =~ "| 0 | the command succeeded |"
    assert page =~ "| #{CommandFrontend.envelope_failure_exit_status()} | "
  end

  test "the served CLI page distinguishes authorization diagnostics by frontend" do
    {:ok, page} = DocumentationLibrary.fetch("cli")

    assert page =~ """
           From shipped CLI input, `authorization_target_unknown` and
           `authorization_not_applicable` are reachable only through source-checkout
           `mix ptc run --authorize-mcp`; runtime-included `ptc` rejects that switch.
           """
  end

  test "the served MCP page uses the source-checkout authorization frontend" do
    {:ok, page} = DocumentationLibrary.fetch("mcp")

    assert page =~ """
           ```console
           mix ptc run ptc.json --host-config ptc-host.json \\
             --authorize-mcp workspace
           ```
           """
  end
end
