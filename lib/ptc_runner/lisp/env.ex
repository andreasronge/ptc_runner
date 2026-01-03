defmodule PtcRunner.Lisp.Env do
  @moduledoc """
  Builds the initial environment with builtins for PTC-Lisp.

  Provides the foundation environment with all builtin functions
  and their descriptors. The environment supports multiple binding types:

  - `{:normal, fun}` - Fixed-arity function
  - `{:variadic, fun, identity}` - Variadic function with identity value for 0-arg case
  - `{:variadic_nonempty, fun}` - Variadic function requiring at least 1 argument
  - `{:multi_arity, tuple_of_funs}` - Multiple arities where tuple index = arity - min_arity
  """

  alias PtcRunner.Lisp.Runtime

  @type binding ::
          {:normal, function()}
          | {:variadic, function(), term()}
          | {:variadic_nonempty, function()}
          | {:multi_arity, tuple()}
  @type env :: %{atom() => binding()}

  @spec initial() :: env()
  def initial do
    builtin_bindings() |> Map.new()
  end

  defp builtin_bindings do
    [
      # ============================================================
      # Collection operations (normal arity)
      # ============================================================
      {:filter, {:normal, &Runtime.filter/2}},
      {:remove, {:normal, &Runtime.remove/2}},
      {:find, {:normal, &Runtime.find/2}},
      {:map, {:normal, &Runtime.map/2}},
      {:mapv, {:normal, &Runtime.mapv/2}},
      {:pluck, {:normal, &Runtime.pluck/2}},
      {:sort, {:normal, &Runtime.sort/1}},
      # sort-by: 2-arity (key, coll) or 3-arity (key, comparator, coll)
      {:"sort-by", {:multi_arity, {&Runtime.sort_by/2, &Runtime.sort_by/3}}},
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
      {:conj, {:variadic_nonempty, &Runtime.conj/2}},
      {:into, {:normal, &Runtime.into/2}},
      {:flatten, {:normal, &Runtime.flatten/1}},
      {:zip, {:normal, &Runtime.zip/2}},
      {:interleave, {:normal, &Runtime.interleave/2}},
      {:count, {:normal, &Runtime.count/1}},
      {:empty?, {:normal, &Runtime.empty?/1}},
      {:seq, {:normal, &Runtime.seq/1}},
      {:reduce, {:multi_arity, {&Runtime.reduce/2, &Runtime.reduce/3}}},
      {:"sum-by", {:normal, &Runtime.sum_by/2}},
      {:"avg-by", {:normal, &Runtime.avg_by/2}},
      {:"min-by", {:normal, &Runtime.min_by/2}},
      {:"max-by", {:normal, &Runtime.max_by/2}},
      {:"group-by", {:normal, &Runtime.group_by/2}},
      {:some, {:normal, &Runtime.some/2}},
      {:every?, {:normal, &Runtime.every?/2}},
      {:"not-any?", {:normal, &Runtime.not_any?/2}},
      {:contains?, {:normal, &Runtime.contains?/2}},

      # ============================================================
      # Map operations
      # ============================================================
      {:get, {:multi_arity, {&Runtime.get/2, &Runtime.get/3}}},
      {:"get-in", {:multi_arity, {&Runtime.get_in/2, &Runtime.get_in/3}}},
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
      {:/, {:variadic_nonempty, &Kernel.//2}},
      {:mod, {:normal, &Runtime.mod/2}},
      {:inc, {:normal, &Runtime.inc/1}},
      {:dec, {:normal, &Runtime.dec/1}},
      {:abs, {:normal, &Runtime.abs/1}},
      {:max, {:variadic_nonempty, &Kernel.max/2}},
      {:min, {:variadic_nonempty, &Kernel.min/2}},
      {:floor, {:normal, &Runtime.floor/1}},
      {:ceil, {:normal, &Runtime.ceil/1}},
      {:round, {:normal, &Runtime.round/1}},
      {:trunc, {:normal, &Runtime.trunc/1}},

      # ============================================================
      # Comparison — normal (binary)
      # ============================================================
      {:=, {:normal, &Kernel.==/2}},
      {:"not=", {:normal, &Kernel.!=/2}},
      {:>, {:normal, &Kernel.>/2}},
      {:<, {:normal, &Kernel.</2}},
      {:>=, {:normal, &Kernel.>=/2}},
      {:<=, {:normal, &Kernel.<=/2}},

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
      {:keyword?, {:normal, fn x -> is_atom(x) and x not in [nil, true, false] end}},
      {:vector?, {:normal, &is_list/1}},
      {:set?, {:normal, &Runtime.set?/1}},
      {:set, {:normal, &Runtime.set/1}},
      {:map?, {:normal, &Runtime.map?/1}},
      {:coll?, {:normal, &is_list/1}},

      # ============================================================
      # String manipulation
      # ============================================================
      {:str, {:variadic, &Runtime.str2/2, ""}},
      {:subs, {:multi_arity, {&Runtime.subs/2, &Runtime.subs/3}}},
      {:join, {:multi_arity, {&Runtime.join/1, &Runtime.join/2}}},
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
      # Numeric predicates
      # ============================================================
      {:zero?, {:normal, fn x -> x == 0 end}},
      {:pos?, {:normal, fn x -> x > 0 end}},
      {:neg?, {:normal, fn x -> x < 0 end}},
      {:even?, {:normal, fn x -> rem(x, 2) == 0 end}},
      {:odd?, {:normal, fn x -> rem(x, 2) != 0 end}}
    ]
  end
end
