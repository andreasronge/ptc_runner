defmodule PtcRunner.ReplLineEditor do
  @moduledoc false

  # Puts an interactive REPL loop under OTP's own line editor.
  #
  # Both frontends boot with `-noshell`, where `IO.gets/1` reads a
  # canonical-mode line: backspace works, and emacs keys, arrow keys, and
  # history arrive as raw bytes. `user_drv`/`group`/`edlin` — the editor `iex`
  # uses — is present in every VM but not installed. `shell.start_interactive/1`
  # installs it.
  #
  # It also takes a process to act as the shell, and the obvious reading of
  # that is to hand it the REPL loop. That reading is wrong here:
  # `PtcRunner.Kernel.ReplSession` is process-affine, so a loop evaluating from
  # a process other than the session's creator gets
  # `{:error, :session_owner_mismatch}`. Instead the shell is a parked
  # placeholder, and the calling process adopts the new group as its group
  # leader. Line editing follows the group, not the shell designation, so the
  # loop keeps running — and keeps owning its session, its `rescue`/`catch`,
  # and its teardown — exactly where it already did.
  #
  # The switch is one-way and VM-global: OTP has no counterpart that restores
  # the plain reader, a second call answers `{:error, :already_started}`, and
  # afterwards the previous `user` reader answers `{:error, :enotsup}` to a
  # line read. Installing it is therefore a terminal-ownership decision, taken
  # once, by an interactive REPL that owns the command's remaining lifetime.
  # Every other outcome leaves the plain reader in place.

  alias PtcRunner.Kernel.AnalysisTerminal

  @history_directory "ptc"
  @history_bytes 512 * 1024
  @history_log :"$#group_history"
  @install_timeout 5_000

  @typedoc "Session kind deciding whether submitted lines reach the disk."
  @type mode :: :direct | :manifest

  @doc """
  Runs `fun` with the interactive line editor installed where possible.

  Returns whatever `fun` returns, in the calling process. Falls back to the
  plain reader — unchanged behavior — without a terminal, when the editor is
  already installed, or when installation does not complete.
  """
  @spec run(mode(), (-> result)) :: result when result: term()
  def run(mode, fun) when mode in [:direct, :manifest] and is_function(fun, 0) do
    run(mode, banner(), fun)
  end

  @doc false
  @spec run(mode(), binary(), (-> result)) :: result when result: term()
  def run(mode, banner, fun)
      when mode in [:direct, :manifest] and is_binary(banner) and is_function(fun, 0) do
    if AnalysisTerminal.attached?() and reads_standard_io?(), do: install(mode)

    IO.puts(banner)

    try do
      fun.()
    after
      flush_history()
    end
  end

  @doc false
  @spec banner() :: binary()
  def banner, do: "PTC-Lisp REPL (:quit to exit; :help for commands)"

  # A manifest session can carry a private event policy and sensitive input, so
  # only the direct scratch-pad session persists submitted lines. Manifest
  # sessions line-edit with in-memory history alone.
  @doc false
  @spec persists_history?(mode()) :: boolean()
  def persists_history?(:direct), do: true
  def persists_history?(:manifest), do: false

  @doc false
  # Runs inside the freshly started group process, which is what makes
  # `self()` the group the caller must adopt. Its return value is the group's
  # shell, so it hands back a placeholder that only parks: `user_drv` restarts
  # a shell that terminates, and nothing else may read from this terminal.
  @spec start_placeholder_shell(pid()) :: pid()
  def start_placeholder_shell(caller) do
    send(caller, {__MODULE__, :group, self()})
    spawn(fn -> Process.sleep(:infinity) end)
  end

  # `AnalysisTerminal.attached?/0` answers for the OS descriptors, which stay
  # pointed at the developer's terminal even when this process reads from
  # somewhere else. `ExUnit.CaptureIO` is the case that matters: it swaps the
  # calling process's group leader for a capture server, and a test that
  # reached the installer would take over that terminal for the whole VM,
  # escape the capture, and write history from a test run.
  defp reads_standard_io?, do: Process.group_leader() == Process.whereis(:user)

  defp install(mode) do
    configure(mode)

    with :ok <- :shell.start_interactive({__MODULE__, :start_placeholder_shell, [self()]}),
         {:ok, group} <- await_group() do
      adopt(group)
    else
      _unavailable -> :ok
    end
  end

  defp await_group do
    receive do
      {__MODULE__, :group, group} -> {:ok, group}
    after
      @install_timeout -> :error
    end
  end

  defp adopt(group) do
    Process.group_leader(self(), group)

    # The new group is a fresh IO server carrying default options; without
    # this the loop reads charlists and every `String` call on a line fails.
    :io.setopts(:standard_io, binary: true, encoding: :unicode)
    :ok
  end

  # These are read when the reader starts, so they are set before the switch
  # and never mutated afterwards. An empty slogan suppresses the `Erlang/OTP
  # ...` banner that `user_drv` would otherwise print; the REPL's own banner is
  # printed by the process that also prompts, which keeps the two ordered.
  defp configure(mode) do
    Application.put_env(:stdlib, :shell_slogan, "")
    history(mode)
  end

  defp history(mode) do
    with true <- persists_history?(mode),
         {:ok, path} <- history_path() do
      Application.put_env(:kernel, :shell_history, :enabled)
      Application.put_env(:kernel, :shell_history_path, String.to_charlist(path))
      Application.put_env(:kernel, :shell_history_file_bytes, @history_bytes)
      :ok
    else
      _no_history -> Application.put_env(:kernel, :shell_history, :disabled)
    end
  end

  # OTP writes history through `disk_log`, which flushes its buffer when the VM
  # stops gracefully. Neither frontend stops gracefully: the Mix adapter exits
  # `{:shutdown, status}` so Mix can set an exit status, and the standalone CLI
  # halts on its own, and `System.halt/1` discards that buffer — every line
  # this session recalled would be missing from the next one. The log name is
  # OTP-internal, so a rename degrades to no persisted history rather than a
  # crash.
  defp flush_history do
    if @history_log in :disk_log.all(), do: :disk_log.sync(@history_log)
    :ok
  end

  # Owner-only, and PtcRunner-owned rather than the shared Erlang shell
  # history: the file holds REPL transcript lines.
  defp history_path do
    path = Path.join(:filename.basedir(:user_cache, @history_directory), "repl-history")

    case File.mkdir_p(path) do
      :ok ->
        _ = File.chmod(path, 0o700)
        {:ok, path}

      {:error, _reason} ->
        :error
    end
  end
end
