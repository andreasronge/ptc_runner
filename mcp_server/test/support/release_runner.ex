defmodule PtcRunnerMcp.Test.ReleaseRunner do
  @moduledoc """
  Test helper that drives the built `ptc_runner_mcp` Mix release from
  ExUnit by piping a sequence of NDJSON-framed JSON-RPC frames into
  the binary's stdin and capturing the reply frames it writes to
  stdout.

  Used by the Phase 6 integration suite (`test/integration/`) to
  satisfy `Plans/ptc-runner-mcp-server.md` § 15 Phase 6's
  "live tests against MCP Inspector and at least one production MCP
  client" deliverable. Per § 7.4 D1, this also gates the
  unknown-tool deviation against a real production-style client.

  ## Why a temp-file + `System.cmd` wrapper instead of a `Port`

  Driving the release as a child Erlang `Port` from inside another
  BEAM (the test VM) does not terminate cleanly. When the release's
  stdio is bound to a parent-BEAM `Port`, child `System.stop(0)`
  never reaches OS-process exit, leaving the subprocess hanging.
  Production MCP clients (Inspector, Claude Desktop, Cursor, Cline)
  drive the release from a non-BEAM parent, where stdio is just a
  POSIX pipe.

  This driver replicates that posture by:

    1. Writing all input frames to a temp file.
    2. Spawning `/bin/sh -c '<bin> start < <stdin_file>
       > <stdout_file> 2> <stderr_file>'` via `System.cmd/3`.
    3. Reading the captured stdout / stderr files after the
       subprocess exits and decoding NDJSON reply frames.

  `System.cmd/3` waits via `wait4()` and reports a real exit status,
  and the release sees real OS file descriptors throughout. This is
  exactly the same shape as a Python or shell-script MCP client.

  ## Termination

  The release exits cleanly when its stdin reaches EOF (§ 6.4 row 1)
  OR when an `exit` notification frame arrives. Tests should append
  one of those to the frame list — the helper does not auto-append
  to keep "what's on the wire" explicit.
  """

  @release_bin Path.expand(
                 "../../_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp",
                 __DIR__
               )

  @doc "Absolute path to the built release binary."
  @spec release_bin() :: String.t()
  def release_bin, do: @release_bin

  @doc "True when the release artifact exists and is executable."
  @spec release_built?() :: boolean()
  def release_built? do
    File.exists?(@release_bin) and
      case File.stat(@release_bin) do
        {:ok, %File.Stat{mode: m}} -> Bitwise.band(m, 0o111) != 0
        _ -> false
      end
  end

  @doc """
  Pipe a sequence of frames through the release and collect the
  decoded reply frames it wrote to stdout.

  Options:

    * `:timeout_ms` — kill the subprocess if it does not exit within
      this many milliseconds. Default `15_000`.
    * `:env` — extra environment variables (list of `{name, value}`).
      The release itself forces `RELEASE_DISTRIBUTION=none`; this
      helper also passes it explicitly so older local release artifacts
      keep the same no-collision behavior.
    * `:args` — release-binary args (default `["start"]`).
    * `:bin` — override the release binary path (mostly for tests of
      this helper itself).

  Returns `{:ok, [reply_map], exit_status, raw_stderr}` where
  `exit_status` is the integer exit code or `:timeout`.
  """
  @spec run_session([map() | binary()], keyword()) ::
          {:ok, [map()], integer() | :timeout, binary()}
  def run_session(frames, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 15_000)
    args = Keyword.get(opts, :args, ["start"])
    extra_env = Keyword.get(opts, :env, [])
    bin = Keyword.get(opts, :bin, @release_bin)

    nonce = System.unique_integer([:positive])
    stdin_path = Path.join(System.tmp_dir!(), "mcp_runner_#{nonce}.stdin")
    stdout_path = Path.join(System.tmp_dir!(), "mcp_runner_#{nonce}.stdout")
    stderr_path = Path.join(System.tmp_dir!(), "mcp_runner_#{nonce}.stderr")

    File.write!(stdin_path, encode_frames(frames))

    cmd = build_shell_cmd(bin, args, stdin_path, stdout_path, stderr_path)

    env =
      [{"RELEASE_DISTRIBUTION", "none"} | extra_env]
      |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)

    {status, stdout, stderr} =
      run_with_timeout("/bin/sh", ["-c", cmd], env, timeout_ms,
        stdout_path: stdout_path,
        stderr_path: stderr_path
      )

    _ = File.rm(stdin_path)
    _ = File.rm(stdout_path)
    _ = File.rm(stderr_path)

    {:ok, decode_reply_lines(stdout), status, stderr}
  end

  defp encode_frames(frames) do
    frames
    |> Enum.map(fn
      m when is_map(m) -> Jason.encode!(m) <> "\n"
      b when is_binary(b) -> ensure_newline(b)
    end)
    |> IO.iodata_to_binary()
  end

  defp ensure_newline(b) do
    if String.ends_with?(b, "\n"), do: b, else: b <> "\n"
  end

  defp build_shell_cmd(bin, args, stdin_path, stdout_path, stderr_path) do
    quoted = Enum.map_join([bin | args], " ", &shell_quote/1)

    "exec " <>
      quoted <>
      " < " <>
      shell_quote(stdin_path) <>
      " > " <>
      shell_quote(stdout_path) <>
      " 2> " <>
      shell_quote(stderr_path)
  end

  defp shell_quote(arg) do
    if Regex.match?(~r{\A[A-Za-z0-9_\-./]+\z}, arg) do
      arg
    else
      "'" <> String.replace(arg, "'", "'\\''") <> "'"
    end
  end

  # Runs `System.cmd` in a Task so we can enforce `timeout_ms`. On
  # timeout, kills the OS process tree (best-effort) and returns
  # whatever we have.
  defp run_with_timeout(executable, args, env, timeout_ms, paths) do
    parent = self()

    task =
      Task.async(fn ->
        result = System.cmd(executable, args, env: env, stderr_to_stdout: false)
        send(parent, {:done, self()})
        result
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_stdout_inline, status}} ->
        {status, read_or_blank(paths[:stdout_path]), read_or_blank(paths[:stderr_path])}

      nil ->
        # Hit the timeout — best-effort kill of any leftover release
        # subprocess. The shell `exec`'s the release directly so the
        # only OS pid we'd need is the shell's, which Task.shutdown
        # has already SIGKILL'd. We additionally pkill by binary name
        # to catch grandchild beam.smp instances under concurrent runs.
        bin_basename = Path.basename(@release_bin)

        _ =
          System.cmd("/bin/sh", [
            "-c",
            "pkill -9 -f #{shell_quote(bin_basename)} 2>/dev/null; true"
          ])

        {:timeout, read_or_blank(paths[:stdout_path]), read_or_blank(paths[:stderr_path])}
    end
  end

  defp read_or_blank(nil), do: <<>>

  defp read_or_blank(path) do
    case File.read(path) do
      {:ok, b} -> b
      _ -> <<>>
    end
  end

  defp decode_reply_lines(stdout) do
    stdout
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"jsonrpc" => "2.0"} = m} -> [m]
        _ -> []
      end
    end)
  end

  # ----------------------------------------------------------------
  # Convenience helpers
  # ----------------------------------------------------------------

  @doc "Standard `initialize` request frame map for tests."
  @spec init_request(integer()) :: map()
  def init_request(id \\ 1) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "phase6a-integration", "version" => "1"}
      }
    }
  end

  @doc "Standard `notifications/initialized` notification frame."
  @spec initialized_notif() :: map()
  def initialized_notif do
    %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
  end

  @doc "Standard `tools/list` request frame."
  @spec tools_list_request(integer()) :: map()
  def tools_list_request(id \\ 2) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/list"}
  end

  @doc "Standard `tools/call` request frame."
  @spec tools_call_request(integer(), String.t(), map()) :: map()
  def tools_call_request(id, tool_name, arguments \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => tool_name, "arguments" => arguments}
    }
  end

  @doc "Standard `exit` notification frame."
  @spec exit_notif() :: map()
  def exit_notif, do: %{"jsonrpc" => "2.0", "method" => "exit"}
end
