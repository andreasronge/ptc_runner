<!-- Auto-generated from priv/functions.exs — do not edit by hand -->
# PTC-Lisp Function Reference

271 functions and special forms.

## Table of Contents

- [Definitions & Bindings](#definitions-bindings) (7)
- [Conditionals](#conditionals) (12)
- [Threading Macros](#threading-macros) (7)
- [Control Flow](#control-flow) (4)
- [Iteration](#iteration) (2)
- [Core](#core) (166)
- [Predicate Builders](#predicate-builders) (4)
- [Functional Tools](#functional-tools) (3)
- [Agent Control](#agent-control) (5)
- [String Functions](#string-functions) (24)
- [Set Operations](#set-operations) (9)
- [Regex Functions](#regex-functions) (6)
- [Math Functions](#math-functions) (13)
- [Interop](#interop) (9)

## Definitions & Bindings

| Function | Signature | Description |
|----------|-----------|-------------|
| `def` | `(def ...)` |  |
| `defn` | `(defn ...)` |  |
| `defonce` | `(defonce ...)` |  |
| `fn` | `(fn ...)` |  |
| `let` | `(let ...)` |  |
| `loop` | `(loop ...)` |  |
| `recur` | `(recur ...)` |  |



## Conditionals

| Function | Signature | Description |
|----------|-----------|-------------|
| `case` | `(case ...)` |  |
| `cond` | `(cond ...)` |  |
| `condp` | `(condp ...)` |  |
| `if` | `(if ...)` |  |
| `if-let` | `(if-let ...)` |  |
| `if-not` | `(if-not ...)` |  |
| `if-some` | `(if-some ...)` |  |
| `when` | `(when ...)` |  |
| `when-first` | `(when-first ...)` |  |
| `when-let` | `(when-let ...)` |  |
| `when-not` | `(when-not ...)` |  |
| `when-some` | `(when-some ...)` |  |



## Threading Macros

| Function | Signature | Description |
|----------|-----------|-------------|
| `->` | `(-> ...)` |  |
| `->>` | `(->> ...)` |  |
| `as->` | `(as-> ...)` |  |
| `cond->` | `(cond-> ...)` |  |
| `cond->>` | `(cond->> ...)` |  |
| `some->` | `(some-> ...)` |  |
| `some->>` | `(some->> ...)` |  |



## Control Flow

| Function | Signature | Description |
|----------|-----------|-------------|
| `and` | `(and x y ...)` | Logical AND (short-circuits) |
| `comment` | `(comment ...)` |  |
| `do` | `(do ...)` |  |
| `or` | `(or x y ...)` | Logical OR (short-circuits) |



## Iteration

| Function | Signature | Description |
|----------|-----------|-------------|
| `doseq` | `(doseq ...)` |  |
| `for` | `(for ...)` |  |



## Core

| Function | Signature | Description |
|----------|-----------|-------------|
| `*` | `(* x y ...)` | Multiplication |
| `+` | `(+ x y ...)` | Addition |
| `-` | `(- x y ...)` | Subtraction |
| `/` | `(/ x y)` | Division (always returns float) |
| `<` | `(< x y)` | Less than |
| `<=` | `(<= x y)` | Less or equal |
| `=` | `(= x y)` | Equality |
| `>` | `(> x y)` | Greater than |
| `>=` | `(>= x y)` | Greater or equal |
| `NaN?` | `(NaN? ...)` |  |
| `apply` | `(apply f coll)` | Applies function `f` to the argument sequence `coll` |
| `assoc` | `(assoc m key val)` | Add/update key |
| `assoc-in` | `(assoc-in m path val)` | Add/update nested |
| `associative?` | `(associative? ...)` |  |
| `avg` * | `(avg coll)` | Average of numbers |
| `avg-by` * | `(avg-by key coll)` | Average field values |
| `boolean` | `(boolean ...)` |  |
| `boolean?` | `(boolean? ...)` |  |
| `butlast` | `(butlast coll)` | All but last (empty list if none) |
| `char?` | `(char? ...)` |  |
| `coll?` | `(coll? ...)` |  |
| `combinations` * | `(combinations coll n)` | Generate all n-combinations |
| `comp` | `(comp f1 f2 ...)` | Returns a function composing fns right-to-left; `(comp)` returns `identity` |
| `compare` | `(compare x y)` | Numeric comparison: `-1` if `x < y`, `0` if `x == y`, `1` if `x > y`. Only supports numbers in PTC-Lisp. |
| `complement` | `(complement f)` | Returns a function with the opposite truth value (always boolean) |
| `concat` | `(concat coll1 coll2 ...)` | Join collections |
| `conj` | `(conj coll x ...)` | Add elements to collection |
| `cons` | `(cons x seq)` | Prepend item to sequence |
| `constantly` | `(constantly x)` | Returns a function that always returns `x`, ignoring its arguments |
| `count` | `(count coll)` | Number of items |
| `counted?` | `(counted? ...)` |  |
| `dec` | `(dec x)` | Subtract 1 |
| `decimal?` | `(decimal? ...)` |  |
| `dedupe` | `(dedupe coll)` | Remove consecutive duplicates |
| `dissoc` | `(dissoc m key)` | Remove key |
| `distinct` | `(distinct coll)` | Remove duplicates |
| `distinct-by` * | `(distinct-by key coll)` | Items with unique field values |
| `distinct?` | `(distinct? x y ...)` | True if all arguments are distinct |
| `double?` | `(double? ...)` |  |
| `drop` | `(drop n coll)` | Skip first n items |
| `drop-last` | `(drop-last coll), (drop-last n coll)` |  |
| `drop-while` | `(drop-while pred coll)` | Drop while pred is true |
| `empty` | `(empty coll)` | Return empty collection of same type |
| `empty?` | `(empty? coll)` | True if empty or nil |
| `entries` | `(entries m)` | Get all `[key value]` pairs as a list |
| `even?` | `(even? ...)` |  |
| `every-pred` | `(every-pred p1 p2 ...)` | Returns a predicate true when all preds are satisfied (always boolean) |
| `every?` | `(every? :key coll)` | True if all have truthy `:key` |
| `false?` | `(false? ...)` |  |
| `ffirst` | `(ffirst coll)` | First of first |
| `filter` | `(filter pred coll)` | Keep items where pred is truthy |
| `filterv` | `(filterv pred coll)` | Same as filter (vectors are the default) |
| `find` | `(find pred coll)` | First item where pred is truthy, or nil |
| `first` | `(first coll)` | First item or nil |
| `flatten` | `(flatten coll)` | Flatten nested collections |
| `float?` | `(float? ...)` |  |
| `fn?` | `(fn? ...)` |  |
| `fnext` | `(fnext coll)` | First of next |
| `fnil` | `(fnil ...)` |  |
| `frequencies` | `(frequencies coll)` | Count occurrences of each item |
| `get` | `(get m key), (get m key default)` | Get with default |
| `get-in` | `(get-in m path), (get-in m path default)` | Get nested with default |
| `group-by` | `(group-by keyfn coll)` | Group items by key |
| `identity` | `(identity x)` | Returns argument unchanged |
| `ifn?` | `(ifn? ...)` |  |
| `inc` | `(inc x)` | Add 1 |
| `indexed?` | `(indexed? ...)` |  |
| `infinite?` | `(infinite? ...)` |  |
| `int?` | `(int? ...)` |  |
| `integer?` | `(integer? ...)` |  |
| `interleave` | `(interleave c1 c2)` | Interleave collections |
| `interpose` | `(interpose sep coll)` | Insert separator between elements |
| `into` | `(into to from)` | Pour from into to |
| `keep` | `(keep f coll)` | Non-nil results of (f item). false is kept. |
| `keep-indexed` | `(keep-indexed f coll)` | Non-nil results of (f index item). false is kept. |
| `key` | `(key ...)` |  |
| `keys` | `(keys m)` | Get all keys |
| `keyword` | `(keyword x)` | Type coercion (string to keyword) |
| `keyword?` | `(keyword? ...)` |  |
| `last` | `(last coll)` | Last item or nil |
| `map` | `(map f coll), (map f c1 c2), (map f c1 c2 c3)` | Apply f to triples |
| `map-entry?` | `(map-entry? ...)` |  |
| `map-indexed` | `(map-indexed f coll)` | Apply f to index and item |
| `map?` | `(map? ...)` |  |
| `mapcat` | `(mapcat f coll)` | Apply f to each item, concatenate results |
| `mapv` | `(mapv f coll), (mapv f c1 c2), (mapv f c1 c2 c3)` | Like map with three collections |
| `max-by` * | `(max-by f x), (max-by f x y & more)` | Item with maximum field |
| `max-key` | `(max-key f x), (max-key f x y & more)` | Return x for which (f x) is greatest |
| `merge` | `(merge m1 m2 ...)` | Merge maps (later wins) |
| `merge-with` | `(merge-with f m1 m2 ...)` | Merge maps with combining function for duplicates |
| `min-by` * | `(min-by f x), (min-by f x y & more)` | Item with minimum field |
| `min-key` | `(min-key f x), (min-key f x y & more)` | Return x for which (f x) is least |
| `mod` | `(mod x y)` | Modulo (floored division, result sign matches divisor) |
| `nat-int?` | `(nat-int? ...)` |  |
| `neg-int?` | `(neg-int? ...)` |  |
| `neg?` | `(neg? ...)` |  |
| `next` | `(next coll)` | All but first (nil if none) |
| `nfirst` | `(nfirst coll)` | Next of first |
| `nil?` | `(nil? ...)` |  |
| `nnext` | `(nnext coll)` | Next of next |
| `not` | `(not x)` | Logical NOT |
| `not-any?` | `(not-any? :key coll)` | True if none have truthy `:key` |
| `not-empty` | `(not-empty coll)` | `coll` if not empty, else `nil` |
| `not-every?` | `(not-every? :key coll)` | True if not all have truthy `:key` |
| `not=` | `(not= x y)` | Inequality |
| `nth` | `(nth coll idx)` | Item at index or nil |
| `number?` | `(number? ...)` |  |
| `odd?` | `(odd? ...)` |  |
| `partial` | `(partial f arg1 ...)` | Returns a function with some arguments pre-filled |
| `partition` | `(partition n coll), (partition n step coll), (partition n step pad coll)` | Sliding window with pad collection for incomplete groups |
| `partition-all` | `(partition-all n coll), (partition-all n step coll)` | Sliding window chunks (incomplete included) |
| `partition-by` | `(partition-by f coll)` | Partition when f's return value changes |
| `peek` | `(peek coll)` | Return last element without removing |
| `pluck` * | `(pluck key coll)` | Extract single field from each item |
| `pop` | `(pop coll)` | Return collection without last element |
| `pos-int?` | `(pos-int? ...)` |  |
| `pos?` | `(pos? ...)` |  |
| `postwalk` * | `(postwalk f form)` | Transform tree bottom-up (post-order traversal) |
| `prewalk` * | `(prewalk f form)` | Transform tree top-down (pre-order traversal) |
| `println` | `(println ...)` | Prints arguments to the execution trace, separated by spaces. Returns `nil`. |
| `range` | `(range end), (range start end), (range start end step)` | Returns sequence with specific step |
| `ratio?` | `(ratio? ...)` |  |
| `rational?` | `(rational? ...)` |  |
| `reduce` | `(reduce f coll), (reduce f init coll)` | Fold collection |
| `reduce-kv` | `(reduce-kv f init m)` | Reduce map with f receiving (acc, key, val) |
| `rem` | `(rem x y)` | Remainder (truncated division, result sign matches dividend) |
| `remove` | `(remove pred coll)` | Remove items where pred is truthy |
| `rest` | `(rest coll)` | All but first (empty list if none) |
| `reverse` | `(reverse coll)` | Reverse order |
| `reversible?` | `(reversible? ...)` |  |
| `second` | `(second coll)` | Second item or nil |
| `select-keys` | `(select-keys m keys)` | Pick specific keys |
| `seq` | `(seq coll)` | Convert to sequence (nil if empty) |
| `seq?` | `(seq? ...)` |  |
| `seqable?` | `(seqable? ...)` |  |
| `sequential?` | `(sequential? ...)` |  |
| `some` | `(some :key coll)` | First truthy `:key` value, or nil |
| `some-fn` | `(some-fn f1 f2 ...)` | Returns a function that returns the first truthy result from any fn |
| `some?` | `(some? ...)` |  |
| `sort` | `(sort coll), (sort comparator coll)` | Sort by natural order |
| `sort-by` | `(sort-by keyfn coll), (sort-by keyfn comparator coll)` | Sort with comparator |
| `sorted?` | `(sorted? ...)` |  |
| `split-at` | `(split-at n coll)` | Split into `[(take n coll) (drop n coll)]` |
| `split-with` | `(split-with pred coll)` | Split into `[(take-while pred coll) (drop-while pred coll)]` |
| `string?` | `(string? ...)` |  |
| `subvec` | `(subvec v start), (subvec v start end)` |  |
| `sum` * | `(sum coll)` | Sum of numbers |
| `sum-by` * | `(sum-by key coll)` | Sum field values |
| `symbol?` | `(symbol? ...)` |  |
| `take` | `(take n coll)` | First n items |
| `take-last` | `(take-last n coll)` | Last n items |
| `take-while` | `(take-while pred coll)` | Take while pred is true |
| `tree-seq` | `(tree-seq branch? children root)` | Flatten tree to depth-first sequence |
| `true?` | `(true? ...)` |  |
| `type` | `(type ...)` |  |
| `update` | `(update m key f & args)` | Update with extra args passed to f |
| `update-in` | `(update-in m path f & args)` | Update nested with extra args |
| `update-keys` | `(update-keys m f)` | Apply f to each key (collision: retained value unspecified) |
| `update-vals` | `(update-vals m f)` | Apply f to each value (matches Clojure 1.11) |
| `val` | `(val ...)` |  |
| `vals` | `(vals m)` | Get all values |
| `vector?` | `(vector? ...)` |  |
| `walk` * | `(walk inner outer form)` | Generic tree walker - applies inner to children, outer to result |
| `zero?` | `(zero? ...)` |  |
| `zip` * | `(zip c1 c2)` | Combine into pairs |
| `zipmap` | `(zipmap keys vals)` | Create map from keys and values seqs |



## Predicate Builders

| Function | Signature | Description |
|----------|-----------|-------------|
| `all-of` * | `(all-of ...)` |  |
| `any-of` * | `(any-of ...)` |  |
| `none-of` * | `(none-of ...)` |  |
| `where` * | `(where ...)` |  |



## Functional Tools

| Function | Signature | Description |
|----------|-----------|-------------|
| `juxt` | `(juxt f1 f2 ...)` | Returns a function that applies all functions and returns a vector of results |
| `pcalls` * | `(pcalls f1 f2 ...)` | Execute thunks in parallel |
| `pmap` * | `(pmap f coll)` | Apply f to each item in parallel |



## Agent Control

| Function | Signature | Description |
|----------|-----------|-------------|
| `fail` | `(fail ...)` |  |
| `return` | `(return ...)` |  |
| `step-done` * | `(step-done ...)` |  |
| `task` * | `(task ...)` |  |
| `task-reset` * | `(task-reset ...)` |  |



## String Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `downcase` * | `(downcase ...)` |  |
| `ends-with?` | `(ends-with? s suffix)` | Check if string ends with suffix |
| `extract` * | `(extract pattern s), (extract pattern s n)` | Extract capture group n (0 = full match) |
| `extract-int` * | `(extract-int pattern s), (extract-int pattern s n), (extract-int pattern s n default)` | Extract group n, parse as int, return default on failure |
| `format` * | `(format fmt-string & args)` | Java-style format string |
| `includes?` | `(includes? s substring)` | Check if string contains substring |
| `index-of` | `(index-of s value), (index-of s value from-index)` | Index of first occurrence from position |
| `join` | `(join coll), (join separator coll)` | Join collection elements (no separator) |
| `last-index-of` | `(last-index-of s value), (last-index-of s value from-index)` | Index of last occurrence up to position |
| `lower-case` | `(lower-case ...)` |  |
| `name` | `(name x)` | Returns name string of keyword or string |
| `parse-double` | `(parse-double ...)` |  |
| `parse-int` | `(parse-int ...)` |  |
| `parse-long` | `(parse-long ...)` |  |
| `pr-str` | `(pr-str ...)` | Readable string representation (strings quoted, nil as "nil", space-separated) |
| `replace` | `(replace s pattern replacement)` | Replace all occurrences |
| `split` | `(split s separator)` | Split string by separator |
| `split-lines` | `(split-lines s)` | Split string into lines (\n or \r\n) |
| `starts-with?` | `(starts-with? s prefix)` | Check if string starts with prefix |
| `str` | `(str ...)` | Convert and concatenate to string |
| `subs` | `(subs s start), (subs s start end)` | Substring from start to end |
| `trim` | `(trim s)` | Remove leading/trailing whitespace |
| `upcase` * | `(upcase ...)` |  |
| `upper-case` | `(upper-case ...)` |  |



## Set Operations

| Function | Signature | Description |
|----------|-----------|-------------|
| `contains?` | `(contains? coll key)` | True if key/element exists (maps, sets, lists) |
| `difference` | `(clojure.set/difference & sets)` | Returns the difference of one or more sets |
| `disj` | `(disj set x ...)` | Remove elements from set |
| `intersection` | `(clojure.set/intersection & sets)` | Returns the intersection of one or more sets |
| `set` | `(set coll)` | Convert collection to set |
| `set?` | `(set? x)` | Returns true if x is a set |
| `union` | `(clojure.set/union & sets)` | Returns the union of zero or more sets |
| `vec` | `(vec coll)` | Convert collection to vector |
| `vector` | `(vector & args)` | Create vector from arguments |



## Regex Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `re-find` | `(re-find re s)` | Returns the first match of `re` in `s` |
| `re-matches` | `(re-matches re s)` | Returns match if `re` matches the **entire** string `s` |
| `re-pattern` | `(re-pattern s)` | Compile string `s` into an opaque regex object |
| `re-seq` | `(re-seq re s)` | Returns all matches of `re` in `s` as a list |
| `re-split` | `(re-split re s)` | Split string `s` by regex pattern `re` |
| `regex?` | `(regex? x)` | Returns true if `x` is a regex object |



## Math Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `abs` | `(abs x)` | Absolute value |
| `ceil` | `(ceil x)` | Round toward +∞ |
| `double` | `(double x)` | Type coercion (to float) |
| `float` | `(float x)` | Alias for double (Clojure compat) |
| `floor` | `(floor x)` | Round toward -∞ |
| `int` | `(int x)` | Type coercion (to integer) |
| `max` | `(max x y ...)` | Maximum value |
| `min` | `(min x y ...)` | Minimum value |
| `pow` | `(pow ...)` |  |
| `quot` | `(quot x y)` | Integer division (truncated toward zero) |
| `round` | `(round x)` | Round to nearest integer |
| `sqrt` | `(sqrt ...)` |  |
| `trunc` | `(trunc ...)` |  |



## Interop

| Function | Signature | Description |
|----------|-----------|-------------|
| `.getTime` | `(.getTime date)` | Return Unix timestamp in milliseconds (**DateTime only**) |
| `.indexOf` | `(.indexOf s substr), (.indexOf s substr from)` | Index of first occurrence starting from position |
| `.lastIndexOf` | `(.lastIndexOf s substr)` | Index of last occurrence, or -1 if not found |
| `NEGATIVE_INFINITY` | `NEGATIVE_INFINITY` | Negative infinity constant (Double/NEGATIVE_INFINITY) |
| `NaN` | `NaN` | Not-a-Number constant (Double/NaN) |
| `POSITIVE_INFINITY` | `POSITIVE_INFINITY` | Positive infinity constant (Double/POSITIVE_INFINITY) |
| `currentTimeMillis` | `(System/currentTimeMillis)` | Return current time in milliseconds since epoch |
| `java.util.Date.` | `(java.util.Date.), (java.util.Date. millis)` | Current UTC time |
| `parse` | `(LocalDate/parse date-str)` | Parse date string to DateTime |


