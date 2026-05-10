defmodule PtcRunner.SubAgent.Namespace.SampleFormatter do
  @moduledoc "Shared sample-value formatting for namespace renderers."

  alias PtcRunner.Lisp.Format

  @doc """
  Format a value as a Clojure-style sample string for namespace prompt sections.

  Reads `:sample_limit` (default 3) and `:sample_printable_limit` (default 80)
  from `opts` and delegates to `PtcRunner.Lisp.Format.to_clojure/2`.

  ## Examples

      iex> PtcRunner.SubAgent.Namespace.SampleFormatter.format(42, [])
      "42"

      iex> PtcRunner.SubAgent.Namespace.SampleFormatter.format([1, 2, 3, 4, 5], sample_limit: 2)
      "[1 2 ...] (5 items, showing first 2)"
  """
  @spec format(term(), keyword()) :: String.t()
  def format(value, opts) do
    limit = Keyword.get(opts, :sample_limit, 3)
    printable_limit = Keyword.get(opts, :sample_printable_limit, 80)
    {str, _truncated} = Format.to_clojure(value, limit: limit, printable_limit: printable_limit)
    str
  end
end
