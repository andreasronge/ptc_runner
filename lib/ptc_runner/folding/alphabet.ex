defmodule PtcRunner.Folding.Alphabet do
  @moduledoc """
  Maps genotype characters to PTC-Lisp fragment types.

  Each character has a fragment type (what PTC-Lisp piece it represents) and a
  fold instruction (how it bends the chain — handled by `Fold.next_direction/2`).

  See `docs/plans/folding-evolution.md` Step 1 for the full character table.
  """

  @doc """
  Convert a character to its fragment type.

  Returns one of:
  - `{:fn_fragment, atom}` — a function (filter, count, map, get, etc.)
  - `{:comparator, atom}` — a binary comparator (+, >, <, =)
  - `{:connective, atom}` — a logical connective (and, or, not)
  - `{:fn_fragment, :fn}` — anonymous function wrapper
  - `{:fn_fragment, :let}` — let binding
  - `{:data_source, atom}` — a data source reference
  - `{:field_key, atom}` — a field key
  - `{:literal, integer}` — a numeric literal
  - `:spacer` — fold-only character (W, X, Y, Z)

  ## Examples

      iex> PtcRunner.Folding.Alphabet.to_fragment(?A)
      {:fn_fragment, :filter}

      iex> PtcRunner.Folding.Alphabet.to_fragment(?a)
      {:field_key, :price}

      iex> PtcRunner.Folding.Alphabet.to_fragment(?5)
      {:literal, 500}

      iex> PtcRunner.Folding.Alphabet.to_fragment(?W)
      :spacer
  """
  @spec to_fragment(char()) :: term()
  # Functions
  def to_fragment(?A), do: {:fn_fragment, :filter}
  def to_fragment(?B), do: {:fn_fragment, :count}
  def to_fragment(?C), do: {:fn_fragment, :map}
  def to_fragment(?D), do: {:fn_fragment, :get}
  def to_fragment(?E), do: {:fn_fragment, :reduce}
  def to_fragment(?F), do: {:fn_fragment, :group_by}
  def to_fragment(?G), do: {:fn_fragment, :set}
  def to_fragment(?H), do: {:fn_fragment, :contains?}
  def to_fragment(?I), do: {:fn_fragment, :first}

  # Connectors / operators
  def to_fragment(?J), do: {:comparator, :+}
  def to_fragment(?K), do: {:comparator, :>}
  def to_fragment(?L), do: {:comparator, :<}
  def to_fragment(?M), do: {:comparator, :=}
  def to_fragment(?N), do: {:connective, :and}
  def to_fragment(?O), do: {:connective, :or}
  def to_fragment(?P), do: {:connective, :not}
  def to_fragment(?Q), do: {:fn_fragment, :fn}
  def to_fragment(?R), do: {:fn_fragment, :let}

  # Data sources
  def to_fragment(?S), do: {:data_source, :products}
  def to_fragment(?T), do: {:data_source, :employees}
  def to_fragment(?U), do: {:data_source, :orders}
  def to_fragment(?V), do: {:data_source, :expenses}

  # Match function (for structural pattern matching on peer source)
  def to_fragment(?W), do: {:fn_fragment, :match}

  # Spacers (fold-only, no code — X=left, Y=right, Z=reverse)
  def to_fragment(?X), do: :spacer
  def to_fragment(?Y), do: :spacer
  def to_fragment(?Z), do: :spacer

  # Field keys (lowercase)
  def to_fragment(?a), do: {:field_key, :price}
  def to_fragment(?b), do: {:field_key, :status}
  def to_fragment(?c), do: {:field_key, :department}
  def to_fragment(?d), do: {:field_key, :id}
  def to_fragment(?e), do: {:field_key, :name}
  def to_fragment(?f), do: {:field_key, :amount}
  def to_fragment(?g), do: {:field_key, :category}
  def to_fragment(?h), do: {:field_key, :employee_id}

  # Remaining lowercase → wildcards (used in match patterns, fold straight)
  def to_fragment(c) when c in ?i..?z, do: :wildcard

  # Digits → numeric literals (0→0, 1→100, ..., 9→900)
  def to_fragment(c) when c in ?0..?9, do: {:literal, (c - ?0) * 100}

  # Anything else → spacer
  def to_fragment(_), do: :spacer

  @doc """
  All valid genotype characters.
  """
  @spec alphabet() :: [char()]
  def alphabet do
    Enum.to_list(?A..?Z) ++ Enum.to_list(?a..?z) ++ Enum.to_list(?0..?9)
  end

  @doc """
  Generate a random genotype string of the given length.
  """
  @spec random_genotype(pos_integer()) :: String.t()
  def random_genotype(length) do
    chars = alphabet()

    1..length
    |> Enum.map(fn _ -> Enum.random(chars) end)
    |> List.to_string()
  end
end
