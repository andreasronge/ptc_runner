defmodule PtcRunner.TestSupport.Spike.FlagsOwner do
  @moduledoc false

  # Spike baseline: the execution-owner lifecycle written the way the shipped
  # owners are written today — a `GenServer` over a flat map whose phase is
  # implied by nilable fields and boolean flags, with legality enforced by
  # `handle_*` head patterns and a catch-all that drops anything unmatched.
  #
  # This is a faithful reduction of `PtcRunner.Kernel.ExecutionSessionOwner`'s
  # control flow with the real resource work replaced by recorded effects, so it
  # can be driven by the same randomized sequences as the `:gen_statem` twin.
  #
  # The three `*_held?` flags are the correction the spike's first run forced:
  # without them, a failure followed by caller death releases everything twice.
  # The shipped owner survives the same sequence only because its downstream
  # `abort`/`close` calls happen to be idempotent.

  use GenServer

  alias PtcRunner.TestSupport.Spike.EffectLog

  @unavailable {:error, :execution_session_unavailable}

  @spec start(EffectLog.t(), pid()) :: {:ok, pid()}
  def start(log, caller), do: GenServer.start(__MODULE__, {log, caller})

  @spec send_await(pid()) :: :gen_server.request_id()
  def send_await(pid), do: :gen_server.send_request(pid, :await)

  @impl GenServer
  def init({log, caller}) do
    caller_ref = Process.monitor(caller)

    {:ok,
     %{
       log: log,
       caller: caller,
       caller_ref: caller_ref,
       result: nil,
       waiter: nil,
       worker_held?: true,
       sinks_held?: true,
       authority_held?: true,
       handoff_waiting?: false,
       closed?: false
     }}
  end

  @impl GenServer
  def handle_call(:await, from, %{result: nil, waiter: nil, worker_held?: true} = state),
    do: {:noreply, %{state | waiter: from}}

  def handle_call(:await, _from, %{result: result} = state) when not is_nil(result),
    do: {:reply, result, %{state | handoff_waiting?: true}}

  def handle_call(:phase, _from, state), do: {:reply, phase(state), state}

  def handle_call(:await, _from, state), do: {:reply, @unavailable, state}

  @impl GenServer
  def handle_info({:worker_result, result}, %{result: nil, worker_held?: true} = state) do
    %{state | worker_held?: false, result: result}
    |> settle(result)
    |> finish_or_wait()
  end

  def handle_info(:worker_down, %{result: nil, worker_held?: true} = state) do
    %{state | worker_held?: false, result: @unavailable}
    |> settle(@unavailable)
    |> finish_or_wait()
  end

  def handle_info(
        {:DOWN, ref, :process, caller, _reason},
        %{caller_ref: ref, caller: caller} = s
      ),
      do: {:stop, :normal, abandon(s)}

  def handle_info(:handoff_ack, %{handoff_waiting?: true} = state) do
    state =
      if state.authority_held? do
        EffectLog.record(state.log, :commit_authority)
        %{state | authority_held?: false}
      else
        state
      end

    {:stop, :normal, %{state | handoff_waiting?: false, closed?: true}}
  end

  # Mirrors the shipped owner's catch-all: anything unrecognised for the current
  # flag combination is dropped without a trace.
  def handle_info(_message, state), do: {:noreply, state}

  # The GenServer needs a dedicated `closed?` flag purely so `terminate/2` can
  # tell "already unwound" from "crashed mid-flight". The `:gen_statem` twin gets
  # the same guarantee from its `:closed` state name, with no extra field.
  @impl GenServer
  def terminate(_reason, %{closed?: true}), do: :ok

  def terminate(_reason, state) do
    _state = abandon(state)
    :ok
  end

  defp finish_or_wait(%{waiter: nil} = state), do: {:noreply, state}

  defp finish_or_wait(%{waiter: waiter, result: result} = state) do
    GenServer.reply(waiter, result)
    {:noreply, %{state | waiter: nil, handoff_waiting?: true}}
  end

  defp settle(state, {:ok, _value}), do: state
  defp settle(state, {:error, _reason}), do: release(state, [:sinks, :authority])

  defp abandon(state) do
    state
    |> release([:worker, :sinks, :authority])
    |> Map.put(:waiter, nil)
    |> Map.put(:closed?, true)
  end

  defp release(state, resources), do: Enum.reduce(resources, state, &release_one(&2, &1))

  defp release_one(%{worker_held?: true} = state, :worker) do
    EffectLog.record(state.log, :stop_worker)
    %{state | worker_held?: false}
  end

  defp release_one(%{sinks_held?: true} = state, :sinks) do
    EffectLog.record(state.log, :finalize_sinks)
    %{state | sinks_held?: false}
  end

  defp release_one(%{authority_held?: true} = state, :authority) do
    EffectLog.record(state.log, :abort_authority)
    %{state | authority_held?: false}
  end

  defp release_one(state, _resource), do: state

  # Only exists so the spike can compare against the model. Reconstructing the
  # phase from flags needs this clause order to be exactly right, and nothing
  # checks that it still matches the `handle_*` heads it is meant to describe.
  defp phase(%{result: nil, waiter: nil, worker_held?: true}), do: :executing
  defp phase(%{result: nil, worker_held?: true}), do: :awaited
  defp phase(%{handoff_waiting?: true}), do: :awaiting_handoff
  defp phase(%{result: result}) when not is_nil(result), do: :completed
  defp phase(_state), do: :closed
end
