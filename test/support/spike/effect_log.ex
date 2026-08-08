defmodule PtcRunner.TestSupport.Spike.EffectLog do
  @moduledoc false

  # Ordered, append-only record of the side effects a spike owner performed.
  #
  # The spike replaces every real resource operation (sink finalization,
  # authority abort/commit, worker teardown) with an entry here, so a test can
  # assert on *how many times* and *in what order* an owner unwound — the
  # properties that ownership bugs actually violate.

  use Agent

  @enforce_keys [:pid]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{pid: pid()}

  @spec start() :: t()
  def start do
    {:ok, pid} = Agent.start_link(fn -> [] end)
    %__MODULE__{pid: pid}
  end

  @spec record(t(), atom()) :: :ok
  def record(%__MODULE__{pid: pid}, effect), do: Agent.update(pid, &[effect | &1])

  @spec effects(t()) :: [atom()]
  def effects(%__MODULE__{pid: pid}), do: pid |> Agent.get(& &1) |> Enum.reverse()

  @spec count(t(), atom()) :: non_neg_integer()
  def count(log, effect), do: log |> effects() |> Enum.count(&(&1 == effect))

  @spec stop(t()) :: :ok
  def stop(%__MODULE__{pid: pid}), do: Agent.stop(pid)
end
