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
