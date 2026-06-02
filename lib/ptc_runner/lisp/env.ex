defmodule PtcRunner.Lisp.Env do
  @moduledoc """
  Builds the initial environment with builtins for PTC-Lisp.

  Provides the foundation environment with all builtin functions
  and their descriptors. The environment supports multiple binding types:

  - `{:normal, fun}` - Fixed-arity function
  - `{:variadic, fun, identity}` - Variadic function with identity value for 0-arg case
  - `{:variadic_nonempty, name, fun}` - Variadic function requiring at least 1 argument
  - `{:multi_arity, name, tuple_of_funs}` - Multiple arities where tuple index = arity - min_arity
  - `{:collect, fun}` - Collects all args into a list and passes to unary function
  """

  alias PtcRunner.Lisp.Env.Builtin
  alias PtcRunner.Lisp.Runtime.Builtins

  @type binding ::
          Builtin.t()
          | {:normal, function()}
          | {:variadic, function(), term()}
          | {:variadic_nonempty, atom(), function()}
          | {:multi_arity, atom(), tuple()}
          | {:collect, function()}
          | {:constant, term()}
  @type env :: %{atom() => binding()}

  @spec initial() :: env()
  def initial do
    case :persistent_term.get({__MODULE__, :initial}, :unset) do
      :unset ->
        env = Builtins.bindings() |> Enum.map(&wrap_builtin_binding/1) |> Map.new()
        :persistent_term.put({__MODULE__, :initial}, env)
        env

      env ->
        env
    end
  end

  @doc """
  Check if a name is a builtin function.

  Returns `true` if the given atom is a builtin function name.

  ## Examples

      iex> PtcRunner.Lisp.Env.builtin?(:map)
      true

      iex> PtcRunner.Lisp.Env.builtin?(:filter)
      true

      iex> PtcRunner.Lisp.Env.builtin?(:my_var)
      false
  """
  @spec builtin?(atom() | String.t()) :: boolean()
  def builtin?(name) when is_atom(name) do
    Map.has_key?(initial(), name)
  end

  # Binary names are never builtins by construction — `SourceAtoms.intern/1`
  # would have returned an atom if the name matched the bounded vocabulary.
  def builtin?(name) when is_binary(name), do: false

  # ============================================================
  # Clojure namespace compatibility
  # ============================================================

  # Map Clojure-style namespaces to function categories for suggestions
  @clojure_namespaces %{
    :"clojure.string" => :string,
    :str => :string,
    :string => :string,
    :"clojure.core" => :core,
    :core => :core,
    :"clojure.set" => :set,
    :set => :set,
    :"clojure.walk" => :walk,
    :walk => :walk,
    :regex => :regex,
    :Math => :math,
    :System => :interop,
    :Boolean => :interop,
    :Float => :interop,
    :Integer => :interop,
    :Long => :interop,
    :"java.time.LocalDate" => :interop,
    :LocalDate => :interop,
    # `Instant/parse` and `LocalDate/parse` both resolve to the `parse`
    # builtin, which auto-dispatches on the string shape (Date vs DateTime).
    :"java.time.Instant" => :interop,
    :Instant => :interop,
    :"java.time.Duration" => :interop,
    :Duration => :interop,
    :Double => :interop,
    :json => :json
  }

  @doc """
  Check if a namespace is a known Clojure-style namespace.

  ## Examples

      iex> PtcRunner.Lisp.Env.clojure_namespace?(:"clojure.string")
      true

      iex> PtcRunner.Lisp.Env.clojure_namespace?(:str)
      true

      iex> PtcRunner.Lisp.Env.clojure_namespace?(:my_ns)
      false
  """
  @spec clojure_namespace?(atom()) :: boolean()
  def clojure_namespace?(ns), do: Map.has_key?(@clojure_namespaces, ns)

  @doc """
  Get the category for a Clojure-style namespace.

  Returns `:string`, `:set`, or `:core`.

  ## Examples

      iex> PtcRunner.Lisp.Env.namespace_category(:"clojure.string")
      :string

      iex> PtcRunner.Lisp.Env.namespace_category(:str)
      :string
  """
  @spec namespace_category(atom()) :: atom() | nil
  def namespace_category(ns), do: Map.get(@clojure_namespaces, ns)

  @doc """
  Check if a name is a namespaced constant.
  """
  def constant?(ns, name) do
    clojure_namespace?(ns) and Map.has_key?(initial(), name) and
      match?({:constant, _}, Map.get(initial(), name))
  end

  defp wrap_builtin_binding({name, {tag, _} = binding})
       when tag in [:normal, :collect] do
    {name, Builtin.wrap(name, binding, args_spec(name))}
  end

  defp wrap_builtin_binding({name, {tag, _, _} = binding})
       when tag in [:variadic, :variadic_nonempty, :multi_arity] do
    {name, Builtin.wrap(name, binding, args_spec(name))}
  end

  defp wrap_builtin_binding(other), do: other

  # A single collection is returned unchanged (Clojure's one-arg identity,
  # GAP-S146), so only validate as maps once 2+ collections are supplied.
  defp args_spec(:merge), do: {:rest_min2, :map_or_nil}
  # A single collection is returned unchanged (Clojure's one-arg identity,
  # GAP-S146), so the maps are validated only once 2+ are supplied; a
  # multi-collection non-map arg then fails this spec with the canonical
  # "expected map" type error.
  defp args_spec(:"merge-with"), do: {:min, 1, [:callable], {:rest_min2, :map_or_nil}}

  defp args_spec(:get),
    do: {:arity, %{2 => [:associative_or_nil, :any], 3 => [:associative_or_nil, :any, :any]}}

  defp args_spec(:"get-in"),
    do:
      {:arity,
       %{2 => [:associative_or_nil, :seqable], 3 => [:associative_or_nil, :seqable, :any]}}

  defp args_spec(:assoc), do: {:min, 1, [:map_or_list_or_nil], {:rest, :any}}
  defp args_spec(:"assoc-in"), do: [:any, :seqable, :any]
  defp args_spec(:update), do: {:min, 3, [:map_or_list, :any, :callable], {:rest, :any}}
  defp args_spec(:"update-in"), do: {:min, 3, [:any, :seqable, :callable], {:rest, :any}}
  defp args_spec(:dissoc), do: {:min, 1, [:map_or_nil], {:rest, :any}}
  defp args_spec(:"select-keys"), do: [:map_or_nil, :seqable]
  defp args_spec(:keys), do: [:map_or_nil]
  defp args_spec(:vals), do: [:map_or_nil]
  defp args_spec(:"update-vals"), do: [:map_or_nil, :callable]
  defp args_spec(:"update-keys"), do: [:map_or_nil, :callable]
  defp args_spec(:"reduce-kv"), do: [:callable, :any, :map_or_nil]
  defp args_spec(:zipmap), do: [:seqable, :seqable]

  defp args_spec(:filter), do: [:predicate, :seqable]
  defp args_spec(:remove), do: [:predicate, :seqable]

  defp args_spec(:map),
    do:
      {:arity,
       %{
         2 => [:keyfn, :seqable],
         3 => [:callable, :seqable, :seqable],
         4 => [:callable, :seqable, :seqable, :seqable]
       }}

  defp args_spec(:mapv), do: args_spec(:map)
  defp args_spec(:mapcat), do: [:callable, :seqable]
  defp args_spec(:keep), do: [:keyfn, :seqable]
  defp args_spec(:sort), do: {:arity, %{1 => [:seqable], 2 => [:callable, :seqable]}}

  defp args_spec(:"sort-by"),
    do: {:arity, %{2 => [:sort_keyfn, :seqable], 3 => [:sort_keyfn, :callable, :seqable]}}

  defp args_spec(:take), do: [:integer, :seqable]
  defp args_spec(:drop), do: [:integer, :seqable]
  defp args_spec(:count), do: [:seqable]
  defp args_spec(:concat), do: {:rest, :seqable}
  defp args_spec(:into), do: [:any, :seqable]

  defp args_spec(:reduce),
    do: {:arity, %{2 => [:callable, :seqable], 3 => [:callable, :any, :seqable]}}

  defp args_spec(_name), do: :unchecked

  @doc """
  Get the list of builtin functions for a category.

  Delegates to `PtcRunner.Lisp.Registry.builtins_by_category/1`.

  ## Examples

      iex> :join in PtcRunner.Lisp.Env.builtins_by_category(:string)
      true

      iex> :set in PtcRunner.Lisp.Env.builtins_by_category(:set)
      true
  """
  defdelegate builtins_by_category(category), to: PtcRunner.Lisp.Registry
  defdelegate builtins_by_namespace(ns), to: PtcRunner.Lisp.Registry

  @doc """
  Get a human-readable name for a category.

  Delegates to `PtcRunner.Lisp.Registry.category_name/1`.

  ## Examples

      iex> PtcRunner.Lisp.Env.category_name(:string)
      "String"

      iex> PtcRunner.Lisp.Env.category_name(:core)
      "Core"
  """
  defdelegate category_name(category), to: PtcRunner.Lisp.Registry
end
