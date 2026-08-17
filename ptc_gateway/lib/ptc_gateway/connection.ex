defmodule PtcGateway.Connection do
  @moduledoc false

  use GenServer

  alias PtcGateway.Admission
  alias PtcGateway.Protocol
  alias PtcGateway.RequestOwner

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    case build_state(opts) do
      {:ok, state} ->
        parent = self()
        reader = spawn_link(fn -> read_loop(parent, state.read) end)
        {:ok, Map.put(state, :reader, reader)}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_info({:line, line}, state) do
    {:noreply, handle_line(state, line)}
  end

  def handle_info(:eof, state) do
    {:stop, :normal, state}
  end

  def handle_info({:request_finished, owner, id, result}, state) do
    write_call_result(state, id, result)
    {:noreply, drop_owner(state, owner, id)}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    {:noreply, owner_exit(state, pid, reason)}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    {:noreply, owner_exit(state, pid, reason)}
  end

  defp read_loop(connection, read) do
    case read.() do
      :eof ->
        send(connection, :eof)

      {:ok, line} ->
        send(connection, {:line, line})
        read_loop(connection, read)
    end
  end

  defp build_state(opts) do
    tools = Keyword.get(opts, :tools, [])
    admission = Keyword.fetch!(opts, :admission)
    read = Keyword.get(opts, :read) || (&stdio_read/0)
    write = Keyword.get(opts, :write) || (&stdio_write/1)

    if is_pid(admission) and valid_tools?(tools) and is_function(read, 0) and
         is_function(write, 1) do
      {:ok,
       %{
         tools: Map.new(tools, &{&1.name, &1}),
         catalog: tools,
         admission: admission,
         read: read,
         write: write,
         owners: %{},
         ids: %{}
       }}
    else
      {:error, :invalid_gateway_config}
    end
  end

  defp handle_line(state, line) do
    case Protocol.decode_line(line) do
      {:ok, inbound} ->
        dispatch(state, inbound)

      {:error, kind} ->
        write_frame(state, Protocol.encode_rpc_error(nil, kind))
        state
    end
  end

  defp dispatch(state, {:notification, "notifications/cancelled", params}) do
    cancel(state, Map.get(params, "requestId"))
  end

  defp dispatch(state, {:notification, _method, _params}), do: state

  defp dispatch(state, {:request, id, "server/discover", _params}) do
    write_frame(state, Protocol.encode_result(id, Protocol.discover_result()))
    state
  end

  defp dispatch(state, {:request, id, "tools/list", _params}) do
    write_frame(state, Protocol.encode_result(id, Protocol.tools_list_result(state.catalog)))
    state
  end

  defp dispatch(state, {:request, id, "tools/call", params}) do
    call_tool(state, id, params)
  end

  defp dispatch(state, {:request, id, _method, _params}) do
    write_frame(state, Protocol.encode_rpc_error(id, :method_not_found))
    state
  end

  defp call_tool(state, id, params) do
    name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})

    cond do
      not is_binary(name) or not is_map(arguments) or is_struct(arguments) ->
        write_frame(state, Protocol.encode_rpc_error(id, :invalid_params))
        state

      not Map.has_key?(state.tools, name) ->
        write_frame(state, Protocol.encode_rpc_error(id, :unknown_tool))
        state

      true ->
        admit_call(state, id, Map.fetch!(state.tools, name), arguments)
    end
  end

  defp admit_call(state, id, tool, arguments) do
    owner = RequestOwner.start(self(), state.admission, id, tool, arguments)

    case Admission.checkout(state.admission, owner) do
      :ok ->
        send(owner, :go)

        %{
          state
          | owners: Map.put(state.owners, id, owner),
            ids: Map.put(state.ids, owner, id)
        }

      :saturated ->
        send(owner, :abort)
        write_frame(state, Protocol.encode_rpc_error(id, :admission))
        state
    end
  end

  defp cancel(state, id) do
    case Map.get(state.owners, id) do
      nil ->
        state

      owner ->
        Process.exit(owner, :kill)
        write_frame(state, Protocol.encode_call_error(id, :cancelled))
        drop_owner(state, owner, id)
    end
  end

  defp write_call_result(state, id, {:ok, value}) when is_map(value) do
    write_frame(state, Protocol.encode_call_success(id, value))
  end

  defp write_call_result(state, id, {:error, kind}) when is_atom(kind) do
    if PtcGateway.Errors.jsonrpc?(kind) do
      write_frame(state, Protocol.encode_rpc_error(id, kind))
    else
      write_frame(state, Protocol.encode_call_error(id, kind))
    end
  end

  defp write_call_result(state, id, _other) do
    write_frame(state, Protocol.encode_call_error(id, :execution))
  end

  defp owner_exit(state, pid, reason) do
    case Map.pop(state.ids, pid) do
      {nil, _ids} ->
        state

      {id, ids} ->
        unless reason in [:normal, :shutdown] do
          write_frame(state, Protocol.encode_call_error(id, :execution))
        end

        %{state | ids: ids, owners: Map.delete(state.owners, id)}
    end
  end

  defp drop_owner(state, owner, id) do
    owners =
      if is_integer(id),
        do: Map.delete(state.owners, id),
        else: state.owners

    %{state | owners: owners, ids: Map.delete(state.ids, owner)}
  end

  defp write_frame(state, frame), do: state.write.(frame)

  defp stdio_read do
    case IO.read(:stdio, :line) do
      :eof -> :eof
      {:error, _reason} -> :eof
      line when is_binary(line) -> {:ok, String.trim_trailing(line, "\n")}
    end
  end

  defp stdio_write(frame), do: IO.write(:stdio, frame)

  defp valid_tools?(tools) when is_list(tools) do
    names = Enum.map(tools, & &1.name)
    Enum.all?(tools, &valid_tool?/1) and names == Enum.uniq(names)
  end

  defp valid_tools?(_tools), do: false

  defp valid_tool?(tool) do
    is_map(tool) and is_binary(tool.name) and tool.name != "" and
      is_binary(tool.description) and is_map(tool.input_schema) and
      is_map(tool.output_schema) and is_map(tool.meta) and
      is_function(tool.call, 1)
  end
end
