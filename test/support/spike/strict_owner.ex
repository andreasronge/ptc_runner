defmodule PtcRunner.TestSupport.Spike.StrictOwner do
  @moduledoc false

  # Third spike variant, used only to exercise the three `:gen_statem` features
  # that have no `GenServer` equivalent:
  #
  #   * `:postpone` — an event that arrives before its state is reached is
  #     re-delivered once the machine gets there, instead of being dropped by a
  #     catch-all clause;
  #   * no catch-all — an event with no clause for the current state crashes the
  #     owner with the state and event named, rather than being swallowed; and
  #   * `:state_timeout` — a per-state deadline that is cancelled automatically
  #     by any state change, with no timer reference to track in the data.
  #
  # It is deliberately not a faithful reduction of the shipped owner; it exists
  # to make the capability difference observable.

  @behaviour :gen_statem

  @spec start(pid(), timeout()) :: {:ok, pid()}
  def start(observer, execution_timeout \\ 50),
    do: :gen_statem.start(__MODULE__, {observer, execution_timeout}, [])

  @impl :gen_statem
  def callback_mode, do: :state_functions

  @impl :gen_statem
  def init({observer, execution_timeout}) do
    {:ok, :executing, %{observer: observer},
     [{:state_timeout, execution_timeout, :execution_deadline}]}
  end

  # --- :executing ----------------------------------------------------------

  def executing(:info, {:worker_result, result}, data),
    do: {:next_state, :awaiting_handoff, Map.put(data, :result, result)}

  # The ack cannot be acted on yet, but it is not discarded either: it is put
  # back in front of the queue and re-delivered on entering the next state.
  def executing(:info, :handoff_ack, _data), do: {:keep_state_and_data, [:postpone]}

  def executing(:state_timeout, :execution_deadline, data) do
    send(data.observer, {:owner, :execution_deadline})
    {:stop, :normal}
  end

  # --- :awaiting_handoff ---------------------------------------------------
  #
  # Entering this state cancels the `:executing` state timeout automatically —
  # a state timeout belongs to the state that set it.

  def awaiting_handoff(:info, :handoff_ack, data) do
    send(data.observer, {:owner, {:committed, data.result}})
    {:stop, :normal}
  end

  # Intentionally no catch-all: an unexpected event here is a crash, not a
  # silent no-op.
end
