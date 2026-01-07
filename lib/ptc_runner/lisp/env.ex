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

  alias PtcRunner.Lisp.Runtime

  @type binding ::
          {:normal, function()}
          | {:variadic, function(), term()}
          | {:variadic_nonempty, atom(), function()}
          | {:multi_arity, atom(), tuple()}
          | {:collect, function()}
  @type env :: %{atom() => binding()}

  @spec initial() :: env()
  def initial do
    builtin_bindings() |> Map.new()
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
  @spec builtin?(atom()) :: boolean()
  def builtin?(name) when is_atom(name) do
    Map.has_key?(initial(), name)
  end

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
    :regex => :regex,
    :Math => :math
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
  Get the list of builtin functions for a category.

  Used to provide helpful error messages when a function is not available.

  ## Examples

      iex> :join in PtcRunner.Lisp.Env.builtins_by_category(:string)
      true

      iex> :set in PtcRunner.Lisp.Env.builtins_by_category(:set)
      true
  """
  @spec builtins_by_category(atom()) :: [atom()]
  def builtins_by_category(:string) do
    [
      :str,
      :subs,
      :join,
      :split,
      :trim,
      :replace,
      :upcase,
      :"upper-case",
      :downcase,
      :"lower-case",
      :"starts-with?",
      :"ends-with?",
      :includes?,
      :"parse-long",
      :"parse-double"
    ]
  end

  def builtins_by_category(:set) do
    [:set, :set?, :vec, :vector, :contains?, :intersection, :union, :difference]
  end

  def builtins_by_category(:regex) do
    [:"re-pattern", :"re-find", :"re-matches", :regex?]
  end

  def builtins_by_category(:math) do
    [:sqrt, :pow, :abs, :floor, :ceil, :round, :trunc, :double, :int, :max, :min]
  end

  def builtins_by_category(:core) do
    # All other builtins (collection, arithmetic, logic, etc.)
    excluded =
      builtins_by_category(:string) ++
        builtins_by_category(:set) ++
        builtins_by_category(:regex) ++
        builtins_by_category(:math)

    (Map.keys(initial()) -- excluded) ++ [:doseq]
  end

  @doc """
  Get a human-readable name for a category.

  ## Examples

      iex> PtcRunner.Lisp.Env.category_name(:string)
      "String"

      iex> PtcRunner.Lisp.Env.category_name(:core)
      "Core"
  """
  @spec category_name(atom()) :: String.t()
  def category_name(:string), do: "String"
  def category_name(:set), do: "Set"
  def category_name(:regex), do: "Regex"
  def category_name(:math), do: "Math"
  def category_name(:core), do: "Core"

  defp builtin_bindings do
    [
      {:apply, {:special, :apply}},
      {:println, {:special, :println}},
      # ============================================================
      # Collection operations (normal arity)
      # ============================================================
      {:filter, {:normal, &Runtime.filter/2}},
      {:remove, {:normal, &Runtime.remove/2}},
      {:find, {:normal, &Runtime.find/2}},
      {:map, {:normal, &Runtime.map/2}},
      {:mapv, {:normal, &Runtime.mapv/2}},
      {:"map-indexed", {:normal, &Runtime.map_indexed/2}},
      {:pluck, {:normal, &Runtime.pluck/2}},
      {:sort, {:multi_arity, :sort, {&Runtime.sort/1, &Runtime.sort/2}}},
      # sort-by: 2-arity (key, coll) or 3-arity (key, comparator, coll)
      {:"sort-by", {:multi_arity, :"sort-by", {&Runtime.sort_by/2, &Runtime.sort_by/3}}},
      {:reverse, {:normal, &Runtime.reverse/1}},
      {:first, {:normal, &Runtime.first/1}},
      {:second, {:normal, &Runtime.second/1}},
      {:last, {:normal, &Runtime.last/1}},
      {:nth, {:normal, &Runtime.nth/2}},
      {:rest, {:normal, &Runtime.rest/1}},
      {:next, {:normal, &Runtime.next/1}},
      {:ffirst, {:normal, &Runtime.ffirst/1}},
      {:fnext, {:normal, &Runtime.fnext/1}},
      {:nfirst, {:normal, &Runtime.nfirst/1}},
      {:nnext, {:normal, &Runtime.nnext/1}},
      {:take, {:normal, &Runtime.take/2}},
      {:drop, {:normal, &Runtime.drop/2}},
      {:"take-while", {:normal, &Runtime.take_while/2}},
      {:"drop-while", {:normal, &Runtime.drop_while/2}},
      {:distinct, {:normal, &Runtime.distinct/1}},
      {:concat, {:variadic, &Runtime.concat2/2, []}},
      {:conj, {:variadic_nonempty, :conj, &Runtime.conj/2}},
      {:into, {:normal, &Runtime.into/2}},
      {:flatten, {:normal, &Runtime.flatten/1}},
      {:zip, {:normal, &Runtime.zip/2}},
      {:interleave, {:normal, &Runtime.interleave/2}},
      {:count, {:normal, &Runtime.count/1}},
      {:empty?, {:normal, &Runtime.empty?/1}},
      {:seq, {:normal, &Runtime.seq/1}},
      {:reduce, {:multi_arity, :reduce, {&Runtime.reduce/2, &Runtime.reduce/3}}},
      {:"sum-by", {:normal, &Runtime.sum_by/2}},
      {:"avg-by", {:normal, &Runtime.avg_by/2}},
      {:"min-by", {:normal, &Runtime.min_by/2}},
      {:"max-by", {:normal, &Runtime.max_by/2}},
      {:"group-by", {:normal, &Runtime.group_by/2}},
      {:frequencies, {:normal, &Runtime.frequencies/1}},
      {:some, {:normal, &Runtime.some/2}},
      {:every?, {:normal, &Runtime.every?/2}},
      {:"not-any?", {:normal, &Runtime.not_any?/2}},
      {:contains?, {:normal, &Runtime.contains?/2}},
      {:range, {:multi_arity, :range, {&Runtime.range/1, &Runtime.range/2, &Runtime.range/3}}},

      # ============================================================
      # Map operations
      # ============================================================
      {:get, {:multi_arity, :get, {&Runtime.get/2, &Runtime.get/3}}},
      {:"get-in", {:multi_arity, :"get-in", {&Runtime.get_in/2, &Runtime.get_in/3}}},
      {:assoc, {:normal, &Runtime.assoc/3}},
      {:"assoc-in", {:normal, &Runtime.assoc_in/3}},
      {:update, {:normal, &Runtime.update/3}},
      {:"update-in", {:normal, &Runtime.update_in/3}},
      {:dissoc, {:normal, &Runtime.dissoc/2}},
      {:merge, {:variadic, &Runtime.merge/2, %{}}},
      {:"select-keys", {:normal, &Runtime.select_keys/2}},
      {:keys, {:normal, &Runtime.keys/1}},
      {:vals, {:normal, &Runtime.vals/1}},
      {:entries, {:normal, &Runtime.entries/1}},
      {:"update-vals", {:normal, &Runtime.update_vals/2}},

      # ============================================================
      # Utility functions
      # ============================================================
      {:identity, {:normal, &Runtime.identity/1}},

      # ============================================================
      # Arithmetic — variadic with identity
      # ============================================================
      {:+, {:variadic, &Kernel.+/2, 0}},
      {:-, {:variadic, &Kernel.-/2, 0}},
      {:*, {:variadic, &Kernel.*/2, 1}},
      {:/, {:variadic_nonempty, :/, &Kernel.//2}},
      {:mod, {:normal, &Runtime.mod/2}},
      {:inc, {:normal, &Runtime.inc/1}},
      {:dec, {:normal, &Runtime.dec/1}},
      {:abs, {:normal, &Runtime.abs/1}},
      {:max, {:variadic_nonempty, :max, &Runtime.max/2}},
      {:min, {:variadic_nonempty, :min, &Runtime.min/2}},
      {:floor, {:normal, &Runtime.floor/1}},
      {:ceil, {:normal, &Runtime.ceil/1}},
      {:round, {:normal, &Runtime.round/1}},
      {:trunc, {:normal, &Runtime.trunc/1}},
      {:double, {:normal, &Runtime.double/1}},
      {:int, {:normal, &Runtime.int/1}},
      {:sqrt, {:normal, &Runtime.sqrt/1}},
      {:pow, {:normal, &Runtime.pow/2}},

      # ============================================================
      # Comparison — normal (binary)
      # ============================================================
      {:=, {:normal, &Kernel.==/2}},
      {:"not=", {:normal, &Kernel.!=/2}},
      {:>, {:normal, &Kernel.>/2}},
      {:<, {:normal, &Kernel.</2}},
      {:>=, {:normal, &Kernel.>=/2}},
      {:<=, {:normal, &Kernel.<=/2}},
      {:compare, {:normal, &Runtime.compare/2}},

      # ============================================================
      # Logic
      # ============================================================
      {:not, {:normal, &Runtime.not_/1}},

      # ============================================================
      # Type predicates
      # ============================================================
      {:nil?, {:normal, &is_nil/1}},
      {:some?, {:normal, fn x -> not is_nil(x) end}},
      {:boolean?, {:normal, &is_boolean/1}},
      {:number?, {:normal, &is_number/1}},
      {:string?, {:normal, &is_binary/1}},
      {:char?, {:normal, &Runtime.char?/1}},
      {:keyword?, {:normal, fn x -> is_atom(x) and x not in [nil, true, false] end}},
      {:vector?, {:normal, &is_list/1}},
      {:set?, {:normal, &Runtime.set?/1}},
      {:set, {:normal, &Runtime.set/1}},
      {:vec, {:normal, &Runtime.vec/1}},
      {:vector, {:collect, &Function.identity/1}},
      {:map?, {:normal, &Runtime.map?/1}},
      {:coll?, {:normal, &is_list/1}},

      # ============================================================
      # String manipulation
      # ============================================================
      {:str, {:variadic, &Runtime.str2/2, ""}},
      {:subs, {:multi_arity, :subs, {&Runtime.subs/2, &Runtime.subs/3}}},
      {:join, {:multi_arity, :join, {&Runtime.join/1, &Runtime.join/2}}},
      {:split, {:normal, &Runtime.split/2}},
      {:trim, {:normal, &Runtime.trim/1}},
      {:replace, {:normal, &Runtime.replace/3}},
      {:upcase, {:normal, &Runtime.upcase/1}},
      {:"upper-case", {:normal, &Runtime.upcase/1}},
      {:downcase, {:normal, &Runtime.downcase/1}},
      {:"lower-case", {:normal, &Runtime.downcase/1}},
      {:"starts-with?", {:normal, &Runtime.starts_with?/2}},
      {:"ends-with?", {:normal, &Runtime.ends_with?/2}},
      {:includes?, {:normal, &Runtime.includes?/2}},

      # ============================================================
      # String parsing
      # ============================================================
      {:"parse-long", {:normal, &Runtime.parse_long/1}},
      {:"parse-double", {:normal, &Runtime.parse_double/1}},

      # ============================================================
      # Regex operations
      # ============================================================
      {:"re-pattern", {:normal, &Runtime.re_pattern/1}},
      {:"re-find", {:normal, &Runtime.re_find/2}},
      {:"re-matches", {:normal, &Runtime.re_matches/2}},
      {:regex?, {:normal, &Runtime.regex?/1}},

      # ============================================================
      # Numeric predicates
      # ============================================================
      {:zero?, {:normal, fn x -> x == 0 end}},
      {:pos?, {:normal, fn x -> x > 0 end}},
      {:neg?, {:normal, fn x -> x < 0 end}},
      {:even?, {:normal, fn x -> rem(x, 2) == 0 end}},
      {:odd?, {:normal, fn x -> rem(x, 2) != 0 end}},

      # ============================================================
      # Set Operations
      # ============================================================
      {:intersection, {:variadic_nonempty, :intersection, &Runtime.intersection/2}},
      {:union, {:variadic, &Runtime.union/2, MapSet.new()}},
      {:difference, {:variadic_nonempty, :difference, &Runtime.difference/2}}
    ]
  end
end
