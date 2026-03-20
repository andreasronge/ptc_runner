# Clojure Core Audit for PTC-Lisp

Auto-generated comparison of `clojure.core` vars against PTC-Lisp builtins.

## Summary

| Status | Count |
|--------|-------|
| ✅ Supported | 150 |
| 🔲 Candidate | 132 |
| ❌ Not Relevant | 252 |
| ❓ Unknown | 0 |
| **Total** | **534** |

## Details

| Var | Status | Description | Notes |
|-----|--------|-------------|-------|
| `*` | ✅ supported | Multiplies numbers; returns 1 with no args |  |
| `*'` | 🔲 candidate | Multiplies numbers with arbitrary precision | pure numerical operation |
| `+` | ✅ supported | Adds numbers; returns 0 with no args |  |
| `+'` | 🔲 candidate | Adds numbers with arbitrary precision | pure numerical operation |
| `-` | ✅ supported | Subtracts numbers or negates single argument |  |
| `-'` | 🔲 candidate | Subtracts numbers with arbitrary precision | pure numerical operation |
| `->` | ✅ supported | Threads expression as second argument through forms |  |
| `->>` | ✅ supported | Threads expression as last argument through forms |  |
| `.` | ❌ not-relevant | Java member access and method calls | Java interop |
| `..` | ❌ not-relevant | Chains member access operations | Java interop |
| `/` | ✅ supported | Divides numbers |  |
| `<` | ✅ supported | Returns true if numbers monotonically increase |  |
| `<=` | ✅ supported | Returns true if numbers non-decreasing |  |
| `=` | ✅ supported | Equality comparison |  |
| `==` | 🔲 candidate | Type-independent numeric equality | pure numeric predicate |
| `>` | ✅ supported | Returns true if numbers monotonically decrease |  |
| `>=` | ✅ supported | Returns true if numbers non-increasing |  |
| `abs` | ✅ supported | Returns absolute value of number |  |
| `accessor` | 🔲 candidate | Returns function accessing structmap value at key | pure functional access to data |
| `aclone` | ❌ not-relevant | Returns clone of Java array | Java array manipulation |
| `add-tap` | ❌ not-relevant | Adds function to receive tap> values | I/O and global state side effects |
| `add-watch` | ❌ not-relevant | Adds watch function to reference | mutable state and referencing |
| `agent` | ❌ not-relevant | Creates agent with initial value | concurrency primitive (mutable state) |
| `agent-error` | ❌ not-relevant | Returns exception from failed agent | depends on agent state and exception handling |
| `aget` | ❌ not-relevant | Returns value at Java array index | Java interop (Java array access) |
| `alength` | ❌ not-relevant | Returns length of Java array | Java interop (Java array length) |
| `alias` | ❌ not-relevant | Adds namespace alias | namespace manipulation |
| `all-ns` | ❌ not-relevant | Returns all namespaces | namespace system |
| `alter` | ❌ not-relevant | Sets ref value in transaction | concurrency primitive (ref mutation) |
| `alter-meta!` | ❌ not-relevant | Atomically sets metadata via function | metadata and mutability |
| `alter-var-root` | ❌ not-relevant | Atomically alters var root binding | var root mutation |
| `amap` | ❌ not-relevant | Maps expression across Java array | Java interop (Java array iteration) |
| `ancestors` | ❌ not-relevant | Returns parents of tag via hierarchy | relies on Clojure's global hierarchy/multimethod system |
| `and` | ✅ supported | Short-circuit logical AND |  |
| `any?` | 🔲 candidate | Returns true for any argument | pure predicate function |
| `apply` | ✅ supported | Applies function to argument sequence |  |
| `areduce` | ❌ not-relevant | Reduces expression across Java array | relies on Java array interoperability |
| `array-map` | 🔲 candidate | Constructs array-map from key-value pairs | pure constructor for map data structure |
| `as->` | ✅ supported | Binds name to expr, threads through forms | threading macro for pure data transformation |
| `aset` | ❌ not-relevant | Sets value in Java array at index | performs mutable operations on Java arrays |
| `assert` | ❌ not-relevant | Throws AssertionError if expr false | relies on exception handling/throwing |
| `assoc` | ✅ supported | Returns map/vector with added key-value pairs |  |
| `assoc!` | ❌ not-relevant | Sets value in transient collection | relies on transient collections (mutability) |
| `assoc-in` | ✅ supported | Associates value in nested structure |  |
| `associative?` | 🔲 candidate | Returns true if coll implements Associative | pure predicate for collection type |
| `atom` | ❌ not-relevant | Creates atom with initial value | relies on mutable state |
| `await` | ❌ not-relevant | Blocks until agent actions complete | relies on agent state |
| `await-for` | ❌ not-relevant | Blocks with timeout for agent actions | relies on agent state |
| `bases` | ❌ not-relevant | Returns immediate superclass and interfaces | Java interop and class inspection |
| `bean` | ❌ not-relevant | Returns map based on JavaBean properties | Java interop (JavaBeans) |
| `bigdec` | 🔲 candidate | Coerces to BigDecimal | pure numerical coercion |
| `bigint` | 🔲 candidate | Coerces to BigInt | pure numerical coercion |
| `biginteger` | 🔲 candidate | Coerces to BigInteger | pure numerical coercion |
| `binding` | ❌ not-relevant | Binds vars to new values for body duration | relies on thread-local var binding mechanism |
| `bit-and` | 🔲 candidate | Bitwise AND | pure bitwise arithmetic |
| `bit-and-not` | 🔲 candidate | Bitwise AND with complement | pure bitwise arithmetic |
| `bit-clear` | 🔲 candidate | Clears bit at index | pure bitwise operation on integers |
| `bit-flip` | 🔲 candidate | Flips bit at index | pure bitwise operation on integers |
| `bit-not` | 🔲 candidate | Bitwise complement | pure bitwise operation on integers |
| `bit-or` | 🔲 candidate | Bitwise OR | pure bitwise operation on integers |
| `bit-set` | 🔲 candidate | Sets bit at index | pure bitwise operation on integers |
| `bit-shift-left` | 🔲 candidate | Bitwise left shift | pure bitwise operation on integers |
| `bit-shift-right` | 🔲 candidate | Bitwise right shift | pure bitwise operation on integers |
| `bit-test` | 🔲 candidate | Tests bit at index | pure bitwise operation on integers |
| `bit-xor` | 🔲 candidate | Bitwise exclusive OR | pure bitwise operation on integers |
| `boolean` | ✅ supported | Coerces to boolean |  |
| `boolean-array` | ❌ not-relevant | Creates boolean Java array | creates Java array, incompatible with BEAM/non-JVM environments |
| `boolean?` | ✅ supported | Returns true if value is Boolean |  |
| `booleans` | ❌ not-relevant | Casts to boolean array | Java array manipulation |
| `bound-fn` | ❌ not-relevant | Returns function with call-site bindings | relies on thread-local/dynamic scope bindings |
| `bound-fn*` | ❌ not-relevant | Returns function applying creation-context bindings | relies on thread-local/dynamic scope bindings |
| `bound?` | ❌ not-relevant | Returns true if all vars have bound value | relies on dynamic var binding state |
| `bounded-count` | ❌ not-relevant | Counts up to n elements | designed for lazy sequences |
| `butlast` | ✅ supported | Returns all but last item |  |
| `byte` | 🔲 candidate | Coerces to byte | pure numerical type coercion |
| `byte-array` | ❌ not-relevant | Creates byte Java array | Java array creation |
| `bytes` | ❌ not-relevant | Casts to byte array | Java array casting |
| `bytes?` | ❌ not-relevant | Returns true if value is byte array | Java array type check |
| `case` | 🔲 candidate | Constant-time dispatch on expression value | pure constant-time dispatch control flow |
| `cast` | ❌ not-relevant | Throws ClassCastException if not instance | relies on Java type system and exception handling |
| `cat` | 🔲 candidate | Transducer concatenating input collections | pure transducer for collection transformation |
| `char` | 🔲 candidate | Coerces to char | pure data type coercion |
| `char-array` | ❌ not-relevant | Creates char Java array | creates Java array |
| `char?` | ✅ supported | Returns true if value is Character |  |
| `chars` | ❌ not-relevant | Casts to char array | relies on Java char array types |
| `class` | ❌ not-relevant | Returns class of value | relies on Java class introspection |
| `class?` | ❌ not-relevant | Returns true if value is Class instance | relies on Java type system |
| `clojure-version` | ❌ not-relevant | Returns Clojure version string | environment info irrelevant to pure data transformation |
| `coll?` | ✅ supported | Returns true if implements IPersistentCollection |  |
| `comment` | ❌ not-relevant | Ignores body, yields nil | REPL/source code construct |
| `commute` | ❌ not-relevant | Sets ref value via commutative function | mutable state primitive (refs) |
| `comp` | ✅ supported | Composes functions right-to-left |  |
| `comparator` | 🔲 candidate | Returns Comparator from predicate | pure function to create a comparison function |
| `compare` | ✅ supported | Compares values returning neg/zero/pos |  |
| `compare-and-set!` | ❌ not-relevant | Atomically sets atom if current equals old | operates on mutable state (atoms) |
| `compile` | ❌ not-relevant | Compiles namespace into classfiles | compilation and class generation |
| `complement` | ✅ supported | Returns function with opposite truth value |  |
| `completing` | 🔲 candidate | Returns reducing function with completion | pure function for reducing transformations |
| `concat` | ✅ supported | Returns lazy seq concatenating collections |  |
| `cond` | ✅ supported | Multi-way conditional |  |
| `cond->` | ✅ supported | Threads through forms where tests true | pure threading macro for logical branching |
| `cond->>` | ✅ supported | Threads as last arg where tests true | pure threading macro for logical branching |
| `condp` | 🔲 candidate | Predicate dispatch against expression | pure control flow dispatch |
| `conj` | ✅ supported | Returns collection with items added |  |
| `conj!` | ❌ not-relevant | Adds item to transient collection | operates on transient collections (mutable) |
| `cons` | ✅ supported | Returns seq with item prepended |  |
| `constantly` | ✅ supported | Returns function ignoring args, returning value |  |
| `contains?` | ✅ supported | Returns true if key present in collection |  |
| `count` | ✅ supported | Returns number of items in collection |  |
| `counted?` | 🔲 candidate | Returns true if constant-time count | pure predicate for collection capabilities |
| `create-ns` | ❌ not-relevant | Creates or returns namespace | requires namespace system |
| `create-struct` | ❌ not-relevant | Returns structure basis object | relies on legacy fixed-key structure system |
| `cycle` | ❌ not-relevant | Returns infinite lazy seq repeating collection | relies on lazy sequences |
| `dec` | ✅ supported | Returns number minus one |  |
| `dec'` | 🔲 candidate | Decrements with arbitrary precision | pure arithmetic function |
| `decimal?` | 🔲 candidate | Returns true if BigDecimal | pure type predicate |
| `declare` | ❌ not-relevant | Defines var names with no bindings | relies on namespace/var system |
| `dedupe` | 🔲 candidate | Removes consecutive duplicates | pure collection transformation |
| `def` | ✅ supported | Creates and interns global var |  |
| `definterface` | ❌ not-relevant | Creates Java interface | Java interop |
| `defmacro` | ❌ not-relevant | Defines macro | macro system |
| `defmethod` | ❌ not-relevant | Creates multimethod implementation | multimethods |
| `defmulti` | ❌ not-relevant | Creates multimethod with dispatch function | multimethods |
| `defn` | ✅ supported | Defines named function |  |
| `defn-` | ❌ not-relevant | Defines private function | namespacing/metadata |
| `defonce` | ✅ supported | Defines var only if not already defined |  |
| `defprotocol` | ❌ not-relevant | Creates protocol with method signatures | protocols |
| `defrecord` | ❌ not-relevant | Creates record type with fields | custom types/Java-like classes |
| `defstruct` | ❌ not-relevant | Creates structure type | obsolete type system |
| `deftype` | ❌ not-relevant | Creates custom type with fields | custom types/Java interop |
| `delay` | ❌ not-relevant | Defers expression evaluation | lazy evaluation/stateful caching |
| `delay?` | ❌ not-relevant | Returns true if value is delay | relies on delay/concurrency which is not supported |
| `deliver` | ❌ not-relevant | Delivers result to promise | relies on promise/mutable state |
| `denominator` | 🔲 candidate | Returns denominator of ratio | pure math operation |
| `deref` | ❌ not-relevant | Dereferences ref/delay/future/promise | relies on mutable state/concurrency types |
| `derive` | ❌ not-relevant | Establishes hierarchical relationship | relies on global namespace/hierarchy state |
| `descendants` | ❌ not-relevant | Returns all descendants of tag | relies on global namespace/hierarchy state |
| `disj` | ✅ supported | Returns set with item removed |  |
| `disj!` | ❌ not-relevant | Removes from transient set | relies on transient/mutable data structures |
| `dissoc` | ✅ supported | Returns map with key removed |  |
| `dissoc!` | ❌ not-relevant | Removes from transient map | relies on transient/mutable data structures |
| `distinct` | ✅ supported | Returns seq removing duplicates |  |
| `distinct?` | 🔲 candidate | Returns true if all args distinct | pure predicate |
| `do` | ✅ supported | Evaluates expressions, returns last |  |
| `doall` | ❌ not-relevant | Realizes entire lazy seq | relies on lazy sequences |
| `dorun` | ❌ not-relevant | Realizes lazy seq, returns nil | relies on lazy sequences |
| `doseq` | ✅ supported | Iterates over sequences for side effects |  |
| `dosync` | ❌ not-relevant | Executes body in STM transaction | relies on concurrency/STM primitives |
| `dotimes` | ❌ not-relevant | Executes body n times with counter | relies on side-effecting loops |
| `doto` | ❌ not-relevant | Calls methods on object, returns object | relies on Java interop |
| `double` | ✅ supported | Coerces to double |  |
| `double-array` | ❌ not-relevant | Creates double Java array | relies on Java arrays |
| `double?` | 🔲 candidate | Returns true if Double | pure predicate for data type checking |
| `doubles` | ❌ not-relevant | Casts to double array | relies on Java arrays |
| `drop` | ✅ supported | Returns seq skipping first n items |  |
| `drop-last` | ✅ supported | Returns seq without last n items |  |
| `drop-while` | ✅ supported | Drops items while predicate true |  |
| `eduction` | ❌ not-relevant | Returns reducible wrapper of transducer | relies on lazy/transducer abstractions |
| `empty` | ✅ supported | Returns empty collection of same type |  |
| `empty?` | ✅ supported | Returns true if collection empty |  |
| `ensure` | ❌ not-relevant | Ensures ref not written by other transaction | relies on software transactional memory (ref/transactional state) |
| `ensure-reduced` | 🔲 candidate | Wraps in reduced if not already | pure utility for reduction flow control |
| `enumeration-seq` | ❌ not-relevant | Lazy seq from Java Enumeration | relies on lazy sequences and Java interop |
| `error-handler` | ❌ not-relevant | Returns agent error handler | relies on agent state |
| `error-mode` | ❌ not-relevant | Returns agent error mode | relies on agent state |
| `eval` | ❌ not-relevant | Evaluates form in current namespace | requires runtime compilation and namespace support |
| `even?` | ✅ supported | Returns true if number is even |  |
| `every-pred` | ✅ supported | Returns combined predicate (all must be true) |  |
| `every?` | ✅ supported | Returns true if pred true for all items |  |
| `ex-cause` | ❌ not-relevant | Returns cause of exception | relies on exception handling |
| `ex-data` | ❌ not-relevant | Returns data map of exception | relies on exception handling |
| `ex-info` | ❌ not-relevant | Creates exception with message and data | relies on exception handling |
| `ex-message` | ❌ not-relevant | Returns exception message string | relies on exception handling |
| `extend` | ❌ not-relevant | Adds protocol implementations for type | relies on protocols |
| `extend-protocol` | ❌ not-relevant | Extends protocol to types | relies on protocols |
| `extend-type` | ❌ not-relevant | Extends type to implement protocol | relies on protocols |
| `extenders` | ❌ not-relevant | Returns types extending protocol | relies on protocols |
| `extends?` | ❌ not-relevant | Returns true if type extends protocol | relies on protocols |
| `false?` | 🔲 candidate | Returns true if value is false | pure predicate |
| `ffirst` | ✅ supported | First of first item |  |
| `file-seq` | ❌ not-relevant | Lazy seq of files in directory tree | relies on lazy sequences and file I/O |
| `filter` | ✅ supported | Returns items where predicate true |  |
| `filterv` | ✅ supported | Returns vector of items where pred true |  |
| `find` | ✅ supported | Returns map entry for key or nil |  |
| `find-keyword` | ❌ not-relevant | Returns keyword with ns and name | relies on namespaces |
| `find-ns` | ❌ not-relevant | Returns namespace or nil | relies on namespace system |
| `find-var` | ❌ not-relevant | Returns var or nil | relies on vars/namespace system |
| `first` | ✅ supported | Returns first item |  |
| `flatten` | ✅ supported | Flattens nested collections |  |
| `float` | ✅ supported | Coerces to float |  |
| `float-array` | ❌ not-relevant | Creates float Java array | creates Java array |
| `float?` | 🔲 candidate | Returns true if Float | pure predicate for data type |
| `floats` | ❌ not-relevant | Casts to float array | handles Java arrays |
| `flush` | ❌ not-relevant | Flushes output writer | I/O operation |
| `fn` | ✅ supported | Defines anonymous function |  |
| `fn?` | 🔲 candidate | Returns true if value is function | pure predicate for function type |
| `fnext` | ✅ supported | First of next item |  |
| `fnil` | ✅ supported | Returns function with nil defaults |  |
| `for` | ✅ supported | List comprehension from nested iteration |  |
| `force` | ❌ not-relevant | Forces evaluation of delay | relies on lazy evaluation/delays |
| `format` | 🔲 candidate | Returns formatted string | pure string formatting function |
| `frequencies` | ✅ supported | Returns map of item frequencies |  |
| `future` | ❌ not-relevant | Async computation | concurrency primitive |
| `future-call` | ❌ not-relevant | Calls function asynchronously | concurrency primitive |
| `future-cancel` | ❌ not-relevant | Cancels future | concurrency primitive |
| `future-cancelled?` | ❌ not-relevant | Returns true if future cancelled | concurrency primitive |
| `future-done?` | ❌ not-relevant | Returns true if future complete | concurrency primitive |
| `future?` | ❌ not-relevant | Returns true if value is future | concurrency primitive |
| `gensym` | ❌ not-relevant | Returns unique symbol | macro system utility |
| `get` | ✅ supported | Returns value for key or nil |  |
| `get-in` | ✅ supported | Returns value at nested key path |  |
| `get-method` | ❌ not-relevant | Returns multimethod implementation | multimethods not supported |
| `get-proxy-class` | ❌ not-relevant | Returns proxy class | Java interop |
| `get-thread-bindings` | ❌ not-relevant | Returns thread-local bindings | concurrency primitive / thread locals |
| `get-validator` | ❌ not-relevant | Returns reference validator | mutable state validator |
| `group-by` | ✅ supported | Groups items by function result |  |
| `halt-when` | ❌ not-relevant | Transducer halting on predicate | relies on transducers which often involve stateful reduction and lazy-like sequence processing |
| `hash` | 🔲 candidate | Returns hash code | pure function computing a value from data |
| `hash-map` | 🔲 candidate | Creates hash map from pairs | pure function creating a hash map data structure |
| `hash-ordered-coll` | 🔲 candidate | Returns hash of ordered collection | pure function computing a hash |
| `hash-set` | 🔲 candidate | Creates hash set from items | pure function creating a hash set data structure |
| `hash-unordered-coll` | 🔲 candidate | Returns hash of unordered collection | pure function computing a hash |
| `ident?` | 🔲 candidate | Returns true if keyword or symbol | pure predicate for data types |
| `identical?` | ❌ not-relevant | Returns true if same object | relies on object identity which is not meaningful for serializable data in a BEAM-based environment |
| `identity` | ✅ supported | Returns argument unchanged |  |
| `if` | ✅ supported | Conditional branch |  |
| `if-let` | ✅ supported | Conditional with binding |  |
| `if-not` | ✅ supported | Negated conditional |  |
| `if-some` | ✅ supported | Binds if not nil | pure control flow structure |
| `ifn?` | 🔲 candidate | Returns true if invokable | pure predicate checking if a value is a function |
| `import` | ❌ not-relevant | Imports Java classes | relies on Java interop |
| `in-ns` | ❌ not-relevant | Changes current namespace | relies on namespace support |
| `inc` | ✅ supported | Returns number plus one |  |
| `inc'` | 🔲 candidate | Increments with arbitrary precision | pure mathematical transformation |
| `indexed?` | 🔲 candidate | Returns true if supports indexed access | predicate for collection structure |
| `infinite?` | 🔲 candidate | Returns true if number infinite | pure numerical predicate |
| `inst-ms` | 🔲 candidate | Milliseconds since epoch for instant | pure data extraction from date object |
| `inst?` | 🔲 candidate | Returns true if instant | pure type predicate |
| `instance?` | ❌ not-relevant | Returns true if instance of class | relies on Java class system |
| `int` | ✅ supported | Coerces to int |  |
| `int-array` | ❌ not-relevant | Creates int Java array | relies on Java array/mutability |
| `int?` | 🔲 candidate | Returns true if Integer | pure type predicate |
| `integer?` | 🔲 candidate | Returns true if integer | pure predicate for data type checking |
| `interleave` | ✅ supported | Interleaves items from collections |  |
| `intern` | ❌ not-relevant | Creates or returns var in namespace | operates on namespaces |
| `interpose` | ✅ supported | Inserts separator between items |  |
| `into` | ✅ supported | Conjoins items from source into target |  |
| `into-array` | ❌ not-relevant | Creates Java array from items | Java interop |
| `ints` | ❌ not-relevant | Casts to int array | Java interop |
| `isa?` | ❌ not-relevant | Returns true if child is parent instance | relies on hierarchy/multimethods system |
| `iterate` | ❌ not-relevant | Lazy seq of repeated function application | creates lazy sequences |
| `iteration` | ❌ not-relevant | Reducible wrapper of iterator | wraps Java iterators |
| `iterator-seq` | ❌ not-relevant | Lazy seq from Java Iterator | creates lazy sequences from Java iterators |
| `juxt` | ✅ supported | Applies multiple functions, collects results |  |
| `keep` | ✅ supported | Keeps non-nil results of function |  |
| `keep-indexed` | 🔲 candidate | Keeps non-nil results with index | pure collection transformation |
| `key` | ✅ supported | Returns key of map entry |  |
| `keys` | ✅ supported | Returns map keys |  |
| `keyword` | 🔲 candidate | Coerces to keyword | pure coercion to keyword type |
| `keyword?` | ✅ supported | Returns true if keyword |  |
| `last` | ✅ supported | Returns last item |  |
| `lazy-cat` | ❌ not-relevant | Lazy concatenation of expressions | relies on lazy sequences |
| `lazy-seq` | ❌ not-relevant | Creates lazy sequence from expression | relies on lazy sequences |
| `let` | ✅ supported | Local variable bindings |  |
| `letfn` | 🔲 candidate | Binds function names for mutual recursion | pure binding of functions for recursion |
| `line-seq` | ❌ not-relevant | Lazy seq of lines from reader | relies on lazy sequences and reader I/O |
| `list` | 🔲 candidate | Creates list from items | pure data structure creation |
| `list*` | 🔲 candidate | Creates list with seq appended | pure list constructor |
| `list?` | 🔲 candidate | Returns true if list | pure predicate |
| `load` | ❌ not-relevant | Loads Clojure file from classpath | relies on file I/O and classpath |
| `load-file` | ❌ not-relevant | Loads Clojure file from path | relies on file I/O |
| `load-reader` | ❌ not-relevant | Loads code from reader | relies on reader I/O |
| `load-string` | ❌ not-relevant | Loads code from string | evaluates code/REPL feature |
| `locking` | ❌ not-relevant | Acquires monitor lock, executes body | concurrency primitive/locking |
| `long` | 🔲 candidate | Coerces to long | type coercion, pure |
| `long-array` | ❌ not-relevant | Creates long Java array | Java interop/primitive array |
| `longs` | ❌ not-relevant | Casts to long array | Java interop/primitive array |
| `loop` | ✅ supported | Loop with recur for tail recursion |  |
| `macroexpand` | ❌ not-relevant | Recursively expands macro | macro system |
| `macroexpand-1` | ❌ not-relevant | Expands macro one level | macro system |
| `make-array` | ❌ not-relevant | Creates Java array | Java interop/array creation |
| `make-hierarchy` | ❌ not-relevant | Returns empty hierarchy | relies on multimethods system |
| `map` | ✅ supported | Applies function to each item |  |
| `map-entry?` | 🔲 candidate | Returns true if map entry | predicate on data structure, pure |
| `map-indexed` | ✅ supported | Applies function with index to items |  |
| `map?` | ✅ supported | Returns true if map |  |
| `mapcat` | ✅ supported | Maps then concatenates results |  |
| `mapv` | ✅ supported | Returns vector from mapping function |  |
| `max` | ✅ supported | Returns greatest number |  |
| `max-key` | ✅ supported | Returns item with greatest function value |  |
| `memfn` | ❌ not-relevant | Returns function calling Java method | relies on Java interop |
| `memoize` | ❌ not-relevant | Caches function results by arguments | relies on mutable state for caching |
| `merge` | ✅ supported | Merges maps |  |
| `merge-with` | ✅ supported | Merges maps with combining function |  |
| `meta` | ❌ not-relevant | Returns metadata | relies on metadata support |
| `methods` | ❌ not-relevant | Returns multimethod implementations | relies on multimethods |
| `min` | ✅ supported | Returns least number |  |
| `min-key` | ✅ supported | Returns item with least function value |  |
| `mod` | ✅ supported | Returns modulo |  |
| `name` | 🔲 candidate | Returns name string of symbol/keyword | pure string property access |
| `namespace` | ❌ not-relevant | Returns namespace of symbol/keyword | relies on namespace support |
| `nat-int?` | 🔲 candidate | Returns true if non-negative integer | pure predicate |
| `neg-int?` | 🔲 candidate | Returns true if negative integer | pure predicate |
| `neg?` | ✅ supported | Returns true if number negative |  |
| `newline` | ❌ not-relevant | Writes newline to output | relies on I/O |
| `next` | ✅ supported | Returns seq after first item |  |
| `nfirst` | ✅ supported | Next of first item |  |
| `nil?` | ✅ supported | Returns true if nil |  |
| `nnext` | ✅ supported | Next of next item |  |
| `not` | ✅ supported | Logical complement |  |
| `not-any?` | ✅ supported | Returns true if pred false for all |  |
| `not-empty` | ✅ supported | Returns collection or nil if empty |  |
| `not-every?` | 🔲 candidate | Returns true if pred false for some | pure predicate logic function |
| `not=` | ✅ supported | Returns true if not equal |  |
| `nth` | ✅ supported | Returns item at index |  |
| `nthnext` | 🔲 candidate | Returns nth next | pure list/sequence navigation |
| `nthrest` | 🔲 candidate | Returns rest after nth item | pure list/sequence navigation |
| `num` | 🔲 candidate | Coerces to number | pure numeric coercion |
| `number?` | ✅ supported | Returns true if number |  |
| `numerator` | 🔲 candidate | Returns numerator of ratio | pure mathematical operation on ratios |
| `object-array` | ❌ not-relevant | Creates object Java array | relies on Java interop and host arrays |
| `odd?` | ✅ supported | Returns true if number odd |  |
| `or` | ✅ supported | Short-circuit logical OR |  |
| `parents` | ❌ not-relevant | Returns immediate parents of tag | metadata/hierarchy manipulation not supported in PTC-Lisp |
| `parse-boolean` | 🔲 candidate | Parses string to boolean | pure string-to-data transformation |
| `parse-double` | ✅ supported | Parses string to double |  |
| `parse-long` | ✅ supported | Parses string to long |  |
| `parse-uuid` | 🔲 candidate | Parses string to UUID | pure string-to-data transformation |
| `partial` | ✅ supported | Fixes supplied arguments to function |  |
| `partition` | ✅ supported | Partitions items into groups of n |  |
| `partition-all` | ✅ supported | Partitions without dropping partial group |  |
| `partition-by` | 🔲 candidate | Partitions by change in function value | pure transformation on sequences |
| `pcalls` | ✅ supported | Parallel calls to zero-arity functions |  |
| `peek` | ✅ supported | Returns last element of vector without removing |  |
| `persistent!` | ❌ not-relevant | Converts transient to persistent | transients are unsupported |
| `pmap` | ✅ supported | Parallel map over collection |  |
| `pop` | ✅ supported | Returns vector without last element |  |
| `pop!` | ❌ not-relevant | Removes from transient collection | transients are unsupported |
| `pos-int?` | 🔲 candidate | Returns true if positive integer | pure predicate |
| `pos?` | ✅ supported | Returns true if number positive |  |
| `pr` | ❌ not-relevant | Prints value in readable form | I/O operation |
| `pr-str` | ✅ supported | Returns readable string of value |  |
| `prefer-method` | ❌ not-relevant | Prefers multimethod implementation | multimethods are unsupported |
| `prefers` | ❌ not-relevant | Returns multimethod preferences | multimethods are unsupported |
| `print` | ❌ not-relevant | Prints value without quoting | I/O operation |
| `print-str` | ❌ not-relevant | Returns printed string of value | relies on printing logic/I/O |
| `printf` | ❌ not-relevant | Prints formatted output | performs stdout I/O |
| `println` | ✅ supported | Prints with newline |  |
| `promise` | ❌ not-relevant | Creates promise | concurrency primitive |
| `proxy` | ❌ not-relevant | Creates proxy implementing interfaces | Java interop |
| `push-thread-bindings` | ❌ not-relevant | Installs thread-local bindings | thread-local mutability/state |
| `qualified-ident?` | 🔲 candidate | Returns true if ident has namespace | pure predicate for data inspection |
| `qualified-keyword?` | 🔲 candidate | Returns true if keyword has namespace | pure predicate for data inspection |
| `qualified-symbol?` | 🔲 candidate | Returns true if symbol has namespace | pure predicate for data inspection |
| `quot` | ✅ supported | Returns integer division quotient |  |
| `quote` | 🔲 candidate | Returns form unevaluated | fundamental Lisp evaluation control |
| `rand` | 🔲 candidate | Returns random float 0-1 | pure data-generating function (if implemented as a pure seeded RNG) |
| `rand-int` | ❌ not-relevant | Returns random int less than arg | relies on non-deterministic side effects/state |
| `rand-nth` | ❌ not-relevant | Returns random item from seq | relies on non-deterministic side effects/state |
| `random-sample` | ❌ not-relevant | Returns random sample of items | relies on non-deterministic side effects/state |
| `random-uuid` | ❌ not-relevant | Returns random UUID | relies on non-deterministic side effects |
| `range` | ✅ supported | Returns sequence of numbers |  |
| `ratio?` | 🔲 candidate | Returns true if ratio | pure type predicate |
| `rational?` | 🔲 candidate | Returns true if rational number | pure type predicate |
| `rationalize` | 🔲 candidate | Coerces to ratio | pure mathematical transformation |
| `re-find` | ✅ supported | Returns first regex match |  |
| `re-groups` | 🔲 candidate | Returns regex match groups | pure string processing function |
| `re-matcher` | ❌ not-relevant | Returns matcher for pattern | returns an object maintaining mutable state/matcher position |
| `re-matches` | ✅ supported | Returns full regex match or nil |  |
| `re-pattern` | ✅ supported | Returns compiled regex pattern |  |
| `re-seq` | ✅ supported | Returns seq of regex matches |  |
| `read` | ❌ not-relevant | Reads next form from reader | implies I/O and interaction with reader contexts |
| `read-line` | ❌ not-relevant | Reads line from input | I/O operation |
| `read-string` | ❌ not-relevant | Reads form from string | invokes reader/eval capabilities not supported in sandbox |
| `realized?` | ❌ not-relevant | Returns true if delay/future complete | relies on concurrency/lazy primitives not supported |
| `record?` | ❌ not-relevant | Returns true if record | relies on class/type system not supported |
| `recur` | ✅ supported | Rebinds loop vars and jumps to loop start |  |
| `reduce` | ✅ supported | Reduces collection with function |  |
| `reduce-kv` | ✅ supported | Reduces map with key-value function |  |
| `reduced` | 🔲 candidate | Wraps value indicating reduction complete | pure control flow mechanism for reduction interruption |
| `reduced?` | 🔲 candidate | Returns true if wrapped in reduced | pure predicate for checking reduction status |
| `reductions` | ❌ not-relevant | Returns intermediate reduction results | returns a lazy sequence |
| `ref` | ❌ not-relevant | Creates STM reference | mutable state/concurrency primitive |
| `ref-set` | ❌ not-relevant | Sets ref value in transaction | mutable state/concurrency primitive |
| `reify` | ❌ not-relevant | Creates instance implementing protocols | relies on protocols and class generation |
| `rem` | ✅ supported | Returns remainder of division |  |
| `remove` | ✅ supported | Returns items where predicate false |  |
| `remove-all-methods` | ❌ not-relevant | Removes all multimethod impls | relies on multimethods |
| `remove-method` | ❌ not-relevant | Removes multimethod impl | relies on multimethods |
| `remove-ns` | ❌ not-relevant | Removes namespace | relies on namespaces |
| `remove-tap` | ❌ not-relevant | Removes function from tap set | relies on global mutable state/taps |
| `remove-watch` | ❌ not-relevant | Removes watch from reference | relies on mutable state references |
| `repeat` | ❌ not-relevant | Returns infinite seq repeating value | returns lazy sequences |
| `repeatedly` | ❌ not-relevant | Returns seq calling function repeatedly | returns lazy sequences |
| `replace` | ✅ supported | Replaces values by map mapping |  |
| `require` | ❌ not-relevant | Requires namespace | relies on namespace/load system |
| `requiring-resolve` | ❌ not-relevant | Requires ns and resolves symbol | relies on namespace/load system |
| `reset!` | ❌ not-relevant | Sets atom value | mutable state (atoms) |
| `reset-meta!` | ❌ not-relevant | Sets metadata | metadata manipulation |
| `reset-vals!` | ❌ not-relevant | Sets atom, returns [old new] | mutable state (atoms) |
| `resolve` | ❌ not-relevant | Resolves symbol in namespace | namespace/symbol resolution |
| `rest` | ✅ supported | Returns seq after first item |  |
| `restart-agent` | ❌ not-relevant | Restarts failed agent | concurrency primitives (agents) |
| `reverse` | ✅ supported | Reverses order of items |  |
| `reversible?` | 🔲 candidate | Returns true if collection reversible | predicate checking collection capability |
| `rseq` | ❌ not-relevant | Returns reverse seq of sorted collection | relies on lazy/sorted sequence implementation details |
| `rsubseq` | ❌ not-relevant | Returns reverse subseq of sorted coll | relies on lazy/sorted sequence implementation details |
| `run!` | ❌ not-relevant | Runs side effects, returns nil | relies on side effects |
| `satisfies?` | ❌ not-relevant | Returns true if type satisfies protocol | protocol/type system feature |
| `second` | ✅ supported | Returns second item |  |
| `select-keys` | ✅ supported | Returns map with only specified keys |  |
| `send` | ❌ not-relevant | Dispatches action to agent | relies on agent mutable state |
| `send-off` | ❌ not-relevant | Dispatches blocking action to agent | relies on agent mutable state |
| `send-via` | ❌ not-relevant | Sends action via executor to agent | relies on agent mutable state |
| `seq` | ✅ supported | Returns sequence or nil if empty |  |
| `seq?` | ✅ supported | Returns true if value is sequence |  |
| `seqable?` | 🔲 candidate | Returns true if implements Seqable | pure predicate checking collection type |
| `sequence` | ❌ not-relevant | Returns seq applying transducer | relies on lazy sequences |
| `sequential?` | ✅ supported | Returns true if sequential |  |
| `set` | ✅ supported | Creates set from items |  |
| `set!` | ❌ not-relevant | Sets thread-local var value | relies on mutable state |
| `set?` | ✅ supported | Returns true if set |  |
| `short` | 🔲 candidate | Coerces to short | pure numerical type coercion |
| `short-array` | ❌ not-relevant | Creates short Java array | relies on Java array instantiation |
| `shorts` | ❌ not-relevant | Casts to short array | relies on Java array interaction |
| `shuffle` | ❌ not-relevant | Returns items in random order | relies on non-deterministic side effects (randomness) |
| `shutdown-agents` | ❌ not-relevant | Shuts down agent thread pool | manages thread pools which is unsupported |
| `simple-ident?` | 🔲 candidate | Returns true if ident has no namespace | pure predicate for data validation |
| `simple-keyword?` | 🔲 candidate | Returns true if keyword has no ns | pure predicate for data validation |
| `simple-symbol?` | 🔲 candidate | Returns true if symbol has no ns | pure predicate for data validation |
| `slurp` | ❌ not-relevant | Reads entire contents of file/URL | involves file/network I/O |
| `some` | ✅ supported | Returns first truthy result or nil |  |
| `some->` | ✅ supported | Threads through forms while non-nil | pure threading macro for data transformation |
| `some->>` | ✅ supported | Threads as last arg while non-nil | pure threading macro for data transformation |
| `some-fn` | ✅ supported | Returns pred true if any fn truthy |  |
| `some?` | ✅ supported | Returns true if not nil |  |
| `sort` | ✅ supported | Returns sorted sequence |  |
| `sort-by` | ✅ supported | Returns seq sorted by function result |  |
| `sorted-map` | 🔲 candidate | Creates sorted map from pairs | pure collection construction |
| `sorted-map-by` | 🔲 candidate | Creates sorted map with comparator | pure collection construction with custom comparator |
| `sorted-set` | 🔲 candidate | Creates sorted set from items | pure collection construction |
| `sorted-set-by` | 🔲 candidate | Creates sorted set with comparator | pure collection construction with custom comparator |
| `sorted?` | 🔲 candidate | Returns true if collection sorted | pure predicate for collection type |
| `spit` | ❌ not-relevant | Writes content to file | file I/O |
| `split-at` | 🔲 candidate | Splits seq at index | pure sequence transformation |
| `split-with` | 🔲 candidate | Splits seq by predicate | pure sequence transformation |
| `str` | ✅ supported | Converts to string |  |
| `string?` | ✅ supported | Returns true if string |  |
| `struct` | ❌ not-relevant | Creates structure instance | legacy structure system, discouraged/deprecated |
| `struct-map` | ❌ not-relevant | Creates structure map from basis | legacy structure system, discouraged/deprecated |
| `subs` | ✅ supported | Returns substring |  |
| `subseq` | 🔲 candidate | Returns subseq of sorted collection | pure operation on sorted collections |
| `subvec` | ✅ supported | Returns subvector (clamps out-of-bounds) |  |
| `supers` | ❌ not-relevant | Returns all ancestors of class | relies on Java class hierarchy/interop |
| `swap!` | ❌ not-relevant | Updates atom with function | requires mutable state (atom) |
| `swap-vals!` | ❌ not-relevant | Updates atom, returns [old new] | requires mutable state (atom) |
| `symbol` | 🔲 candidate | Coerces to symbol | pure data coercion |
| `symbol?` | 🔲 candidate | Returns true if symbol | predicate for pure data type |
| `take` | ✅ supported | Returns first n items |  |
| `take-last` | ✅ supported | Returns last n items |  |
| `take-nth` | ❌ not-relevant | Returns every nth item | returns a lazy sequence |
| `take-while` | ✅ supported | Takes items while predicate true |  |
| `tap>` | ❌ not-relevant | Sends value to taps | side-effecting I/O mechanism |
| `test` | ❌ not-relevant | Runs tests for namespace | built-in testing framework/REPL tool |
| `throw` | ❌ not-relevant | Throws exception | exception handling |
| `time` | ❌ not-relevant | Evaluates and prints elapsed time | side-effecting I/O and timing |
| `to-array` | ❌ not-relevant | Converts to object array | Java interop for array creation |
| `to-array-2d` | ❌ not-relevant | Converts to 2D array | Java interop for array creation |
| `trampoline` | 🔲 candidate | Mutual recursion without stack overflow | Pure mutual recursion utility |
| `transduce` | 🔲 candidate | Reduces with transducer | Pure data transformation utility |
| `transient` | ❌ not-relevant | Creates transient collection | Mutable state/transients are not supported |
| `tree-seq` | ✅ supported | Depth-first seq from root |  |
| `true?` | 🔲 candidate | Returns true if value is true | Pure predicate |
| `try` | ❌ not-relevant | Exception handling | Exception handling is not supported |
| `type` | ✅ supported | Returns type of value |  |
| `unchecked-add` | ❌ not-relevant | Adds without overflow check | Java-specific math optimization |
| `unchecked-add-int` | ❌ not-relevant | Adds ints without overflow check | Java-specific math optimization |
| `unchecked-byte` | ❌ not-relevant | Casts to byte without check | Java-specific primitive casting |
| `unchecked-char` | ❌ not-relevant | Casts to char without check | Relies on Java primitive casting/low-level JVM semantics |
| `unchecked-dec` | ❌ not-relevant | Decrements without overflow check | Relies on Java primitive casting/low-level JVM semantics |
| `unchecked-dec-int` | ❌ not-relevant | Decrements int without check | Relies on Java primitive casting/low-level JVM semantics |
| `unchecked-divide-int` | ❌ not-relevant | Divides ints without check | Relies on Java primitive casting/low-level JVM semantics |
| `unchecked-double` | ❌ not-relevant | Casts to double without check | Relies on Java primitive casting/low-level JVM semantics |
| `unchecked-float` | ❌ not-relevant | Casts to float without check | Relies on Java primitive casting/low-level JVM semantics |
| `unchecked-inc` | ❌ not-relevant | Increments without overflow check | Relies on Java primitive casting/low-level JVM semantics |
| `unchecked-inc-int` | ❌ not-relevant | Increments int without check | Relies on Java primitive casting/low-level JVM semantics |
| `unchecked-int` | ❌ not-relevant | Casts to int without check | Relies on Java primitive casting/low-level JVM semantics |
| `unchecked-long` | ❌ not-relevant | Casts to long without check | Relies on Java primitive casting/low-level JVM semantics |
| `unchecked-multiply` | ❌ not-relevant | Multiplies without overflow check | relies on JVM-specific primitive behavior/overflow semantics |
| `unchecked-multiply-int` | ❌ not-relevant | Multiplies ints without check | relies on JVM-specific primitive behavior/overflow semantics |
| `unchecked-negate` | ❌ not-relevant | Negates without overflow check | relies on JVM-specific primitive behavior/overflow semantics |
| `unchecked-negate-int` | ❌ not-relevant | Negates int without check | relies on JVM-specific primitive behavior/overflow semantics |
| `unchecked-remainder-int` | ❌ not-relevant | Remainder without check | relies on JVM-specific primitive behavior/overflow semantics |
| `unchecked-short` | ❌ not-relevant | Casts to short without check | relies on Java type casting/interop |
| `unchecked-subtract` | ❌ not-relevant | Subtracts without overflow check | relies on JVM-specific primitive behavior/overflow semantics |
| `unchecked-subtract-int` | ❌ not-relevant | Subtracts ints without check | relies on JVM-specific primitive behavior/overflow semantics |
| `underive` | ❌ not-relevant | Removes hierarchical relationship | requires global hierarchy/multimethod infrastructure |
| `unreduced` | 🔲 candidate | Unwraps from reduced | pure transformation used for handling reduced values in reductions |
| `unsigned-bit-shift-right` | 🔲 candidate | Unsigned right shift | pure bitwise arithmetic operation |
| `update` | ✅ supported | Applies function to map value at key |  |
| `update-in` | ✅ supported | Applies function to nested map value |  |
| `update-keys` | ✅ supported | Applies function to map keys |  |
| `update-proxy` | ❌ not-relevant | Updates proxy method implementations | relies on Java interop/proxy class system |
| `update-vals` | ✅ supported | Applies function to map values |  |
| `val` | ✅ supported | Returns value of map entry |  |
| `vals` | ✅ supported | Returns map values |  |
| `var-get` | ❌ not-relevant | Gets value of var | relies on specific var/namespace system |
| `var-set` | ❌ not-relevant | Sets var in thread-local binding | relies on mutable thread-local bindings |
| `var?` | ❌ not-relevant | Returns true if var | relies on var data structure absent in PTC-Lisp |
| `vary-meta` | ❌ not-relevant | Returns value with transformed metadata | relies on metadata feature |
| `vec` | ✅ supported | Converts to vector |  |
| `vector` | ✅ supported | Creates vector from items |  |
| `vector?` | ✅ supported | Returns true if vector |  |
| `volatile!` | ❌ not-relevant | Creates volatile with initial value | relies on mutable state |
| `volatile?` | ❌ not-relevant | Returns true if volatile | relies on mutable state |
| `vreset!` | ❌ not-relevant | Sets volatile value | relies on mutable state |
| `vswap!` | ❌ not-relevant | Updates volatile with function | involves mutable state (volatiles) |
| `when` | ✅ supported | Evaluates body if test true |  |
| `when-first` | ✅ supported | Evaluates body if seq non-empty | pure logic operating on sequences (assuming non-lazy or realized collections) |
| `when-let` | ✅ supported | Binds if truthy, evaluates body |  |
| `when-not` | ✅ supported | Evaluates body if test false |  |
| `when-some` | ✅ supported | Binds if not nil, evaluates body | pure control flow and binding logic |
| `while` | ❌ not-relevant | Repeats body while test true | imperative looping construct typically relying on side effects |
| `with-bindings` | ❌ not-relevant | Executes body with thread-local bindings | relies on thread-local state which is not supported in the BEAM model for PTC-Lisp |
| `with-in-str` | ❌ not-relevant | Evaluates body with string as input | relies on I/O streams |
| `with-local-vars` | ❌ not-relevant | Evaluates body with local var bindings | requires mutable local vars |
| `with-meta` | ❌ not-relevant | Returns value with new metadata | metadata is not supported |
| `with-open` | ❌ not-relevant | Opens resources, closes on exit | relies on I/O and resource management |
| `with-out-str` | ❌ not-relevant | Captures output to string | relies on capturing side-effecting I/O |
| `with-precision` | ❌ not-relevant | Sets decimal precision for body | relies on specific BigDecimal support and dynamic binding context not present in PTC-Lisp |
| `with-redefs` | ❌ not-relevant | Redefines vars for body duration | modifies global var bindings, which is not supported in a functional, immutable sandbox |
| `xml-seq` | ❌ not-relevant | Lazy seq of XML elements | relies on lazy sequences and I/O-related parsing |
| `zero?` | ✅ supported | Returns true if number is zero |  |
| `zipmap` | ✅ supported | Creates map from keys and values seqs |  |
