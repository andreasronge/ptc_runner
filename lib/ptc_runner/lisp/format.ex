defmodule PtcRunner.Lisp.Format do
  @moduledoc """
  Format PTC-Lisp values for human/LLM display.

  Handles special Lisp types that should not expose internal implementation:
  - Closures: `{:closure, params, body, env, history}` → `#fn[x y]`
  - Builtins: `{:normal, fun}` etc. → `#<builtin>`

  Works recursively, so closures nested in maps/lists are also formatted.

  ## Examples

      iex> PtcRunner.Lisp.Format.to_string({:closure, [{:var, :x}], nil, %{}, []})
      "#fn[x]"

      iex> PtcRunner.Lisp.Format.to_string({:normal, &Enum.map/2})
      "#<builtin>"

      iex> PtcRunner.Lisp.Format.to_string(%{a: 1})
      "%{a: 1}"
  """

  # Wrapper struct for formatted closures/builtins that inspects nicely
  defmodule Fn do
    @moduledoc false
    defstruct [:params]

    defimpl Inspect do
      def inspect(%{params: params}, _opts) do
        "#fn[#{params}]"
      end
    end
  end

  defmodule Builtin do
    @moduledoc false
    defstruct []

    defimpl Inspect do
      def inspect(%Builtin{}, _opts), do: "#<builtin>"
    end
  end

  defmodule Var do
    @moduledoc false
    defstruct [:name]

    defimpl Inspect do
      def inspect(%{name: name}, _opts), do: "#'#{name}"
    end
  end

  @doc """
  Format a Lisp value as a string for display.

  ## Options

  All options are passed through to `Kernel.inspect/2` for regular values:
  - `:pretty` - Use pretty-printing
  - `:limit` - Maximum items to show in collections
  - `:width` - Target width for pretty printing
  - `:printable_limit` - Maximum string bytes to show

  ## Examples

      iex> PtcRunner.Lisp.Format.to_string(42)
      "42"

      iex> PtcRunner.Lisp.Format.to_string({:closure, [{:var, :x}, {:var, :y}], nil, %{}, []})
      "#fn[x y]"

      iex> PtcRunner.Lisp.Format.to_string({:var, :my_var})
      "#'my_var"

      iex> PtcRunner.Lisp.Format.to_string([1, 2, 3], limit: 2)
      "[1, 2, ...]"

      iex> PtcRunner.Lisp.Format.to_string(%{f: {:closure, [{:var, :x}], nil, %{}, []}})
      "%{f: #fn[x]}"
  """
  @spec to_string(term(), keyword()) :: String.t()
  def to_string(value, opts \\ []) do
    value
    |> sanitize()
    |> inspect(opts)
  end

  @doc """
  Format a Lisp value as Clojure syntax for LLM feedback.

  Produces Clojure-style output that matches the syntax the LLM writes:
  - Maps: `{:key value}` instead of `%{key: value}`
  - Lists: `[1 2 3]` (space-separated) instead of `[1, 2, 3]`
  - Keywords: `:foo` (same as Clojure)
  - Strings/numbers/booleans: standard literals

  Returns `{formatted_string, truncated?}` tuple.

  ## Options

  - `:limit` - Maximum items to show in collections (default: :infinity)
  - `:printable_limit` - Maximum string bytes to show (default: :infinity)

  ## Examples

      iex> PtcRunner.Lisp.Format.to_clojure(42)
      {"42", false}

      iex> PtcRunner.Lisp.Format.to_clojure([1, 2, 3])
      {"[1 2 3]", false}

      iex> PtcRunner.Lisp.Format.to_clojure(%{id: 101, count: 45})
      {"{:count 45 :id 101}", false}

      iex> PtcRunner.Lisp.Format.to_clojure(%{"name" => "Alice", "age" => 30})
      {~s({"age" 30 "name" "Alice"}), false}

      iex> PtcRunner.Lisp.Format.to_clojure({:closure, [{:var, :x}], nil, %{}, []})
      {"#fn[x]", false}

      iex> PtcRunner.Lisp.Format.to_clojure({:var, :x})
      {"#'x", false}

      iex> PtcRunner.Lisp.Format.to_clojure(nil)
      {"nil", false}

      iex> PtcRunner.Lisp.Format.to_clojure(:keyword)
      {":keyword", false}

      iex> PtcRunner.Lisp.Format.to_clojure([%{a: 1}, %{b: 2}])
      {"[{:a 1} {:b 2}]", false}

      iex> PtcRunner.Lisp.Format.to_clojure([1, 2, 3, 4, 5], limit: 2)
      {"[1 2 ...] (5 items, showing first 2)", true}

      iex> PtcRunner.Lisp.Format.to_clojure("very long string here", printable_limit: 10)
      {~s("very long ..."), true}
  """
  @spec to_clojure(term(), keyword()) :: {String.t(), boolean()}
  def to_clojure(value, opts \\ []) do
    value
    |> sanitize()
    |> format_clojure(opts)
  end

  # Format a value as Clojure syntax - returns {string, truncated?}
  defp format_clojure(nil, _opts), do: {"nil", false}
  defp format_clojure(true, _opts), do: {"true", false}
  defp format_clojure(false, _opts), do: {"false", false}
  defp format_clojure(n, _opts) when is_integer(n), do: {Integer.to_string(n), false}
  defp format_clojure(f, _opts) when is_float(f), do: {Float.to_string(f), false}
  defp format_clojure(s, opts) when is_binary(s), do: format_clojure_string(s, opts)
  defp format_clojure(a, _opts) when is_atom(a), do: {":#{a}", false}

  defp format_clojure(%Fn{params: params}, _opts), do: {"#fn[#{params}]", false}
  defp format_clojure(%Builtin{}, _opts), do: {"#<builtin>", false}
  defp format_clojure(%Var{name: name}, _opts), do: {"#'#{name}", false}

  # Structs (other than our wrapper types) pass through to inspect
  defp format_clojure(%MapSet{} = set, opts) do
    limit = Keyword.get(opts, :limit, :infinity)
    items = MapSet.to_list(set)
    {to_show, set_truncated} = apply_limit(items, limit)

    {formatted_items, any_child_truncated} =
      Enum.map_reduce(to_show, false, fn item, acc ->
        {str, truncated} = format_clojure(item, opts)
        {str, acc or truncated}
      end)

    formatted = Enum.join(formatted_items, " ")

    if set_truncated do
      total = MapSet.size(set)
      {"\#{#{formatted} ...} (#{total} items, showing first #{limit})", true}
    else
      {"\#{#{formatted}}", any_child_truncated}
    end
  end

  defp format_clojure(%_{} = struct, _opts), do: {inspect(struct), false}

  defp format_clojure(list, opts) when is_list(list) do
    limit = Keyword.get(opts, :limit, :infinity)
    {items, list_truncated} = apply_limit(list, limit)

    {formatted_items, any_child_truncated} =
      Enum.map_reduce(items, false, fn item, acc ->
        {str, truncated} = format_clojure(item, opts)
        {str, acc or truncated}
      end)

    formatted = Enum.join(formatted_items, " ")

    if list_truncated do
      total = length(list)
      {"[#{formatted} ...] (#{total} items, showing first #{limit})", true}
    else
      {"[#{formatted}]", any_child_truncated}
    end
  end

  defp format_clojure(map, opts) when is_map(map) do
    limit = Keyword.get(opts, :limit, :infinity)
    printable_limit = Keyword.get(opts, :printable_limit, :infinity)
    # Sort keys for consistent output
    entries = map |> Map.to_list() |> Enum.sort_by(&elem(&1, 0))

    # Auto-reduce entry limit when printable_limit is too small for all entries
    # Each entry needs ~30 chars minimum (key ~10 + value preview ~20)
    effective_limit =
      case {printable_limit, limit} do
        {:infinity, l} ->
          l

        {total, :infinity} ->
          min_per_entry = 30
          max(div(total, min_per_entry), 1)

        {total, l} ->
          min_per_entry = 30
          min(l, max(div(total, min_per_entry), 1))
      end

    {items, map_truncated} = apply_limit(entries, effective_limit)

    # Distribute printable_limit across values
    # Reserve ~10 chars per key for key name + formatting overhead
    value_opts =
      case {printable_limit, length(items)} do
        {:infinity, _} ->
          opts

        {total_limit, n} when n > 0 ->
          overhead_per_entry = 10
          available = max(total_limit - n * overhead_per_entry, 0)
          per_value_limit = max(div(available, n), 10)
          Keyword.put(opts, :printable_limit, per_value_limit)

        _ ->
          opts
      end

    {formatted_items, any_child_truncated} =
      Enum.map_reduce(items, false, fn {k, v}, acc ->
        {v_str, v_truncated} = format_clojure(v, value_opts)
        {"#{format_clojure_key(k)} #{v_str}", acc or v_truncated}
      end)

    formatted = Enum.join(formatted_items, " ")

    if map_truncated do
      total = map_size(map)
      {"{#{formatted} ...} (#{total} entries, showing first #{length(items)})", true}
    else
      {"{#{formatted}}", any_child_truncated}
    end
  end

  defp format_clojure(tuple, opts) when is_tuple(tuple) do
    # Tuples rendered as vectors (consistent with PTC-Lisp)
    list = Tuple.to_list(tuple)
    format_clojure(list, opts)
  end

  # Format map keys - atoms as keywords, strings as strings
  defp format_clojure_key(k) when is_atom(k), do: ":#{k}"
  defp format_clojure_key(k) when is_binary(k), do: inspect(k)

  defp format_clojure_key(k) do
    {str, _truncated} = format_clojure(k, [])
    str
  end

  # Format strings with printable_limit - returns {string, truncated?}
  defp format_clojure_string(s, opts) do
    limit = Keyword.get(opts, :printable_limit, :infinity)

    case limit do
      :infinity ->
        {inspect(s), false}

      n when byte_size(s) > n ->
        {inspect(String.slice(s, 0, n) <> "..."), true}

      _ ->
        {inspect(s), false}
    end
  end

  # Apply limit to a list, returning {kept_items, was_truncated?}
  defp apply_limit(list, :infinity), do: {list, false}

  defp apply_limit(list, limit) when is_integer(limit) do
    if length(list) > limit do
      {Enum.take(list, limit), true}
    else
      {list, false}
    end
  end

  # Recursively replace internal types with inspectable wrappers
  defp sanitize({:closure, params, _body, _env, _history}) do
    names = Enum.map_join(params, " ", &extract_param_name/1)
    %Fn{params: names}
  end

  defp sanitize({:normal, fun}) when is_function(fun), do: %Builtin{}
  defp sanitize({:variadic, fun, _identity}) when is_function(fun), do: %Builtin{}

  defp sanitize({:variadic_nonempty, name, fun}) when is_atom(name) and is_function(fun),
    do: %Builtin{}

  defp sanitize({:multi_arity, name, funs}) when is_atom(name) and is_tuple(funs), do: %Builtin{}
  defp sanitize({:collect, fun}) when is_function(fun), do: %Builtin{}

  # Var references - convert to Var struct for display
  defp sanitize({:var, name}) when is_atom(name), do: %Var{name: name}

  # Pass through wrapper structs unchanged (they're already sanitized)
  defp sanitize(%Var{} = v), do: v
  defp sanitize(%Fn{} = f), do: f
  defp sanitize(%Builtin{} = b), do: b

  # Exclude structs (MapSet, DateTime, etc.) - they enumerate differently
  defp sanitize(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {k, sanitize(v)} end)
  end

  # Structs pass through unchanged (let Inspect handle them)
  defp sanitize(%_{} = struct), do: struct

  defp sanitize(list) when is_list(list) do
    Enum.map(list, &sanitize/1)
  end

  defp sanitize(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&sanitize/1)
    |> List.to_tuple()
  end

  defp sanitize({:re_mp, _mp, _anchored, source}), do: "#\"#{source}\""
  defp sanitize(value), do: value

  # Extract parameter name from pattern AST
  defp extract_param_name({:var, name}), do: Atom.to_string(name)
  defp extract_param_name({:destructure, _}), do: "_"
  defp extract_param_name(_), do: "_"
end
