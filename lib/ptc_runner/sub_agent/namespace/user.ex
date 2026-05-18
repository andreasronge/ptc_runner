defmodule PtcRunner.SubAgent.Namespace.User do
  @moduledoc "Renders the user/ namespace section (LLM-defined functions and values)."

  alias PtcRunner.SubAgent.Namespace.SampleFormatter
  alias PtcRunner.SubAgent.Namespace.TypeVocabulary
  alias PtcRunner.SubAgent.UntrustedRenderer

  @doc """
  Render user/ namespace section for USER message.

  Returns `nil` for empty memory maps, otherwise a formatted string with header
  and entries showing functions (with params and optional return type) and values
  (with type and optional sample).

  Functions are listed first, then values, both sorted alphabetically (DEF-009).
  Samples are only shown when `has_println` is false (SAM-001, SAM-002).

  ## Options

  - `:has_println` - Boolean, controls whether samples are shown (default: false)
  - `:sample_limit` - Max items to show in collections (default: 3)
  - `:sample_printable_limit` - Max chars for strings (default: 80)

  ## Examples

      iex> PtcRunner.SubAgent.Namespace.User.render(%{}, [])
      nil

      iex> closure = {:closure, [{:var, :x}], nil, %{}, [], %{}}
      iex> PtcRunner.SubAgent.Namespace.User.render(%{double: closure}, [])
      ";; === user/ (your prelude) ===\\n(double [x])"

      iex> closure = {:closure, [{:var, :x}], nil, %{}, [], %{return_type: "integer"}}
      iex> PtcRunner.SubAgent.Namespace.User.render(%{double: closure}, [])
      ";; === user/ (your prelude) ===\\n(double [x]) -> integer"

      iex> closure = {:closure, [{:var, :x}], nil, %{}, [], %{docstring: "Doubles x"}}
      iex> PtcRunner.SubAgent.Namespace.User.render(%{double: closure}, [])
      ";; === user/ (your prelude) ===\\n(double [x])                  ; \\"Doubles x\\""

      iex> closure = {:closure, [{:var, :x}], nil, %{}, [], %{docstring: "Doubles x", return_type: "integer"}}
      iex> PtcRunner.SubAgent.Namespace.User.render(%{double: closure}, [])
      ";; === user/ (your prelude) ===\\n(double [x])                  ; \\"Doubles x\\" -> integer"

      iex> result = PtcRunner.SubAgent.Namespace.User.render(%{total: 42}, [])
      iex> result =~ "total"
      true
      iex> result =~ "integer, sample: 42"
      true
      iex> result =~ "untrusted_ptc_output"
      true

      iex> result = PtcRunner.SubAgent.Namespace.User.render(%{total: 42}, has_println: true)
      iex> result =~ "total"
      true
      iex> result =~ "; = integer"
      true

      iex> result = PtcRunner.SubAgent.Namespace.User.render(%{_secret: "token123"}, [])
      iex> result =~ "_secret"
      true
      iex> result =~ "untrusted_ptc_output"
      true
  """
  @spec render(map(), keyword()) :: String.t() | nil
  def render(memory, _opts) when map_size(memory) == 0, do: nil

  def render(memory, opts) do
    {functions, values} = partition_memory(memory)

    if functions == [] and values == [] do
      nil
    else
      function_lines = format_functions(functions)
      value_lines = format_values(values, opts)

      wrapped_value_lines = wrap_value_lines(value_lines)

      [";; === user/ (your prelude) ===" | function_lines ++ wrapped_value_lines]
      |> Enum.join("\n")
    end
  end

  # Partition memory into functions (closures) and values
  # Filters out uninformative values (nil, empty lists, empty maps)
  defp partition_memory(memory) do
    memory
    |> Enum.reject(fn {_name, value} -> uninformative?(value) end)
    |> Enum.split_with(fn {_name, value} -> closure?(value) end)
    |> then(fn {fns, vals} ->
      {Enum.sort_by(fns, &display_name(elem(&1, 0))),
       Enum.sort_by(vals, &display_name(elem(&1, 0)))}
    end)
  end

  # Values that provide no useful information to the LLM
  defp uninformative?(nil), do: true
  defp uninformative?([]), do: true
  defp uninformative?(map) when is_map(map) and map_size(map) == 0, do: true
  defp uninformative?(_), do: false

  defp closure?({:closure, _, _, _, _, _}), do: true
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
      base = "(#{display_name(name)} [#{params_str}])"
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

  defp format_params({:closure, params, _, _, _, _}), do: do_format_params(params)

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

  defp extract_param_name({:var, name}), do: display_name(name)
  defp extract_param_name(_), do: "_"

  # Extract docstring from metadata (6-tuple only)
  defp get_docstring({:closure, _, _, _, _, %{docstring: doc}}) when is_binary(doc), do: doc
  defp get_docstring(_), do: nil

  # Extract return type from metadata (6-tuple only)
  defp get_return_type({:closure, _, _, _, _, %{return_type: type}}) when not is_nil(type),
    do: type

  defp get_return_type(_), do: nil

  # Format values: name ; = type with optional sample
  defp format_values(values, opts) do
    has_println = Keyword.get(opts, :has_println, false)

    Enum.map(values, fn {name, value} ->
      type_label = TypeVocabulary.type_of(value)
      name_str = display_name(name)
      # Pad name to 30 chars for alignment
      padded_name = String.pad_trailing(name_str, 30)

      if has_println do
        "#{padded_name}; = #{type_label}"
      else
        sample = SampleFormatter.format(value, opts)
        "#{padded_name}; = #{type_label}, sample: #{sample}"
      end
    end)
  end

  defp wrap_value_lines([]), do: []

  defp wrap_value_lines(lines) do
    content = Enum.join(lines, "\n")
    [UntrustedRenderer.wrap(content, "memory")]
  end

  defp display_name(name) when is_atom(name), do: Atom.to_string(name)
  defp display_name(name) when is_binary(name), do: name
  defp display_name(name), do: inspect(name)
end
