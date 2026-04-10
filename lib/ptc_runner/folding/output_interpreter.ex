defmodule PtcRunner.Folding.OutputInterpreter do
  @moduledoc """
  Interprets a tester's phenotype output as a data context modification.

  Instead of hashing tester output into an arbitrary challenge spec, the tester's
  phenotype IS the data transformation. If the output is a list of maps, it replaces
  the relevant data source in the context. Otherwise, the context is unchanged.

  This provides a direct fitness gradient: small mutations to the tester's phenotype
  create small changes in the transformation, which may break different solvers.

  ## How it works

  1. Run tester phenotype against base context → output
  2. If output is a list (possibly of maps) → valid transformation
  3. Detect which data source the tester references → replace that source
  4. If output isn't a list → identity (no modification)

  ## Constraints

  - Empty list output → identity (prevents degenerate "delete all data" challenges)
  - Output must be a list → other types are not valid context modifications
  - At least one element must be a map → prevents lists of bare values replacing structured data
  """

  @data_sources ~w(products employees orders expenses)

  @doc """
  Interpret a tester's output and produce a modified context.

  Takes the tester's phenotype source (to detect which data source is referenced),
  the raw output from running the phenotype, and the base context.

  Returns the modified context, or the base context unchanged if the output
  isn't a valid transformation.

  ## Examples

      iex> base = %{"products" => [%{"price" => 100}]}
      iex> output = [%{"price" => 500}]
      iex> PtcRunner.Folding.OutputInterpreter.interpret("(map ...products...)", output, base)
      %{"products" => [%{"price" => 500}]}

      iex> base = %{"products" => [%{"price" => 100}]}
      iex> PtcRunner.Folding.OutputInterpreter.interpret("anything", 42, base)
      %{"products" => [%{"price" => 100}]}
  """
  @spec interpret(String.t() | nil, term(), map()) :: map()
  def interpret(_source, output, base_context) when not is_list(output), do: base_context
  def interpret(_source, [], base_context), do: base_context

  def interpret(source, output, base_context) when is_list(output) do
    if valid_data_list?(output) do
      case detect_source(source) do
        {:ok, source_name} -> Map.put(base_context, source_name, output)
        :unknown -> base_context
      end
    else
      base_context
    end
  end

  @doc """
  Detect which data source a phenotype source string references.

  Scans for `data/products`, `data/employees`, etc. Returns the first match.
  """
  @spec detect_source(String.t() | nil) :: {:ok, String.t()} | :unknown
  def detect_source(nil), do: :unknown

  def detect_source(source) when is_binary(source) do
    case Enum.find(@data_sources, fn name -> String.contains?(source, "data/#{name}") end) do
      nil -> :unknown
      name -> {:ok, name}
    end
  end

  # A valid data list has at least one map element
  defp valid_data_list?(list) do
    Enum.any?(list, &is_map/1)
  end
end
