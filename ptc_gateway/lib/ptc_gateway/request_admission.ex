defmodule PtcGateway.RequestAdmission do
  @moduledoc false
  use Agent

  def start_link(maximum), do: Agent.start_link(fn -> %{active: 0, maximum: maximum} end)

  def acquire(owner) do
    Agent.get_and_update(owner, fn state ->
      if state.active < state.maximum,
        do: {:ok, %{state | active: state.active + 1}},
        else: {:full, state}
    end)
  catch
    :exit, _ -> :unavailable
  end

  def release(owner) do
    Agent.update(owner, fn state -> %{state | active: max(state.active - 1, 0)} end)
  catch
    :exit, _ -> :ok
  end
end
