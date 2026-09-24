defmodule PtcRunner.TestSupport.MCPStdioTransportHelpers do
  @moduledoc false

  @fixture Path.expand("mcp_stdio_fixture.exs", __DIR__)
  @root Path.expand("../..", __DIR__)
  @inherited_environment ~w(HOME LOGNAME PATH SHELL TERM USER)
  @fixture_start_timeout_ms 35_000

  def launch_options(tmp_dir, marker \\ nil, fixture_mode \\ "read", opts \\ []) do
    marker = marker || Path.join(tmp_dir, "unused")
    {:ok, launcher} = PtcRunnerLauncher.executable_path()
    executable = System.find_executable("elixir")

    [
      launcher: launcher,
      launcher_protocol_version: PtcRunnerLauncher.protocol_version(),
      executable: executable,
      executable_sha256: executable |> File.read!() |> then(&:crypto.hash(:sha256, &1)),
      cwd: @root,
      args: [@fixture, marker, fixture_mode],
      env: inherited_environment(),
      grace_ms: Keyword.get(opts, :grace_ms, 50),
      start_timeout_ms: @fixture_start_timeout_ms
    ]
    |> then(fn options ->
      case Keyword.get(opts, :stderr_bytes) do
        nil -> options
        bytes -> Keyword.put(options, :stderr_bytes, bytes)
      end
    end)
  end

  defp inherited_environment do
    @inherited_environment
    |> Enum.flat_map(fn name ->
      case System.get_env(name) do
        value when is_binary(value) -> [{name, value}]
        _missing -> []
      end
    end)
    |> Map.new()
  end
end
