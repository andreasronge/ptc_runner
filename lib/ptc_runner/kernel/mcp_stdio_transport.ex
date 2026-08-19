defmodule PtcRunner.Kernel.MCPStdioTransport do
  @moduledoc false

  use GenServer

  alias PtcRunner.Kernel.MCPProtocol
  alias PtcRunner.Kernel.ResourceRegistrar
  alias PtcRunner.Utf8

  @enforce_keys [:pid, :outcome]
  defstruct [:pid, :outcome]

  @type t :: %__MODULE__{pid: pid(), outcome: :atomics.atomics_ref()}

  @protocol_version 1
  @protocol_metadata %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}
  @max_frame_bytes 1_048_576
  @max_response_bytes 2_097_152
  @max_arguments 256
  @max_environment 256
  @stdio_locale_environment {"LC_ALL", "C.UTF-8"}
  @max_config_string 131_072
  @max_start_timeout_ms 60_000
  @max_request_timeout_ms 300_000
  @max_pending_requests 128
  @finish_drain_timeout_ms 100
  @default_grace_ms 250
  @default_stderr_bytes 65_536
  @default_start_timeout_ms 5_000
  @outcome_clean 1
  @outcome_failed 2
  @verified_cleanup_reasons [:server_exit, :owner_eof, :launcher_signal, :protocol_error]

  @spec start(keyword()) :: {:ok, t()} | {:error, atom()}
  def start(opts), do: start(opts, self())

  @doc false
  @spec start(keyword(), pid(), ResourceRegistrar.t() | nil) :: {:ok, t()} | {:error, atom()}
  def start(opts, owner, registrar \\ nil)

  def start(opts, owner, registrar) when is_list(opts) and is_pid(owner) do
    outcome = :atomics.new(1, signed: false)

    with {:ok, config} <- validate_options(opts) do
      case GenServer.start(__MODULE__, {owner, config, outcome, registrar}) do
        {:ok, pid} -> {:ok, %__MODULE__{pid: pid, outcome: outcome}}
        {:error, reason} when is_atom(reason) -> {:error, reason}
        {:error, _reason} -> {:error, :mcp_stdio_launcher_unavailable}
      end
    end
  end

  def start(_opts, _owner, _registrar), do: {:error, :invalid_mcp_stdio_launch}

  @doc false
  @spec validate_options(keyword()) :: {:ok, map()} | {:error, :invalid_mcp_stdio_launch}
  def validate_options(opts) when is_list(opts), do: validate_launch_options(opts)
  def validate_options(_opts), do: {:error, :invalid_mcp_stdio_launch}

  @doc false
  @spec request_ceilings() :: %{timeout_ms: pos_integer(), result_bytes: pos_integer()}
  def request_ceilings do
    %{timeout_ms: @max_request_timeout_ms, result_bytes: @max_response_bytes}
  end

  @spec request(t(), binary(), map(), map(), pos_integer(), pos_integer()) ::
          {:ok, map()}
          | {:error,
             :closed
             | :mcp_protocol_error
             | :mcp_response_exceeded
             | :mcp_timeout
             | :mcp_transport_busy
             | :mcp_transport_error}
  def request(
        %__MODULE__{pid: pid},
        method,
        params,
        metadata,
        max_bytes,
        timeout_ms
      ) do
    safe_call(pid, {:request, method, params, metadata, max_bytes, timeout_ms, false})
  end

  @doc false
  @spec request_exchange(t(), binary(), map(), map(), pos_integer(), pos_integer()) ::
          {:ok,
           %{request: map(), response: map(), stderr: binary(), stderr_truncated?: boolean()}}
          | {:error,
             :closed
             | :mcp_protocol_error
             | :mcp_response_exceeded
             | :mcp_timeout
             | :mcp_transport_busy
             | :mcp_transport_error}
  def request_exchange(
        %__MODULE__{pid: pid},
        method,
        params,
        metadata,
        max_bytes,
        timeout_ms
      ) do
    safe_call(pid, {:request, method, params, metadata, max_bytes, timeout_ms, true})
  end

  @spec close(t()) :: :ok | {:error, :mcp_transport_error}
  def close(%__MODULE__{pid: pid, outcome: outcome}) do
    ref = Process.monitor(pid)

    try do
      result = safe_call(pid, :close)

      down? =
        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> true
        after
          10_000 -> false
        end

      case {result, down?, :atomics.get(outcome, 1)} do
        {:ok, true, @outcome_clean} -> :ok
        {{:error, :closed}, true, @outcome_clean} -> :ok
        _failed -> {:error, :mcp_transport_error}
      end
    after
      Process.demonitor(ref, [:flush])
    end
  end

  @impl GenServer
  def init({owner, config, outcome, registrar}) do
    Process.flag(:trap_exit, true)
    owner_ref = Process.monitor(owner)

    with :ok <- ResourceRegistrar.register_root(registrar),
         :ok <- supported_platform(),
         {:ok, payload} <- bootstrap(config),
         {:ok, port} <- open_port(config.launcher),
         :ok <- start_launcher(port, payload, config.start_timeout_ms, owner_ref) do
      {:ok,
       %{
         port: port,
         owner_ref: owner_ref,
         next_id: 1,
         next_ack_id: 1,
         pending: %{},
         monitors: %{},
         writes: :queue.new(),
         controls: :queue.new(),
         writing: nil,
         retry_scheduled?: false,
         stdout: "",
         stderr: "",
         stderr_limit: config.stderr_bytes,
         stderr_truncated?: false,
         exchange_waiters: :queue.new(),
         unscoped_notification_bytes: 0,
         closing: nil,
         close_timeout_ms: config.grace_ms * 4 + 2_000,
         close_timer: nil,
         terminal_pending?: false,
         outcome: outcome
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(
        {:request, _method, _params, _metadata, _max_bytes, _timeout_ms, _exchange?},
        _from,
        %{terminal_pending?: true} = state
      ),
      do: {:reply, {:error, :mcp_transport_error}, state}

  def handle_call(
        {:request, _method, _params, _metadata, _max_bytes, _timeout_ms, _exchange?},
        _from,
        %{closing: closing} = state
      )
      when not is_nil(closing),
      do: {:reply, {:error, :closed}, state}

  def handle_call(
        {:request, method, params, metadata, max_bytes, timeout_ms, true},
        from,
        state
      ) do
    if exchange_in_flight?(state) do
      waiter = {from, method, params, metadata, max_bytes, timeout_ms}

      {:noreply, %{state | exchange_waiters: :queue.in(waiter, state.exchange_waiters)}}
    else
      dispatch_request(from, method, params, metadata, max_bytes, timeout_ms, true, state)
    end
  end

  def handle_call(
        {:request, _method, _params, _metadata, _max_bytes, _timeout_ms, _exchange?},
        _from,
        %{pending: pending} = state
      )
      when map_size(pending) >= @max_pending_requests,
      do: {:reply, {:error, :mcp_transport_busy}, state}

  def handle_call(
        {:request, method, params, metadata, max_bytes, timeout_ms, exchange?},
        from,
        state
      ) do
    dispatch_request(from, method, params, metadata, max_bytes, timeout_ms, exchange?, state)
  end

  def handle_call(:close, from, %{closing: waiters} = state) when is_list(waiters),
    do: {:noreply, %{state | closing: [from | waiters]}}

  def handle_call(:close, from, %{terminal_pending?: true, closing: nil} = state),
    do: {:noreply, %{state | closing: [from]}}

  def handle_call(:close, from, %{closing: nil} = state) do
    if unacknowledged_request?(state) do
      state
      |> fail_pending(:mcp_transport_error)
      |> discard_queued_writes()
      |> abort_transport([from])
    else
      state =
        state
        |> fail_pending(:mcp_transport_error)
        |> discard_queued_writes()
        |> Map.put(:closing, [from])
        |> enqueue_control("C")
        |> schedule_close_timeout()

      continue_after_flush(state)
    end
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :closed}, state}

  @impl GenServer
  def handle_cast(_request, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(
        {port, {:data, <<"X", finish::binary-size(6)>>}},
        %{port: port, terminal_pending?: true} = state
      ) do
    case decode_finish(finish) do
      {:ok, finish} -> finish_transport(state, finish)
      :error -> stop_transport(state)
    end
  end

  def handle_info({port, {:data, _discarded}}, %{port: port, terminal_pending?: true} = state),
    do: {:noreply, state}

  def handle_info(
        {port, {:data, <<"O", _discarded::binary>>}},
        %{port: port, closing: closing} = state
      )
      when is_list(closing) do
    state
    |> enqueue_control("K")
    |> continue_after_flush()
  end

  def handle_info({port, {:data, <<"O", bytes::binary>>}}, %{port: port} = state) do
    case consume_stdout(%{state | stdout: state.stdout <> bytes}) do
      {:ok, state} ->
        state
        |> enqueue_control("K")
        |> continue_after_flush()

      {:error, reason, state} ->
        stop_transport(state, reason)
    end
  end

  def handle_info({port, {:data, <<"A", ack_id::unsigned-big-64>>}}, %{port: port} = state) do
    case state.writing do
      %{ack_id: ^ack_id, request_id: request_id, timer: timer} ->
        Process.cancel_timer(timer)

        state
        |> mark_sent(request_id)
        |> Map.put(:writing, nil)
        |> continue_after_flush()

      _unexpected ->
        stop_transport(state)
    end
  end

  def handle_info({port, {:data, <<"E", bytes::binary>>}}, %{port: port} = state),
    do: {:noreply, append_stderr(state, bytes)}

  def handle_info({port, {:data, "T"}}, %{port: port} = state),
    do: {:noreply, %{state | stderr_truncated?: true}}

  def handle_info({port, {:data, <<"X", finish::binary-size(6)>>}}, %{port: port} = state) do
    case decode_finish(finish) do
      {:ok, finish} -> finish_transport(state, finish)
      :error -> stop_transport(state)
    end
  end

  def handle_info({port, {:data, _invalid}}, %{port: port} = state),
    do: stop_transport(state)

  def handle_info({port, {:exit_status, _status}}, %{port: port} = state),
    do: defer_terminal_failure(state)

  def handle_info({port, :eof}, %{port: port} = state), do: defer_terminal_failure(state)

  def handle_info({:EXIT, port, _reason}, %{port: port} = state),
    do: defer_terminal_failure(state)

  def handle_info(:terminal_without_finish, state), do: stop_transport(state)

  def handle_info({:request_timeout, id}, state) do
    case Map.fetch(state.pending, id) do
      {:ok, _pending} ->
        if writing_request?(state, id) do
          state
          |> reply_pending(id, {:error, :mcp_timeout})
          |> stop_transport()
        else
          state
          |> cancel_request(id, :mcp_timeout, true)
          |> continue_after_flush()
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:write_ack_timeout, ack_id}, %{writing: %{ack_id: ack_id}} = state),
    do: stop_transport(state)

  def handle_info({:write_ack_timeout, _ack_id}, state), do: {:noreply, state}

  def handle_info(:flush_writes, %{terminal_pending?: true} = state), do: {:noreply, state}

  def handle_info(:flush_writes, state),
    do: state |> Map.put(:retry_scheduled?, false) |> continue_after_flush()

  def handle_info(:close_timeout, state), do: stop_transport(state)

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{owner_ref: ref, terminal_pending?: true} = state
      ),
      do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    state =
      state
      |> fail_pending(:mcp_transport_error)

    if unacknowledged_request?(state) do
      state
      |> discard_queued_writes()
      |> abort_transport([])
    else
      state
      |> begin_owner_close()
      |> continue_after_flush()
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, ref) do
      {:ok, id} ->
        if writing_request?(state, id) do
          state
          |> drop_pending(id)
          |> stop_transport()
        else
          state
          |> cancel_request(id, :mcp_transport_error, false)
          |> continue_after_flush()
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  if {:format_status, 1} in GenServer.behaviour_info(:callbacks) do
    @impl GenServer
    def format_status(status), do: redact_status(status)
  else
    def format_status(status), do: redact_status(status)
  end

  @impl GenServer
  def format_status(_reason, _status), do: [data: [{~c"State", :redacted}]]

  @impl GenServer
  def terminate(_reason, state) do
    close_port(state.port)
    :ok
  end

  defp validate_launch_options(opts) do
    allowed = [
      :launcher,
      :launcher_protocol_version,
      :executable,
      :executable_sha256,
      :cwd,
      :args,
      :env,
      :grace_ms,
      :stderr_bytes,
      :start_timeout_ms
    ]

    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- keys -- allowed == [] and Enum.uniq(keys) == keys,
         launcher when is_binary(launcher) <- Keyword.get(opts, :launcher),
         true <- valid_absolute_path?(launcher),
         @protocol_version <- Keyword.get(opts, :launcher_protocol_version),
         executable when is_binary(executable) <- Keyword.get(opts, :executable),
         true <- valid_absolute_path?(executable),
         digest when is_binary(digest) and byte_size(digest) == 32 <-
           Keyword.get(opts, :executable_sha256),
         cwd when is_binary(cwd) <- Keyword.get(opts, :cwd),
         true <- valid_absolute_path?(cwd),
         args when is_list(args) and length(args) <= @max_arguments <-
           Keyword.get(opts, :args, []),
         true <- Enum.all?(args, &valid_string?/1),
         env when is_map(env) and not is_struct(env) <-
           Keyword.get(opts, :env, %{}),
         env =
           Map.put(env, elem(@stdio_locale_environment, 0), elem(@stdio_locale_environment, 1)),
         true <- map_size(env) <= @max_environment,
         true <- valid_environment?(env),
         grace_ms when is_integer(grace_ms) and grace_ms in 1..5_000 <-
           Keyword.get(opts, :grace_ms, @default_grace_ms),
         stderr_bytes when is_integer(stderr_bytes) and stderr_bytes in 0..@max_frame_bytes <-
           Keyword.get(opts, :stderr_bytes, @default_stderr_bytes),
         start_timeout_ms
         when is_integer(start_timeout_ms) and start_timeout_ms in 1..@max_start_timeout_ms <-
           Keyword.get(opts, :start_timeout_ms, @default_start_timeout_ms) do
      {:ok,
       %{
         launcher: launcher,
         executable: executable,
         executable_sha256: digest,
         cwd: cwd,
         args: args,
         env: env,
         grace_ms: grace_ms,
         stderr_bytes: stderr_bytes,
         start_timeout_ms: start_timeout_ms
       }}
    else
      _reason -> {:error, :invalid_mcp_stdio_launch}
    end
  end

  defp validate_request(method, params, metadata, max_bytes, timeout_ms) do
    if is_binary(method) and byte_size(method) in 1..256 and is_map(params) and
         not is_struct(params) and is_map(metadata) and not is_struct(metadata) and
         is_integer(max_bytes) and max_bytes in 1..@max_response_bytes and
         is_integer(timeout_ms) and timeout_ms in 1..@max_request_timeout_ms,
       do: :ok,
       else: {:error, :mcp_protocol_error}
  end

  defp supported_platform do
    case :os.type() do
      {:unix, platform} when platform in [:darwin, :linux] -> :ok
      _platform -> {:error, :unsupported_mcp_stdio_platform}
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

  defp bootstrap(config) do
    environment = Enum.sort_by(config.env, &elem(&1, 0))

    body = [
      <<@protocol_version, config.grace_ms::unsigned-big-32,
        config.start_timeout_ms::unsigned-big-32, config.stderr_bytes::unsigned-big-64,
        config.executable_sha256::binary-size(32)>>,
      encode_string(config.executable),
      encode_string(config.cwd),
      <<length(config.args)::unsigned-big-32>>,
      Enum.map(config.args, &encode_string/1),
      <<length(environment)::unsigned-big-32>>,
      Enum.map(environment, fn {name, value} ->
        [encode_string(name), encode_string(value)]
      end)
    ]

    if IO.iodata_length(body) + 1 <= @max_frame_bytes,
      do: {:ok, IO.iodata_to_binary(["B", body])},
      else: {:error, :invalid_mcp_stdio_launch}
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

  defp clear_environment do
    System.get_env()
    |> Map.keys()
    |> Enum.map(&{String.to_charlist(&1), false})
  end

  defp start_launcher(port, payload, timeout_ms, owner_ref) do
    deadline = monotonic_ms() + timeout_ms

    result =
      with :ok <- command_until(port, payload, deadline, owner_ref) do
        receive do
          {^port, {:data, "R"}} -> :ok
          {^port, {:data, <<"F", _details::binary>>}} -> {:error, :mcp_stdio_spawn_failed}
          {^port, {:exit_status, _status}} -> {:error, :mcp_stdio_spawn_failed}
          {^port, :eof} -> {:error, :mcp_stdio_spawn_failed}
          {:EXIT, ^port, _reason} -> {:error, :mcp_stdio_spawn_failed}
          {:DOWN, ^owner_ref, :process, _pid, _reason} -> {:error, :mcp_stdio_owner_down}
        after
          remaining_ms(deadline) -> {:error, :mcp_stdio_spawn_timeout}
        end
      end

    if match?({:error, _reason}, result), do: close_port(port)
    result
  end

  defp command_until(port, data, deadline, owner_ref) do
    case port_command(port, data) do
      :ok ->
        :ok

      :busy ->
        if remaining_ms(deadline) == 0 do
          {:error, :mcp_stdio_spawn_timeout}
        else
          receive do
            {:DOWN, ^owner_ref, :process, _pid, _reason} ->
              {:error, :mcp_stdio_owner_down}
          after
            1 -> command_until(port, data, deadline, owner_ref)
          end
        end

      :closed ->
        {:error, :mcp_stdio_launcher_unavailable}
    end
  end

  defp encode_request(id, method, params, metadata) do
    metadata = Map.put(metadata, "progressToken", id)
    request = MCPProtocol.request(id, method, params, metadata)

    with {:ok, encoded} <- Jason.encode(request),
         bytes = encoded <> "\n",
         true <- byte_size(bytes) <= @max_frame_bytes - 9 do
      {:ok, request, bytes}
    else
      _reason -> {:error, :mcp_protocol_error}
    end
  end

  defp encode_cancellation(id) do
    MCPProtocol.notification(
      "notifications/cancelled",
      %{"requestId" => id, "reason" => "request abandoned"},
      @protocol_metadata
    )
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp enqueue_write(state, request_id, bytes, timeout_ms) do
    ack_id = state.next_ack_id

    write = %{
      ack_id: ack_id,
      request_id: request_id,
      timeout_ms: timeout_ms,
      bytes: <<"D", ack_id::64, bytes::binary>>
    }

    %{state | next_ack_id: ack_id + 1, writes: :queue.in(write, state.writes)}
  end

  defp enqueue_control(state, bytes),
    do: %{state | controls: :queue.in(bytes, state.controls)}

  defp flush_writes(state) do
    case :queue.out(state.controls) do
      {{:value, bytes}, controls} ->
        case port_command(state.port, bytes) do
          :ok -> flush_writes(%{state | controls: controls})
          :busy -> {:ok, schedule_retry(state)}
          :closed -> {:error, state}
        end

      {:empty, _controls} when not is_nil(state.writing) ->
        {:ok, state}

      {:empty, _controls} ->
        flush_request_write(state)
    end
  end

  defp flush_request_write(state) do
    case :queue.out(state.writes) do
      {{:value, write}, writes} ->
        case port_command(state.port, write.bytes) do
          :ok ->
            timer =
              Process.send_after(
                self(),
                {:write_ack_timeout, write.ack_id},
                write.timeout_ms
              )

            state =
              state
              |> Map.put(:writes, writes)
              |> Map.put(
                :writing,
                write
                |> Map.take([:ack_id, :request_id])
                |> Map.put(:timer, timer)
              )

            {:ok, state}

          :busy ->
            {:ok, schedule_retry(state)}

          :closed ->
            {:error, state}
        end

      {:empty, _writes} ->
        {:ok, state}
    end
  end

  defp port_command(port, bytes) do
    case Port.command(port, bytes, [:nosuspend]) do
      true -> :ok
      false -> :busy
    end
  rescue
    ArgumentError -> :closed
  end

  defp schedule_retry(%{retry_scheduled?: true} = state), do: state

  defp schedule_retry(state) do
    Process.send_after(self(), :flush_writes, 1)
    %{state | retry_scheduled?: true}
  end

  defp mark_sent(state, nil), do: state

  defp mark_sent(state, id) do
    case Map.fetch(state.pending, id) do
      {:ok, pending} -> put_in(state, [:pending, id], %{pending | sent?: true})
      :error -> state
    end
  end

  defp consume_stdout(state) do
    case :binary.match(state.stdout, "\n") do
      {index, 1} ->
        line = binary_part(state.stdout, 0, index)
        rest = binary_part(state.stdout, index + 1, byte_size(state.stdout) - index - 1)

        line =
          if String.ends_with?(line, "\r"),
            do: binary_part(line, 0, byte_size(line) - 1),
            else: line

        if byte_size(line) <= @max_response_bytes do
          case consume_line(line, %{state | stdout: rest}) do
            {:ok, state} -> consume_stdout(state)
            {:error, reason, state} -> {:error, reason, state}
          end
        else
          {:error, :mcp_response_exceeded, state}
        end

      :nomatch ->
        if partial_stdout_within_limit?(state.stdout),
          do: {:ok, state},
          else: {:error, :mcp_response_exceeded, state}
    end
  end

  defp partial_stdout_within_limit?(stdout) do
    byte_size(stdout) <= @max_response_bytes or
      (byte_size(stdout) == @max_response_bytes + 1 and String.ends_with?(stdout, "\r"))
  end

  defp consume_line(line, state) do
    case MCPProtocol.decode_message(line) do
      {:ok, {:notification, notification}} ->
        charge_notification_bytes(state, notification, byte_size(line))

      {:ok, {:response, id, response}} ->
        consume_response(id, response, byte_size(line), state)

      {:error, :mcp_protocol_error} ->
        {:error, :mcp_protocol_error, state}
    end
  end

  defp consume_response(id, response, bytes, state) do
    case Map.fetch(state.pending, id) do
      {:ok, %{sent?: true} = pending} ->
        state = %{state | unscoped_notification_bytes: 0}

        {result, state} =
          cond do
            pending.response_bytes + bytes > pending.max_bytes ->
              {{:error, :mcp_response_exceeded}, state}

            pending.exchange? ->
              {stderr, truncated?, state} = drain_stderr(state)

              {{:ok,
                %{
                  request: pending.request,
                  response: response,
                  stderr: stderr,
                  stderr_truncated?: truncated?
                }}, state}

            true ->
              {{:ok, response}, state}
          end

        {:ok, reply_pending(state, id, result)}

      {:ok, %{sent?: false}} ->
        {:error, :mcp_protocol_error, state}

      :error ->
        if id < state.next_id,
          do: charge_unscoped_bytes(state, bytes),
          else: {:error, :mcp_protocol_error, state}
    end
  end

  defp charge_notification_bytes(state, notification, bytes) do
    case notification_request_id(notification, state.pending) do
      {:ok, id, pending} ->
        response_bytes = pending.response_bytes + bytes
        state = put_in(state, [:pending, id, :response_bytes], response_bytes)

        state =
          if response_bytes > pending.max_bytes,
            do: cancel_request(state, id, :mcp_response_exceeded, true),
            else: state

        {:ok, state}

      :unscoped ->
        charge_unscoped_bytes(state, bytes)
    end
  end

  defp charge_unscoped_bytes(state, frame_bytes) do
    bytes = state.unscoped_notification_bytes + frame_bytes

    if bytes <= @max_response_bytes,
      do: {:ok, %{state | unscoped_notification_bytes: bytes}},
      else: {:error, :mcp_response_exceeded, state}
  end

  defp notification_request_id(
         %{"params" => %{"progressToken" => id}},
         pending_requests
       )
       when is_integer(id) and id > 0 do
    case Map.fetch(pending_requests, id) do
      {:ok, %{sent?: true} = pending} -> {:ok, id, pending}
      _missing_or_unsent -> :unscoped
    end
  end

  defp notification_request_id(_notification, _pending), do: :unscoped

  defp cancel_request(state, id, reason, reply?) do
    case Map.fetch(state.pending, id) do
      {:ok, %{sent?: sent?, write_timeout_ms: write_timeout_ms}} ->
        state =
          if reply?, do: reply_pending(state, id, {:error, reason}), else: drop_pending(state, id)

        if sent? do
          state
          |> enqueue_write(nil, encode_cancellation(id), write_timeout_ms)
        else
          %{state | writes: reject_write(state.writes, id)}
        end

      :error ->
        state
    end
  end

  defp reject_write(writes, id) do
    writes
    |> :queue.to_list()
    |> Enum.reject(&(&1.request_id == id))
    |> :queue.from_list()
  end

  defp writing_request?(%{writing: %{request_id: id}}, id) when is_integer(id), do: true
  defp writing_request?(_state, _id), do: false

  defp unacknowledged_request?(%{writing: %{request_id: id}}) when is_integer(id), do: true
  defp unacknowledged_request?(_state), do: false

  defp reply_pending(state, id, result) do
    case pop_pending(state, id) do
      {nil, state} ->
        state

      {%{exchange?: true} = pending, state} ->
        GenServer.reply(pending.from, result)
        start_next_exchange(state)

      {pending, state} ->
        GenServer.reply(pending.from, result)
        state
    end
  end

  defp complete_pending(state, id, result) do
    case pop_pending(state, id) do
      {nil, state} ->
        state

      {pending, state} ->
        GenServer.reply(pending.from, result)
        state
    end
  end

  defp drop_pending(state, id) do
    case pop_pending(state, id) do
      {nil, state} -> state
      {%{exchange?: true}, state} -> start_next_exchange(state)
      {_pending, state} -> state
    end
  end

  defp pop_pending(state, id) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {nil, state}

      {pending, remaining} ->
        Process.cancel_timer(pending.timer)
        Process.demonitor(pending.monitor, [:flush])

        {pending,
         %{
           state
           | pending: remaining,
             monitors: Map.delete(state.monitors, pending.monitor)
         }}
    end
  end

  defp fail_pending(state, reason) do
    state = fail_exchange_waiters(state, reason)

    Enum.reduce(Map.keys(state.pending), state, fn id, state ->
      complete_pending(state, id, {:error, reason})
    end)
  end

  defp discard_queued_writes(state), do: %{state | writes: :queue.new()}

  defp begin_owner_close(%{closing: nil} = state) do
    state
    |> discard_queued_writes()
    |> Map.put(:closing, [])
    |> enqueue_control("C")
    |> schedule_close_timeout()
  end

  defp begin_owner_close(state), do: state

  defp schedule_close_timeout(%{close_timer: nil} = state) do
    timer = Process.send_after(self(), :close_timeout, state.close_timeout_ms)
    %{state | close_timer: timer}
  end

  defp schedule_close_timeout(state), do: state

  defp continue_after_flush(state) do
    case flush_writes(state) do
      {:ok, state} -> {:noreply, state}
      {:error, state} -> stop_transport(state)
    end
  end

  defp defer_terminal_failure(%{terminal_pending?: true} = state), do: {:noreply, state}

  defp defer_terminal_failure(state) do
    Process.send_after(self(), :terminal_without_finish, @finish_drain_timeout_ms)

    state =
      state
      |> fail_pending(:mcp_transport_error)
      |> discard_queued_writes()
      |> Map.put(:controls, :queue.new())
      |> Map.put(:writing, nil)
      |> Map.put(:terminal_pending?, true)

    {:noreply, state}
  end

  defp abort_transport(state, close_waiters) do
    reply_close_waiters(close_waiters, {:error, :mcp_transport_error})
    record_outcome(state.outcome, @outcome_failed)
    close_port(state.port)
    {:stop, :normal, state}
  end

  defp finish_transport(%{closing: waiters} = state, %{reason: :close})
       when is_list(waiters) do
    reply_close_waiters(waiters, :ok)
    record_outcome(state.outcome, @outcome_clean)
    {:stop, :normal, state}
  end

  defp finish_transport(state, %{reason: reason}) when reason in @verified_cleanup_reasons do
    state = fail_pending(state, :mcp_transport_error)

    if is_list(state.closing), do: reply_close_waiters(state.closing, :ok)

    record_outcome(state.outcome, @outcome_clean)
    close_port(state.port)
    {:stop, :normal, state}
  end

  defp finish_transport(state, _finish), do: stop_transport(state)

  defp stop_transport(state, reason \\ :mcp_transport_error) do
    state = fail_pending(state, reason)
    record_outcome(state.outcome, @outcome_failed)

    if is_list(state.closing),
      do: reply_close_waiters(state.closing, {:error, :mcp_transport_error})

    close_port(state.port)
    {:stop, :normal, state}
  end

  defp reply_close_waiters(waiters, result),
    do: Enum.each(waiters, &GenServer.reply(&1, result))

  defp decode_finish(<<reason, exit_status::signed-big-32, stderr_truncated::unsigned-integer-8>>)
       when reason in 0..5 and stderr_truncated in 0..1 do
    reasons = [
      :server_exit,
      :close,
      :owner_eof,
      :launcher_signal,
      :protocol_error,
      :termination_timeout
    ]

    {:ok,
     %{
       reason: Enum.at(reasons, reason),
       exit_status: exit_status,
       stderr_truncated?: stderr_truncated == 1
     }}
  end

  defp decode_finish(_finish), do: :error

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp record_outcome(outcome, value) do
    :atomics.put(outcome, 1, value)
    :ok
  end

  defp safe_call(pid, request) do
    GenServer.call(pid, request, :infinity)
  catch
    :exit, _reason -> {:error, :closed}
  end

  defp append_stderr(%{stderr_limit: limit} = state, _bytes) when limit <= 0, do: state

  defp append_stderr(state, bytes) when is_binary(bytes) do
    taken = byte_size(state.stderr)
    remaining = state.stderr_limit - taken

    cond do
      remaining <= 0 ->
        %{state | stderr_truncated?: true}

      byte_size(bytes) <= remaining ->
        %{state | stderr: state.stderr <> bytes}

      true ->
        %{
          state
          | stderr: state.stderr <> binary_part(bytes, 0, remaining),
            stderr_truncated?: true
        }
    end
  end

  defp drain_stderr(%{stderr_truncated?: true} = state) do
    text = Utf8.truncate_valid(state.stderr, state.stderr_limit)

    {text, true, %{state | stderr: "", stderr_truncated?: false}}
  end

  defp drain_stderr(state) do
    text = Utf8.truncate_valid(state.stderr, state.stderr_limit)
    rest = binary_part(state.stderr, byte_size(text), byte_size(state.stderr) - byte_size(text))

    {text, false, %{state | stderr: rest, stderr_truncated?: false}}
  end

  defp dispatch_request(from, method, params, metadata, max_bytes, timeout_ms, exchange?, state) do
    case begin_request(from, method, params, metadata, max_bytes, timeout_ms, exchange?, state) do
      {:ok, state} -> continue_after_flush(state)
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  defp begin_request(from, method, params, metadata, max_bytes, timeout_ms, exchange?, state) do
    with :ok <- validate_request(method, params, metadata, max_bytes, timeout_ms),
         {:ok, request, bytes} <- encode_request(state.next_id, method, params, metadata) do
      id = state.next_id
      {caller, _tag} = from
      monitor = Process.monitor(caller)
      timer = Process.send_after(self(), {:request_timeout, id}, timeout_ms)

      pending = %{
        from: from,
        caller: caller,
        monitor: monitor,
        timer: timer,
        max_bytes: max_bytes,
        response_bytes: 0,
        write_timeout_ms: timeout_ms,
        exchange?: exchange?,
        request: if(exchange?, do: request),
        sent?: false
      }

      {:ok,
       state
       |> Map.put(:next_id, id + 1)
       |> put_in([:pending, id], pending)
       |> put_in([:monitors, monitor], id)
       |> enqueue_write(id, bytes, timeout_ms)}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp exchange_in_flight?(state) do
    Enum.any?(state.pending, fn {_id, pending} -> pending.exchange? end)
  end

  defp start_next_exchange(state) do
    case :queue.out(state.exchange_waiters) do
      {{:value, {from, method, params, metadata, max_bytes, timeout_ms}}, waiters} ->
        state = %{state | exchange_waiters: waiters}

        case begin_request(
               from,
               method,
               params,
               metadata,
               max_bytes,
               timeout_ms,
               true,
               state
             ) do
          {:ok, state} ->
            state

          {:error, reason, state} ->
            GenServer.reply(from, {:error, reason})
            start_next_exchange(state)
        end

      {:empty, _waiters} ->
        state
    end
  end

  defp fail_exchange_waiters(state, reason) do
    Enum.each(:queue.to_list(state.exchange_waiters), fn {from, _method, _params, _metadata,
                                                          _max_bytes, _timeout_ms} ->
      GenServer.reply(from, {:error, reason})
    end)

    %{state | exchange_waiters: :queue.new()}
  end

  defp redact_status(status) do
    Map.new(status, fn
      {key, _value} when key in [:state, :message, :reason] -> {key, :redacted}
      {:log, _value} -> {:log, []}
      key_value -> key_value
    end)
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
  defp remaining_ms(deadline), do: max(deadline - monotonic_ms(), 0)
end
