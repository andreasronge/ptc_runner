defmodule PtcRunner.Folding.Operators do
  @moduledoc """
  Genetic operators for genotype strings in the folding system.

  Unlike GP operators that work on ASTs, these operate directly on the genotype
  string. The folding process creates the non-linear mapping to phenotype, so
  simple string operations can have complex phenotypic effects.

  - **Point mutation**: flip one character to a random character
  - **Insertion**: insert a random character at a random position
  - **Deletion**: delete a character at a random position
  - **Crossover**: single-point splice of two parent genotypes

  See `docs/plans/folding-evolution.md` Step 4 for details.
  """

  alias PtcRunner.Folding.Alphabet

  @doc """
  Apply a random mutation to a genotype string.

  Returns `{:ok, mutated_genotype, operator}` or `{:error, reason}`.

  Options:
  - `:operator` — force a specific operator (`:point`, `:insert`, `:delete`)
  """
  @spec mutate(String.t(), keyword()) :: {:ok, String.t(), atom()} | {:error, atom()}
  def mutate(genotype, opts \\ []) do
    operator = Keyword.get(opts, :operator, Enum.random([:point, :insert, :delete]))
    apply_mutation(genotype, operator)
  end

  @doc """
  Single-point crossover between two parent genotypes.

  Cuts parent A at a random position, cuts parent B at a random position,
  and joins the head of A with the tail of B.

  Returns `{:ok, offspring}`.
  """
  @spec crossover(String.t(), String.t()) :: {:ok, String.t()}
  def crossover(parent_a, parent_b) when byte_size(parent_a) > 0 and byte_size(parent_b) > 0 do
    cut_a = :rand.uniform(byte_size(parent_a))
    cut_b = :rand.uniform(byte_size(parent_b))

    head = binary_part(parent_a, 0, cut_a)
    tail = binary_part(parent_b, cut_b, byte_size(parent_b) - cut_b)

    {:ok, head <> tail}
  end

  # === Mutation Implementations ===

  defp apply_mutation(genotype, :point) when byte_size(genotype) > 0 do
    chars = String.to_charlist(genotype)
    pos = :rand.uniform(length(chars)) - 1
    new_char = Enum.random(Alphabet.alphabet())
    mutated = List.replace_at(chars, pos, new_char) |> List.to_string()
    {:ok, mutated, :point}
  end

  defp apply_mutation(genotype, :insert) do
    chars = String.to_charlist(genotype)
    pos = :rand.uniform(length(chars) + 1) - 1
    new_char = Enum.random(Alphabet.alphabet())
    mutated = List.insert_at(chars, pos, new_char) |> List.to_string()
    {:ok, mutated, :insert}
  end

  defp apply_mutation(genotype, :delete) when byte_size(genotype) > 1 do
    chars = String.to_charlist(genotype)
    pos = :rand.uniform(length(chars)) - 1
    mutated = List.delete_at(chars, pos) |> List.to_string()
    {:ok, mutated, :delete}
  end

  defp apply_mutation(genotype, :delete) when byte_size(genotype) <= 1 do
    # Can't delete from a 0 or 1 char string — fall back to point mutation
    apply_mutation(genotype, :point)
  end

  defp apply_mutation(_genotype, :point) do
    {:error, :empty_genotype}
  end
end
