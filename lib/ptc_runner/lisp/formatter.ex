defmodule PtcRunner.Lisp.Formatter do
  @moduledoc """
  Serialize PTC-Lisp AST to source code string.

  Used for:
  - Property-based testing (roundtrip: AST -> source -> parse -> AST)
  - Debugging (pretty-print generated ASTs)
  """

  @doc "Format an AST node as PTC-Lisp source code"
  @spec format(term()) :: String.t()
  def format(nil), do: "nil"
  def format(true), do: "true"
  def format(false), do: "false"
  def format(n) when is_integer(n), do: Integer.to_string(n)

  def format(n) when is_float(n) do
    # Ensure consistent float formatting
    :erlang.float_to_binary(n, [:compact, decimals: 10])
  end

  def format({:string, s}), do: ~s("#{escape_string(s)}")
  def format({:keyword, k}), do: ":#{k}"
  def format({:symbol, name}), do: Atom.to_string(name)
  def format({:ns_symbol, ns, key}), do: "#{ns}/#{key}"

  def format({:vector, elems}) do
    "[#{format_list(elems)}]"
  end

  def format({:map, pairs}) do
    "{#{format_pairs(pairs)}}"
  end

  def format({:set, elems}) do
    "\#{#{format_list(elems)}}"
  end

  def format({:list, elems}) do
    "(#{format_list(elems)})"
  end

  # --- Helpers ---

  defp format_list(elems) do
    Enum.map_join(elems, " ", &format/1)
  end

  defp format_pairs(pairs) do
    Enum.map_join(pairs, " ", fn {k, v} -> "#{format(k)} #{format(v)}" end)
  end

  defp escape_string(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\t", "\\t")
    |> String.replace("\r", "\\r")
  end
end
