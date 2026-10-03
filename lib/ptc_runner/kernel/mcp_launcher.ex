defmodule PtcRunner.Kernel.MCPLauncher do
  @moduledoc false

  @spec protocol_version() :: pos_integer()
  def protocol_version, do: 2

  @spec locale_environment() :: %{binary() => binary()}
  def locale_environment, do: %{"LC_ALL" => "C.UTF-8"}

  @spec companion() :: {:ok, binary()} | {:error, atom()}
  def companion do
    launcher = Module.concat(["PtcRunnerLauncher"])

    if Code.ensure_loaded?(launcher) and
         function_exported?(launcher, :protocol_version, 0) and
         function_exported?(launcher, :executable_path, 0) and
         launcher.protocol_version() == protocol_version() do
      case launcher.executable_path() do
        {:ok, path} -> {:ok, path}
        {:error, :unsupported_platform} -> {:error, :unsupported_mcp_stdio_platform}
        {:error, _reason} -> {:error, :mcp_stdio_launcher_unavailable}
      end
    else
      {:error, :mcp_stdio_launcher_unavailable}
    end
  end
end
