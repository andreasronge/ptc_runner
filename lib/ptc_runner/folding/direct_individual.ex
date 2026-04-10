defmodule PtcRunner.Folding.DirectIndividual do
  @moduledoc """
  An individual using direct encoding (no folding).

  Same interface as `Individual` but uses `Direct.develop/1` instead of
  `Phenotype.develop/1`. This allows the metrics module to measure both
  representations with the same API.
  """

  alias PtcRunner.Folding.Direct

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
  Create an individual from a genotype string using direct encoding.
  """
  @spec from_genotype(String.t(), keyword()) :: t()
  def from_genotype(genotype, opts \\ []) do
    {source, valid?, size} =
      case Direct.develop(genotype) do
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
    "dir-#{:erlang.unique_integer([:positive, :monotonic])}"
  end
end
