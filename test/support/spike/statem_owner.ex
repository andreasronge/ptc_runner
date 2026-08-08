defmodule PtcRunner.TestSupport.Spike.StatemOwner do
  @moduledoc false

  # Spike candidate: the same execution-owner lifecycle as
  # `PtcRunner.TestSupport.Spike.FlagsOwner`, written as an OTP `:gen_statem` in
  # `:state_functions` mode.
  #
  # The phase is the callback name rather than a flag combination, so an event
  # arriving in a phase that cannot legally handle it has nowhere to land unless
  # a clause is written for it. `handle_event_function` mode is deliberately not
  # used: it would reintroduce one catch-all clause list and give up exactly the
  # property under evaluation.
  #
  # Resource ownership still lives in `data.held`, exactly as in the twin: naming
  # the phase does not by itself answer "what is still mine to release". What the
  # state name *does* buy is the `terminate/3` guard, which needs no extra field.

  @behaviour :gen_statem

  alias PtcRunner.TestSupport.Spike.EffectLog

  @unavailable {:error, :execution_session_unavailable}

  @spec start(EffectLog.t(), pid()) :: {:ok, pid()}
  def start(log, caller), do: :gen_statem.start(__MODULE__, {log, caller}, [])

  @spec send_await(pid()) :: :gen_statem.request_id()
  def send_await(pid), do: :gen_statem.send_request(pid, :await)

  @impl :gen_statem
  def callback_mode, do: :state_functions

  @impl :gen_statem
  def init({log, caller}) do
    caller_ref = Process.monitor(caller)

    {:ok, :executing,
     %{
       log: log,
       caller: caller,
       caller_ref: caller_ref,
       result: nil,
       waiter: nil,
       held: MapSet.new([:worker, :sinks, :authority])
     }}
  end

  # Unwinding is skipped in exactly one state, and that state is named rather
  # than inferred. The GenServer twin needs a `closed?` field for this.
  @impl :gen_statem
  def terminate(_reason, :closed, _data), do: :ok

  def terminate(_reason, _state, data) do
    _released = release(data, [:worker, :sinks, :authority])
    :ok
  end

  # --- :executing — worker running, nobody waiting -------------------------

  def executing({:call, from}, :await, data),
    do: {:next_state, :awaited, %{data | waiter: from}}

  def executing(:info, {:worker_result, result}, data), do: settle(:completed, data, result, [])

  def executing(:info, :worker_down, data),
    do: settle(:completed, forget(data, :worker), @unavailable, [])

  def executing(:info, {:DOWN, ref, :process, _pid, _reason}, %{caller_ref: ref} = data),
    do: abandon(data)

  def executing(kind, event, data), do: common(:executing, kind, event, data)

  # --- :awaited — worker running, caller parked in await -------------------

  def awaited(:info, {:worker_result, result}, data),
    do: settle(:awaiting_handoff, %{data | waiter: nil}, result, [{:reply, data.waiter, result}])

  def awaited(:info, :worker_down, data) do
    settle(
      :awaiting_handoff,
      %{forget(data, :worker) | waiter: nil},
      @unavailable,
      [{:reply, data.waiter, @unavailable}]
    )
  end

  def awaited(:info, {:DOWN, ref, :process, _pid, _reason}, %{caller_ref: ref} = data),
    do: abandon(data)

  def awaited({:call, from}, :await, _data),
    do: {:keep_state_and_data, [{:reply, from, @unavailable}]}

  def awaited(kind, event, data), do: common(:awaited, kind, event, data)

  # --- :completed — result held, caller has not collected it yet -----------

  def completed({:call, from}, :await, data),
    do: {:next_state, :awaiting_handoff, data, [{:reply, from, data.result}]}

  def completed(:info, {:DOWN, ref, :process, _pid, _reason}, %{caller_ref: ref} = data),
    do: abandon(data)

  def completed(kind, event, data), do: common(:completed, kind, event, data)

  # --- :awaiting_handoff — result delivered, authority may still be held ----

  def awaiting_handoff(:info, :handoff_ack, data) do
    if MapSet.member?(data.held, :authority) do
      EffectLog.record(data.log, :commit_authority)
      {:next_state, :closed, forget(data, :authority), [{:next_event, :internal, :stop}]}
    else
      {:next_state, :closed, data, [{:next_event, :internal, :stop}]}
    end
  end

  def awaiting_handoff(:info, {:DOWN, ref, :process, _pid, _reason}, %{caller_ref: ref} = data),
    do: abandon(data)

  def awaiting_handoff(kind, event, data), do: common(:awaiting_handoff, kind, event, data)

  # --- :closed — terminal --------------------------------------------------

  def closed(:internal, :stop, _data), do: {:stop, :normal}

  def closed({:call, from}, :phase, _data), do: {:keep_state_and_data, [{:reply, from, :closed}]}

  def closed({:call, from}, _event, _data),
    do: {:keep_state_and_data, [{:reply, from, @unavailable}]}

  def closed(_kind, _event, _data), do: :keep_state_and_data

  # `phase` is answerable directly from the state name — but the name has to be
  # threaded in by hand: a `:state_functions` callback is not told which state it
  # is. That is the mode's main ergonomic cost for genuinely shared events.
  defp common(state, {:call, from}, :phase, _data),
    do: {:keep_state_and_data, [{:reply, from, state}]}

  defp common(_state, _kind, _event, _data), do: :keep_state_and_data

  defp settle(state, data, {:ok, _value} = result, actions),
    do: {:next_state, state, %{data | result: result}, actions}

  defp settle(state, data, {:error, _reason} = result, actions) do
    released = release(data, [:sinks, :authority])
    {:next_state, state, %{released | result: result}, actions}
  end

  defp abandon(data) do
    released = release(data, [:worker, :sinks, :authority])
    {:next_state, :closed, %{released | waiter: nil}, [{:next_event, :internal, :stop}]}
  end

  defp release(data, resources) do
    Enum.reduce(resources, data, fn resource, acc ->
      if MapSet.member?(acc.held, resource) do
        EffectLog.record(acc.log, release_effect(resource))
        forget(acc, resource)
      else
        acc
      end
    end)
  end

  defp release_effect(:worker), do: :stop_worker
  defp release_effect(:sinks), do: :finalize_sinks
  defp release_effect(:authority), do: :abort_authority

  defp forget(data, resource), do: %{data | held: MapSet.delete(data.held, resource)}
end
