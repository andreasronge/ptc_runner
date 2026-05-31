defmodule PtcRunner.Lisp.Runtime.Args do
  @moduledoc """
  Shared runtime argument validation for Env builtin calls.
  """

  alias PtcRunner.Lisp.Env.Builtin
  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.Format
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.RuntimeCallable
  alias PtcRunner.Lisp.TypeError

  @spec validate!(Builtin.t() | term(), [term()]) :: :ok
  def validate!(callable, args) do
    name = display_name(callable)

    case custom_call_error(name, args) do
      nil ->
        case Builtin.args(callable) do
          :unchecked -> :ok
          spec -> validate_shape!(name, spec, args)
        end

      message ->
        raise TypeError, message: message
    end
  end

  @spec valid_seqable?(term()) :: boolean()
  def valid_seqable?(nil), do: true
  def valid_seqable?(x) when is_list(x), do: true
  def valid_seqable?(x) when is_binary(x), do: true
  def valid_seqable?(%MapSet{}), do: true
  def valid_seqable?(x) when is_function(x), do: false
  def valid_seqable?(x) when is_map(x) and not is_struct(x), do: true
  def valid_seqable?(x), do: !!Enumerable.impl_for(x)

  @spec valid_callable?(term()) :: boolean()
  def valid_callable?(x) when is_function(x), do: true
  def valid_callable?(%RuntimeCallable{}), do: true
  def valid_callable?({:special, :println}), do: true
  def valid_callable?(%LispKeyword{}), do: true
  def valid_callable?(x) when is_atom(x) and x not in [nil, true, false], do: true
  def valid_callable?(x), do: Builtin.builtin?(x) or closure?(x)

  @spec valid_predicate?(term()) :: boolean()
  def valid_predicate?(%MapSet{}), do: true
  def valid_predicate?(x), do: valid_keyfn?(x)

  @spec valid_keyfn?(term()) :: boolean()
  def valid_keyfn?(%MapSet{}), do: true
  def valid_keyfn?(x) when is_atom(x) and x not in [nil, true, false], do: true
  def valid_keyfn?(%LispKeyword{}), do: true
  def valid_keyfn?(x), do: valid_callable?(x)

  @spec valid_sort_keyfn?(term()) :: boolean()
  def valid_sort_keyfn?(x) when is_list(x), do: true
  def valid_sort_keyfn?(x), do: valid_keyfn?(x)

  defp validate_shape!(name, specs, args) when is_list(specs) do
    validate_list!(name, specs, args)
  end

  defp validate_shape!(name, {:arity, arities}, args) when is_map(arities) do
    case Map.fetch(arities, length(args)) do
      {:ok, specs} -> validate_list!(name, specs, args)
      :error -> :ok
    end
  end

  defp validate_shape!(name, {:rest, spec}, args) do
    Enum.with_index(args, 1)
    |> Enum.each(fn {arg, index} -> validate_arg!(name, index, spec, arg, args) end)
  end

  # Like `{:rest, spec}` but only validates when at least two args are present.
  # A single argument is exempt — used for variadic helpers whose one-arg form
  # is an identity that returns the argument unchanged (e.g. merge, GAP-S146).
  defp validate_shape!(_name, {:rest_min2, _spec}, args) when length(args) < 2, do: :ok

  defp validate_shape!(name, {:rest_min2, spec}, args) do
    validate_shape!(name, {:rest, spec}, args)
  end

  defp validate_shape!(name, {:min, min, fixed_specs, {rest_tag, rest_spec}}, args)
       when rest_tag in [:rest, :rest_min2] do
    if length(args) >= min do
      {fixed, rest} = Enum.split(args, length(fixed_specs))

      validate_list!(name, fixed_specs, fixed, args)

      # `:rest_min2` exempts a single rest arg (the merge-with identity form).
      unless rest_tag == :rest_min2 and length(rest) < 2 do
        rest
        |> Enum.with_index(length(fixed_specs) + 1)
        |> Enum.each(fn {arg, index} -> validate_arg!(name, index, rest_spec, arg, args) end)
      end
    else
      :ok
    end
  end

  defp validate_list!(name, specs, args), do: validate_list!(name, specs, args, args)

  defp validate_list!(name, specs, args, all_args) do
    Enum.zip(specs, args)
    |> Enum.with_index(1)
    |> Enum.each(fn {{spec, arg}, index} -> validate_arg!(name, index, spec, arg, all_args) end)
  end

  defp custom_call_error("sort-by", [key, coll, comp])
       when (is_atom(key) or is_binary(key) or is_function(key, 1) or
               is_list(key) or is_struct(key, LispKeyword)) and is_list(coll) do
    if valid_callable?(comp) or comp in [:asc, :desc, :>, :<] do
      "sort-by expects (key, comparator, collection) but got (key, collection, comparator). Try: (sort-by #{format_hint_value(key)} #{format_hint_value(comp)} collection)"
    end
  end

  defp custom_call_error(_name, _args), do: nil

  defp format_hint_value(%Builtin{name: name}), do: display_atom(name)
  defp format_hint_value(:>), do: ">"
  defp format_hint_value(:<), do: "<"
  defp format_hint_value(:asc), do: ":asc"
  defp format_hint_value(:desc), do: ":desc"

  defp format_hint_value(value) do
    {formatted, _truncated?} = Format.to_clojure(value)
    formatted
  end

  defp display_atom(name), do: name |> Atom.to_string() |> String.replace("_", "-")

  defp validate_arg!(name, index, spec, arg, args) do
    case custom_error(name, index, spec, arg, args) do
      nil ->
        if valid?(spec, arg) do
          :ok
        else
          raise TypeError,
            message: "#{name}: arg #{index} expected #{expected(spec)}, got #{actual(arg)}"
        end

      message ->
        raise TypeError, message: message
    end
  end

  defp custom_error("filter", 2, :seqable, arg, [_pred, arg]) when is_function(arg) do
    "expected a collection, got a function — collection operations like filter/map/reduce take the collection last; arguments may be swapped"
  end

  defp custom_error("filter", 1, :predicate, _arg, [_coll, pred]) when is_function(pred) do
    "expected a collection, got a function — collection operations like filter/map/reduce take the collection last; arguments may be swapped"
  end

  defp custom_error("filter", 1, :predicate, _arg, [coll, pred]) do
    if valid_seqable?(coll) and valid_callable?(pred) do
      "expected a collection, got a function — collection operations like filter/map/reduce take the collection last; arguments may be swapped"
    end
  end

  defp custom_error("map", 2, :seqable, arg, [_f, arg]) when is_function(arg) do
    "expected a collection, got a function — collection operations like filter/map/reduce take the collection last; arguments may be swapped"
  end

  defp custom_error("reduce", index, :seqable, arg, args)
       when is_function(arg) and index == length(args) do
    "expected a collection, got a function — collection operations like filter/map/reduce take the collection last; arguments may be swapped"
  end

  defp custom_error("get", 1, _spec, key, [key, m | _])
       when is_map(m) and not is_struct(m) and
              (is_atom(key) or is_binary(key) or is_list(key) or is_struct(key, LispKeyword)) do
    "get expects the collection first, e.g. (get map key) — got (#{actual(key)}, map), arguments appear to be swapped"
  end

  defp custom_error("get-in", 1, _spec, key, [key, m | _])
       when is_map(m) and not is_struct(m) and
              (is_atom(key) or is_binary(key) or is_list(key) or is_struct(key, LispKeyword)) do
    "get-in expects the collection first, e.g. (get-in map key) — got (#{actual(key)}, map), arguments appear to be swapped"
  end

  defp custom_error("update-vals", 1, _spec, f, [f, m]) when is_map(m) and is_function(f) do
    "update-vals expects (map, function) but got (function, map). Use -> (thread-first) instead of ->> (thread-last) with update-vals"
  end

  defp custom_error("update-vals", 1, _spec, f, [f, m]) when is_map(m) do
    if Builtin.builtin?(f) do
      "update-vals expects (map, function) but got (function, map). Use -> (thread-first) instead of ->> (thread-last) with update-vals"
    end
  end

  defp custom_error(_name, _index, _spec, _arg, _args), do: nil

  defp valid?(:any, _), do: true
  defp valid?(:map, x), do: is_map(x) and not is_struct(x)
  defp valid?(:map_or_nil, nil), do: true
  defp valid?(:map_or_nil, x), do: valid?(:map, x)
  defp valid?(:associative_or_nil, nil), do: true
  defp valid?(:associative_or_nil, x), do: (is_map(x) and not is_struct(x)) or is_list(x)
  defp valid?(:list, x), do: is_list(x)
  defp valid?(:map_or_list, x), do: valid?(:map, x) or is_list(x)
  defp valid?(:map_or_list_or_nil, nil), do: true
  defp valid?(:map_or_list_or_nil, x), do: valid?(:map_or_list, x)
  defp valid?(:seqable, x), do: valid_seqable?(x)
  defp valid?(:callable, x), do: valid_callable?(x)
  defp valid?(:predicate, x), do: valid_predicate?(x)
  defp valid?(:keyfn, x), do: valid_keyfn?(x)
  defp valid?(:sort_keyfn, x), do: valid_sort_keyfn?(x)
  defp valid?(:number, x), do: is_number(x)
  defp valid?(:integer, x), do: is_integer(x)
  defp valid?(:non_neg_integer, x), do: is_integer(x) and x >= 0
  defp valid?(:string, x), do: is_binary(x)
  defp valid?(:keyword, %LispKeyword{}), do: true
  defp valid?(:keyword, x), do: is_atom(x) and x not in [nil, true, false]
  defp valid?(:regex, {:re_mp, _, _, _}), do: true
  defp valid?({:one_of, specs}, x), do: Enum.any?(specs, &valid?(&1, x))

  defp expected(:map_or_nil), do: "map"
  defp expected(:associative_or_nil), do: "associative"
  defp expected(:map_or_list), do: "map or list"
  defp expected(:map_or_list_or_nil), do: "map or list"
  defp expected(:non_neg_integer), do: "non-negative integer"
  defp expected({:one_of, specs}), do: Enum.map_join(specs, " or ", &expected/1)
  defp expected(spec), do: spec |> Atom.to_string() |> String.replace("_", " ")

  defp actual(value), do: Helpers.describe_type(value)

  defp display_name(%Builtin{name: name}),
    do: name |> Atom.to_string() |> String.replace("_", "-")

  defp display_name(other), do: Builtin.name(other) || "function"

  defp closure?({:closure, _, _, _, _, _}), do: true
  defp closure?(_), do: false
end
