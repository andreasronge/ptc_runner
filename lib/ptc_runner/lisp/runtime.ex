defmodule PtcRunner.Lisp.Runtime do
  @moduledoc """
  Built-in functions for PTC-Lisp.

  Provides collection operations, map operations, arithmetic, string manipulation,
  and type predicates. This module acts as the public API and delegates to
  focused submodules:

  - `Runtime.FlexAccess` - Flexible key access helpers
  - `Runtime.Collection` - Collection operations (filter, map, reduce, etc.)
  - `Runtime.MapOps` - Map operations (get, assoc, merge, etc.)
  - `Runtime.String` - String manipulation and parsing
  - `Runtime.Math` - Arithmetic operations
  - `Runtime.Predicates` - Type and numeric predicates
  """

  alias PtcRunner.Lisp.Runtime.Collection
  alias PtcRunner.Lisp.Runtime.FlexAccess
  alias PtcRunner.Lisp.Runtime.Interop
  alias PtcRunner.Lisp.Runtime.MapOps
  alias PtcRunner.Lisp.Runtime.Math
  alias PtcRunner.Lisp.Runtime.Predicates
  alias PtcRunner.Lisp.Runtime.Regex
  alias PtcRunner.Lisp.Runtime.String, as: RuntimeString

  # ============================================================
  # Flexible Key Access Helper
  # ============================================================

  defdelegate flex_get(map, key), to: FlexAccess
  defdelegate flex_fetch(map, key), to: FlexAccess
  defdelegate flex_get_in(data, path), to: FlexAccess
  defdelegate flex_put_in(data, path, value), to: FlexAccess
  defdelegate flex_update_in(data, path, func), to: FlexAccess

  # ============================================================
  # Collection Operations
  # ============================================================

  defdelegate filter(pred, coll), to: Collection
  defdelegate remove(pred, coll), to: Collection
  defdelegate find(pred, coll), to: Collection
  defdelegate map(f, coll), to: Collection
  defdelegate map(f, coll1, coll2), to: Collection
  defdelegate map(f, coll1, coll2, coll3), to: Collection
  defdelegate mapv(f, coll), to: Collection
  defdelegate mapv(f, coll1, coll2), to: Collection
  defdelegate mapv(f, coll1, coll2, coll3), to: Collection
  defdelegate map_indexed(f, coll), to: Collection
  defdelegate pluck(key, coll), to: Collection
  defdelegate sort(coll), to: Collection
  defdelegate sort(comp, coll), to: Collection
  defdelegate sort_by(keyfn, coll), to: Collection
  defdelegate sort_by(keyfn, comp, coll), to: Collection
  defdelegate reverse(coll), to: Collection
  defdelegate first(coll), to: Collection
  defdelegate second(coll), to: Collection
  defdelegate last(coll), to: Collection
  defdelegate nth(coll, idx), to: Collection
  defdelegate rest(coll), to: Collection
  defdelegate next(coll), to: Collection
  defdelegate ffirst(coll), to: Collection
  defdelegate fnext(coll), to: Collection
  defdelegate nfirst(coll), to: Collection
  defdelegate nnext(coll), to: Collection
  defdelegate take(n, coll), to: Collection
  defdelegate drop(n, coll), to: Collection
  defdelegate take_while(pred, coll), to: Collection
  defdelegate drop_while(pred, coll), to: Collection
  defdelegate distinct(coll), to: Collection
  defdelegate concat2(a, b), to: Collection
  defdelegate conj(coll, x), to: Collection
  defdelegate into(to, from), to: Collection
  defdelegate flatten(coll), to: Collection
  defdelegate zip(c1, c2), to: Collection
  defdelegate interleave(c1, c2), to: Collection
  defdelegate partition(n, coll), to: Collection
  defdelegate partition(n, step, coll), to: Collection
  defdelegate count(coll), to: Collection
  defdelegate empty?(coll), to: Collection
  defdelegate not_empty(coll), to: Collection
  defdelegate seq(coll), to: Collection
  defdelegate reduce(f, coll), to: Collection
  defdelegate reduce(f, init, coll), to: Collection
  defdelegate sum_by(keyfn, coll), to: Collection
  defdelegate avg_by(keyfn, coll), to: Collection
  defdelegate min_by(keyfn, coll), to: Collection
  defdelegate max_by(keyfn, coll), to: Collection
  defdelegate distinct_by(keyfn, coll), to: Collection
  defdelegate max_key_variadic(args), to: Collection
  defdelegate min_key_variadic(args), to: Collection
  defdelegate group_by(keyfn, coll), to: Collection
  defdelegate frequencies(coll), to: Collection
  defdelegate some(pred, coll), to: Collection
  defdelegate every?(pred, coll), to: Collection
  defdelegate not_any?(pred, coll), to: Collection
  defdelegate contains?(coll, val), to: Collection
  defdelegate range(end_val), to: Collection
  defdelegate range(start, end_val), to: Collection
  defdelegate range(start, end_val, step), to: Collection

  # ============================================================
  # Map Operations
  # ============================================================

  defdelegate get(m, k), to: MapOps
  defdelegate get(m, k, default), to: MapOps
  defdelegate get_in(m, path), to: MapOps
  defdelegate get_in(m, path, default), to: MapOps
  defdelegate assoc(m, k, v), to: MapOps
  defdelegate assoc_variadic(args), to: MapOps
  defdelegate assoc_in(m, path, v), to: MapOps
  defdelegate dissoc_variadic(args), to: MapOps
  defdelegate update(m, k, f), to: MapOps
  defdelegate update_variadic(args), to: MapOps
  defdelegate update_in(m, path, f), to: MapOps
  defdelegate update_in_variadic(args), to: MapOps
  defdelegate dissoc(m, k), to: MapOps
  defdelegate merge(m1, m2), to: MapOps
  defdelegate select_keys(m, ks), to: MapOps
  defdelegate keys(m), to: MapOps
  defdelegate vals(m), to: MapOps
  defdelegate key(entry), to: MapOps
  defdelegate val(entry), to: MapOps
  defdelegate entries(m), to: MapOps
  defdelegate update_vals(m, f), to: MapOps

  # ============================================================
  # Arithmetic
  # ============================================================

  defdelegate add(args), to: Math
  defdelegate subtract(args), to: Math
  defdelegate multiply(args), to: Math
  defdelegate divide(x, y), to: Math
  defdelegate mod(x, y), to: Math
  defdelegate remainder(x, y), to: Math
  defdelegate inc(x), to: Math
  defdelegate dec(x), to: Math
  defdelegate abs(x), to: Math
  defdelegate max(x, y), to: Math
  defdelegate min(x, y), to: Math
  defdelegate floor(x), to: Math
  defdelegate ceil(x), to: Math
  defdelegate round(x), to: Math
  defdelegate trunc(x), to: Math
  defdelegate double(x), to: Math
  defdelegate float(x), to: Math
  defdelegate int(x), to: Math
  defdelegate sqrt(x), to: Math
  defdelegate pow(x, y), to: Math

  # ============================================================
  # Comparison
  # ============================================================

  defdelegate lt(x, y), to: Math
  defdelegate gt(x, y), to: Math
  defdelegate lte(x, y), to: Math
  defdelegate gte(x, y), to: Math
  defdelegate not_eq(x, y), to: Math
  defdelegate compare(x, y), to: Math

  # ============================================================
  # Logic
  # ============================================================

  defdelegate not_(x), to: Predicates
  defdelegate identity(x), to: Predicates
  defdelegate fnil(f, default), to: Predicates

  # ============================================================
  # String Manipulation
  # ============================================================

  defdelegate str2(a, b), to: RuntimeString
  defdelegate subs(s, start), to: RuntimeString
  defdelegate subs(s, start, end_idx), to: RuntimeString
  defdelegate join(coll), to: RuntimeString
  defdelegate join(separator, coll), to: RuntimeString
  defdelegate split(s, separator), to: RuntimeString
  defdelegate split_lines(s), to: RuntimeString
  defdelegate trim(s), to: RuntimeString
  defdelegate replace(s, pattern, replacement), to: RuntimeString
  defdelegate upcase(s), to: RuntimeString
  defdelegate downcase(s), to: RuntimeString
  defdelegate starts_with?(s, prefix), to: RuntimeString
  defdelegate ends_with?(s, suffix), to: RuntimeString
  defdelegate includes?(s, substring), to: RuntimeString

  # ============================================================
  # String Parsing
  # ============================================================

  defdelegate parse_long(s), to: RuntimeString
  defdelegate parse_double(s), to: RuntimeString

  # ============================================================
  # Regex Operations
  # ============================================================
  defdelegate re_pattern(s), to: Regex
  defdelegate re_find(re, s), to: Regex
  defdelegate re_matches(re, s), to: Regex
  defdelegate re_split(re, s), to: Regex

  # ============================================================
  # Type Predicates
  # ============================================================

  defdelegate nil?(x), to: Predicates
  defdelegate some?(x), to: Predicates
  defdelegate boolean?(x), to: Predicates
  defdelegate number?(x), to: Predicates
  defdelegate string?(x), to: Predicates
  defdelegate char?(x), to: Predicates
  defdelegate regex?(x), to: Predicates
  defdelegate keyword?(x), to: Predicates
  defdelegate vector?(x), to: Predicates
  defdelegate set?(x), to: Predicates
  defdelegate map?(x), to: Predicates
  defdelegate coll?(x), to: Predicates
  defdelegate set(coll), to: Predicates
  defdelegate vec(coll), to: Predicates

  # ============================================================
  # Numeric Predicates
  # ============================================================

  defdelegate zero?(x), to: Predicates
  defdelegate pos?(x), to: Predicates
  defdelegate neg?(x), to: Predicates
  defdelegate even?(x), to: Predicates
  defdelegate odd?(x), to: Predicates

  # ============================================================
  # Set Operations
  # ============================================================

  defdelegate intersection(s1, s2), to: Collection
  defdelegate union(s1, s2), to: Collection
  defdelegate difference(s1, s2), to: Collection

  # ============================================================
  # Interop
  # ============================================================

  defdelegate java_util_date(), to: Interop
  defdelegate java_util_date(ms), to: Interop
  defdelegate dot_get_time(dt), to: Interop
  defdelegate current_time_millis, to: Interop
  defdelegate local_date_parse(s), to: Interop
end
