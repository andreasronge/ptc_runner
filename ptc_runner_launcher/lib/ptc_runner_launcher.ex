defmodule PtcRunnerLauncher do
  @moduledoc """
  Locates the native launcher being prepared for PtcRunner's MCP stdio
  transport.

  The package owns the native process boundary and its artifact locator.
  Supported release targets restore a mandatory-checksum precompiled
  executable; other macOS and Linux targets compile the included source. The
  core `ptc_runner` package will own MCP framing, request correlation,
  deadlines, and transport supervision when stdio integration lands.
  """

  @protocol_version 1
  @executable_name "ptc_runner_launcher"

  @doc """
  Returns the packet protocol version implemented by the bundled launcher.
  """
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

  @doc """
  Returns the absolute path of the bundled launcher executable.

  Unsupported operating systems fail before a target process can be spawned.
  A missing or non-executable artifact is reported as unavailable rather than
  returned to the caller.
  """
  @spec executable_path() ::
          {:ok, binary()}
          | {:error, :launcher_unavailable | :unsupported_platform}
  def executable_path do
    with :ok <- supported_platform(),
         priv_dir when is_list(priv_dir) <- :code.priv_dir(:ptc_runner_launcher),
         path = Path.join(List.to_string(priv_dir), @executable_name),
         {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular and executable?(stat.mode) do
      {:ok, path}
    else
      {:error, :unsupported_platform} = error -> error
      _reason -> {:error, :launcher_unavailable}
    end
  end

  defp supported_platform do
    case :os.type() do
      {:unix, platform} when platform in [:darwin, :linux] -> :ok
      _platform -> {:error, :unsupported_platform}
    end
  end

  defp executable?(mode), do: Bitwise.band(mode, 0o111) != 0
end
