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

  ## Options

  - `:limit` - Maximum items to show in collections (default: :infinity)
  - `:printable_limit` - Maximum string bytes to show (default: :infinity)

  ## Examples

      iex> PtcRunner.Lisp.Format.to_clojure(42)
      "42"

      iex> PtcRunner.Lisp.Format.to_clojure([1, 2, 3])
      "[1 2 3]"

      iex> PtcRunner.Lisp.Format.to_clojure(%{id: 101, count: 45})
      "{:count 45 :id 101}"

      iex> PtcRunner.Lisp.Format.to_clojure(%{"name" => "Alice", "age" => 30})
      ~s({"age" 30 "name" "Alice"})

      iex> PtcRunner.Lisp.Format.to_clojure({:closure, [{:var, :x}], nil, %{}, []})
      "#fn[x]"

      iex> PtcRunner.Lisp.Format.to_clojure(nil)
      "nil"

      iex> PtcRunner.Lisp.Format.to_clojure(:keyword)
      ":keyword"

      iex> PtcRunner.Lisp.Format.to_clojure([%{a: 1}, %{b: 2}])
      "[{:a 1} {:b 2}]"
  """
  @spec to_clojure(term(), keyword()) :: String.t()
  def to_clojure(value, opts \\ []) do
    value
    |> sanitize()
    |> format_clojure(opts)
  end

  # Format a value as Clojure syntax
  defp format_clojure(nil, _opts), do: "nil"
  defp format_clojure(true, _opts), do: "true"
  defp format_clojure(false, _opts), do: "false"
  defp format_clojure(n, _opts) when is_integer(n), do: Integer.to_string(n)
  defp format_clojure(f, _opts) when is_float(f), do: Float.to_string(f)
  defp format_clojure(s, opts) when is_binary(s), do: format_clojure_string(s, opts)
  defp format_clojure(a, _opts) when is_atom(a), do: ":#{a}"

  defp format_clojure(%Fn{params: params}, _opts), do: "#fn[#{params}]"
  defp format_clojure(%Builtin{}, _opts), do: "#<builtin>"

  defp format_clojure(list, opts) when is_list(list) do
    limit = Keyword.get(opts, :limit, :infinity)
    {items, truncated} = apply_limit(list, limit)
    formatted = Enum.map_join(items, " ", &format_clojure(&1, opts))

    if truncated do
      "[#{formatted} ...]"
    else
      "[#{formatted}]"
    end
  end

  defp format_clojure(map, opts) when is_map(map) do
    limit = Keyword.get(opts, :limit, :infinity)
    # Sort keys for consistent output
    entries = map |> Map.to_list() |> Enum.sort_by(&elem(&1, 0))
    {items, truncated} = apply_limit(entries, limit)

    formatted =
      Enum.map_join(items, " ", fn {k, v} ->
        "#{format_clojure_key(k)} #{format_clojure(v, opts)}"
      end)

    if truncated do
      "{#{formatted} ...}"
    else
      "{#{formatted}}"
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
  defp format_clojure_key(k), do: format_clojure(k, [])

  # Format strings with printable_limit
  defp format_clojure_string(s, opts) do
    limit = Keyword.get(opts, :printable_limit, :infinity)

    truncated =
      case limit do
        :infinity -> s
        n when byte_size(s) > n -> String.slice(s, 0, n) <> "..."
        _ -> s
      end

    inspect(truncated)
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
  defp sanitize({:variadic_nonempty, fun}) when is_function(fun), do: %Builtin{}
  defp sanitize({:multi_arity, funs}) when is_tuple(funs), do: %Builtin{}

  defp sanitize(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, sanitize(v)} end)
  end

  defp sanitize(list) when is_list(list) do
    Enum.map(list, &sanitize/1)
  end

  defp sanitize(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&sanitize/1)
    |> List.to_tuple()
  end

  defp sanitize(value), do: value

  # Extract parameter name from pattern AST
  defp extract_param_name({:var, name}), do: Atom.to_string(name)
  defp extract_param_name({:destructure, _}), do: "_"
  defp extract_param_name(_), do: "_"
end
