defmodule PtcRunner.Kernel.MCPSettlement do
  @moduledoc false

  alias PtcRunner.Kernel.MCPBorrowToken
  alias PtcRunner.Kernel.ServingEvents

  def new, do: %{entries: %{}, waiters: %{}}

  def sealed?(token), do: MCPBorrowToken.sealed?(token)

  def admit(ledger, id, token), do: put_in(ledger.entries[id], MCPBorrowToken.id(token))

  def release(ledger, id) do
    ledger = %{ledger | entries: Map.delete(ledger.entries, id)}

    Enum.reduce(ledger.waiters, ledger, fn {ref, {token, from, timer}}, acc ->
      if empty_id?(acc, token) do
        Process.cancel_timer(timer)
        GenServer.reply(from, :ok)
        %{acc | waiters: Map.delete(acc.waiters, ref)}
      else
        acc
      end
    end)
  end

  def seal(ledger, token) do
    :ok = MCPBorrowToken.seal(token)
    ledger
  end

  def seal_reply(state, token),
    do: {:reply, :ok, %{state | settlement: seal(state.settlement, token)}}

  def await_reply(state, token, deadline, from) do
    case await(state.settlement, token, deadline, from) do
      {:reply, result, ledger} ->
        if result != :ok,
          do: ServingEvents.counter(state.events, :settlement_timeout)

        {:reply, result, %{state | settlement: ledger}}

      {:noreply, ledger} ->
        {:noreply, %{state | settlement: ledger}}
    end
  end

  def await(ledger, token, deadline, from) do
    cond do
      empty?(ledger, token) ->
        {:reply, :ok, ledger}

      deadline <= System.monotonic_time(:millisecond) ->
        {:reply, {:error, :provider_cleanup_failed}, ledger}

      true ->
        ref = make_ref()

        timer =
          Process.send_after(
            self(),
            {:settlement_timeout, ref},
            max(deadline - System.monotonic_time(:millisecond), 0)
          )

        {:noreply, put_in(ledger.waiters[ref], {MCPBorrowToken.id(token), from, timer})}
    end
  end

  def timeout(ledger, ref, events \\ nil) do
    case Map.pop(ledger.waiters, ref) do
      {nil, _} ->
        ledger

      {{_token, from, _timer}, waiters} ->
        ServingEvents.counter(events, :settlement_timeout)
        GenServer.reply(from, {:error, :provider_cleanup_failed})
        %{ledger | waiters: waiters}
    end
  end

  defp empty?(ledger, token), do: empty_id?(ledger, MCPBorrowToken.id(token))

  defp empty_id?(ledger, token_id),
    do: not Enum.any?(ledger.entries, fn {_id, borrow} -> borrow == token_id end)

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0) + 1

  def seal_and_wait(pid, token, deadline) do
    with :ok <- GenServer.call(pid, {:seal_borrow, token}, remaining(deadline)) do
      GenServer.call(pid, {:await_borrow, token, deadline}, remaining(deadline))
    end
  catch
    :exit, _ -> {:error, :provider_cleanup_failed}
  end
end
