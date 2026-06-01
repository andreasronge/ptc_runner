defmodule PtcRunner.Upstream.Transport.McpStdio do
  @moduledoc false

  @behaviour PtcRunner.Upstream.Transport

  use GenServer

  alias PtcRunner.Upstream.Transport
  alias PtcRunner.Upstream.Transport.McpResult

  @default_timeout 5_000

  @spec start_link(String.t(), map()) :: GenServer.on_start()
  def start_link(name, config), do: Transport.start_trapped(__MODULE__, name, config)

  @impl PtcRunner.Upstream.Transport
  def list_tools(%{client_pid: pid}) when is_pid(pid),
    do: GenServer.call(pid, :list_tools, 30_000)

  @impl PtcRunner.Upstream.Transport
  def call(%{client_pid: pid}, tool_name, args, opts) when is_pid(pid) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_bytes = Keyword.get(opts, :max_response_bytes, 2 * 1024 * 1024)
    GenServer.call(pid, {:call_tool, tool_name, args, timeout, max_bytes}, timeout + 1_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout, "mcp_stdio call timed out"}
    :exit, _ -> {:error, :upstream_unavailable, "mcp_stdio client exited"}
  end

  @impl GenServer
  def init({name, config}) do
    Process.flag(:trap_exit, true)

    with {:ok, command} <- resolve_command(config.command),
         {:ok, port} <- open_port(command, config) do
      {:ok,
       %{
         name: name,
         config: config,
         port: port,
         next_id: 1,
         buffer: "",
         initialized?: false,
         tools: nil
       }}
    else
      {:error, detail} -> {:stop, {:upstream_unavailable, detail}}
    end
  end

  @impl GenServer
  def handle_call(:list_tools, _from, state) do
    case ensure_initialized(state) do
      {:ok, tools, state} -> {:reply, {:ok, tools}, state}
      {:error, reason, detail, state} -> {:reply, {:error, reason, detail}, state}
    end
  end

  def handle_call({:call_tool, tool_name, args, timeout, max_bytes}, _from, state) do
    with {:ok, _tools, state} <- ensure_initialized(state),
         {:ok, result, state} <-
           request(
             state,
             "tools/call",
             %{"name" => tool_name, "arguments" => args},
             timeout,
             max_bytes
           ) do
      {:reply, McpResult.normalize(result), state}
    else
      {:error, reason, detail, state} -> {:reply, {:error, reason, detail}, state}
    end
  end

  @impl GenServer
  def handle_info({_port, {:exit_status, status}}, state) do
    {:stop, {:upstream_unavailable, "mcp_stdio process exited with status #{status}"}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp ensure_initialized(%{initialized?: true, tools: tools} = state), do: {:ok, tools, state}

  defp ensure_initialized(state) do
    timeout = Map.get(state.config, :handshake_timeout_ms, 10_000)
    max_bytes = Map.get(state.config, :max_response_bytes, 2 * 1024 * 1024)

    with {:ok, _init, state} <-
           request(
             state,
             "initialize",
             %{
               "protocolVersion" => "2024-11-05",
               "capabilities" => %{},
               "clientInfo" => %{"name" => "ptc_runner", "version" => "0.x"}
             },
             timeout,
             max_bytes
           ),
         {:ok, state} <- notify(state, "notifications/initialized", %{}),
         {:ok, %{"tools" => tools}, state} <-
           request(state, "tools/list", %{}, timeout, max_bytes) do
      {:ok, tools, %{state | initialized?: true, tools: tools}}
    else
      {:ok, other, state} ->
        {:error, :upstream_error,
         "tools/list returned unexpected payload #{inspect(other, limit: 20)}", state}

      {:error, reason, detail, state} ->
        {:error, reason, detail, state}
    end
  end

  defp request(state, method, params, timeout, max_bytes) do
    id = state.next_id
    frame = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    case send_frame(state.port, frame) do
      :ok -> wait_for_response(%{state | next_id: id + 1}, id, deadline(timeout), max_bytes)
      {:error, detail} -> {:error, :upstream_unavailable, detail, state}
    end
  end

  defp notify(state, method, params) do
    frame = %{"jsonrpc" => "2.0", "method" => method, "params" => params}

    case send_frame(state.port, frame) do
      :ok -> {:ok, state}
      {:error, detail} -> {:error, :upstream_unavailable, detail, state}
    end
  end

  defp wait_for_response(state, id, deadline, max_bytes) do
    case pop_line(state.buffer) do
      {:ok, line, rest} ->
        state = %{state | buffer: rest}

        case decode_response(line, id, max_bytes) do
          {:ok, result} -> {:ok, result, state}
          :skip -> wait_for_response(state, id, deadline, max_bytes)
          {:error, reason, detail} -> {:error, reason, detail, state}
        end

      :more ->
        wait_for_chunk(state, id, deadline, max_bytes)
    end
  end

  defp wait_for_chunk(state, id, deadline, max_bytes) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout, "mcp_stdio request timed out", state}
    else
      receive do
        {port, {:data, data}} when port == state.port ->
          if byte_size(state.buffer) + byte_size(data) > max_bytes do
            {:error, :response_too_large, "mcp_stdio response exceeded #{max_bytes} bytes",
             %{state | buffer: ""}}
          else
            wait_for_response(%{state | buffer: state.buffer <> data}, id, deadline, max_bytes)
          end

        {port, {:exit_status, status}} when port == state.port ->
          {:error, :upstream_unavailable, "mcp_stdio process exited with status #{status}", state}
      after
        remaining ->
          {:error, :timeout, "mcp_stdio request timed out", state}
      end
    end
  end

  defp decode_response(line, id, max_bytes) do
    if byte_size(line) > max_bytes do
      {:error, :response_too_large, "mcp_stdio response exceeded #{max_bytes} bytes"}
    else
      case Jason.decode(line) do
        {:ok, %{"id" => ^id, "result" => result}} ->
          {:ok, result}

        {:ok, %{"id" => ^id, "error" => error}} ->
          {:error, :upstream_error, error_message(error)}

        {:ok, _other} ->
          :skip

        {:error, reason} ->
          {:error, :upstream_error, "invalid JSON-RPC response: #{inspect(reason)}"}
      end
    end
  end

  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(error), do: inspect(error, limit: 20, printable_limit: 200)

  defp send_frame(port, frame) do
    case Jason.encode(frame) do
      {:ok, encoded} ->
        Port.command(port, encoded <> "\n")
        :ok

      {:error, reason} ->
        {:error, "failed to encode JSON-RPC frame: #{inspect(reason)}"}
    end
  rescue
    ArgumentError -> {:error, "port closed"}
  end

  defp pop_line(buffer) do
    case :binary.match(buffer, "\n") do
      {pos, 1} ->
        <<line::binary-size(pos), _newline, rest::binary>> = buffer
        {:ok, line, rest}

      :nomatch ->
        :more
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp resolve_command(command) do
    cond do
      Path.type(command) == :absolute and File.exists?(command) -> {:ok, command}
      found = System.find_executable(command) -> {:ok, found}
      true -> {:error, "command not found: #{command}"}
    end
  end

  defp open_port(command, config) do
    opts =
      [
        :binary,
        :exit_status,
        :hide,
        args: Enum.map(Map.get(config, :args, []), &String.to_charlist/1)
      ]
      |> maybe_put_port_opt(:cd, Map.get(config, :cd))
      |> maybe_put_port_opt(:env, env_list(Map.get(config, :env, %{})))

    {:ok, Port.open({:spawn_executable, command}, opts)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp maybe_put_port_opt(opts, _key, nil), do: opts
  defp maybe_put_port_opt(opts, :env, []), do: opts
  defp maybe_put_port_opt(opts, key, value), do: [{key, value} | opts]

  defp env_list(env) do
    Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end
end
