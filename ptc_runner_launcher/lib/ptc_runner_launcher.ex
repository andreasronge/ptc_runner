defmodule PtcRunnerLauncher do
  @moduledoc """
  Locates PtcRunner's native POSIX platform helper.

  The package owns the native process boundary and its artifact locator.
  Supported release targets restore a mandatory-checksum precompiled
  executable; other macOS and Linux targets compile the included source. The
  core `ptc_runner` package owns MCP framing, request correlation, deadlines,
  transport supervision, and initialization state.
  """

  @protocol_version 1
  @executable_name "ptc_runner_launcher"
  @publish_timeout_ms 10_000

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

  @doc """
  Atomically publishes one directory without replacing the target.

  Linux uses `renameat2(RENAME_NOREPLACE)` and macOS uses
  `renamex_np(RENAME_EXCL)`. Unsupported filesystems and cross-device targets
  fail without falling back to a check-then-rename sequence. If the launcher
  does not report its exit status before the deadline, returns
  `:publication_status_unknown`; callers must verify the staged directory's
  identity at the target before deciding whether publication committed.
  """
  @spec publish_directory_noreplace(binary(), binary()) ::
          :ok
          | {:error,
             :collision
             | :publication_failed
             | :publication_status_unknown
             | :launcher_unavailable
             | :unsupported_platform}
  def publish_directory_noreplace(staging, target)
      when is_binary(staging) and is_binary(target) do
    with true <- Path.type(staging) == :absolute and Path.type(target) == :absolute,
         {:ok, executable} <- executable_path() do
      case PtcRunnerLauncher.Command.run(
             executable,
             ["--publish-directory-noreplace", staging, target],
             @publish_timeout_ms
           ) do
        {:ok, {"", 0}} -> :ok
        {:ok, {_output, 73}} -> {:error, :collision}
        {:ok, {_output, 74}} -> {:error, :unsupported_platform}
        {:ok, {_output, _status}} -> {:error, :publication_failed}
        {:error, _reason} -> {:error, :publication_status_unknown}
      end
    else
      false -> {:error, :publication_failed}
      {:error, _reason} = error -> error
    end
  rescue
    _exception -> {:error, :publication_failed}
  catch
    _kind, _reason -> {:error, :publication_failed}
  end

  def publish_directory_noreplace(_staging, _target),
    do: {:error, :publication_failed}

  defp supported_platform do
    case :os.type() do
      {:unix, platform} when platform in [:darwin, :linux] -> :ok
      _platform -> {:error, :unsupported_platform}
    end
  end

  defp executable?(mode), do: Bitwise.band(mode, 0o111) != 0
end
