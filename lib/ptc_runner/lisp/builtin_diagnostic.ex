defmodule PtcRunner.Lisp.BuiltinDiagnostic do
  @moduledoc """
  Closed rendering of builtin argument diagnostics for private sessions.

  Only code-owned builtin names, fixed type labels, and bounded argument counts
  are admitted. Unknown shapes fail closed; rendered evaluator prose is ignored.
  """

  alias PtcRunner.Lisp.Env
  alias PtcRunner.Lisp.Env.Builtin
  alias PtcRunner.Lisp.Eval.Helpers

  @expected [
    "any",
    "map",
    "associative",
    "list",
    "seqable",
    "callable",
    "predicate",
    "keyfn",
    "sort keyfn",
    "number",
    "integer",
    "non-negative integer",
    "string",
    "keyword",
    "regex"
  ]

  @doc false
  @spec message(term()) :: {:ok, String.t()} | :error
  def message(
        %{kind: :builtin_argument, name: name, index: index, expected: expected, actual: actual} =
          diagnostic
      )
      when map_size(diagnostic) == 5 do
    if builtin_name?(name) and is_integer(index) and index in 1..1_000_000 and
         expected?(expected) and actual in Helpers.safe_type_names() do
      {:ok, "#{name}: arg #{index} expected #{expected}, got #{actual}"}
    else
      :error
    end
  end

  def message(%{kind: :builtin_types, name: name, types: types} = diagnostic)
      when map_size(diagnostic) == 3 and is_list(types) and length(types) <= 64 do
    if builtin_name?(name) and Enum.all?(types, &(&1 in Helpers.safe_type_names())) do
      {:ok, "#{name}: invalid argument types: #{Enum.join(types, ", ")}"}
    else
      :error
    end
  end

  def message(_diagnostic), do: :error

  @doc false
  @spec builtin_name?(term()) :: boolean()
  def builtin_name?(name) when is_binary(name) and byte_size(name) <= 256 do
    Enum.any?(Env.initial(), fn {key, binding} ->
      name == display_name(key) or name in binding_names(Builtin.unwrap(binding))
    end)
  end

  def builtin_name?(_name), do: false

  @doc false
  @spec arity?(term()) :: boolean()
  def arity?(n) when is_integer(n), do: n in 0..1_000_000
  def arity?({:at_least, n}) when is_integer(n), do: arity?(n)

  def arity?(ns) when is_list(ns) and length(ns) in 1..64,
    do: Enum.all?(ns, &(is_integer(&1) and &1 in 0..1_000_000))

  def arity?(_expected), do: false

  defp expected?(expected) when is_binary(expected) and byte_size(expected) <= 256,
    do: Enum.all?(String.split(expected, " or "), &(&1 in @expected))

  defp expected?(_expected), do: false

  defp display_name(name), do: name |> Atom.to_string() |> String.replace("_", "-")

  defp binding_names(binding) when is_tuple(binding) do
    binding |> Tuple.to_list() |> Enum.flat_map(&binding_names/1)
  end

  defp binding_names(fun) when is_function(fun),
    do: [fun |> Function.info(:name) |> elem(1) |> Atom.to_string()]

  defp binding_names(_binding), do: []
end
