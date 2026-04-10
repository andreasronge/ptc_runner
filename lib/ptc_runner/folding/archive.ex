defmodule PtcRunner.Folding.Archive do
  @moduledoc """
  Hall-of-fame archive for interactive coevolution.

  Maintains separate archives of strong solvers and strong testers.
  Prevents coevolution cycling by providing stable selection pressure
  from historically successful individuals.

  Archives are deduplicated by phenotype — two individuals with the
  same source code are considered duplicates.
  """

  alias PtcRunner.Folding.Individual

  @type t :: %__MODULE__{
          solvers: [Individual.t()],
          testers: [Individual.t()],
          max_size: pos_integer()
        }

  defstruct solvers: [], testers: [], max_size: 10

  @doc "Create a new empty archive."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{max_size: Keyword.get(opts, :max_size, 10)}
  end

  @doc """
  Update the archive with the current population.

  Adds the best solver (by solve_score) and best tester (by test_score)
  if their phenotype is novel. If the archive is full, replaces the
  lowest-scoring member.
  """
  @spec update(t(), [Individual.t()]) :: t()
  def update(%__MODULE__{} = archive, population) do
    valid = Enum.filter(population, & &1.valid?)

    best_solver =
      valid
      |> Enum.max_by(fn i -> Map.get(i.metadata, :solve_score, 0.0) end, fn -> nil end)

    best_tester =
      valid
      |> Enum.max_by(fn i -> Map.get(i.metadata, :test_score, 0.0) end, fn -> nil end)

    archive
    |> maybe_add_solver(best_solver)
    |> maybe_add_tester(best_tester)
  end

  @doc "Get archived solvers."
  @spec solver_archive(t()) :: [Individual.t()]
  def solver_archive(%__MODULE__{solvers: s}), do: s

  @doc "Get archived testers."
  @spec tester_archive(t()) :: [Individual.t()]
  def tester_archive(%__MODULE__{testers: t}), do: t

  defp maybe_add_solver(archive, nil), do: archive

  defp maybe_add_solver(%__MODULE__{solvers: solvers, max_size: max} = archive, individual) do
    if phenotype_exists?(solvers, individual) do
      archive
    else
      new_solvers = add_to_list(solvers, individual, max, :solve_score)
      %{archive | solvers: new_solvers}
    end
  end

  defp maybe_add_tester(archive, nil), do: archive

  defp maybe_add_tester(%__MODULE__{testers: testers, max_size: max} = archive, individual) do
    if phenotype_exists?(testers, individual) do
      archive
    else
      new_testers = add_to_list(testers, individual, max, :test_score)
      %{archive | testers: new_testers}
    end
  end

  defp phenotype_exists?(list, individual) do
    Enum.any?(list, fn i -> i.source == individual.source end)
  end

  defp add_to_list(list, individual, max_size, _score_key) when length(list) < max_size do
    [individual | list]
  end

  defp add_to_list(list, individual, _max_size, score_key) do
    worst = Enum.min_by(list, fn i -> Map.get(i.metadata, score_key, 0.0) end)
    worst_score = Map.get(worst.metadata, score_key, 0.0)
    new_score = Map.get(individual.metadata, score_key, 0.0)

    if new_score > worst_score do
      list
      |> List.delete(worst)
      |> then(&[individual | &1])
    else
      list
    end
  end
end
