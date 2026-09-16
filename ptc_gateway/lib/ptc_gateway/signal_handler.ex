defmodule PtcGateway.SignalHandler do
  @moduledoc false
  @behaviour :gen_event

  @impl true
  def init({owner, reference}), do: {:ok, {owner, reference}}

  @impl true
  def handle_event(signal, {owner, reference} = state) do
    send(owner, {:gateway_signal, reference, signal})
    {:ok, state}
  end

  @impl true
  def handle_call(_request, state), do: {:ok, :ok, state}

  @impl true
  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  @impl true
  def code_change(_old_version, state, _extra), do: {:ok, state}
end
