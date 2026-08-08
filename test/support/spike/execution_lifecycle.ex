defmodule PtcRunner.TestSupport.Spike.ExecutionLifecycle do
  @moduledoc false

  # Pure lifecycle extracted from `PtcRunner.Kernel.ExecutionSessionOwner`.
  #
  # The shipped owner keeps this machine implicit: five nilable/boolean fields
  # (`result`, `waiter`, `worker_pid`, `handoff_waiting?`, `authority_handed_off?`)
  # encode the phase, and legality is enforced by `handle_*` head patterns.
  #
  # Two things are named explicitly here that the shipped owner leaves implicit:
  #
  #   * the phase, as an atom rather than a flag combination; and
  #   * the set of resources still held, which is what makes "release exactly
  #     once" checkable. The shipped owner instead nils resource fields as it
  #     goes and relies on each downstream `close`/`abort` being idempotent.
  #
  # In the spike this module is the oracle: randomized event sequences are run
  # against it and against both process implementations, and any disagreement is
  # a finding about that implementation rather than about the model.

  @type phase :: :executing | :awaited | :completed | :awaiting_handoff | :closed

  @type resource :: :worker | :sinks | :authority

  @type from :: term()

  @type event ::
          {:await, from()}
          | {:worker_result, {:ok, term()} | {:error, term()}}
          | :worker_down
          | :caller_down
          | :handoff_ack

  @type effect ::
          {:reply, from(), term()}
          | :stop_worker
          | :finalize_sinks
          | :abort_authority
          | :commit_authority
          | :stop

  @type data :: %{result: term() | nil, waiter: from() | nil, held: MapSet.t(resource())}

  @type t :: {phase(), data()}

  @unavailable {:error, :execution_session_unavailable}

  @spec new() :: t()
  def new,
    do: {:executing, %{result: nil, waiter: nil, held: MapSet.new([:worker, :sinks, :authority])}}

  @spec phase(t()) :: phase()
  def phase({phase, _data}), do: phase

  @spec held(t()) :: MapSet.t(resource())
  def held({_phase, data}), do: data.held

  @doc """
  Applies one event, returning the next machine and the effects to run.

  Effects are returned in the order the process layer must execute them.
  """
  @spec step(t(), event()) :: {t(), [effect()]}
  def step({phase, data}, event), do: transition(phase, event, data)

  # --- :executing — worker running, nobody waiting -------------------------

  defp transition(:executing, {:await, from}, data),
    do: {{:awaited, %{data | waiter: from}}, []}

  defp transition(:executing, {:worker_result, result}, data),
    do: settle(:completed, data, result, [])

  defp transition(:executing, :worker_down, data),
    do: settle(:completed, drop(data, :worker), @unavailable, [])

  defp transition(:executing, :caller_down, data), do: abandon(data)

  # --- :awaited — worker running, caller parked in await -------------------

  defp transition(:awaited, {:worker_result, result}, data),
    do: settle(:awaiting_handoff, %{data | waiter: nil}, result, [{:reply, data.waiter, result}])

  defp transition(:awaited, :worker_down, data) do
    settle(
      :awaiting_handoff,
      %{drop(data, :worker) | waiter: nil},
      @unavailable,
      [{:reply, data.waiter, @unavailable}]
    )
  end

  defp transition(:awaited, :caller_down, data), do: abandon(data)

  # A second await while one is parked is a protocol violation, not a queue.
  defp transition(:awaited, {:await, from}, data),
    do: {{:awaited, data}, [{:reply, from, @unavailable}]}

  # --- :completed — result held, caller has not collected it yet -----------

  defp transition(:completed, {:await, from}, data),
    do: {{:awaiting_handoff, data}, [{:reply, from, data.result}]}

  defp transition(:completed, :caller_down, data), do: abandon(data)

  # --- :awaiting_handoff — result delivered, authority may still be held ----
  #
  # A failed run already released its authority when it settled, so the ack has
  # nothing left to commit. Gating on the held set — rather than on the phase —
  # is what keeps commit and abort mutually exclusive.

  defp transition(:awaiting_handoff, :handoff_ack, data) do
    if MapSet.member?(data.held, :authority) do
      {{:closed, drop(data, :authority)}, [:commit_authority, :stop]}
    else
      {{:closed, data}, [:stop]}
    end
  end

  # The shipped owner reaches this window between `GenServer.call` returning and
  # the caller's `:handoff_ack` landing. A caller that dies inside it has the
  # result but never acknowledged it, so the authority is aborted, not committed.
  defp transition(:awaiting_handoff, :caller_down, data), do: abandon(data)

  # --- terminal and ignored ------------------------------------------------

  defp transition(:closed, _event, data), do: {{:closed, data}, []}

  defp transition(phase, _event, data), do: {{phase, data}, []}

  # A failed run releases its sinks and authority as it settles; a successful one
  # holds both until the caller acknowledges the handoff.
  defp settle(phase, data, {:ok, _value} = result, effects),
    do: {{phase, %{data | result: result}}, effects}

  defp settle(phase, data, {:error, _reason} = result, effects) do
    {released, release_effects} = release(data, [:sinks, :authority])
    {{phase, %{released | result: result}}, effects ++ release_effects}
  end

  # Caller death anywhere before a committed handoff unwinds whatever is left.
  defp abandon(data) do
    {released, effects} = release(data, [:worker, :sinks, :authority])
    {{:closed, %{released | waiter: nil}}, effects ++ [:stop]}
  end

  # Only resources still held produce an effect, so replaying a release is a
  # no-op instead of a second real teardown.
  defp release(data, resources) do
    Enum.reduce(resources, {data, []}, fn resource, {acc, effects} ->
      if MapSet.member?(acc.held, resource) do
        {drop(acc, resource), effects ++ [release_effect(resource)]}
      else
        {acc, effects}
      end
    end)
  end

  defp release_effect(:worker), do: :stop_worker
  defp release_effect(:sinks), do: :finalize_sinks
  defp release_effect(:authority), do: :abort_authority

  defp drop(data, resource), do: %{data | held: MapSet.delete(data.held, resource)}
end
