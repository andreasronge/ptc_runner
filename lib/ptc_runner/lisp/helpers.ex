defmodule PtcRunner.Lisp.Helpers do
  @moduledoc """
  Shared result threading, builtin labels, and safe existing-atom conversion.
  """

  @doc "Renders an atom or string builtin name as its Lisp diagnostic label."
  @spec lisp_name(atom() | String.t()) :: String.t()
  def lisp_name(name) when is_atom(name), do: Atom.to_string(name)
  def lisp_name(name) when is_binary(name), do: name

  @doc """
  Reduces an enumerable with a callback returning tagged accumulators.

  Stops immediately on `:ambiguous` or `{:error, reason}`. The callback receives
  each item and the unwrapped accumulator; successful results stay tagged.
  """
  @spec map_reduce_ok(Enumerable.t(), term(), (term(), term() ->
                                                 {:ok, term()} | :ambiguous | {:error, term()})) ::
          {:ok, term()} | :ambiguous | {:error, term()}
  def map_reduce_ok(items, initial, fun) do
    Enum.reduce_while(items, {:ok, initial}, fn item, {:ok, acc} ->
      case fun.(item, acc) do
        {:ok, _} = result -> {:cont, result}
        :ambiguous -> {:halt, :ambiguous}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Converts a string to an existing atom without creating atoms.

  Returns `:error` when no atom exists. This centralizes exception handling;
  it does not eliminate the underlying conversion exception on a miss.
  """
  @spec existing_atom(String.t()) :: {:ok, atom()} | :error
  def existing_atom(name) when is_binary(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end
end
