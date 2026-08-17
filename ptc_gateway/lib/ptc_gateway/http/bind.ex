defmodule PtcGateway.HTTP.Bind do
  @moduledoc false

  use GenServer

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec put(pid(), {binary(), pos_integer()}) :: :ok
  def put(pid, {host, port} = authority)
      when is_pid(pid) and is_binary(host) and is_integer(port) and port > 0 do
    GenServer.call(pid, {:put, authority})
  end

  @spec authority(pid()) :: {binary(), non_neg_integer()}
  def authority(pid) when is_pid(pid), do: GenServer.call(pid, :get)

  @impl GenServer
  def init(opts) do
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)

    if is_binary(host) and host != "" and is_integer(port) and port in 0..65_535 do
      {:ok, {host, port}}
    else
      {:stop, :invalid_gateway_config}
    end
  end

  @impl GenServer
  def handle_call({:put, {host, port} = authority}, _from, _state)
      when is_binary(host) and is_integer(port) and port > 0 do
    {:reply, :ok, authority}
  end

  def handle_call(:get, _from, state), do: {:reply, state, state}
end
