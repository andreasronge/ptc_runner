defmodule PtcRunner.TestSupport.PtcFsMCP do
  @moduledoc """
  Hermetic install of the pinned `ptc-fs-mcp` package for tests that spawn
  with `inherit_environment: false`.
  """

  @package "ptc-fs-mcp@0.1.0"

  @doc """
  Installs `#{@package}` under `dir` and returns the absolute `dist/cli.js`.

  The package bin begins `#!/usr/bin/env node`, so a scrubbed environment
  cannot start it. Tests must run absolute `node` against this script.
  """
  @spec install!(Path.t()) :: Path.t()
  def install!(dir) when is_binary(dir) do
    {output, 0} =
      System.cmd("npm", ["install", "--no-save", @package],
        cd: dir,
        stderr_to_stdout: true
      )

    {resolved, 0} =
      System.cmd("node", ["-p", "require.resolve('ptc-fs-mcp/package.json')"],
        cd: dir,
        stderr_to_stdout: true
      )

    cli = resolved |> String.trim() |> Path.dirname() |> Path.join("dist/cli.js")

    File.exists?(cli) || raise "ptc-fs-mcp CLI missing after install: #{output}"
    cli
  end
end
