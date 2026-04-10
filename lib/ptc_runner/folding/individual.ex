defmodule PtcRunner.Folding.Individual do
  @moduledoc """
  An individual in a folding evolution population.

  Holds the genotype string, the developed phenotype (PTC-Lisp source),
  and fitness metadata. The genotype-to-phenotype mapping goes through
  the folding pipeline (fold → chemistry → assembly).
  """

  alias PtcRunner.Folding.Phenotype

  @type t :: %__MODULE__{
          id: String.t(),
          genotype: String.t(),
          source: String.t() | nil,
          parent_ids: [String.t()],
          generation: non_neg_integer(),
          fitness: float() | nil,
          program_size: non_neg_integer(),
          valid?: boolean(),
          metadata: map()
        }

  defstruct [
    :id,
    :genotype,
    :source,
    :fitness,
    parent_ids: [],
    generation: 0,
    program_size: 0,
    valid?: false,
    metadata: %{}
  ]

  @doc """
  Create an individual from a genotype string.

  Develops the genotype through the folding pipeline to produce a phenotype.
  Always succeeds — invalid genotypes just have `valid?: false` and `source: nil`.
  """
  @spec from_genotype(String.t(), keyword()) :: t()
  def from_genotype(genotype, opts \\ []) do
    {source, valid?, size} =
      case Phenotype.develop(genotype) do
        {:ok, src} -> {src, true, String.length(src)}
        {:error, _} -> {nil, false, 0}
      end

    %__MODULE__{
      id: opts[:id] || generate_id(),
      genotype: genotype,
      source: source,
      parent_ids: opts[:parent_ids] || [],
      generation: opts[:generation] || 0,
      program_size: size,
      valid?: valid?,
      metadata: opts[:metadata] || %{}
    }
  end

  defp generate_id do
    "fold-#{:erlang.unique_integer([:positive, :monotonic])}"
  end
end
