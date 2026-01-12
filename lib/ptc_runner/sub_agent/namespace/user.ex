defmodule PtcRunner.SubAgent.Namespace.User do
  @moduledoc "Renders the user/ namespace section (LLM-defined functions and values)."

  alias PtcRunner.Lisp.Format
  alias PtcRunner.SubAgent.Namespace.TypeVocabulary

  @doc """
  Render user/ namespace section for USER message.

  Returns `nil` for empty memory maps, otherwise a formatted string with header
  and entries showing functions (with params and optional return type) and values
  (with type and optional sample).

  Functions are listed first, then values, both sorted alphabetically (DEF-009).
  Samples are only shown when `has_println` is false (SAM-001, SAM-002).

  ## Examples

      iex> PtcRunner.SubAgent.Namespace.User.render(%{}, false)
      nil

      iex> closure = {:closure, [{:var, :x}], nil, %{}, [], %{}}
      iex> PtcRunner.SubAgent.Namespace.User.render(%{double: closure}, false)
      ";; === user/ (your prelude) ===\\n(double [x])"

      iex> closure = {:closure, [{:var, :x}], nil, %{}, [], %{return_type: "integer"}}
      iex> PtcRunner.SubAgent.Namespace.User.render(%{double: closure}, false)
      ";; === user/ (your prelude) ===\\n(double [x]) -> integer"

      iex> closure = {:closure, [{:var, :x}], nil, %{}, [], %{docstring: "Doubles x"}}
      iex> PtcRunner.SubAgent.Namespace.User.render(%{double: closure}, false)
      ";; === user/ (your prelude) ===\\n(double [x])                  ; \\"Doubles x\\""

      iex> closure = {:closure, [{:var, :x}], nil, %{}, [], %{docstring: "Doubles x", return_type: "integer"}}
      iex> PtcRunner.SubAgent.Namespace.User.render(%{double: closure}, false)
      ";; === user/ (your prelude) ===\\n(double [x])                  ; \\"Doubles x\\" -> integer"

      iex> PtcRunner.SubAgent.Namespace.User.render(%{total: 42}, false)
      ";; === user/ (your prelude) ===\\ntotal                         ; = integer, sample: 42"

      iex> PtcRunner.SubAgent.Namespace.User.render(%{total: 42}, true)
      ";; === user/ (your prelude) ===\\ntotal                         ; = integer"
  """
  @spec render(map(), boolean()) :: String.t() | nil
  def render(memory, _has_println) when map_size(memory) == 0, do: nil

  def render(memory, has_println) do
    {functions, values} = partition_memory(memory)

    function_lines = format_functions(functions)
    value_lines = format_values(values, has_println)

    [";; === user/ (your prelude) ===" | function_lines ++ value_lines]
    |> Enum.join("\n")
  end

  # Partition memory into functions (closures) and values
  defp partition_memory(memory) do
    memory
    |> Enum.split_with(fn {_name, value} -> closure?(value) end)
    |> then(fn {fns, vals} ->
      {Enum.sort_by(fns, &elem(&1, 0)), Enum.sort_by(vals, &elem(&1, 0))}
    end)
  end

  defp closure?({:closure, _, _, _, _, _}), do: true
  defp closure?({:closure, _, _, _, _}), do: true
  defp closure?(_), do: false

  # Format functions: (name [params]) with optional docstring and return_type
  # Per spec FMT-006/FMT-007:
  #   - With docstring + return: (name [params])              ; "docstring" -> type
  #   - With docstring only:    (name [params])              ; "docstring"
  #   - With return only:       (name [params]) -> type
  #   - Minimal:                (name [params])
  defp format_functions(functions) do
    Enum.map(functions, fn {name, closure} ->
      params_str = format_params(closure)
      base = "(#{name} [#{params_str}])"
      docstring = get_docstring(closure)
      return_type = get_return_type(closure)

      case {docstring, return_type} do
        {nil, nil} ->
          base

        {nil, type} ->
          "#{base} -> #{type}"

        {doc, nil} ->
          # Pad to align docstrings
          padded_base = String.pad_trailing(base, 30)
          "#{padded_base}; \"#{doc}\""

        {doc, type} ->
          padded_base = String.pad_trailing(base, 30)
          "#{padded_base}; \"#{doc}\" -> #{type}"
      end
    end)
  end

  # Extract params from closure (5-tuple or 6-tuple)
  defp format_params({:closure, params, _, _, _, _}), do: do_format_params(params)
  defp format_params({:closure, params, _, _, _}), do: do_format_params(params)

  defp do_format_params({:variadic, leading, rest}) do
    leading_str = Enum.map_join(leading, " ", &extract_param_name/1)
    rest_str = "& #{extract_param_name(rest)}"

    if leading_str == "" do
      rest_str
    else
      "#{leading_str} #{rest_str}"
    end
  end

  defp do_format_params(params) when is_list(params) do
    Enum.map_join(params, " ", &extract_param_name/1)
  end

  defp extract_param_name({:var, name}), do: Atom.to_string(name)
  defp extract_param_name(_), do: "_"

  # Extract docstring from metadata (6-tuple only)
  defp get_docstring({:closure, _, _, _, _, %{docstring: doc}}) when is_binary(doc), do: doc
  defp get_docstring(_), do: nil

  # Extract return type from metadata (6-tuple only)
  defp get_return_type({:closure, _, _, _, _, %{return_type: type}}) when not is_nil(type),
    do: type

  defp get_return_type(_), do: nil

  # Format values: name ; = type with optional sample
  defp format_values(values, has_println) do
    Enum.map(values, fn {name, value} ->
      type_label = TypeVocabulary.type_of(value)
      name_str = Atom.to_string(name)
      # Pad name to 30 chars for alignment
      padded_name = String.pad_trailing(name_str, 30)

      if has_println do
        "#{padded_name}; = #{type_label}"
      else
        sample = format_sample(value)
        "#{padded_name}; = #{type_label}, sample: #{sample}"
      end
    end)
  end

  defp format_sample(value) do
    {str, _truncated} = Format.to_clojure(value, limit: 3, printable_limit: 80)
    str
  end
end
