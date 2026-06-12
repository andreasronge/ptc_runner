defmodule PtcRunner.Lisp.Runtime.Builtins do
  @moduledoc """
  The manifest of PTC-Lisp builtin bindings exposed by the Runtime subsystem.

  Owns the flat `{name, binding}` table that maps builtin names to their
  `&Runtime.*` implementations. `PtcRunner.Lisp.Env` consumes `bindings/0` to
  build the initial environment, keeping `Env` decoupled from the `Runtime`
  facade.

  Binding tuple shapes are documented in `PtcRunner.Lisp.Env`.
  """

  alias PtcRunner.Lisp.Runtime

  @spec bindings() :: [{atom(), tuple()}]
  def bindings do
    [
      {:apply, {:special, :apply}},
      {:println, {:special, :println}},
      # ============================================================
      # Collection operations (normal arity)
      # ============================================================
      {:filter, {:normal, &Runtime.filter/2}},
      {:remove, {:normal, &Runtime.remove/2}},
      {:keep, {:normal, &Runtime.keep/2}},
      {:find, {:normal, &Runtime.find/2}},
      {:map, {:multi_arity, :map, {&Runtime.map/2, &Runtime.map/3, &Runtime.map/4}}},
      {:mapv, {:multi_arity, :mapv, {&Runtime.mapv/2, &Runtime.mapv/3, &Runtime.mapv/4}}},
      {:"map-indexed", {:normal, &Runtime.map_indexed/2}},
      {:mapcat, {:normal, &Runtime.mapcat/2}},
      {:sort, {:multi_arity, :sort, {&Runtime.sort/1, &Runtime.sort/2}}},
      # sort-by: 2-arity (key, coll) or 3-arity (key, comparator, coll)
      {:"sort-by", {:multi_arity, :"sort-by", {&Runtime.sort_by/2, &Runtime.sort_by/3}}},
      {:reverse, {:normal, &Runtime.reverse/1}},
      {:first, {:normal, &Runtime.first/1}},
      {:second, {:normal, &Runtime.second/1}},
      {:last, {:normal, &Runtime.last/1}},
      {:nth, {:multi_arity, :nth, {&Runtime.nth/2, &Runtime.nth/3}}},
      {:rest, {:normal, &Runtime.rest/1}},
      {:butlast, {:normal, &Runtime.butlast/1}},
      {:next, {:normal, &Runtime.next/1}},
      {:ffirst, {:normal, &Runtime.ffirst/1}},
      {:fnext, {:normal, &Runtime.fnext/1}},
      {:nfirst, {:normal, &Runtime.nfirst/1}},
      {:nnext, {:normal, &Runtime.nnext/1}},
      {:take, {:normal, &Runtime.take/2}},
      {:drop, {:normal, &Runtime.drop/2}},
      {:nthrest, {:normal, &Runtime.nthrest/2}},
      {:nthnext, {:normal, &Runtime.nthnext/2}},
      {:"take-while", {:normal, &Runtime.take_while/2}},
      {:"drop-while", {:normal, &Runtime.drop_while/2}},
      {:"take-last", {:normal, &Runtime.take_last/2}},
      {:"drop-last", {:multi_arity, :"drop-last", {&Runtime.drop_last/1, &Runtime.drop_last/2}}},
      {:distinct, {:normal, &Runtime.distinct/1}},
      {:concat, {:variadic, &Runtime.concat2/2, []}},
      {:cons, {:normal, &Runtime.cons/2}},
      {:conj, {:variadic, &Runtime.conj/2, []}},
      {:into, {:normal, &Runtime.into/2}},
      {:flatten, {:normal, &Runtime.flatten/1}},
      {:zip, {:normal, &Runtime.zip/2}},
      {:interleave, {:collect, &Runtime.interleave_variadic/1}},
      {:interpose, {:normal, &Runtime.interpose/2}},
      {:partition,
       {:multi_arity, :partition,
        {&Runtime.partition/2, &Runtime.partition/3, &Runtime.partition/4}}},
      {:"partition-all",
       {:multi_arity, :partition_all, {&Runtime.partition_all/2, &Runtime.partition_all/3}}},
      {:"split-at", {:normal, &Runtime.split_at/2}},
      {:"split-with", {:normal, &Runtime.split_with/2}},
      {:"partition-by", {:normal, &Runtime.partition_by/2}},
      {:dedupe, {:normal, &Runtime.dedupe/1}},
      {:"keep-indexed", {:normal, &Runtime.keep_indexed/2}},
      {:count, {:normal, &Runtime.count/1}},
      {:empty?, {:normal, &Runtime.empty?/1}},
      {:empty, {:normal, &Runtime.empty/1}},
      {:peek, {:normal, &Runtime.peek/1}},
      {:pop, {:normal, &Runtime.pop/1}},
      {:subvec, {:multi_arity, :subvec, {&Runtime.subvec/2, &Runtime.subvec/3}}},
      {:filterv, {:normal, &Runtime.filterv/2}},
      {:"not-empty", {:normal, &Runtime.not_empty/1}},
      {:seq, {:normal, &Runtime.seq/1}},
      {:reduce, {:multi_arity, :reduce, {&Runtime.reduce/2, &Runtime.reduce/3}}},
      {:sum, {:normal, &Runtime.sum/1}},
      {:avg, {:normal, &Runtime.avg/1}},
      {:"sum-by", {:normal, &Runtime.sum_by/2}},
      {:"avg-by", {:normal, &Runtime.avg_by/2}},
      {:"min-by", {:collect, &Runtime.min_by_variadic/1}},
      {:"max-by", {:collect, &Runtime.max_by_variadic/1}},
      {:"distinct-by", {:normal, &Runtime.distinct_by/2}},
      {:"max-key", {:collect, &Runtime.max_key_variadic/1}},
      {:"min-key", {:collect, &Runtime.min_key_variadic/1}},
      {:"group-by", {:normal, &Runtime.group_by/2}},
      {:frequencies, {:normal, &Runtime.frequencies/1}},
      {:some, {:normal, &Runtime.some/2}},
      {:every?, {:normal, &Runtime.every?/2}},
      {:"not-any?", {:normal, &Runtime.not_any?/2}},
      {:"not-every?", {:normal, &Runtime.not_every?/2}},
      {:contains?, {:normal, &Runtime.contains?/2}},
      {:range, {:multi_arity, :range, {&Runtime.range/1, &Runtime.range/2, &Runtime.range/3}}},
      {:combinations, {:normal, &Runtime.combinations/2}},

      # ============================================================
      # Tree Traversal
      # ============================================================
      {:walk, {:normal, &Runtime.walk/3}},
      {:prewalk, {:normal, &Runtime.prewalk/2}},
      {:postwalk, {:normal, &Runtime.postwalk/2}},
      {:"tree-seq", {:normal, &Runtime.tree_seq/3}},

      # ============================================================
      # Map operations
      # ============================================================
      {:get, {:multi_arity, :get, {&Runtime.get/2, &Runtime.get/3}}},
      {:"get-in", {:multi_arity, :"get-in", {&Runtime.get_in/2, &Runtime.get_in/3}}},
      {:assoc, {:collect, &Runtime.assoc_variadic/1}},
      {:"assoc-in", {:normal, &Runtime.assoc_in/3}},
      {:update, {:collect, &Runtime.update_variadic/1}},
      {:"update-in", {:collect, &Runtime.update_in_variadic/1}},
      {:dissoc, {:collect, &Runtime.dissoc_variadic/1}},
      {:merge, {:collect, &Runtime.merge_variadic/1}},
      {:"select-keys", {:normal, &Runtime.select_keys/2}},
      {:keys, {:normal, &Runtime.keys/1}},
      {:vals, {:normal, &Runtime.vals/1}},
      {:key, {:normal, &Runtime.key/1}},
      {:val, {:normal, &Runtime.val/1}},
      {:entries, {:normal, &Runtime.entries/1}},
      {:"update-vals", {:normal, &Runtime.update_vals/2}},
      {:"update-keys", {:normal, &Runtime.update_keys/2}},
      {:disj, {:variadic_nonempty, :disj, &Runtime.disj/2}},
      {:"merge-with", {:collect, &Runtime.merge_with_variadic/1}},
      {:"reduce-kv", {:normal, &Runtime.reduce_kv/3}},
      {:zipmap, {:normal, &Runtime.zipmap/2}},

      # ============================================================
      # Utility functions
      # ============================================================
      {:identity, {:normal, &Runtime.identity/1}},
      {:fnil, {:normal, &Runtime.fnil/2}},
      {:comp, {:collect, &Runtime.comp_variadic/1}},
      {:partial, {:collect, &Runtime.partial_variadic/1}},
      {:complement, {:normal, &Runtime.complement/1}},
      {:constantly, {:normal, &Runtime.constantly/1}},
      {:"every-pred", {:collect, &Runtime.every_pred_variadic/1}},
      {:"some-fn", {:collect, &Runtime.some_fn_variadic/1}},

      # ============================================================
      # Arithmetic — variadic with identity
      # ============================================================
      {:+, {:variadic, &Runtime.Math.add/2, 0}},
      {:-, {:variadic_nonempty, :-, &Runtime.Math.subtract/2}},
      {:*, {:variadic, &Runtime.Math.multiply/2, 1}},
      {:/, {:variadic_nonempty, :/, &Runtime.Math.divide/2}},
      {:mod, {:normal, &Runtime.mod/2}},
      {:rem, {:normal, &Runtime.remainder/2}},
      {:quot, {:normal, &Runtime.Math.quot/2}},
      {:inc, {:normal, &Runtime.inc/1}},
      {:dec, {:normal, &Runtime.dec/1}},
      {:"+'", {:collect, &Runtime.Math.add/1}},
      {:"-'", {:collect, &Runtime.Math.subtract/1}},
      {:"*'", {:collect, &Runtime.Math.multiply/1}},
      {:"inc'", {:normal, &Runtime.inc/1}},
      {:"dec'", {:normal, &Runtime.dec/1}},
      {:abs, {:normal, &Runtime.abs/1}},
      {:max, {:variadic_nonempty, :max, &Runtime.Math.max/2}},
      {:min, {:variadic_nonempty, :min, &Runtime.Math.min/2}},
      {:floor, {:normal, &Runtime.floor/1}},
      {:ceil, {:normal, &Runtime.ceil/1}},
      {:round, {:normal, &Runtime.round/1}},
      {:trunc, {:normal, &Runtime.trunc/1}},
      {:double, {:normal, &Runtime.double/1}},
      {:float, {:normal, &Runtime.float/1}},
      {:int, {:normal, &Runtime.int/1}},
      {:sqrt, {:normal, &Runtime.sqrt/1}},
      {:pow, {:normal, &Runtime.pow/2}},

      # ============================================================
      # Bitwise operations — integers only
      # ============================================================
      {:"bit-and", {:collect, &Runtime.bit_and/1}},
      {:"bit-or", {:collect, &Runtime.bit_or/1}},
      {:"bit-xor", {:collect, &Runtime.bit_xor/1}},
      {:"bit-and-not", {:collect, &Runtime.bit_and_not/1}},
      {:"bit-not", {:normal, &Runtime.bit_not/1}},
      {:"bit-shift-left", {:normal, &Runtime.bit_shift_left/2}},
      {:"bit-shift-right", {:normal, &Runtime.bit_shift_right/2}},
      {:"bit-clear", {:normal, &Runtime.bit_clear/2}},
      {:"bit-set", {:normal, &Runtime.bit_set/2}},
      {:"bit-flip", {:normal, &Runtime.bit_flip/2}},
      {:"bit-test", {:normal, &Runtime.bit_test/2}},

      # ============================================================
      # Comparison
      # ============================================================
      {:=, {:collect, &Runtime.eq_variadic/1}},
      {:==, {:collect, &Runtime.numeric_eq_variadic/1}},
      {:"not=", {:collect, &Runtime.not_eq_variadic/1}},
      {:>, {:collect, &Runtime.gt_variadic/1}},
      {:<, {:collect, &Runtime.lt_variadic/1}},
      {:>=, {:collect, &Runtime.gte_variadic/1}},
      {:<=, {:collect, &Runtime.lte_variadic/1}},
      {:compare, {:normal, &Runtime.compare/2}},

      # ============================================================
      # Logic
      # ============================================================
      {:not, {:normal, &Runtime.not_/1}},
      {:boolean, {:normal, &Runtime.boolean/1}},

      # ============================================================
      # Type predicates
      # ============================================================
      {:nil?, {:normal, &Runtime.nil?/1}},
      {:some?, {:normal, &Runtime.some?/1}},
      {:boolean?, {:normal, &Runtime.boolean?/1}},
      {:number?, {:normal, &Runtime.number?/1}},
      {:int?, {:normal, &Runtime.int?/1}},
      {:integer?, {:normal, &Runtime.integer?/1}},
      {:float?, {:normal, &Runtime.float?/1}},
      {:double?, {:normal, &Runtime.double?/1}},
      {:false?, {:normal, &Runtime.false?/1}},
      {:true?, {:normal, &Runtime.true?/1}},
      {:fn?, {:normal, &Runtime.fn?/1}},
      {:symbol?, {:normal, &Runtime.symbol?/1}},
      {:decimal?, {:normal, &Runtime.decimal?/1}},
      {:ratio?, {:normal, &Runtime.ratio?/1}},
      {:rational?, {:normal, &Runtime.rational?/1}},
      {:"nat-int?", {:normal, &Runtime.nat_int?/1}},
      {:"neg-int?", {:normal, &Runtime.neg_int?/1}},
      {:"pos-int?", {:normal, &Runtime.pos_int?/1}},
      {:infinite?, {:normal, &Runtime.infinite?/1}},
      {:NaN?, {:normal, &Runtime.nan?/1}},
      {:string?, {:normal, &Runtime.string?/1}},
      {:char?, {:normal, &Runtime.char?/1}},
      {:keyword?, {:normal, &Runtime.keyword?/1}},
      {:vector?, {:normal, &Runtime.vector?/1}},
      {:set?, {:normal, &Runtime.set?/1}},
      {:set, {:normal, &Runtime.set/1}},
      {:vec, {:normal, &Runtime.vec/1}},
      {:keyword, {:normal, &Runtime.keyword/1}},
      {:vector, {:collect, &Function.identity/1}},
      # `list` is an alias for `vector` — PTC-Lisp is vector-first, but LLMs
      # reach for Clojure's `list`. Returning a vector keeps semantics uniform.
      {:list, {:collect, &Function.identity/1}},
      {:"hash-map", {:collect, &Runtime.hash_map/1}},
      {:"array-map", {:collect, &Runtime.array_map/1}},
      {:"hash-set", {:collect, &Runtime.hash_set/1}},
      {:map?, {:normal, &Runtime.map?/1}},
      {:coll?, {:normal, &Runtime.coll?/1}},
      {:sequential?, {:normal, &Runtime.sequential?/1}},
      {:seq?, {:normal, &Runtime.seq?/1}},
      {:associative?, {:normal, &Runtime.associative?/1}},
      {:counted?, {:normal, &Runtime.counted?/1}},
      {:indexed?, {:normal, &Runtime.indexed?/1}},
      {:reversible?, {:normal, &Runtime.reversible?/1}},
      {:sorted?, {:normal, &Runtime.sorted?/1}},
      {:seqable?, {:normal, &Runtime.seqable?/1}},
      {:ifn?, {:normal, &Runtime.ifn?/1}},
      {:"map-entry?", {:normal, &Runtime.map_entry?/1}},
      {:distinct?, {:collect, &Runtime.distinct_args?/1}},
      {:type, {:normal, &Runtime.type_of/1}},

      # ============================================================
      # String manipulation
      # ============================================================
      {:format, {:collect, &Runtime.format_variadic/1}},
      {:name, {:normal, &Runtime.name/1}},
      {:str, {:collect, &Runtime.str_variadic/1}},
      {:"pr-str", {:collect, &Runtime.pr_str_variadic/1}},
      {:subs, {:multi_arity, :subs, {&Runtime.subs/2, &Runtime.subs/3}}},
      {:join, {:multi_arity, :join, {&Runtime.join/1, &Runtime.join/2}}},
      {:split, {:normal, &Runtime.split/2}},
      {:"split-lines", {:normal, &Runtime.split_lines/1}},
      {:trim, {:normal, &Runtime.trim/1}},
      {:blank?, {:normal, &Runtime.blank?/1}},
      {:"trim-newline", {:normal, &Runtime.trim_newline/1}},
      {:triml, {:normal, &Runtime.triml/1}},
      {:trimr, {:normal, &Runtime.trimr/1}},
      # Arity-2 is clojure.core/replace (seq replace via a map/vector lookup);
      # arity-3 is the clojure.string/replace convenience alias.
      {:replace, {:multi_arity, :replace, {&Runtime.replace/2, &Runtime.replace/3}}},
      {:upcase, {:normal, &Runtime.upcase/1}},
      {:"upper-case", {:normal, &Runtime.upcase/1}},
      {:downcase, {:normal, &Runtime.downcase/1}},
      {:"lower-case", {:normal, &Runtime.downcase/1}},
      {:"starts-with?", {:normal, &Runtime.starts_with?/2}},
      {:"ends-with?", {:normal, &Runtime.ends_with?/2}},
      {:includes?, {:normal, &Runtime.includes?/2}},
      {:"index-of", {:multi_arity, :"index-of", {&Runtime.index_of/2, &Runtime.index_of/3}}},
      {:"last-index-of",
       {:multi_arity, :"last-index-of", {&Runtime.last_index_of/2, &Runtime.last_index_of/3}}},

      # ============================================================
      # String parsing
      # ============================================================
      {:"parse-long", {:normal, &Runtime.parse_long/1}},
      {:"parse-int", {:normal, &Runtime.parse_long/1}},
      {:"parse-double", {:normal, &Runtime.parse_double/1}},
      {:"parse-boolean", {:normal, &Runtime.parse_boolean/1}},

      # ============================================================
      # JSON builtins (Plans/json-support.md §4)
      # ============================================================
      {:"json/parse-string", {:normal, &Runtime.Json.parse_string/1}},
      {:"json/parse-lines", {:normal, &Runtime.Json.parse_lines/1}},
      {:"json/generate-string", {:normal, &Runtime.Json.generate_string/1}},

      # ============================================================
      # Regex operations
      # ============================================================
      {:"re-pattern", {:normal, &Runtime.re_pattern/1}},
      {:"re-find", {:normal, &Runtime.re_find/2}},
      {:"re-matches", {:normal, &Runtime.re_matches/2}},
      {:"re-split", {:normal, &Runtime.re_split/2}},
      {:"re-seq", {:normal, &Runtime.re_seq/2}},
      {:regex?, {:normal, &Runtime.regex?/1}},
      {:extract, {:multi_arity, :extract, {&Runtime.extract/2, &Runtime.extract/3}}},
      {:"extract-int",
       {:multi_arity, :"extract-int",
        {&Runtime.extract_int/2, &Runtime.extract_int/3, &Runtime.extract_int/4}}},

      # ============================================================
      # Numeric predicates
      # ============================================================
      {:zero?, {:normal, &Runtime.zero?/1}},
      {:pos?, {:normal, &Runtime.pos?/1}},
      {:neg?, {:normal, &Runtime.neg?/1}},
      {:even?, {:normal, &Runtime.even?/1}},
      {:odd?, {:normal, &Runtime.odd?/1}},

      # ============================================================
      # Set Operations
      # ============================================================
      {:intersection, {:variadic_nonempty, :intersection, &Runtime.intersection/2}},
      {:union, {:variadic, &Runtime.union/2, MapSet.new()}},
      {:difference, {:variadic_nonempty, :difference, &Runtime.difference/2}},

      # ============================================================
      # Interop
      # ============================================================
      {:"Boolean/parseBoolean", {:normal, &Runtime.boolean_parse_boolean/1}},
      {:"java.util.Date.",
       {:multi_arity, :"java.util.Date.", {&Runtime.java_util_date/0, &Runtime.java_util_date/1}}},
      {:".getTime", {:normal, &Runtime.dot_get_time/1}},
      {:".toEpochDay", {:normal, &Runtime.dot_to_epoch_day/1}},
      {:".plusDays", {:normal, &Runtime.dot_plus_days/2}},
      {:".minusDays", {:normal, &Runtime.dot_minus_days/2}},
      {:"Duration/between", {:normal, &Runtime.duration_between/2}},
      {:".toMillis", {:normal, &Runtime.dot_to_millis/1}},
      {:".toDays", {:normal, &Runtime.dot_to_days/1}},
      {:".contains", {:normal, &Runtime.dot_contains/2}},
      {:".indexOf",
       {:multi_arity, :".indexOf", {&Runtime.dot_index_of/2, &Runtime.dot_index_of/3}}},
      {:".lastIndexOf", {:normal, &Runtime.dot_last_index_of/2}},
      {:".toLowerCase", {:normal, &Runtime.dot_to_lower_case/1}},
      {:".toUpperCase", {:normal, &Runtime.dot_to_upper_case/1}},
      {:".length", {:normal, &Runtime.dot_length/1}},
      {:".substring",
       {:multi_arity, :".substring", {&Runtime.dot_substring/2, &Runtime.dot_substring/3}}},
      {:".startsWith", {:normal, &Runtime.dot_starts_with/2}},
      {:".endsWith", {:normal, &Runtime.dot_ends_with/2}},
      {:".isBefore", {:normal, &Runtime.dot_is_before/2}},
      {:".isAfter", {:normal, &Runtime.dot_is_after/2}},
      {:currentTimeMillis, {:normal, &Runtime.current_time_millis/0}},
      {:parse, {:normal, &Runtime.parse_temporal/1}},

      # ============================================================
      # Double Constants
      # ============================================================
      {:POSITIVE_INFINITY, {:constant, :infinity}},
      {:NEGATIVE_INFINITY, {:constant, :negative_infinity}},
      {:NaN, {:constant, :nan}}
    ]
  end
end
