defmodule PtcRunner.Evolve.Individual do
  @moduledoc """
  An individual in a GP population — a PTC-Lisp program with fitness metadata.

  Each individual holds source code, the parsed AST, and fitness tracking data.
  GP operators work on the AST; the source is regenerated from the AST after mutation.
  """

  alias PtcRunner.Lisp.Parser

  @type t :: %__MODULE__{
          id: String.t(),
          source: String.t(),
          ast: term(),
          parent_ids: [String.t()],
          generation: non_neg_integer(),
          fitness: float() | nil,
          llm_tokens_used: non_neg_integer(),
          program_size: non_neg_integer(),
          metadata: map()
        }

  defstruct [
    :id,
    :source,
    :ast,
    :fitness,
    parent_ids: [],
    generation: 0,
    llm_tokens_used: 0,
    program_size: 0,
    metadata: %{}
  ]

  @doc """
  Create an individual from PTC-Lisp source code.

  Parses the source into an AST and computes program size (node count).
  Returns `{:ok, individual}` or `{:error, reason}`.
  """
  @spec from_source(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_source(source, opts \\ []) do
    case Parser.parse(source) do
      {:ok, ast} ->
        individual = %__MODULE__{
          id: opts[:id] || generate_id(),
          source: source,
          ast: ast,
          parent_ids: opts[:parent_ids] || [],
          generation: opts[:generation] || 0,
          program_size: node_count(ast),
          metadata: opts[:metadata] || %{}
        }

        {:ok, individual}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Create an individual from source, raising on parse error.
  """
  @spec from_source!(String.t(), keyword()) :: t()
  def from_source!(source, opts \\ []) do
    case from_source(source, opts) do
      {:ok, ind} -> ind
      {:error, reason} -> raise "Failed to parse: #{inspect(reason)}"
    end
  end

  @doc """
  Count AST nodes (measure of program complexity).
  """
  @spec node_count(term()) :: non_neg_integer()
  def node_count(nil), do: 1
  def node_count(x) when is_boolean(x), do: 1
  def node_count(x) when is_number(x), do: 1
  def node_count({:string, _}), do: 1
  def node_count({:keyword, _}), do: 1
  def node_count({:symbol, _}), do: 1
  def node_count({:ns_symbol, _, _}), do: 1
  def node_count({:turn_history, _}), do: 1
  def node_count({:vector, items}), do: 1 + Enum.sum(Enum.map(items, &node_count/1))
  def node_count({:set, items}), do: 1 + Enum.sum(Enum.map(items, &node_count/1))

  def node_count({:map, pairs}) do
    1 + Enum.sum(Enum.map(pairs, fn {k, v} -> node_count(k) + node_count(v) end))
  end

  def node_count({:list, items}), do: 1 + Enum.sum(Enum.map(items, &node_count/1))
  def node_count(_), do: 1

  defp generate_id do
    "ind-#{:erlang.unique_integer([:positive, :monotonic])}"
  end
end
