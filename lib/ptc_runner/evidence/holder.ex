defmodule PtcRunner.Evidence.Holder do
  @moduledoc """
  Host-side owner for one normalized evidence bundle.
  """

  use GenServer

  alias PtcRunner.Evidence.Bundle

  @spec start(Bundle.t(), keyword()) :: {:ok, pid()}
  def start(%Bundle{} = bundle, opts \\ []) do
    GenServer.start(__MODULE__, {bundle, Keyword.get(opts, :owner, self())})
  end

  @spec stop(pid()) :: :ok
  def stop(holder) when is_pid(holder) do
    GenServer.stop(holder, :normal)
    :ok
  end

  @spec query(pid(), (Bundle.t() -> term()), timeout()) :: term()
  def query(holder, fun, timeout \\ 5_000) when is_function(fun, 1) do
    case GenServer.call(holder, {:query, fun}, timeout) do
      {:ok, result} -> result
      {:error, exception, stacktrace} -> reraise(exception, stacktrace)
    end
  end

  @impl true
  def init({bundle, owner}) do
    if is_pid(owner), do: Process.monitor(owner)
    {:ok, bundle}
  end

  @impl true
  def handle_call({:query, fun}, _from, bundle) do
    reply =
      try do
        {:ok, fun.(bundle)}
      rescue
        exception -> {:error, exception, __STACKTRACE__}
      end

    {:reply, reply, bundle}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _owner, _reason}, bundle) do
    {:stop, :normal, bundle}
  end
end
