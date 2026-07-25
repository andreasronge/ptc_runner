defmodule PtcRunnerLauncher.TestSupport.LauncherPort do
  @moduledoc """
  Test client for the versioned PtcRunner stdio launcher protocol.

  The reference launcher supports only macOS and Linux. It receives the target
  executable, arguments, working directory, and explicit environment over a
  packet-framed private channel; none are placed in a shell command or in the
  launcher's OS argument list. The bootstrap includes the caller's frozen
  executable SHA-256. The target is started only after the launcher opens the
  canonical executable, hashes it, and confirms that identity. It then starts
  a new session/process group with only the supplied environment. Linux hashes
  and executes the same held readable descriptor. macOS hashes a readable
  descriptor for the same file and executes the canonical host-installed path.
  The trusted operator must not modify executable contents during startup on
  either platform; macOS additionally requires its installation hierarchy to
  remain immutable. Linux script interpreters intentionally inherit the held
  executable descriptor because the kernel uses it for the interpreter
  handoff; native executables do not.

  Launcher output is framed as separate stdout and bounded-stderr events.
  At most one stdout frame is in flight; consuming it acknowledges the frame
  before the launcher reads more target output. A synchronous input write
  services and preserves up to one MiB of concurrent stdout so a full-duplex
  server can make progress. Input writes are acknowledged only after the
  target's stdin accepts the complete frame, providing bounded backpressure. A
  write timeout closes the launcher and discards undelivered queued input; the
  transport owner must not enqueue another write. Returning the timeout may
  include the launcher's bounded process-group cleanup interval.
  Closing stdin starts a bounded EOF, TERM, then KILL sequence for the target
  process group. `close/1` drains but deliberately discards output emitted
  after shutdown begins; request output must be consumed before closing.
  Losing the owning BEAM process closes the Port and triggers the same cleanup.
  POSIX process groups contain descendants that remain in the launched group;
  a deliberately trusted child can escape with `setpgid` or `setsid`. A killed
  group is only observably empty once every member has been reaped, so the
  launcher adopts orphaned descendants as a Linux child subreaper and collects
  them before reporting a clean shutdown. A host whose init does not reap
  orphans would otherwise turn every escalated teardown into
  `:termination_timeout`.
  MCP executables remain host-installed trusted dependencies rather than a
  hostile-code sandbox.

  Canonicalization and descriptor opening are separate POSIX operations.
  Operators must not mutate executable contents or the working-directory path
  hierarchy during startup on either platform. Linux executes the held object
  after it is opened; macOS executes the canonical path and therefore also
  requires its executable path hierarchy to stay immutable.

  This module is deliberately test-only. It exercises the packet protocol that
  the future core transport will consume without making that transport part of
  the native companion package.
  """

  @enforce_keys [:port, :owner, :close_timeout_ms]
  defstruct [:port, :owner, :close_timeout_ms]

  @type t :: %__MODULE__{port: port(), owner: pid(), close_timeout_ms: pos_integer()}
  @type finish_reason ::
          :server_exit
          | :close
          | :owner_eof
          | :launcher_signal
          | :protocol_error
          | :termination_timeout
  @type event ::
          {:stdout, binary()}
          | {:stderr, binary()}
          | :stderr_truncated
          | {:stdin_flushed, non_neg_integer()}
          | {:finished,
             %{
               reason: finish_reason(),
               exit_status: integer(),
               stderr_truncated?: boolean()
             }}
          | {:port_exit, non_neg_integer()}
          | :eof

  @max_frame_bytes 1_048_576
  @max_arguments 256
  @max_environment 256
  @max_config_string 131_072
  @default_grace_ms 250
  @default_stderr_bytes 65_536
  @default_start_timeout_ms 5_000
  @max_start_timeout_ms 60_000
  @default_send_timeout_ms 5_000
  @default_inherited_env_vars ~w(HOME LOGNAME PATH SHELL TERM USER)

  @spec open(keyword()) :: {:ok, t()} | {:error, atom()}
  def open(opts) when is_list(opts) do
    with :ok <- supported_platform(),
         {:ok, config} <- validate_options(opts),
         {:ok, launcher} <- launcher_path(),
         {:ok, payload} <- bootstrap(config) do
      open_started_launcher(launcher, payload, config)
    end
  end

  def open(_opts), do: {:error, :invalid_mcp_stdio_launch}

  @spec send_bytes(t(), binary()) ::
          :ok | {:error, :closed | :invalid_data | :not_owner | :timeout}
  def send_bytes(%__MODULE__{owner: owner}, _bytes) when owner != self(),
    do: {:error, :not_owner}

  def send_bytes(%__MODULE__{} = launcher, bytes),
    do: send_bytes(launcher, bytes, @default_send_timeout_ms)

  @spec send_bytes(t(), binary(), pos_integer()) ::
          :ok | {:error, :closed | :invalid_data | :invalid_timeout | :not_owner | :timeout}
  def send_bytes(%__MODULE__{owner: owner}, _bytes, _timeout_ms) when owner != self(),
    do: {:error, :not_owner}

  def send_bytes(
        %__MODULE__{port: port, close_timeout_ms: close_timeout_ms},
        bytes,
        timeout_ms
      )
      when is_binary(bytes) and byte_size(bytes) <= @max_frame_bytes - 9 and
             is_integer(timeout_ms) and timeout_ms > 0 do
    ack_id = System.unique_integer([:positive, :monotonic])
    deadline_ms = monotonic_ms() + timeout_ms
    payload = <<"D", ack_id::unsigned-big-64, bytes::binary>>

    result =
      with :ok <- command_until(port, payload, deadline_ms) do
        await_stdin_flushed(port, ack_id, deadline_ms)
      end

    case result do
      {:error, :timeout} = timeout ->
        close_and_flush_port(port, monotonic_ms() + close_timeout_ms)
        discard_buffered_events(port)
        timeout

      other ->
        other
    end
  rescue
    ArgumentError -> {:error, :closed}
  end

  def send_bytes(%__MODULE__{}, bytes, _timeout_ms) when not is_binary(bytes),
    do: {:error, :invalid_data}

  def send_bytes(%__MODULE__{}, bytes, _timeout_ms)
      when byte_size(bytes) > @max_frame_bytes - 9,
      do: {:error, :invalid_data}

  def send_bytes(%__MODULE__{}, _bytes, _timeout_ms), do: {:error, :invalid_timeout}

  @spec receive_event(t(), timeout()) :: {:ok, event()} | {:error, :not_owner | :timeout}
  def receive_event(%__MODULE__{owner: owner}, _timeout_ms) when owner != self(),
    do: {:error, :not_owner}

  def receive_event(%__MODULE__{port: port}, timeout_ms) do
    deadline_ms = operation_deadline(timeout_ms)

    case pop_buffered_event(port) do
      {:ok, event} -> {:ok, event}
      :empty -> receive_port_event(port, timeout_ms, deadline_ms)
    end
  end

  defp receive_port_event(port, timeout_ms, deadline_ms) do
    receive do
      {^port, {:data, <<"O", bytes::binary>>}} ->
        _ = acknowledge_stdout(port, deadline_ms)
        {:ok, {:stdout, bytes}}

      {^port, {:data, <<"E", bytes::binary>>}} ->
        {:ok, {:stderr, bytes}}

      {^port, {:data, "T"}} ->
        {:ok, :stderr_truncated}

      {^port, {:data, <<"A", ack_id::unsigned-big-64>>}} ->
        {:ok, {:stdin_flushed, ack_id}}

      {^port, {:data, <<"X", finish::binary-size(6)>>}} ->
        close_and_flush_port(port, deadline_ms)
        {:ok, decode_finish(finish)}

      {^port, {:exit_status, status}} when is_integer(status) and status >= 0 ->
        result = take_preserved_finish(port, {:port_exit, status})
        close_and_flush_port(port, deadline_ms)
        result

      {^port, :eof} ->
        result = take_preserved_finish(port, :eof)
        close_and_flush_port(port, deadline_ms)
        result
    after
      timeout_ms -> {:error, :timeout}
    end
  end

  @spec close(t()) :: {:ok, map()} | {:error, :closed | :not_owner | :timeout}
  def close(%__MODULE__{owner: owner}) when owner != self(), do: {:error, :not_owner}

  def close(%__MODULE__{close_timeout_ms: timeout_ms} = launcher),
    do: close(launcher, timeout_ms)

  @spec close(t(), pos_integer()) ::
          {:ok, map()} | {:error, :closed | :timeout | :invalid_timeout | :not_owner}
  def close(%__MODULE__{owner: owner}, _timeout_ms) when owner != self(),
    do: {:error, :not_owner}

  def close(%__MODULE__{} = launcher, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    deadline_ms = monotonic_ms() + timeout_ms

    case command_until(launcher.port, "C", deadline_ms) do
      :ok ->
        case await_finished(launcher, deadline_ms) do
          {:ok, _finish} = finished ->
            discard_buffered_events(launcher.port)
            finished

          {:error, _reason} = error ->
            close_and_flush_port(launcher.port, deadline_ms)
            discard_buffered_events(launcher.port)
            error
        end

      {:error, reason} ->
        close_and_flush_port(launcher.port, deadline_ms)
        discard_buffered_events(launcher.port)
        {:error, reason}
    end
  end

  def close(%__MODULE__{}, _timeout_ms), do: {:error, :invalid_timeout}

  defp supported_platform do
    case :os.type() do
      {:unix, platform} when platform in [:darwin, :linux] -> :ok
      _platform -> {:error, :unsupported_mcp_stdio_platform}
    end
  end

  defp validate_options(opts) do
    allowed = [
      :executable,
      :cwd,
      :args,
      :env,
      :inherit_environment,
      :grace_ms,
      :stderr_bytes,
      :start_timeout_ms,
      :executable_sha256
    ]

    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- keys -- allowed == [] and Enum.uniq(keys) == keys,
         executable when is_binary(executable) <- Keyword.get(opts, :executable),
         true <- valid_absolute_path?(executable),
         cwd when is_binary(cwd) <- Keyword.get(opts, :cwd),
         true <- valid_absolute_path?(cwd),
         args when is_list(args) and length(args) <= @max_arguments <-
           Keyword.get(opts, :args, []),
         true <- Enum.all?(args, &valid_string?/1),
         env when is_map(env) and not is_struct(env) and map_size(env) <= @max_environment <-
           Keyword.get(opts, :env, %{}),
         true <- valid_environment?(env),
         inherit_environment when is_boolean(inherit_environment) <-
           Keyword.get(opts, :inherit_environment, true),
         effective_env = effective_environment(env, inherit_environment),
         true <-
           map_size(effective_env) <= @max_environment and
             valid_environment?(effective_env),
         grace_ms when is_integer(grace_ms) and grace_ms in 1..5_000 <-
           Keyword.get(opts, :grace_ms, @default_grace_ms),
         stderr_bytes
         when is_integer(stderr_bytes) and stderr_bytes in 0..@max_frame_bytes <-
           Keyword.get(opts, :stderr_bytes, @default_stderr_bytes),
         start_timeout_ms
         when is_integer(start_timeout_ms) and start_timeout_ms in 1..@max_start_timeout_ms <-
           Keyword.get(opts, :start_timeout_ms, @default_start_timeout_ms),
         executable_sha256
         when is_binary(executable_sha256) and byte_size(executable_sha256) == 32 <-
           Keyword.get(opts, :executable_sha256) do
      {:ok,
       %{
         executable: executable,
         executable_sha256: executable_sha256,
         cwd: cwd,
         args: args,
         env: effective_env,
         grace_ms: grace_ms,
         stderr_bytes: stderr_bytes,
         start_timeout_ms: start_timeout_ms
       }}
    else
      _reason -> {:error, :invalid_mcp_stdio_launch}
    end
  end

  defp valid_absolute_path?(path),
    do: valid_string?(path) and Path.type(path) == :absolute

  defp valid_string?(value),
    do:
      is_binary(value) and byte_size(value) <= @max_config_string and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp valid_environment?(env) do
    Enum.all?(env, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        valid_string?(name) and name =~ ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/ and
          valid_string?(value)

      _binding ->
        false
    end)
  end

  defp effective_environment(explicit, false), do: explicit

  defp effective_environment(explicit, true) do
    inherited =
      @default_inherited_env_vars
      |> Map.new(fn name -> {name, System.get_env(name)} end)
      |> Map.reject(fn {_name, value} ->
        is_nil(value) or not valid_string?(value) or String.starts_with?(value, "()")
      end)

    Map.merge(inherited, explicit)
  end

  defp launcher_path, do: PtcRunnerLauncher.executable_path()

  defp bootstrap(config) do
    environment = Enum.sort_by(config.env, &elem(&1, 0))

    body = [
      <<1, config.grace_ms::unsigned-big-32, config.start_timeout_ms::unsigned-big-32,
        config.stderr_bytes::unsigned-big-64, config.executable_sha256::binary-size(32)>>,
      encode_string(config.executable),
      encode_string(config.cwd),
      <<length(config.args)::unsigned-big-32>>,
      Enum.map(config.args, &encode_string/1),
      <<length(environment)::unsigned-big-32>>,
      Enum.map(environment, fn {name, value} ->
        [encode_string(name), encode_string(value)]
      end)
    ]

    if IO.iodata_length(body) + 1 <= @max_frame_bytes do
      {:ok, IO.iodata_to_binary(["B", body])}
    else
      {:error, :invalid_mcp_stdio_launch}
    end
  end

  defp encode_string(value), do: [<<byte_size(value)::unsigned-big-32>>, value]

  defp open_port(launcher) do
    options = [
      :binary,
      {:packet, 4},
      :exit_status,
      :use_stdio,
      :hide,
      {:env, clear_environment()}
    ]

    {:ok, Port.open({:spawn_executable, String.to_charlist(launcher)}, options)}
  rescue
    ArgumentError -> {:error, :mcp_stdio_launcher_unavailable}
  end

  defp open_started_launcher(launcher, payload, config) do
    with {:ok, port} <- open_port(launcher) do
      deadline_ms = monotonic_ms() + config.start_timeout_ms

      case start_launcher(port, payload, deadline_ms) do
        :ok ->
          {:ok,
           %__MODULE__{
             port: port,
             owner: self(),
             close_timeout_ms: default_close_timeout_ms(config.grace_ms)
           }}

        {:error, _reason} = error ->
          close_and_flush_port(port, deadline_ms)
          normalize_start_error(error)
      end
    end
  end

  defp start_launcher(port, payload, deadline_ms) do
    case command_until(port, payload, deadline_ms) do
      :ok -> await_ready(port, deadline_ms)
      {:error, _reason} = error -> error
    end
  end

  defp normalize_start_error({:error, :closed}),
    do: {:error, :mcp_stdio_launcher_closed}

  defp normalize_start_error({:error, :timeout}),
    do: {:error, :mcp_stdio_spawn_timeout}

  defp normalize_start_error({:error, _reason} = error), do: error

  defp clear_environment do
    System.get_env()
    |> Map.keys()
    |> Enum.map(&{String.to_charlist(&1), false})
  end

  defp await_ready(port, deadline_ms) do
    remaining_ms = remaining_ms(deadline_ms)

    receive do
      {^port, {:data, "R"}} ->
        :ok

      {^port, {:data, <<"F", _details::binary>>}} ->
        {:error, :mcp_stdio_spawn_failed}

      {^port, {:exit_status, _status}} ->
        {:error, :mcp_stdio_spawn_failed}

      {^port, :eof} ->
        {:error, :mcp_stdio_spawn_failed}
    after
      remaining_ms ->
        {:error, :mcp_stdio_spawn_timeout}
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp command_until(port, data, deadline_ms) do
    case Port.command(port, data, [:nosuspend]) do
      true ->
        :ok

      false ->
        retry_port_command(port, data, deadline_ms)
    end
  rescue
    ArgumentError -> {:error, :closed}
  end

  defp retry_port_command(port, data, deadline_ms) do
    remaining_ms = remaining_ms(deadline_ms)

    cond do
      is_nil(Port.info(port)) ->
        {:error, :closed}

      remaining_ms == 0 ->
        {:error, :timeout}

      true ->
        receive do
        after
          min(remaining_ms, 1) -> command_until(port, data, deadline_ms)
        end
    end
  end

  defp await_stdin_flushed(port, ack_id, deadline_ms) do
    await_stdin_flushed(port, ack_id, deadline_ms, [], buffered_stdout_bytes(port))
  end

  defp await_stdin_flushed(port, ack_id, deadline_ms, events, stdout_bytes) do
    remaining_ms = remaining_ms(deadline_ms)

    receive do
      {^port, {:data, <<"A", ^ack_id::unsigned-big-64>>}} ->
        preserve_events(port, events)
        :ok

      {^port, {:data, <<"O", bytes::binary>>}} ->
        next_bytes = stdout_bytes + byte_size(bytes)

        if next_bytes <= @max_frame_bytes do
          case acknowledge_stdout(port, deadline_ms) do
            :ok ->
              await_stdin_flushed(
                port,
                ack_id,
                deadline_ms,
                [{:stdout, bytes} | events],
                next_bytes
              )

            {:error, :closed} ->
              preserve_events(port, [{:stdout, bytes} | events])
              {:error, :closed}
          end
        else
          close_and_flush_port(port, deadline_ms)
          preserve_events(port, events)
          {:error, :closed}
        end

      {^port, {:data, <<"E", bytes::binary>>}} ->
        await_stdin_flushed(port, ack_id, deadline_ms, [{:stderr, bytes} | events], stdout_bytes)

      {^port, {:data, "T"}} ->
        await_stdin_flushed(port, ack_id, deadline_ms, [:stderr_truncated | events], stdout_bytes)

      {^port, {:data, <<"X", finish::binary-size(6)>>}} ->
        close_and_flush_port(port, deadline_ms)
        preserve_events(port, [decode_finish(finish) | events])
        {:error, :closed}
    after
      min(remaining_ms, 1) ->
        cond do
          is_nil(Port.info(port)) ->
            preserve_events(port, events)
            {:error, :closed}

          remaining_ms == 0 ->
            preserve_events(port, events)
            {:error, :timeout}

          true ->
            await_stdin_flushed(port, ack_id, deadline_ms, events, stdout_bytes)
        end
    end
  end

  defp await_finished(launcher, deadline_ms) do
    remaining_ms = max(deadline_ms - monotonic_ms(), 0)

    case receive_event(launcher, remaining_ms) do
      {:ok, {:finished, finish}} -> {:ok, finish}
      {:ok, {:port_exit, _status}} -> {:error, :closed}
      {:ok, :eof} -> await_finished(launcher, deadline_ms)
      {:ok, _event} -> await_finished(launcher, deadline_ms)
      {:error, :timeout} -> {:error, :timeout}
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp remaining_ms(deadline_ms), do: max(deadline_ms - monotonic_ms(), 0)

  defp default_close_timeout_ms(grace_ms), do: grace_ms * 4 + 2_000

  defp acknowledge_stdout(port, deadline_ms) do
    case command_until(port, "K", deadline_ms) do
      :ok ->
        :ok

      {:error, :closed} = error ->
        error

      {:error, :timeout} ->
        close_and_flush_port(port, deadline_ms)
        {:error, :closed}
    end
  end

  defp close_and_flush_port(port, deadline_ms) do
    monitor = monitor_port(port)

    close_port(port)

    if monitor do
      drain_closed_port(port, monitor, deadline_ms)
    else
      flush_port_messages(port)
    end
  end

  defp monitor_port(port) do
    if Port.info(port), do: :erlang.monitor(:port, port)
  rescue
    ArgumentError -> nil
  end

  defp drain_closed_port(port, monitor, deadline_ms) do
    receive do
      {:DOWN, ^monitor, :port, ^port, _reason} ->
        flush_port_messages(port)

      {^port, _message} ->
        drain_closed_port(port, monitor, deadline_ms)
    after
      min(remaining_ms(deadline_ms), 100) ->
        if monitor, do: :erlang.demonitor(monitor, [:flush])
        flush_port_messages(port)
    end
  end

  defp flush_port_messages(port) do
    receive do
      {^port, _message} -> flush_port_messages(port)
    after
      0 -> :ok
    end
  end

  defp preserve_events(_port, []), do: :ok

  defp preserve_events(port, reversed_events) do
    events = Enum.reverse(reversed_events)
    key = event_buffer_key(port)
    existing = Process.get(key, %{events: [], bytes: 0})
    added_bytes = Enum.reduce(events, 0, &(&2 + stdout_event_bytes(&1)))

    Process.put(key, %{
      events: existing.events ++ events,
      bytes: existing.bytes + added_bytes
    })
  end

  defp pop_buffered_event(port) do
    key = event_buffer_key(port)

    case Process.get(key) do
      %{events: [event], bytes: _byte_count} ->
        Process.delete(key)
        {:ok, event}

      %{events: [event | rest], bytes: byte_count} ->
        Process.put(key, %{events: rest, bytes: byte_count - stdout_event_bytes(event)})
        {:ok, event}

      _empty ->
        :empty
    end
  end

  defp buffered_stdout_bytes(port),
    do: Process.get(event_buffer_key(port), %{bytes: 0}).bytes

  defp discard_buffered_events(port), do: Process.delete(event_buffer_key(port))

  defp stdout_event_bytes({:stdout, bytes}), do: byte_size(bytes)
  defp stdout_event_bytes(_event), do: 0

  defp event_buffer_key(port), do: {__MODULE__, :event_buffer, port}

  defp operation_deadline(:infinity), do: monotonic_ms() + @default_send_timeout_ms
  defp operation_deadline(timeout_ms), do: monotonic_ms() + timeout_ms

  defp take_preserved_finish(port, fallback) do
    receive do
      {^port, {:data, <<"X", finish::binary-size(6)>>}} ->
        {:ok, decode_finish(finish)}
    after
      0 -> {:ok, fallback}
    end
  end

  defp decode_finish(<<reason, exit_status::signed-big-32, stderr_truncated::unsigned-integer-8>>) do
    {:finished,
     %{
       reason: finish_reason(reason),
       exit_status: exit_status,
       stderr_truncated?: stderr_truncated == 1
     }}
  end

  defp finish_reason(0), do: :server_exit
  defp finish_reason(1), do: :close
  defp finish_reason(2), do: :owner_eof
  defp finish_reason(3), do: :launcher_signal
  defp finish_reason(4), do: :protocol_error
  defp finish_reason(5), do: :termination_timeout
  defp finish_reason(_unknown), do: :protocol_error
end
