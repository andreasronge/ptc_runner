defmodule GapAnalyzer.Workspace do
  @moduledoc """
  Agent-based workspace for storing investigation state.

  Keeps findings and pending work in Elixir memory, not LLM context.
  This allows the LLM to work with fresh context each turn while
  maintaining state across the investigation.
  """
  use Agent

  defstruct findings: [], pending: [], investigated: MapSet.new()

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %__MODULE__{} end, name: __MODULE__)
  end

  def stop do
    if Process.whereis(__MODULE__), do: Agent.stop(__MODULE__)
  end

  @doc "Reset workspace to initial state"
  def reset do
    Agent.update(__MODULE__, fn _ -> %__MODULE__{} end)
  end

  @doc "Add items to investigate"
  def add_pending(items) when is_list(items) do
    Agent.update(__MODULE__, fn state ->
      # Don't add items already investigated
      new_items = Enum.reject(items, &MapSet.member?(state.investigated, &1.id))
      %{state | pending: state.pending ++ new_items}
    end)
  end

  @doc "Get pending items (not yet investigated)"
  def get_pending(limit \\ 5) do
    Agent.get(__MODULE__, fn state ->
      state.pending
      |> Enum.reject(&MapSet.member?(state.investigated, &1.id))
      |> Enum.take(limit)
    end)
  end

  @doc "Mark items as investigated"
  def mark_investigated(ids) when is_list(ids) do
    Agent.update(__MODULE__, fn state ->
      new_investigated = Enum.reduce(ids, state.investigated, &MapSet.put(&2, &1))
      new_pending = Enum.reject(state.pending, &(&1.id in ids))
      %{state | investigated: new_investigated, pending: new_pending}
    end)
  end

  @doc "Save findings"
  def save_findings(findings) when is_list(findings) do
    Agent.update(__MODULE__, fn state ->
      %{state | findings: state.findings ++ findings}
    end)
  end

  @doc "Get all findings"
  def get_findings do
    Agent.get(__MODULE__, & &1.findings)
  end

  @doc "Get current state summary"
  def status do
    Agent.get(__MODULE__, fn state ->
      %{
        findings_count: length(state.findings),
        pending_count: length(state.pending),
        investigated_count: MapSet.size(state.investigated)
      }
    end)
  end
end
