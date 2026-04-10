defmodule PtcRunner.Folding.Phenotype do
  @moduledoc """
  Converts a genotype string into a PTC-Lisp phenotype.

  The full pipeline: genotype string → fold onto 2D grid → bond chemistry →
  assembled AST fragments → PTC-Lisp source string.

  This is the genotype-to-phenotype mapping — the "development process" that
  creates a non-linear relationship between sequence position and program structure.

  See `docs/plans/folding-evolution.md` for the full design.
  """

  alias PtcRunner.Evolve.Operators
  alias PtcRunner.Folding.{Chemistry, Fold}

  @doc """
  Develop a genotype string into a PTC-Lisp phenotype.

  Returns `{:ok, source}` if the genotype folds into at least one valid AST
  fragment, or `{:error, :no_fragments}` if nothing assembled.

  ## Examples

      iex> {:ok, source} = PtcRunner.Folding.Phenotype.develop("DaK5QAS")
      iex> is_binary(source)
      true
  """
  @spec develop(String.t()) :: {:ok, String.t()} | {:error, :no_fragments}
  def develop(genotype) when is_binary(genotype) do
    {grid, _placements} = Fold.fold(genotype)
    fragments = Chemistry.assemble(grid)

    case select_phenotype(fragments) do
      nil -> {:error, :no_fragments}
      fragment -> {:ok, Operators.format_ast(fragment_to_ast(fragment))}
    end
  end

  @doc """
  Develop a genotype and return the full pipeline result for inspection.

  Returns a map with `:grid`, `:placements`, `:fragments`, `:ast`, and `:source`.
  """
  @spec develop_debug(String.t()) :: map()
  def develop_debug(genotype) when is_binary(genotype) do
    {grid, placements} = Fold.fold(genotype)
    fragments = Chemistry.assemble(grid)
    ast = select_phenotype(fragments)

    source =
      case ast do
        nil -> nil
        fragment -> Operators.format_ast(fragment_to_ast(fragment))
      end

    %{
      genotype: genotype,
      grid: grid,
      placements: placements,
      fragments: fragments,
      ast: ast,
      source: source,
      grid_size: map_size(grid),
      fragment_count: length(fragments),
      valid?: ast != nil
    }
  end

  @doc """
  Measure the validity rate of random genotypes.

  Generates `n` random genotypes of the given length and returns the fraction
  that produce valid PTC-Lisp programs.
  """
  @spec validity_rate(pos_integer(), pos_integer()) :: float()
  def validity_rate(genotype_length, n \\ 1000) do
    alias PtcRunner.Folding.Alphabet

    valid_count =
      1..n
      |> Enum.count(fn _ ->
        genotype = Alphabet.random_genotype(genotype_length)

        case develop(genotype) do
          {:ok, _} -> true
          {:error, _} -> false
        end
      end)

    valid_count / n
  end

  # Select the best fragment as the phenotype.
  # Prefer the largest assembled fragment (most bonds).
  defp select_phenotype([]), do: nil

  defp select_phenotype(fragments) do
    fragments
    |> Enum.reject(&(&1 == :wildcard))
    |> Enum.max_by(&fragment_complexity/1, fn -> nil end)
  end

  defp fragment_complexity({:assembled, ast}), do: ast_size(ast)
  defp fragment_complexity({:literal, _}), do: 1
  defp fragment_complexity({:data_source, _}), do: 1
  defp fragment_complexity({:field_key, _}), do: 1
  defp fragment_complexity(:wildcard), do: 0
  defp fragment_complexity(_), do: 0

  defp ast_size({:list, items}), do: 1 + Enum.sum(Enum.map(items, &ast_size/1))
  defp ast_size({:vector, items}), do: 1 + Enum.sum(Enum.map(items, &ast_size/1))
  defp ast_size(_), do: 1

  # Fragment → AST conversion (mirrors Chemistry's internal conversion)
  defp fragment_to_ast({:assembled, ast}), do: ast
  defp fragment_to_ast({:literal, n}), do: n
  defp fragment_to_ast({:data_source, name}), do: {:ns_symbol, :data, name}
  defp fragment_to_ast({:field_key, key}), do: {:keyword, key}
  defp fragment_to_ast({:fn_fragment, name}), do: {:symbol, name}
  defp fragment_to_ast({:comparator, op}), do: {:symbol, op}
  defp fragment_to_ast({:connective, op}), do: {:symbol, op}
  defp fragment_to_ast(:wildcard), do: {:symbol, :*}
end
