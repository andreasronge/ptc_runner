defmodule PtcGateway.HTTP.Secret do
  @moduledoc false

  use GenServer

  alias PtcGateway.HTTP.Auth

  def child_spec(_arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      type: :worker,
      restart: :temporary,
      significant: true
    }
  end

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :pending)
  end

  @spec install(pid(), binary()) :: :ok | {:error, atom()}
  def install(pid, token) when is_pid(pid) and is_binary(token) and token != "" do
    GenServer.call(pid, {:install, token})
  end

  def install(_pid, _token), do: {:error, :invalid_gateway_config}

  @spec matches?(pid(), binary()) :: boolean()
  def matches?(pid, presented) when is_pid(pid) and is_binary(presented) do
    GenServer.call(pid, {:matches?, presented})
  end

  def matches?(_pid, _presented), do: false

  @impl GenServer
  def init(:pending), do: {:ok, :pending}

  @impl GenServer
  def handle_call({:install, token}, _from, :pending)
      when is_binary(token) and token != "" do
    {:reply, :ok, token}
  end

  def handle_call({:install, _token}, _from, state),
    do: {:reply, {:error, :already_installed}, state}

  def handle_call({:matches?, presented}, _from, token) when is_binary(token) do
    {:reply, Auth.matches?(presented, token), token}
  end

  def handle_call({:matches?, _presented}, _from, :pending) do
    {:reply, false, :pending}
  end

  if {:format_status, 1} in GenServer.behaviour_info(:callbacks) do
    @impl GenServer
    def format_status(status), do: redact_status(status)
  else
    def format_status(status), do: redact_status(status)
  end

  @impl GenServer
  def format_status(_reason, _status), do: [data: [{~c"State", :redacted}]]

  defp redact_status(status) do
    Map.new(status, fn
      {key, _value} when key in [:state, :message, :reason] -> {key, :redacted}
      {:log, _value} -> {:log, []}
      key_value -> key_value
    end)
  end
end
