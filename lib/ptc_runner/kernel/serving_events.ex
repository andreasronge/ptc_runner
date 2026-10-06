defmodule PtcRunner.Kernel.ServingEvents do
  @moduledoc false

  # Diagnostics must never become a serving dependency. The host supplies
  # bounded callbacks; records here contain closed classes and names only.
  def emit(nil, _record), do: :ok
  def emit(events, record), do: invoke(events.emit, record)
  def counter(nil, _kind), do: :ok
  def counter(events, kind), do: invoke(events.counter, kind)

  def count(state, kind) do
    counter(state.events, kind)
    state
  end

  def observe(nil, _handles), do: :ok
  def observe(events, handles), do: invoke(events.observe, handles)

  defp invoke(callback, value) do
    callback.(value)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
