defmodule PtcRunner.Lisp.RetainedSize do
  @moduledoc false

  @word_bytes :erlang.system_info(:wordsize)

  @doc """
  Return a retained-heap byte estimate for a term, or `:oversized` if the term
  cannot be sized safely.

  This uses the same units as the sandbox bills: flat heap words plus reachable
  referenced binary parent sizes. Structs are sized through their fields because
  native Lisp memory can contain safe data structs such as `MapSet` in closure
  metadata.
  """
  @spec bytes(term()) :: non_neg_integer() | :oversized
  def bytes(value) do
    :erts_debug.flat_size(value) * @word_bytes + referenced_binary_size(value)
  rescue
    _ -> :oversized
  end

  @doc """
  Return the retained size only if it is within `cap`; short-circuit when the
  flat heap alone already breaches the cap.
  """
  @spec bytes_with_cap(term(), pos_integer()) :: non_neg_integer() | :oversized
  def bytes_with_cap(value, cap) when is_integer(cap) and cap > 0 do
    case heap_size(value) do
      :oversized -> :oversized
      heap when heap > cap -> heap
      heap -> heap + referenced_binary_size(value)
    end
  rescue
    _ -> :oversized
  end

  defp heap_size(value) do
    :erts_debug.flat_size(value) * @word_bytes
  rescue
    _ -> :oversized
  end

  defp referenced_binary_size(value) when is_binary(value),
    do: :binary.referenced_byte_size(value)

  defp referenced_binary_size(value) when is_list(value),
    do: Enum.reduce(value, 0, &(referenced_binary_size(&1) + &2))

  defp referenced_binary_size(%MapSet{} = value),
    do: value |> MapSet.to_list() |> referenced_binary_size()

  defp referenced_binary_size(%_{} = value),
    do: value |> Map.from_struct() |> referenced_binary_size()

  defp referenced_binary_size(value) when is_map(value) do
    Enum.reduce(value, 0, fn {k, v}, acc ->
      acc + referenced_binary_size(k) + referenced_binary_size(v)
    end)
  end

  defp referenced_binary_size(value) when is_function(value) do
    if runtime_function?(value) do
      {:env, env} = :erlang.fun_info(value, :env)
      heap_size(env) + referenced_binary_size(env)
    else
      raise ArgumentError, "cannot retain host function memory"
    end
  end

  defp referenced_binary_size(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> referenced_binary_size()

  defp referenced_binary_size(_value), do: 0

  defp runtime_function?(fun) do
    {:module, module} = :erlang.fun_info(fun, :module)

    module in [PtcRunner.Lisp.Eval, PtcRunner.Lisp.Runtime] or
      module
      |> Atom.to_string()
      |> String.starts_with?("Elixir.PtcRunner.Lisp.Runtime.")
  end
end
