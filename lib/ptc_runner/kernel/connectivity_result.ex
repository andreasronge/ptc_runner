defmodule PtcRunner.Kernel.ConnectivityResult do
  @moduledoc false

  # Internal success value of the `:connect` execution operation.
  #
  # One entry per selected occurrence, in declaration order. Occurrences are
  # never collapsed by alias here: an alias may be selected once per
  # destination, and each occurrence carries its own selection and destination,
  # so which occurrence was reached is part of the answer. Collapsing belongs to
  # the doctor plan that renders one group per alias, and it can only collapse
  # correctly if this value kept them apart.
  #
  # The outcome set is closed and validated at construction rather than trusted
  # from the producer, on the same terms as the doctor plan's settled outcomes:
  # a value that cannot express an unknown result cannot smuggle one into a row.

  alias PtcRunner.Kernel.PreparedRun

  @destinations [:workflow, :mission]
  @modes [:none, :probe, :acquisition]
  @outcomes [:skipped]
  @keys [:name, :destination, :index, :mode, :outcome]
  @name ~r/\A[a-z][a-z0-9._-]{0,127}\z/
  @max_entries 128

  @type outcome :: :skipped
  @type entry :: %{
          name: binary(),
          destination: :workflow | :mission,
          index: non_neg_integer(),
          mode: :none | :probe | :acquisition,
          outcome: outcome()
        }
  @type t :: [entry()]

  @spec outcomes() :: [outcome()]
  @doc false
  def outcomes, do: @outcomes

  @spec new([entry()]) :: {:ok, t()} | {:error, :invalid_connectivity_result}
  @doc false
  def new(entries) when is_list(entries) and length(entries) <= @max_entries do
    if Enum.all?(entries, &valid_entry?/1) and ordered?(entries),
      do: {:ok, entries},
      else: {:error, :invalid_connectivity_result}
  end

  def new(_entries), do: {:error, :invalid_connectivity_result}

  @spec valid?(term()) :: boolean()
  @doc false
  def valid?(entries), do: match?({:ok, _entries}, new(entries))

  @doc """
  Checks that a result answers for exactly the occurrences a preparation
  selected, in the order it declared them.

  A result that dropped, reordered, or invented an occurrence would let a later
  plan settle a row nothing reached, so the correspondence is checked rather
  than assumed.
  """
  @spec covers?(term(), PreparedRun.t()) :: boolean()
  def covers?(entries, %PreparedRun{} = prepared) do
    valid?(entries) and
      Enum.map(entries, &{&1.name, &1.destination, &1.index}) ==
        Enum.map(prepared.provider_declarations, &{&1.name, &1.destination, &1.index})
  end

  def covers?(_entries, _prepared), do: false

  defp valid_entry?(%{} = entry) when not is_struct(entry) do
    Enum.sort(Map.keys(entry)) == Enum.sort(@keys) and
      is_binary(entry.name) and entry.name =~ @name and
      entry.destination in @destinations and
      is_integer(entry.index) and entry.index >= 0 and
      entry.mode in @modes and entry.outcome in @outcomes
  end

  defp valid_entry?(_entry), do: false

  # Declaration order is workflow before mission, ascending within a
  # destination. Checking it here means a producer cannot hand back the same
  # occurrences in an order that no longer says which one was reached first.
  defp ordered?(entries) do
    sites = Enum.map(entries, &{destination_rank(&1.destination), &1.index})
    sites == Enum.sort(sites) and sites == Enum.uniq(sites)
  end

  defp destination_rank(:workflow), do: 0
  defp destination_rank(:mission), do: 1
end
