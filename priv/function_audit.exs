%{
  clojure_core_audit: [
    %{
      name: "*",
      status: :supported,
      description: "Multiplies numbers; returns 1 with no args",
      notes: "BUG GAP-S104: unary nonnumeric inputs are returned unchanged instead of raising"
    },
    %{
      name: "*'",
      status: :supported,
      description: "Multiplies numbers with arbitrary precision",
      notes: "alias for *; BEAM integers are already arbitrary precision"
    },
    %{
      name: "+",
      status: :supported,
      description: "Adds numbers; returns 0 with no args",
      notes: "BUG GAP-S104: unary nonnumeric inputs are returned unchanged instead of raising"
    },
    %{
      name: "+'",
      status: :supported,
      description: "Adds numbers with arbitrary precision",
      notes: "alias for +; BEAM integers are already arbitrary precision"
    },
    %{
      name: "-",
      status: :supported,
      description: "Subtracts numbers or negates single argument",
      notes: "BUG GAP-S28: zero-arity form currently returns 0 instead of raising"
    },
    %{
      name: "-'",
      status: :supported,
      description: "Subtracts numbers with arbitrary precision",
      notes: "alias for -; BEAM integers are already arbitrary precision"
    },
    %{
      name: "->",
      status: :supported,
      description: "Threads expression as second argument through forms",
      notes: "BUG GAP-S128: nil thread form returns nil instead of raising"
    },
    %{
      name: "->>",
      status: :supported,
      description: "Threads expression as last argument through forms",
      notes: "BUG GAP-S128: nil thread form returns nil instead of raising"
    },
    %{
      name: ".",
      status: :not_relevant,
      description: "Java member access and method calls",
      notes: "Java interop"
    },
    %{
      name: "..",
      status: :not_relevant,
      description: "Chains member access operations",
      notes: "Java interop"
    },
    %{
      name: "/",
      status: :supported,
      description: "Divides numbers",
      notes:
        "BUG GAP-S29: unary form currently returns the argument instead of reciprocal. BUG GAP-S69: floating division by zero returns infinity instead of raising. BUG GAP-S104: unary nonnumeric inputs are returned unchanged instead of raising"
    },
    %{
      name: "<",
      status: :supported,
      description: "Returns true if numbers monotonically increase",
      notes: "DIV-30: ordering predicates use PTC's recoverable total term ordering"
    },
    %{
      name: "<=",
      status: :supported,
      description: "Returns true if numbers non-decreasing",
      notes: "DIV-30: ordering predicates use PTC's recoverable total term ordering"
    },
    %{
      name: "=",
      status: :supported,
      description: "Equality comparison",
      notes:
        "DIV-32: numeric equality is type-independent. BUG GAP-S120: character literals compare equal to one-character strings"
    },
    %{
      name: "==",
      status: :supported,
      description: "Type-independent numeric equality",
      notes:
        "alias for numeric equality; BUG GAP-S120: character literals compare equal to strings"
    },
    %{
      name: ">",
      status: :supported,
      description: "Returns true if numbers monotonically decrease",
      notes: "DIV-30: ordering predicates use PTC's recoverable total term ordering"
    },
    %{
      name: ">=",
      status: :supported,
      description: "Returns true if numbers non-increasing",
      notes: "DIV-30: ordering predicates use PTC's recoverable total term ordering"
    },
    %{
      name: "abs",
      status: :supported,
      description: "Returns absolute value of number",
      notes:
        "DIV-37: uses PTC-Lisp arbitrary-precision integers instead of JVM Long/MIN_VALUE overflow"
    },
    %{
      name: "accessor",
      status: :not_relevant,
      description: "Returns function accessing structmap value at key",
      notes: "legacy structmap helper; structmaps are not supported"
    },
    %{
      name: "aclone",
      status: :not_relevant,
      description: "Returns clone of Java array",
      notes: "Java array manipulation"
    },
    %{
      name: "add-tap",
      status: :not_relevant,
      description: "Adds function to receive tap> values",
      notes: "I/O and global state side effects"
    },
    %{
      name: "add-watch",
      status: :not_relevant,
      description: "Adds watch function to reference",
      notes: "mutable state and referencing"
    },
    %{
      name: "agent",
      status: :not_relevant,
      description: "Creates agent with initial value",
      notes: "concurrency primitive (mutable state)"
    },
    %{
      name: "agent-error",
      status: :not_relevant,
      description: "Returns exception from failed agent",
      notes: "depends on agent state and exception handling"
    },
    %{
      name: "aget",
      status: :not_relevant,
      description: "Returns value at Java array index",
      notes: "Java interop (Java array access)"
    },
    %{
      name: "alength",
      status: :not_relevant,
      description: "Returns length of Java array",
      notes: "Java interop (Java array length)"
    },
    %{
      name: "alias",
      status: :not_relevant,
      description: "Adds namespace alias",
      notes: "namespace manipulation"
    },
    %{
      name: "all-ns",
      status: :not_relevant,
      description: "Returns all namespaces",
      notes: "namespace system"
    },
    %{
      name: "alter",
      status: :not_relevant,
      description: "Sets ref value in transaction",
      notes: "concurrency primitive (ref mutation)"
    },
    %{
      name: "alter-meta!",
      status: :not_relevant,
      description: "Atomically sets metadata via function",
      notes: "metadata and mutability"
    },
    %{
      name: "alter-var-root",
      status: :not_relevant,
      description: "Atomically alters var root binding",
      notes: "var root mutation"
    },
    %{
      name: "amap",
      status: :not_relevant,
      description: "Maps expression across Java array",
      notes: "Java interop (Java array iteration)"
    },
    %{
      name: "ancestors",
      status: :not_relevant,
      description: "Returns parents of tag via hierarchy",
      notes: "relies on Clojure's global hierarchy/multimethod system"
    },
    %{name: "and", status: :supported, description: "Short-circuit logical AND", notes: ""},
    %{
      name: "any?",
      status: :candidate,
      description: "Returns true for any argument",
      notes: "pure predicate function"
    },
    %{
      name: "apply",
      status: :supported,
      description: "Applies function to argument sequence",
      notes:
        "BUG GAP-S33: nil and string final arguments currently raise instead of acting seqable. A nil function position raises (not callable), matching Clojure. BUG GAP-S13: vector function position is rejected"
    },
    %{
      name: "areduce",
      status: :not_relevant,
      description: "Reduces expression across Java array",
      notes: "relies on Java array interoperability"
    },
    %{
      name: "array-map",
      status: :supported,
      description: "Constructs array-map from key-value pairs",
      notes: "alias for hash-map; no separate small-map representation"
    },
    %{
      name: "as->",
      status: :supported,
      description: "Binds name to expr, threads through forms",
      notes:
        "BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "aset",
      status: :not_relevant,
      description: "Sets value in Java array at index",
      notes: "performs mutable operations on Java arrays"
    },
    %{
      name: "assert",
      status: :not_relevant,
      description: "Throws AssertionError if expr false",
      notes: "relies on exception handling/throwing"
    },
    %{
      name: "assoc",
      status: :supported,
      description: "Returns map/vector with added key-value pairs",
      notes: "The one-arity form raises (assoc requires key/value pairs), matching Clojure"
    },
    %{
      name: "assoc!",
      status: :not_relevant,
      description: "Sets value in transient collection",
      notes: "relies on transient collections (mutability)"
    },
    %{
      name: "assoc-in",
      status: :supported,
      description: "Associates value in nested structure",
      notes:
        "An empty or nil path associates the value at the nil key, matching Clojure's recursive assoc-in definition"
    },
    %{
      name: "associative?",
      status: :supported,
      description: "Returns true if coll implements Associative",
      notes:
        "BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "atom",
      status: :not_relevant,
      description: "Creates atom with initial value",
      notes: "relies on mutable state"
    },
    %{
      name: "await",
      status: :not_relevant,
      description: "Blocks until agent actions complete",
      notes: "relies on agent state"
    },
    %{
      name: "await-for",
      status: :not_relevant,
      description: "Blocks with timeout for agent actions",
      notes: "relies on agent state"
    },
    %{
      name: "bases",
      status: :not_relevant,
      description: "Returns immediate superclass and interfaces",
      notes: "Java interop and class inspection"
    },
    %{
      name: "bean",
      status: :not_relevant,
      description: "Returns map based on JavaBean properties",
      notes: "Java interop (JavaBeans)"
    },
    %{
      name: "bigdec",
      status: :not_relevant,
      description: "Coerces to BigDecimal",
      notes: "BEAM runtime has no BigDecimal type in PTC-Lisp"
    },
    %{
      name: "bigint",
      status: :not_relevant,
      description: "Coerces to BigInt",
      notes: "BEAM integers are already arbitrary precision"
    },
    %{
      name: "biginteger",
      status: :not_relevant,
      description: "Coerces to BigInteger",
      notes: "JVM-specific BigInteger coercion; BEAM integers are already arbitrary precision"
    },
    %{
      name: "binding",
      status: :not_relevant,
      description: "Binds vars to new values for body duration",
      notes: "relies on thread-local var binding mechanism"
    },
    %{
      name: "bit-and",
      status: :supported,
      description: "Bitwise AND",
      notes:
        "integers only; unary forms raise (require at least two arguments), matching Clojure. BUG GAP-S142: BigInt operands are accepted instead of raising"
    },
    %{
      name: "bit-and-not",
      status: :supported,
      description: "Bitwise AND with complement",
      notes:
        "integers only; unary forms raise (require at least two arguments), matching Clojure. BUG GAP-S142: BigInt operands are accepted instead of raising"
    },
    %{
      name: "bit-clear",
      status: :supported,
      description: "Clears bit at index",
      notes:
        "integers only; BUG GAP-S52: negative or >=64 indexes are not JVM-masked correctly. BUG GAP-S142: BigInt operands are accepted instead of raising"
    },
    %{
      name: "bit-flip",
      status: :supported,
      description: "Flips bit at index",
      notes:
        "integers only; BUG GAP-S52: negative or >=64 indexes are not JVM-masked correctly. BUG GAP-S142: BigInt operands are accepted instead of raising"
    },
    %{
      name: "bit-not",
      status: :supported,
      description: "Bitwise complement",
      notes: "integers only; BUG GAP-S142: BigInt operands are accepted instead of raising"
    },
    %{
      name: "bit-or",
      status: :supported,
      description: "Bitwise OR",
      notes:
        "integers only; unary forms raise (require at least two arguments), matching Clojure. BUG GAP-S142: BigInt operands are accepted instead of raising"
    },
    %{
      name: "bit-set",
      status: :supported,
      description: "Sets bit at index",
      notes:
        "integers only; BUG GAP-S52: negative or >=64 indexes are not JVM-masked correctly. BUG GAP-S142: BigInt operands are accepted instead of raising"
    },
    %{
      name: "bit-shift-left",
      status: :supported,
      description: "Bitwise left shift",
      notes:
        "integers only; BUG GAP-S52: negative shift counts are rejected instead of JVM-masked. BUG GAP-S142: BigInt operands are accepted instead of raising"
    },
    %{
      name: "bit-shift-right",
      status: :supported,
      description: "Bitwise right shift",
      notes:
        "integers only; arithmetic (sign-extending) shift; BUG GAP-S52: negative shift counts are rejected instead of JVM-masked. BUG GAP-S142: BigInt operands are accepted instead of raising"
    },
    %{
      name: "bit-test",
      status: :supported,
      description: "Tests bit at index",
      notes:
        "integers only; BUG GAP-S52: negative or >=64 indexes are not JVM-masked correctly. BUG GAP-S142: BigInt operands are accepted instead of raising"
    },
    %{
      name: "bit-xor",
      status: :supported,
      description: "Bitwise exclusive OR",
      notes:
        "integers only; unary forms raise (require at least two arguments), matching Clojure. BUG GAP-S142: BigInt operands are accepted instead of raising"
    },
    %{name: "boolean", status: :supported, description: "Coerces to boolean", notes: ""},
    %{
      name: "boolean-array",
      status: :not_relevant,
      description: "Creates boolean Java array",
      notes: "creates Java array, incompatible with BEAM/non-JVM environments"
    },
    %{
      name: "boolean?",
      status: :supported,
      description: "Returns true if value is Boolean",
      notes:
        "BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "booleans",
      status: :not_relevant,
      description: "Casts to boolean array",
      notes: "Java array manipulation"
    },
    %{
      name: "bound-fn",
      status: :not_relevant,
      description: "Returns function with call-site bindings",
      notes: "relies on thread-local/dynamic scope bindings"
    },
    %{
      name: "bound-fn*",
      status: :not_relevant,
      description: "Returns function applying creation-context bindings",
      notes: "relies on thread-local/dynamic scope bindings"
    },
    %{
      name: "bound?",
      status: :not_relevant,
      description: "Returns true if all vars have bound value",
      notes: "relies on dynamic var binding state"
    },
    %{
      name: "bounded-count",
      status: :not_relevant,
      description: "Counts up to n elements",
      notes: "designed for lazy sequences"
    },
    %{
      name: "butlast",
      status: :supported,
      description: "Returns all but last item",
      notes:
        "nil, empty, and singleton sequential/string inputs return nil (Clojure empty-seq punning). BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "byte",
      status: :not_relevant,
      description: "Coerces to byte",
      notes: "JVM primitive width coercion"
    },
    %{
      name: "byte-array",
      status: :not_relevant,
      description: "Creates byte Java array",
      notes: "Java array creation"
    },
    %{
      name: "bytes",
      status: :not_relevant,
      description: "Casts to byte array",
      notes: "Java array casting"
    },
    %{
      name: "bytes?",
      status: :not_relevant,
      description: "Returns true if value is byte array",
      notes: "Java array type check"
    },
    %{
      name: "case",
      status: :supported,
      description: "Constant-time dispatch on expression value",
      notes:
        "BUG GAP-S37: no-match/no-default form currently returns nil instead of raising. BUG GAP-S72: duplicate constants are accepted and compound constants are rejected. BUG GAP-S120: character literals dispatch as equal to one-character strings. DIV-32: numeric dispatch follows PTC's type-independent numeric equality"
    },
    %{
      name: "cast",
      status: :not_relevant,
      description: "Throws ClassCastException if not instance",
      notes: "relies on Java type system and exception handling"
    },
    %{
      name: "cat",
      status: :not_relevant,
      description: "Transducer concatenating input collections",
      notes: "transducers are not supported"
    },
    %{
      name: "char",
      status: :not_relevant,
      description: "Coerces to char",
      notes: "JVM character coercion; PTC-Lisp strings are UTF-8 binaries"
    },
    %{
      name: "char-array",
      status: :not_relevant,
      description: "Creates char Java array",
      notes: "creates Java array"
    },
    %{
      name: "char?",
      status: :supported,
      description: "Returns true if value is Character",
      notes: "BUG GAP-S44: one-character strings currently return true"
    },
    %{
      name: "chars",
      status: :not_relevant,
      description: "Casts to char array",
      notes: "relies on Java char array types"
    },
    %{
      name: "class",
      status: :not_relevant,
      description: "Returns class of value",
      notes: "relies on Java class introspection"
    },
    %{
      name: "class?",
      status: :not_relevant,
      description: "Returns true if value is Class instance",
      notes: "relies on Java type system"
    },
    %{
      name: "clojure-version",
      status: :not_relevant,
      description: "Returns Clojure version string",
      notes: "environment info irrelevant to pure data transformation"
    },
    %{
      name: "coll?",
      status: :supported,
      description: "Returns true if implements IPersistentCollection",
      notes: ""
    },
    %{
      name: "comment",
      status: :not_relevant,
      description: "Ignores body, yields nil",
      notes: "REPL/source code construct"
    },
    %{
      name: "commute",
      status: :not_relevant,
      description: "Sets ref value via commutative function",
      notes: "mutable state primitive (refs)"
    },
    %{
      name: "comp",
      status: :supported,
      description: "Composes functions right-to-left",
      notes:
        "BUG GAP-S71: map/set/vector callables are rejected in composed function position. A nil composed function raises when called (not callable), matching Clojure"
    },
    %{
      name: "comparator",
      status: :candidate,
      description: "Returns Comparator from predicate",
      notes: "pure function to create a comparison function"
    },
    %{
      name: "compare",
      status: :supported,
      description: "Compares values returning neg/zero/pos",
      notes:
        "DIV-30: uses PTC's recoverable total term ordering for nil, maps, and mixed values; DIV-33: NaN is unordered and raises"
    },
    %{
      name: "compare-and-set!",
      status: :not_relevant,
      description: "Atomically sets atom if current equals old",
      notes: "operates on mutable state (atoms)"
    },
    %{
      name: "compile",
      status: :not_relevant,
      description: "Compiles namespace into classfiles",
      notes: "compilation and class generation"
    },
    %{
      name: "complement",
      status: :supported,
      description: "Returns function with opposite truth value",
      notes: "BUG GAP-S71: map/set callables are rejected in predicate position"
    },
    %{
      name: "completing",
      status: :candidate,
      description: "Returns reducing function with completion",
      notes: "pure function for reducing transformations"
    },
    %{
      name: "concat",
      status: :supported,
      description: "Returns lazy seq concatenating collections",
      notes: "BUG GAP-S57: string inputs currently raise instead of being treated as seqable"
    },
    %{
      name: "cond",
      status: :supported,
      description: "Multi-way conditional",
      notes: "The zero-clause form returns nil, matching Clojure"
    },
    %{
      name: "cond->",
      status: :supported,
      description: "Threads through forms where tests true",
      notes:
        "BUG GAP-S123: trailing unmatched test raises instead of acting as a no-op. BUG GAP-S128: truthy nil thread form returns nil instead of raising"
    },
    %{
      name: "cond->>",
      status: :supported,
      description: "Threads as last arg where tests true",
      notes:
        "BUG GAP-S123: trailing unmatched test raises instead of acting as a no-op. BUG GAP-S128: truthy nil thread form returns nil instead of raising"
    },
    %{
      name: "condp",
      status: :supported,
      description: "Predicate dispatch against expression",
      notes:
        "BUG GAP-S38: :>> result-function clauses are unsupported. BUG GAP-S103: no-match/no-default form currently returns nil instead of raising"
    },
    %{
      name: "conj",
      status: :supported,
      description: "Returns collection with items added",
      notes:
        "BUG GAP-S76: conjoining a map into a map currently raises instead of merging entries. The zero-arity form returns an empty vector (Clojure's conj identity). BUG GAP-S137: list pairs are treated as map entries instead of raising. DIV-25: nil/list targets use vector append semantics"
    },
    %{
      name: "conj!",
      status: :not_relevant,
      description: "Adds item to transient collection",
      notes: "operates on transient collections (mutable)"
    },
    %{
      name: "cons",
      status: :supported,
      description: "Returns seq with item prepended",
      notes:
        "BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "constantly",
      status: :supported,
      description: "Returns function ignoring args, returning value",
      notes: ""
    },
    %{
      name: "contains?",
      status: :supported,
      description: "Returns true if key present in collection",
      notes:
        "DIV-27 for sequential collections and map entries; returns false for a nil collection (matching Clojure); BUG GAP-S35 on string indexes, including numeric indexes Clojure accepts"
    },
    %{
      name: "count",
      status: :supported,
      description: "Returns number of items in collection",
      notes:
        "DIV-36: string counts use Unicode graphemes instead of JVM UTF-16 code units. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "counted?",
      status: :supported,
      description: "Returns true if constant-time count",
      notes: "BUG GAP-S70: strings currently return true but Clojure returns false"
    },
    %{
      name: "create-ns",
      status: :not_relevant,
      description: "Creates or returns namespace",
      notes: "requires namespace system"
    },
    %{
      name: "create-struct",
      status: :not_relevant,
      description: "Returns structure basis object",
      notes: "relies on legacy fixed-key structure system"
    },
    %{
      name: "cycle",
      status: :not_relevant,
      description: "Returns infinite lazy seq repeating collection",
      notes: "relies on lazy sequences"
    },
    %{name: "dec", status: :supported, description: "Returns number minus one", notes: ""},
    %{
      name: "dec'",
      status: :supported,
      description: "Decrements with arbitrary precision",
      notes: "alias for dec; BEAM integers are already arbitrary precision"
    },
    %{
      name: "decimal?",
      status: :supported,
      description: "Returns true if BigDecimal",
      notes: "always false; BigDecimal literals are unsupported, see DIV-20"
    },
    %{
      name: "declare",
      status: :not_relevant,
      description: "Defines var names with no bindings",
      notes: "relies on namespace/var system"
    },
    %{
      name: "dedupe",
      status: :supported,
      description: "Removes consecutive duplicates",
      notes:
        "BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "def",
      status: :supported,
      description: "Creates and interns global var",
      notes:
        "BUG GAP-S140: no-init def raises instead of creating an unbound var. BUG GAP-S141: return value omits the user namespace"
    },
    %{
      name: "definterface",
      status: :not_relevant,
      description: "Creates Java interface",
      notes: "Java interop"
    },
    %{
      name: "defmacro",
      status: :not_relevant,
      description: "Defines macro",
      notes: "macro system"
    },
    %{
      name: "defmethod",
      status: :not_relevant,
      description: "Creates multimethod implementation",
      notes: "multimethods"
    },
    %{
      name: "defmulti",
      status: :not_relevant,
      description: "Creates multimethod with dispatch function",
      notes: "multimethods"
    },
    %{
      name: "defn",
      status: :supported,
      description: "Defines named function",
      notes:
        "DIV-15: multi-arity defn is intentionally unsupported. BUG GAP-S118/GAP-S119: parameter destructuring misses associative vector sources and rest key/value coercion"
    },
    %{
      name: "defn-",
      status: :not_relevant,
      description: "Defines private function",
      notes: "namespacing/metadata"
    },
    %{
      name: "defonce",
      status: :supported,
      description: "Defines var only if not already defined",
      notes: "BUG GAP-S141: return value omits the user namespace"
    },
    %{
      name: "defprotocol",
      status: :not_relevant,
      description: "Creates protocol with method signatures",
      notes: "protocols"
    },
    %{
      name: "defrecord",
      status: :not_relevant,
      description: "Creates record type with fields",
      notes: "custom types/Java-like classes"
    },
    %{
      name: "defstruct",
      status: :not_relevant,
      description: "Creates structure type",
      notes: "obsolete type system"
    },
    %{
      name: "deftype",
      status: :not_relevant,
      description: "Creates custom type with fields",
      notes: "custom types/Java interop"
    },
    %{
      name: "delay",
      status: :not_relevant,
      description: "Defers expression evaluation",
      notes: "lazy evaluation/stateful caching"
    },
    %{
      name: "delay?",
      status: :not_relevant,
      description: "Returns true if value is delay",
      notes: "relies on delay/concurrency which is not supported"
    },
    %{
      name: "deliver",
      status: :not_relevant,
      description: "Delivers result to promise",
      notes: "relies on promise/mutable state"
    },
    %{
      name: "denominator",
      status: :not_relevant,
      description: "Returns denominator of ratio",
      notes: "ratio values are not supported"
    },
    %{
      name: "deref",
      status: :not_relevant,
      description: "Dereferences ref/delay/future/promise",
      notes: "relies on mutable state/concurrency types"
    },
    %{
      name: "derive",
      status: :not_relevant,
      description: "Establishes hierarchical relationship",
      notes: "relies on global namespace/hierarchy state"
    },
    %{
      name: "descendants",
      status: :not_relevant,
      description: "Returns all descendants of tag",
      notes: "relies on global namespace/hierarchy state"
    },
    %{name: "disj", status: :supported, description: "Returns set with item removed", notes: ""},
    %{
      name: "disj!",
      status: :not_relevant,
      description: "Removes from transient set",
      notes: "relies on transient/mutable data structures"
    },
    %{
      name: "dissoc",
      status: :supported,
      description: "Returns map with key removed",
      notes: "BUG GAP-S19: nil map root currently raises instead of returning nil"
    },
    %{
      name: "dissoc!",
      status: :not_relevant,
      description: "Removes from transient map",
      notes: "relies on transient/mutable data structures"
    },
    %{
      name: "distinct",
      status: :supported,
      description: "Returns seq removing duplicates",
      notes:
        "BUG GAP-S20: nil input currently raises instead of returning an empty seq. BUG GAP-S134: direct map input returns entries instead of raising"
    },
    %{
      name: "distinct?",
      status: :supported,
      description: "Returns true if all args distinct",
      notes:
        "BUG GAP-S64: zero-arity distinct? returns true instead of raising. BUG GAP-S101: repeated NaN values are treated as duplicates"
    },
    %{
      name: "do",
      status: :supported,
      description: "Evaluates expressions, returns last",
      notes: ""
    },
    %{
      name: "doall",
      status: :not_relevant,
      description: "Realizes entire lazy seq",
      notes: "relies on lazy sequences"
    },
    %{
      name: "dorun",
      status: :not_relevant,
      description: "Realizes lazy seq, returns nil",
      notes: "relies on lazy sequences"
    },
    %{
      name: "doseq",
      status: :supported,
      description: "Iterates over sequences for side effects",
      notes: "BUG GAP-S18: def side effects inside doseq are not visible after the loop"
    },
    %{
      name: "dosync",
      status: :not_relevant,
      description: "Executes body in STM transaction",
      notes: "relies on concurrency/STM primitives"
    },
    %{
      name: "dotimes",
      status: :not_relevant,
      description: "Executes body n times with counter",
      notes: "relies on side-effecting loops"
    },
    %{
      name: "doto",
      status: :not_relevant,
      description: "Calls methods on object, returns object",
      notes: "relies on Java interop"
    },
    %{name: "double", status: :supported, description: "Coerces to double", notes: ""},
    %{
      name: "double-array",
      status: :not_relevant,
      description: "Creates double Java array",
      notes: "relies on Java arrays"
    },
    %{
      name: "double?",
      status: :supported,
      description: "Returns true if Double",
      notes: "BUG GAP-S127: special float literals return false instead of true"
    },
    %{
      name: "doubles",
      status: :not_relevant,
      description: "Casts to double array",
      notes: "relies on Java arrays"
    },
    %{
      name: "drop",
      status: :supported,
      description: "Returns seq skipping first n items",
      notes:
        "BUG GAP-S20: nil input currently raises instead of returning an empty seq; BUG GAP-S32: negative count drops from the end instead of returning the input; BUG GAP-S79: numeric count coercion rejects floats Clojure accepts"
    },
    %{
      name: "drop-last",
      status: :supported,
      description: "Returns seq without last n items",
      notes:
        "BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "drop-while",
      status: :supported,
      description: "Drops items while predicate true",
      notes:
        "BUG GAP-S71: map/vector callables are rejected in predicate position. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "eduction",
      status: :not_relevant,
      description: "Returns reducible wrapper of transducer",
      notes: "relies on lazy/transducer abstractions"
    },
    %{
      name: "empty",
      status: :supported,
      description: "Returns empty collection of same type",
      notes:
        "BUG GAP-S56: string input returns an empty string instead of nil. BUG GAP-S88: non-collection inputs should return nil but currently raise or return an empty map"
    },
    %{
      name: "empty?",
      status: :supported,
      description: "Returns true if collection empty",
      notes:
        "BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "ensure",
      status: :not_relevant,
      description: "Ensures ref not written by other transaction",
      notes: "relies on software transactional memory (ref/transactional state)"
    },
    %{
      name: "ensure-reduced",
      status: :candidate,
      description: "Wraps in reduced if not already",
      notes: "pure utility for reduction flow control"
    },
    %{
      name: "enumeration-seq",
      status: :not_relevant,
      description: "Lazy seq from Java Enumeration",
      notes: "relies on lazy sequences and Java interop"
    },
    %{
      name: "error-handler",
      status: :not_relevant,
      description: "Returns agent error handler",
      notes: "relies on agent state"
    },
    %{
      name: "error-mode",
      status: :not_relevant,
      description: "Returns agent error mode",
      notes: "relies on agent state"
    },
    %{
      name: "eval",
      status: :not_relevant,
      description: "Evaluates form in current namespace",
      notes: "requires runtime compilation and namespace support"
    },
    %{
      name: "even?",
      status: :supported,
      description: "Returns true if number is even",
      notes: "DIV-31: numeric predicates return false for non-numeric inputs"
    },
    %{
      name: "every-pred",
      status: :supported,
      description: "Returns combined predicate (all must be true)",
      notes: "BUG GAP-S71: map/set/vector callables are rejected in predicate position"
    },
    %{
      name: "every?",
      status: :supported,
      description: "Returns true if pred true for all items",
      notes:
        "BUG GAP-S71: map/vector callables are rejected in predicate position. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "ex-cause",
      status: :not_relevant,
      description: "Returns cause of exception",
      notes: "relies on exception handling"
    },
    %{
      name: "ex-data",
      status: :not_relevant,
      description: "Returns data map of exception",
      notes: "relies on exception handling"
    },
    %{
      name: "ex-info",
      status: :not_relevant,
      description: "Creates exception with message and data",
      notes: "relies on exception handling"
    },
    %{
      name: "ex-message",
      status: :not_relevant,
      description: "Returns exception message string",
      notes: "relies on exception handling"
    },
    %{
      name: "extend",
      status: :not_relevant,
      description: "Adds protocol implementations for type",
      notes: "relies on protocols"
    },
    %{
      name: "extend-protocol",
      status: :not_relevant,
      description: "Extends protocol to types",
      notes: "relies on protocols"
    },
    %{
      name: "extend-type",
      status: :not_relevant,
      description: "Extends type to implement protocol",
      notes: "relies on protocols"
    },
    %{
      name: "extenders",
      status: :not_relevant,
      description: "Returns types extending protocol",
      notes: "relies on protocols"
    },
    %{
      name: "extends?",
      status: :not_relevant,
      description: "Returns true if type extends protocol",
      notes: "relies on protocols"
    },
    %{
      name: "false?",
      status: :supported,
      description: "Returns true if value is false",
      notes: ""
    },
    %{
      name: "ffirst",
      status: :supported,
      description: "First of first item",
      notes: "nil input returns nil, matching Clojure"
    },
    %{
      name: "file-seq",
      status: :not_relevant,
      description: "Lazy seq of files in directory tree",
      notes: "relies on lazy sequences and file I/O"
    },
    %{
      name: "filter",
      status: :supported,
      description: "Returns items where predicate true",
      notes:
        "BUG GAP-S71: map callables are rejected in predicate position. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "filterv",
      status: :supported,
      description: "Returns vector of items where pred true",
      notes:
        "BUG GAP-S71: map callables are rejected in predicate position. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "find",
      status: :supported,
      description: "Returns map entry for key or nil",
      notes:
        "BUG GAP-S09: currently implements predicate-search semantics instead of associative lookup"
    },
    %{
      name: "find-keyword",
      status: :not_relevant,
      description: "Returns keyword with ns and name",
      notes: "relies on namespaces"
    },
    %{
      name: "find-ns",
      status: :not_relevant,
      description: "Returns namespace or nil",
      notes: "relies on namespace system"
    },
    %{
      name: "find-var",
      status: :not_relevant,
      description: "Returns var or nil",
      notes: "relies on vars/namespace system"
    },
    %{
      name: "first",
      status: :supported,
      description: "Returns first item",
      notes:
        "DIV-29: direct map input raises; use seq/entries/keys/vals for ordered map views. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "flatten",
      status: :supported,
      description: "Flattens nested collections",
      notes:
        "BUG GAP-S20: nil input currently raises instead of returning an empty seq. BUG GAP-S81: scalar/string/character/map roots raise instead of returning an empty seq"
    },
    %{
      name: "float",
      status: :supported,
      description: "Coerces to float",
      notes: "BUG GAP-S122: infinite inputs return infinities instead of raising"
    },
    %{
      name: "float-array",
      status: :not_relevant,
      description: "Creates float Java array",
      notes: "creates Java array"
    },
    %{
      name: "float?",
      status: :supported,
      description: "Returns true if Float",
      notes: "BUG GAP-S127: special float literals return false instead of true"
    },
    %{
      name: "floats",
      status: :not_relevant,
      description: "Casts to float array",
      notes: "handles Java arrays"
    },
    %{
      name: "flush",
      status: :not_relevant,
      description: "Flushes output writer",
      notes: "I/O operation"
    },
    %{
      name: "fn",
      status: :supported,
      description: "Defines anonymous function",
      notes:
        "DIV-15: multi-arity fn is intentionally unsupported. BUG GAP-S39: vector destructuring :as patterns are unsupported in params. BUG GAP-S86: map destructuring :syms is unsupported in params. BUG GAP-S87: vector destructuring rejects string inputs in params. BUG GAP-S97: vector rest destructuring binds nil input rest as [] in params. BUG GAP-S118/GAP-S119: parameter destructuring misses associative vector sources and rest key/value coercion"
    },
    %{
      name: "fn?",
      status: :supported,
      description: "Returns true if value is function",
      notes: ""
    },
    %{
      name: "fnext",
      status: :supported,
      description: "First of next item",
      notes: "nil input returns nil, matching Clojure"
    },
    %{
      name: "fnil",
      status: :supported,
      description: "Returns function with nil defaults",
      notes:
        "BUG GAP-S42: two- and three-default arities are unsupported. BUG GAP-S71: keyword/map/set/vector callables are rejected in function position"
    },
    %{
      name: "for",
      status: :supported,
      description: "List comprehension from nested iteration",
      notes:
        "BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "force",
      status: :not_relevant,
      description: "Forces evaluation of delay",
      notes: "relies on lazy evaluation/delays"
    },
    %{
      name: "format",
      status: :supported,
      description: "Returns formatted string",
      notes:
        "DIV-39: %s collection rendering uses deterministic PTC readable formatting. BUG GAP-S65: width/alignment/zero-padding and sign flags are currently ignored or rejected. BUG GAP-S89: boolean and newline conversions are currently rejected. BUG GAP-S96: several Java Formatter conversions and argument indexes are unsupported. BUG GAP-S117: supported numeric conversions reject nil instead of rendering null"
    },
    %{
      name: "frequencies",
      status: :supported,
      description: "Returns map of item frequencies",
      notes:
        "BUG GAP-S20: nil input currently raises instead of returning an empty frequency map; direct map input raises instead of counting map entries. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "future",
      status: :not_relevant,
      description: "Async computation",
      notes: "concurrency primitive"
    },
    %{
      name: "future-call",
      status: :not_relevant,
      description: "Calls function asynchronously",
      notes: "concurrency primitive"
    },
    %{
      name: "future-cancel",
      status: :not_relevant,
      description: "Cancels future",
      notes: "concurrency primitive"
    },
    %{
      name: "future-cancelled?",
      status: :not_relevant,
      description: "Returns true if future cancelled",
      notes: "concurrency primitive"
    },
    %{
      name: "future-done?",
      status: :not_relevant,
      description: "Returns true if future complete",
      notes: "concurrency primitive"
    },
    %{
      name: "future?",
      status: :not_relevant,
      description: "Returns true if value is future",
      notes: "concurrency primitive"
    },
    %{
      name: "gensym",
      status: :not_relevant,
      description: "Returns unique symbol",
      notes: "macro system utility"
    },
    %{
      name: "get",
      status: :supported,
      description: "Returns value for key or nil",
      notes:
        "BUG GAP-S12: string indexes and non-index keys currently raise. BUG GAP-S36: set lookup currently raises instead of returning value/default, including nil members"
    },
    %{
      name: "get-in",
      status: :supported,
      description: "Returns value at nested key path",
      notes:
        "BUG GAP-S19: nil map root currently raises instead of returning nil/default; BUG GAP-S22: default is returned for explicitly present nil values in maps/vectors; BUG GAP-S12: string indexes currently raise; BUG GAP-S36: set roots currently raise instead of using set lookup. A nil path returns the root value, matching Clojure"
    },
    %{
      name: "get-method",
      status: :not_relevant,
      description: "Returns multimethod implementation",
      notes: "multimethods not supported"
    },
    %{
      name: "get-proxy-class",
      status: :not_relevant,
      description: "Returns proxy class",
      notes: "Java interop"
    },
    %{
      name: "get-thread-bindings",
      status: :not_relevant,
      description: "Returns thread-local bindings",
      notes: "concurrency primitive / thread locals"
    },
    %{
      name: "get-validator",
      status: :not_relevant,
      description: "Returns reference validator",
      notes: "mutable state validator"
    },
    %{
      name: "group-by",
      status: :supported,
      description: "Groups items by function result",
      notes:
        "BUG GAP-S67: string inputs are rejected instead of treated as seqable. BUG GAP-S71: map/set/vector callables are rejected or misapplied as key functions"
    },
    %{
      name: "halt-when",
      status: :not_relevant,
      description: "Transducer halting on predicate",
      notes:
        "relies on transducers which often involve stateful reduction and lazy-like sequence processing"
    },
    %{
      name: "hash",
      status: :not_relevant,
      description: "Returns hash code",
      notes: "runtime-specific hash values are not stable across hosts"
    },
    %{
      name: "hash-map",
      status: :supported,
      description: "Creates hash map from pairs",
      notes: ""
    },
    %{
      name: "hash-ordered-coll",
      status: :not_relevant,
      description: "Returns hash of ordered collection",
      notes: "Clojure hashing internals; not stable across PTC-Lisp hosts"
    },
    %{
      name: "hash-set",
      status: :supported,
      description: "Creates hash set from items",
      notes: "constructs a PTC-Lisp set from variadic arguments"
    },
    %{
      name: "hash-unordered-coll",
      status: :not_relevant,
      description: "Returns hash of unordered collection",
      notes: "Clojure hashing internals; not stable across PTC-Lisp hosts"
    },
    %{
      name: "ident?",
      status: :not_relevant,
      description: "Returns true if keyword or symbol",
      notes: "PTC-Lisp has keywords but no first-class symbol or namespaced identifier values"
    },
    %{
      name: "identical?",
      status: :not_relevant,
      description: "Returns true if same object",
      notes:
        "relies on object identity which is not meaningful for serializable data in a BEAM-based environment"
    },
    %{name: "identity", status: :supported, description: "Returns argument unchanged", notes: ""},
    %{name: "if", status: :supported, description: "Conditional branch", notes: ""},
    %{
      name: "if-let",
      status: :supported,
      description: "Conditional with binding",
      notes:
        "DIV-14: destructuring bindings are intentionally unsupported. BUG GAP-S115: no-else arity is unsupported. BUG GAP-S145: extra binding-vector forms are rejected instead of ignored"
    },
    %{name: "if-not", status: :supported, description: "Negated conditional", notes: ""},
    %{
      name: "if-some",
      status: :supported,
      description: "Binds if not nil",
      notes:
        "DIV-14: destructuring bindings are intentionally unsupported. BUG GAP-S115: no-else arity is unsupported. BUG GAP-S145: extra binding-vector forms are rejected instead of ignored"
    },
    %{
      name: "ifn?",
      status: :supported,
      description: "Returns true if invokable",
      notes: "BUG GAP-S13: vectors are callable in Clojure but not in PTC-Lisp"
    },
    %{
      name: "import",
      status: :not_relevant,
      description: "Imports Java classes",
      notes: "relies on Java interop"
    },
    %{
      name: "in-ns",
      status: :not_relevant,
      description: "Changes current namespace",
      notes: "relies on namespace support"
    },
    %{name: "inc", status: :supported, description: "Returns number plus one", notes: ""},
    %{
      name: "inc'",
      status: :supported,
      description: "Increments with arbitrary precision",
      notes: "alias for inc; BEAM integers are already arbitrary precision"
    },
    %{
      name: "indexed?",
      status: :supported,
      description: "Returns true if supports indexed access",
      notes: "BUG GAP-S70: strings currently return true but Clojure returns false"
    },
    %{
      name: "infinite?",
      status: :supported,
      description: "Returns true if number infinite",
      notes: "DIV-31: returns false for nil/non-numeric inputs instead of raising"
    },
    %{
      name: "NaN?",
      status: :supported,
      description: "Returns true if number is NaN",
      notes: "DIV-31: returns false for nil/non-numeric inputs instead of raising"
    },
    %{
      name: "inst-ms",
      status: :not_relevant,
      description: "Milliseconds since epoch for instant",
      notes: "covered by existing temporal interop .getTime"
    },
    %{
      name: "inst?",
      status: :not_relevant,
      description: "Returns true if instant",
      notes: "Clojure instant predicate; PTC-Lisp temporal interop uses host date structs"
    },
    %{
      name: "instance?",
      status: :not_relevant,
      description: "Returns true if instance of class",
      notes: "relies on Java class system"
    },
    %{
      name: "int",
      status: :supported,
      description: "Coerces to int",
      notes:
        "BUG GAP-S62: NaN input raises instead of returning 0. BUG GAP-S111: out-of-range integer inputs return unchanged instead of raising. BUG GAP-S121: character literals raise instead of returning code points"
    },
    %{
      name: "int-array",
      status: :not_relevant,
      description: "Creates int Java array",
      notes: "relies on Java array/mutability"
    },
    %{
      name: "int?",
      status: :supported,
      description: "Returns true if Integer",
      notes: "DIV-37: arbitrary-precision PTC integers have no distinct JVM int/long width"
    },
    %{name: "integer?", status: :supported, description: "Returns true if integer", notes: ""},
    %{
      name: "interleave",
      status: :supported,
      description: "Interleaves items from collections",
      notes:
        "Variadic (0/1/n arity) over lists. BUG GAP-S20: nil inputs currently raise instead of returning an empty seq. BUG GAP-S98: string inputs currently raise instead of being treated as seqable. DIV-29: direct map input raises; use seq/entries/keys/vals for ordered map views."
    },
    %{
      name: "intern",
      status: :not_relevant,
      description: "Creates or returns var in namespace",
      notes: "operates on namespaces"
    },
    %{
      name: "interpose",
      status: :supported,
      description: "Inserts separator between items",
      notes:
        "Strings are seqable (interposed as characters). DIV-29: direct map input raises; use seq/entries/keys/vals for ordered map views."
    },
    %{
      name: "into",
      status: :supported,
      description: "Conjoins items from source into target",
      notes:
        "BUG GAP-S41: zero/one arities, string sources, and nil targets currently raise instead of following Clojure seq/list behavior"
    },
    %{
      name: "into-array",
      status: :not_relevant,
      description: "Creates Java array from items",
      notes: "Java interop"
    },
    %{
      name: "ints",
      status: :not_relevant,
      description: "Casts to int array",
      notes: "Java interop"
    },
    %{
      name: "isa?",
      status: :not_relevant,
      description: "Returns true if child is parent instance",
      notes: "relies on hierarchy/multimethods system"
    },
    %{
      name: "iterate",
      status: :not_relevant,
      description: "Lazy seq of repeated function application",
      notes: "creates lazy sequences"
    },
    %{
      name: "iteration",
      status: :not_relevant,
      description: "Reducible wrapper of iterator",
      notes: "wraps Java iterators"
    },
    %{
      name: "iterator-seq",
      status: :not_relevant,
      description: "Lazy seq from Java Iterator",
      notes: "creates lazy sequences from Java iterators"
    },
    %{
      name: "juxt",
      status: :supported,
      description: "Applies multiple functions, collects results",
      notes:
        "BUG GAP-S58: resulting function currently supports only one call argument. Zero-arity juxt raises (requires at least one function), matching Clojure. BUG GAP-S71: map/set/vector callables are rejected in function position"
    },
    %{
      name: "keep",
      status: :supported,
      description: "Keeps non-nil results of function",
      notes:
        "BUG GAP-S71: map/vector callables are rejected in function position. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "keep-indexed",
      status: :supported,
      description: "Keeps non-nil results with index",
      notes:
        "BUG GAP-S71: map callables are rejected in function position. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "key",
      status: :supported,
      description: "Returns key of map entry",
      notes: "BUG GAP-S17: currently accepts plain vectors/list pairs as map entries"
    },
    %{
      name: "keys",
      status: :supported,
      description: "Returns map keys",
      notes:
        "DIV-38: map views are sorted by key instead of preserving Clojure map iteration order"
    },
    %{
      name: "keyword",
      status: :supported,
      description: "Coerces to keyword",
      notes:
        "BUG GAP-S34: namespace/name arity is unsupported. BUG GAP-S63: keyword invocation matches string keys. BUG GAP-S78: non-string/non-keyword inputs raise instead of returning nil. DIV-13/DIV-34/DIV-35: namespaced, empty, and broad-character keywords are outside the PTC-Lisp data model."
    },
    %{name: "keyword?", status: :supported, description: "Returns true if keyword", notes: ""},
    %{
      name: "last",
      status: :supported,
      description: "Returns last item",
      notes:
        "nil input returns nil, matching Clojure. DIV-29: direct map input raises; use seq/entries/keys/vals for ordered map views. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "lazy-cat",
      status: :not_relevant,
      description: "Lazy concatenation of expressions",
      notes: "relies on lazy sequences"
    },
    %{
      name: "lazy-seq",
      status: :not_relevant,
      description: "Creates lazy sequence from expression",
      notes: "relies on lazy sequences"
    },
    %{
      name: "let",
      status: :supported,
      description: "Local variable bindings",
      notes:
        "BUG GAP-S39: vector destructuring :as patterns are unsupported, including after rest bindings. BUG GAP-S86: map destructuring :syms is unsupported. BUG GAP-S87: vector destructuring rejects string inputs. BUG GAP-S97: vector rest destructuring binds nil input rest as []. BUG GAP-S118/GAP-S119: map destructuring rejects associative vector sources and vector rest map destructuring misses key/value coercion"
    },
    %{
      name: "letfn",
      status: :not_relevant,
      description: "Binds function names for mutual recursion",
      notes: "mutual recursion binding form is outside PTC-Lisp's small evaluator surface"
    },
    %{
      name: "line-seq",
      status: :not_relevant,
      description: "Lazy seq of lines from reader",
      notes: "relies on lazy sequences and reader I/O"
    },
    %{
      name: "list",
      status: :supported,
      description: "Alias for vector (PTC-Lisp is vector-first)",
      notes: "implemented as alias for vector"
    },
    %{
      name: "list*",
      status: :not_relevant,
      description: "Creates list with seq appended",
      notes: "PTC-Lisp is vector-first and has no separate list runtime type"
    },
    %{
      name: "list?",
      status: :not_relevant,
      description: "Returns true if list",
      notes: "PTC-Lisp is vector-first and has no separate list runtime type"
    },
    %{
      name: "load",
      status: :not_relevant,
      description: "Loads Clojure file from classpath",
      notes: "relies on file I/O and classpath"
    },
    %{
      name: "load-file",
      status: :not_relevant,
      description: "Loads Clojure file from path",
      notes: "relies on file I/O"
    },
    %{
      name: "load-reader",
      status: :not_relevant,
      description: "Loads code from reader",
      notes: "relies on reader I/O"
    },
    %{
      name: "load-string",
      status: :not_relevant,
      description: "Loads code from string",
      notes: "evaluates code/REPL feature"
    },
    %{
      name: "locking",
      status: :not_relevant,
      description: "Acquires monitor lock, executes body",
      notes: "concurrency primitive/locking"
    },
    %{
      name: "long",
      status: :not_relevant,
      description: "Coerces to long",
      notes: "JVM primitive width coercion; use int for integer coercion"
    },
    %{
      name: "long-array",
      status: :not_relevant,
      description: "Creates long Java array",
      notes: "Java interop/primitive array"
    },
    %{
      name: "longs",
      status: :not_relevant,
      description: "Casts to long array",
      notes: "Java interop/primitive array"
    },
    %{
      name: "loop",
      status: :supported,
      description: "Loop with recur for tail recursion",
      notes: "Bodyless form returns nil, matching Clojure"
    },
    %{
      name: "macroexpand",
      status: :not_relevant,
      description: "Recursively expands macro",
      notes: "macro system"
    },
    %{
      name: "macroexpand-1",
      status: :not_relevant,
      description: "Expands macro one level",
      notes: "macro system"
    },
    %{
      name: "make-array",
      status: :not_relevant,
      description: "Creates Java array",
      notes: "Java interop/array creation"
    },
    %{
      name: "make-hierarchy",
      status: :not_relevant,
      description: "Returns empty hierarchy",
      notes: "relies on multimethods system"
    },
    %{
      name: "map",
      status: :supported,
      description: "Applies function to each item",
      notes:
        "BUG GAP-S71: map/vector callables are rejected in function position. BUG GAP-S102: multi-collection arity rejects string inputs. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "map-entry?",
      status: :supported,
      description: "Returns true if map entry",
      notes: "BUG GAP-S136: explicit seq map entries are not recognized as map entries"
    },
    %{
      name: "map-indexed",
      status: :supported,
      description: "Applies function with index to items",
      notes: "BUG GAP-S71: map callables are rejected in function position"
    },
    %{name: "map?", status: :supported, description: "Returns true if map", notes: ""},
    %{
      name: "mapcat",
      status: :supported,
      description: "Maps then concatenates results",
      notes:
        "BUG GAP-S49: multiple input collections, nil results, and string results currently raise. BUG GAP-S71: map callables are rejected in function position"
    },
    %{
      name: "mapv",
      status: :supported,
      description: "Returns vector from mapping function",
      notes:
        "BUG GAP-S71: map/vector callables are rejected in function position. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "max",
      status: :supported,
      description: "Returns greatest number",
      notes: "DIV-30: uses PTC's recoverable total term ordering for nil and mixed values"
    },
    %{
      name: "max-key",
      status: :supported,
      description: "Returns item with greatest function value",
      notes:
        "DIV-30: key comparison uses PTC's recoverable total term ordering for nil and mixed values. BUG GAP-S47: ties currently return the first maximum instead of the last. BUG GAP-S71: map/vector callables are rejected as key functions"
    },
    %{
      name: "memfn",
      status: :not_relevant,
      description: "Returns function calling Java method",
      notes: "relies on Java interop"
    },
    %{
      name: "memoize",
      status: :not_relevant,
      description: "Caches function results by arguments",
      notes: "relies on mutable state for caching"
    },
    %{
      name: "merge",
      status: :supported,
      description: "Merges maps",
      notes:
        "BUG GAP-S54: zero-arity and single nil forms return an empty map instead of nil; A single non-map collection is returned unchanged (Clojure semantics). BUG GAP-S90: vector targets are rejected. BUG GAP-S100: direct vector map-entry sources are rejected"
    },
    %{
      name: "merge-with",
      status: :supported,
      description: "Merges maps with combining function",
      notes:
        "BUG GAP-S54: no-map and single nil forms return an empty map instead of nil. A single non-map collection is returned unchanged (Clojure semantics). BUG GAP-S90: vector targets are rejected"
    },
    %{
      name: "meta",
      status: :not_relevant,
      description: "Returns metadata",
      notes: "relies on metadata support"
    },
    %{
      name: "methods",
      status: :not_relevant,
      description: "Returns multimethod implementations",
      notes: "relies on multimethods"
    },
    %{
      name: "min",
      status: :supported,
      description: "Returns least number",
      notes: "DIV-30: uses PTC's recoverable total term ordering for nil and mixed values"
    },
    %{
      name: "min-key",
      status: :supported,
      description: "Returns item with least function value",
      notes:
        "DIV-30: key comparison uses PTC's recoverable total term ordering for nil and mixed values. BUG GAP-S47: ties currently return the first minimum instead of the last. BUG GAP-S71: map/vector callables are rejected as key functions"
    },
    %{
      name: "mod",
      status: :supported,
      description: "Returns modulo",
      notes:
        "BUG GAP-S138: non-finite operands return NaN instead of matching Clojure/JVM behavior"
    },
    %{
      name: "name",
      status: :supported,
      description: "Returns name string of symbol/keyword",
      notes:
        "DIV-19: quoted symbols are not supported as runtime values. BUG GAP-S129: character literals return strings instead of raising"
    },
    %{
      name: "namespace",
      status: :not_relevant,
      description: "Returns namespace of symbol/keyword",
      notes: "relies on namespace support"
    },
    %{
      name: "nat-int?",
      status: :supported,
      description: "Returns true if non-negative integer",
      notes: "DIV-37: arbitrary-precision PTC integers have no distinct JVM int/long width"
    },
    %{
      name: "neg-int?",
      status: :supported,
      description: "Returns true if negative integer",
      notes: "DIV-37: arbitrary-precision PTC integers have no distinct JVM int/long width"
    },
    %{
      name: "neg?",
      status: :supported,
      description: "Returns true if number negative",
      notes: "DIV-31: returns false for nil/non-numeric inputs instead of raising"
    },
    %{
      name: "newline",
      status: :not_relevant,
      description: "Writes newline to output",
      notes: "relies on I/O"
    },
    %{
      name: "next",
      status: :supported,
      description: "Returns seq after first item",
      notes:
        "DIV-29: direct map input raises; use seq/entries/keys/vals for ordered map views. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "nfirst",
      status: :supported,
      description: "Next of first item",
      notes: "nil input returns nil, matching Clojure"
    },
    %{name: "nil?", status: :supported, description: "Returns true if nil", notes: ""},
    %{
      name: "nnext",
      status: :supported,
      description: "Next of next item",
      notes: "nil input returns nil, matching Clojure"
    },
    %{name: "not", status: :supported, description: "Logical complement", notes: ""},
    %{
      name: "not-any?",
      status: :supported,
      description: "Returns true if pred false for all",
      notes:
        "BUG GAP-S71: map/vector callables are rejected in predicate position. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "not-empty",
      status: :supported,
      description: "Returns collection or nil if empty",
      notes:
        "BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "not-every?",
      status: :supported,
      description: "Returns true if pred false for some",
      notes:
        "BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "not=",
      status: :supported,
      description: "Returns true if not equal",
      notes:
        "DIV-32: numeric equality is type-independent. BUG GAP-S120: character literals compare equal to one-character strings"
    },
    %{
      name: "nth",
      status: :supported,
      description: "Returns item at index",
      notes:
        "DIV-26 for out-of-range signal values; DIV-36 for string grapheme indexing; nil input returns nil (2-arity) or the default (3-arity), matching Clojure; the 3-arity (nth coll idx not-found) returns the default for out-of-range/negative; BUG GAP-S10/GAP-S79. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "nthnext",
      status: :supported,
      description: "Returns nth next",
      notes:
        "implemented as seq after nthrest. BUG GAP-S79: numeric count coercion rejects floats Clojure accepts. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "nthrest",
      status: :supported,
      description: "Returns rest after nth item",
      notes:
        "implemented as drop alias with Clojure argument order. BUG GAP-S79: numeric count coercion rejects floats Clojure accepts. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "num",
      status: :not_relevant,
      description: "Coerces to number",
      notes: "JVM Number coercion; parse-long/parse-double cover string parsing"
    },
    %{name: "number?", status: :supported, description: "Returns true if number", notes: ""},
    %{
      name: "numerator",
      status: :not_relevant,
      description: "Returns numerator of ratio",
      notes: "ratio values are not supported"
    },
    %{
      name: "object-array",
      status: :not_relevant,
      description: "Creates object Java array",
      notes: "relies on Java interop and host arrays"
    },
    %{
      name: "odd?",
      status: :supported,
      description: "Returns true if number odd",
      notes: "DIV-31: numeric predicates return false for non-numeric inputs"
    },
    %{name: "or", status: :supported, description: "Short-circuit logical OR", notes: ""},
    %{
      name: "parents",
      status: :not_relevant,
      description: "Returns immediate parents of tag",
      notes: "metadata/hierarchy manipulation not supported in PTC-Lisp"
    },
    %{
      name: "parse-boolean",
      status: :supported,
      description: "Parses string to boolean",
      notes: "returns true, false, or nil"
    },
    %{
      name: "parse-double",
      status: :supported,
      description: "Parses string to double",
      notes:
        "BUG GAP-S61: surrounding whitespace and Java decimal spellings return nil instead of parsing"
    },
    %{
      name: "parse-long",
      status: :supported,
      description: "Parses string to long",
      notes:
        "BUG GAP-S85: out-of-range long values return arbitrary-precision integers instead of nil"
    },
    %{
      name: "parse-uuid",
      status: :not_relevant,
      description: "Parses string to UUID",
      notes: "no UUID runtime type; keep UUIDs as strings"
    },
    %{
      name: "partial",
      status: :supported,
      description: "Fixes supplied arguments to function",
      notes: "BUG GAP-S71: map/set/vector callables are rejected in function position"
    },
    %{
      name: "partition",
      status: :supported,
      description: "Partitions items into groups of n",
      notes:
        "BUG GAP-S31: nil padding collection currently raises instead of acting empty. BUG GAP-S53: negative partition size raises instead of returning an empty seq. BUG GAP-S79: numeric size/step coercion rejects floats Clojure accepts."
    },
    %{
      name: "partition-all",
      status: :supported,
      description: "Partitions without dropping partial group",
      notes:
        "BUG GAP-S79: numeric size/step coercion rejects floats Clojure accepts. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "partition-by",
      status: :supported,
      description: "Partitions by change in function value",
      notes:
        "BUG GAP-S71: map/vector callables are rejected in function position. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "pcalls",
      status: :supported,
      description: "Parallel calls to zero-arity functions",
      notes: ""
    },
    %{
      name: "peek",
      status: :supported,
      description: "Returns first/last without removing",
      notes: "DIV-25 for list alias behavior"
    },
    %{
      name: "persistent!",
      status: :not_relevant,
      description: "Converts transient to persistent",
      notes: "transients are unsupported"
    },
    %{
      name: "pmap",
      status: :supported,
      description: "Parallel map over one or more collections",
      notes:
        "Matches map's finite seqable contract: nil collections, string collections, and multiple collections (zip-truncate to shortest) are supported while keeping bounded parallel limits"
    },
    %{
      name: "pop",
      status: :supported,
      description: "Returns collection without first/last",
      notes: "DIV-25 for list alias behavior; DIV-26 for empty collection signal value"
    },
    %{
      name: "pop!",
      status: :not_relevant,
      description: "Removes from transient collection",
      notes: "transients are unsupported"
    },
    %{
      name: "pos-int?",
      status: :supported,
      description: "Returns true if positive integer",
      notes: "DIV-37: arbitrary-precision PTC integers have no distinct JVM int/long width"
    },
    %{
      name: "pos?",
      status: :supported,
      description: "Returns true if number positive",
      notes: "DIV-31: returns false for nil/non-numeric inputs instead of raising"
    },
    %{
      name: "pr",
      status: :not_relevant,
      description: "Prints value in readable form",
      notes: "I/O operation"
    },
    %{
      name: "pr-str",
      status: :supported,
      description: "Returns readable string of value",
      notes:
        "DIV-39: collection rendering is deterministic, key-sorted for maps, and space-separated. BUG GAP-S126: character literals print as strings instead of character syntax"
    },
    %{
      name: "prefer-method",
      status: :not_relevant,
      description: "Prefers multimethod implementation",
      notes: "multimethods are unsupported"
    },
    %{
      name: "prefers",
      status: :not_relevant,
      description: "Returns multimethod preferences",
      notes: "multimethods are unsupported"
    },
    %{
      name: "print",
      status: :not_relevant,
      description: "Prints value without quoting",
      notes: "I/O operation"
    },
    %{
      name: "print-str",
      status: :not_relevant,
      description: "Returns printed string of value",
      notes: "relies on printing logic/I/O"
    },
    %{
      name: "printf",
      status: :not_relevant,
      description: "Prints formatted output",
      notes: "performs stdout I/O"
    },
    %{name: "println", status: :supported, description: "Prints with newline", notes: ""},
    %{
      name: "promise",
      status: :not_relevant,
      description: "Creates promise",
      notes: "concurrency primitive"
    },
    %{
      name: "proxy",
      status: :not_relevant,
      description: "Creates proxy implementing interfaces",
      notes: "Java interop"
    },
    %{
      name: "push-thread-bindings",
      status: :not_relevant,
      description: "Installs thread-local bindings",
      notes: "thread-local mutability/state"
    },
    %{
      name: "qualified-ident?",
      status: :not_relevant,
      description: "Returns true if ident has namespace",
      notes: "namespaced identifiers are not supported as runtime values"
    },
    %{
      name: "qualified-keyword?",
      status: :not_relevant,
      description: "Returns true if keyword has namespace",
      notes: "namespaced keywords are not supported"
    },
    %{
      name: "qualified-symbol?",
      status: :not_relevant,
      description: "Returns true if symbol has namespace",
      notes: "symbols are not supported as runtime values"
    },
    %{
      name: "quot",
      status: :supported,
      description: "Returns integer division quotient",
      notes:
        "DIV-37: uses PTC-Lisp arbitrary-precision integers instead of JVM Long/MIN_VALUE overflow. BUG GAP-S138: non-finite operands return NaN instead of matching Clojure/JVM behavior"
    },
    %{
      name: "quote",
      status: :not_relevant,
      description: "Returns form unevaluated",
      notes: "quote syntax is intentionally unsupported; use vectors and data literals directly"
    },
    %{
      name: "rand",
      status: :not_relevant,
      description: "Returns random float 0-1",
      notes: "non-deterministic randomness contradicts sandbox determinism"
    },
    %{
      name: "rand-int",
      status: :not_relevant,
      description: "Returns random int less than arg",
      notes: "relies on non-deterministic side effects/state"
    },
    %{
      name: "rand-nth",
      status: :not_relevant,
      description: "Returns random item from seq",
      notes: "relies on non-deterministic side effects/state"
    },
    %{
      name: "random-sample",
      status: :not_relevant,
      description: "Returns random sample of items",
      notes: "relies on non-deterministic side effects/state"
    },
    %{
      name: "random-uuid",
      status: :not_relevant,
      description: "Returns random UUID",
      notes: "relies on non-deterministic side effects"
    },
    %{
      name: "range",
      status: :supported,
      description: "Returns sequence of numbers",
      notes:
        "BUG GAP-S45: zero-step range currently returns an empty vector. BUG GAP-S99: nil and nonnumeric bounds/steps return an empty vector instead of raising"
    },
    %{
      name: "ratio?",
      status: :supported,
      description: "Returns true if ratio",
      notes: "always false; ratio literals are unsupported, see DIV-20"
    },
    %{
      name: "rational?",
      status: :supported,
      description: "Returns true if rational number",
      notes: ""
    },
    %{
      name: "rationalize",
      status: :not_relevant,
      description: "Coerces to ratio",
      notes: "ratio values are not supported"
    },
    %{
      name: "re-find",
      status: :supported,
      description: "Returns first regex match",
      notes:
        "BUG GAP-S92: optional unmatched capture groups are dropped instead of returned as nil slots. BUG GAP-S131: character inputs are accepted instead of raising"
    },
    %{
      name: "re-groups",
      status: :not_relevant,
      description: "Returns regex match groups",
      notes: "capture groups are returned directly by re-find, re-matches, and re-seq"
    },
    %{
      name: "re-matcher",
      status: :not_relevant,
      description: "Returns matcher for pattern",
      notes: "returns an object maintaining mutable state/matcher position"
    },
    %{
      name: "re-matches",
      status: :supported,
      description: "Returns full regex match or nil",
      notes:
        "BUG GAP-S92: optional unmatched capture groups are dropped instead of returned as nil slots. BUG GAP-S131: character inputs are accepted instead of raising"
    },
    %{
      name: "re-pattern",
      status: :supported,
      description: "Returns compiled regex pattern",
      notes:
        "BUG GAP-S66: existing regex patterns are rejected instead of returned. BUG GAP-S131: character patterns are accepted instead of raising"
    },
    %{
      name: "re-seq",
      status: :supported,
      description: "Returns seq of regex matches",
      notes:
        "BUG GAP-S82: no-match returns [] instead of nil. BUG GAP-S92: optional unmatched capture groups are dropped instead of returned as nil slots. BUG GAP-S131: character inputs are accepted instead of raising"
    },
    %{
      name: "read",
      status: :not_relevant,
      description: "Reads next form from reader",
      notes: "implies I/O and interaction with reader contexts"
    },
    %{
      name: "read-line",
      status: :not_relevant,
      description: "Reads line from input",
      notes: "I/O operation"
    },
    %{
      name: "read-string",
      status: :not_relevant,
      description: "Reads form from string",
      notes: "invokes reader/eval capabilities not supported in sandbox"
    },
    %{
      name: "realized?",
      status: :not_relevant,
      description: "Returns true if delay/future complete",
      notes: "relies on concurrency/lazy primitives not supported"
    },
    %{
      name: "record?",
      status: :not_relevant,
      description: "Returns true if record",
      notes: "relies on class/type system not supported"
    },
    %{
      name: "recur",
      status: :supported,
      description: "Rebinds loop vars and jumps to loop start",
      notes: ""
    },
    %{
      name: "reduce",
      status: :supported,
      description: "Reduces collection with function",
      notes:
        "BUG GAP-S21: empty/nil input without init returns nil instead of calling the reducing function's zero-arity identity. BUG GAP-S71: map callables are rejected in function position. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "reduce-kv",
      status: :supported,
      description: "Reduces map with key-value function",
      notes: "BUG GAP-S59: vector input currently raises instead of reducing indexes and values"
    },
    %{
      name: "reduced",
      status: :candidate,
      description: "Wraps value indicating reduction complete",
      notes: "pure control flow mechanism for reduction interruption"
    },
    %{
      name: "reduced?",
      status: :candidate,
      description: "Returns true if wrapped in reduced",
      notes: "pure predicate for checking reduction status"
    },
    %{
      name: "reductions",
      status: :not_relevant,
      description: "Returns intermediate reduction results",
      notes: "returns a lazy sequence"
    },
    %{
      name: "ref",
      status: :not_relevant,
      description: "Creates STM reference",
      notes: "mutable state/concurrency primitive"
    },
    %{
      name: "ref-set",
      status: :not_relevant,
      description: "Sets ref value in transaction",
      notes: "mutable state/concurrency primitive"
    },
    %{
      name: "reify",
      status: :not_relevant,
      description: "Creates instance implementing protocols",
      notes: "relies on protocols and class generation"
    },
    %{
      name: "rem",
      status: :supported,
      description: "Returns remainder of division",
      notes:
        "BUG GAP-S138: non-finite operands return NaN instead of matching Clojure/JVM behavior"
    },
    %{
      name: "remove",
      status: :supported,
      description: "Returns items where predicate false",
      notes:
        "BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "remove-all-methods",
      status: :not_relevant,
      description: "Removes all multimethod impls",
      notes: "relies on multimethods"
    },
    %{
      name: "remove-method",
      status: :not_relevant,
      description: "Removes multimethod impl",
      notes: "relies on multimethods"
    },
    %{
      name: "remove-ns",
      status: :not_relevant,
      description: "Removes namespace",
      notes: "relies on namespaces"
    },
    %{
      name: "remove-tap",
      status: :not_relevant,
      description: "Removes function from tap set",
      notes: "relies on global mutable state/taps"
    },
    %{
      name: "remove-watch",
      status: :not_relevant,
      description: "Removes watch from reference",
      notes: "relies on mutable state references"
    },
    %{
      name: "repeat",
      status: :not_relevant,
      description: "Returns infinite seq repeating value",
      notes: "returns lazy sequences"
    },
    %{
      name: "repeatedly",
      status: :not_relevant,
      description: "Returns seq calling function repeatedly",
      notes: "returns lazy sequences"
    },
    %{
      name: "replace",
      status: :supported,
      description: "Replaces values by map mapping",
      notes:
        "Arity-2 clojure.core seq replace (smap lookup over any seqable coll); arity-3 is the clojure.string/replace alias. 1-arity transducer form unsupported. Namespace collapse: (clojure.string/replace smap coll) runs the seq form instead of raising on arity."
    },
    %{
      name: "require",
      status: :not_relevant,
      description: "Requires namespace",
      notes: "relies on namespace/load system"
    },
    %{
      name: "requiring-resolve",
      status: :not_relevant,
      description: "Requires ns and resolves symbol",
      notes: "relies on namespace/load system"
    },
    %{
      name: "reset!",
      status: :not_relevant,
      description: "Sets atom value",
      notes: "mutable state (atoms)"
    },
    %{
      name: "reset-meta!",
      status: :not_relevant,
      description: "Sets metadata",
      notes: "metadata manipulation"
    },
    %{
      name: "reset-vals!",
      status: :not_relevant,
      description: "Sets atom, returns [old new]",
      notes: "mutable state (atoms)"
    },
    %{
      name: "resolve",
      status: :not_relevant,
      description: "Resolves symbol in namespace",
      notes: "namespace/symbol resolution"
    },
    %{
      name: "rest",
      status: :supported,
      description: "Returns seq after first item",
      notes:
        "DIV-29: direct map input raises; use seq/entries/keys/vals for ordered map views. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "restart-agent",
      status: :not_relevant,
      description: "Restarts failed agent",
      notes: "concurrency primitives (agents)"
    },
    %{
      name: "reverse",
      status: :supported,
      description: "Reverses order of items",
      notes:
        "DIV-29: direct map input raises; use seq/entries/keys/vals for ordered map views. BUG GAP-S20: nil input currently raises instead of returning an empty seq"
    },
    %{
      name: "reversible?",
      status: :supported,
      description: "Returns true if collection reversible",
      notes: "BUG GAP-S70: strings currently return true but Clojure returns false"
    },
    %{
      name: "rseq",
      status: :not_relevant,
      description: "Returns reverse seq of sorted collection",
      notes: "relies on lazy/sorted sequence implementation details"
    },
    %{
      name: "rsubseq",
      status: :not_relevant,
      description: "Returns reverse subseq of sorted coll",
      notes: "relies on lazy/sorted sequence implementation details"
    },
    %{
      name: "run!",
      status: :not_relevant,
      description: "Runs side effects, returns nil",
      notes: "relies on side effects"
    },
    %{
      name: "satisfies?",
      status: :not_relevant,
      description: "Returns true if type satisfies protocol",
      notes: "protocol/type system feature"
    },
    %{
      name: "second",
      status: :supported,
      description: "Returns second item",
      notes:
        "DIV-29: direct map input raises; use seq/entries/keys/vals for ordered map views. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "select-keys",
      status: :supported,
      description: "Returns map with only specified keys",
      notes:
        "BUG GAP-S23: nil and string keyseqs currently raise instead of returning an empty map; BUG GAP-S43: vector inputs currently raise instead of selecting indexes"
    },
    %{
      name: "send",
      status: :not_relevant,
      description: "Dispatches action to agent",
      notes: "relies on agent mutable state"
    },
    %{
      name: "send-off",
      status: :not_relevant,
      description: "Dispatches blocking action to agent",
      notes: "relies on agent mutable state"
    },
    %{
      name: "send-via",
      status: :not_relevant,
      description: "Sends action via executor to agent",
      notes: "relies on agent mutable state"
    },
    %{
      name: "seq",
      status: :supported,
      description: "Returns sequence or nil if empty",
      notes:
        "DIV-38: map views are sorted by key instead of preserving Clojure map iteration order. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "seq?",
      status: :supported,
      description: "Returns true if value is sequence",
      notes: "BUG GAP-S84: vectors currently return true instead of false"
    },
    %{
      name: "seqable?",
      status: :supported,
      description: "Returns true if implements Seqable",
      notes: "BUG GAP-S125: character literals return true instead of false"
    },
    %{
      name: "sequence",
      status: :not_relevant,
      description: "Returns seq applying transducer",
      notes: "relies on lazy sequences"
    },
    %{
      name: "sequential?",
      status: :supported,
      description: "Returns true if sequential",
      notes: ""
    },
    %{
      name: "set",
      status: :supported,
      description: "Creates set from items",
      notes: "BUG GAP-S30: nil and string inputs currently raise instead of producing sets"
    },
    %{
      name: "set!",
      status: :not_relevant,
      description: "Sets thread-local var value",
      notes: "relies on mutable state"
    },
    %{name: "set?", status: :supported, description: "Returns true if set", notes: ""},
    %{
      name: "short",
      status: :not_relevant,
      description: "Coerces to short",
      notes: "JVM primitive width coercion"
    },
    %{
      name: "short-array",
      status: :not_relevant,
      description: "Creates short Java array",
      notes: "relies on Java array instantiation"
    },
    %{
      name: "shorts",
      status: :not_relevant,
      description: "Casts to short array",
      notes: "relies on Java array interaction"
    },
    %{
      name: "shuffle",
      status: :not_relevant,
      description: "Returns items in random order",
      notes: "relies on non-deterministic side effects (randomness)"
    },
    %{
      name: "shutdown-agents",
      status: :not_relevant,
      description: "Shuts down agent thread pool",
      notes: "manages thread pools which is unsupported"
    },
    %{
      name: "simple-ident?",
      status: :not_relevant,
      description: "Returns true if ident has no namespace",
      notes: "PTC-Lisp has keywords but no first-class symbol or namespaced identifier values"
    },
    %{
      name: "simple-keyword?",
      status: :not_relevant,
      description: "Returns true if keyword has no ns",
      notes: "namespaced keywords are not supported"
    },
    %{
      name: "simple-symbol?",
      status: :not_relevant,
      description: "Returns true if symbol has no ns",
      notes: "symbols are not supported as runtime values"
    },
    %{
      name: "slurp",
      status: :not_relevant,
      description: "Reads entire contents of file/URL",
      notes: "involves file/network I/O"
    },
    %{
      name: "some",
      status: :supported,
      description: "Returns first truthy result or nil",
      notes:
        "BUG GAP-S71: map/vector callables are rejected in function position. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "some->",
      status: :supported,
      description: "Threads through forms while non-nil",
      notes: "BUG GAP-S128: nil thread form returns nil instead of raising"
    },
    %{
      name: "some->>",
      status: :supported,
      description: "Threads as last arg while non-nil",
      notes: "BUG GAP-S128: nil thread form returns nil instead of raising"
    },
    %{
      name: "some-fn",
      status: :supported,
      description: "Returns pred true if any fn truthy",
      notes: "BUG GAP-S71: map/set/vector callables are rejected in predicate position"
    },
    %{name: "some?", status: :supported, description: "Returns true if not nil", notes: ""},
    %{
      name: "sort",
      status: :supported,
      description: "Returns sorted sequence",
      notes:
        "DIV-30: uses PTC's recoverable total term ordering for nil and mixed values; BUG GAP-S20: nil input currently raises instead of returning an empty seq; BUG GAP-S46: nil comparator currently raises instead of using default compare; BUG GAP-S107: boolean comparator functions are not honored with Clojure ordering semantics"
    },
    %{
      name: "sort-by",
      status: :supported,
      description: "Returns seq sorted by function result",
      notes:
        "DIV-30: uses PTC's recoverable total term ordering for nil and mixed values; BUG GAP-S71: map/vector callables are rejected as key functions; BUG GAP-S107: boolean comparator functions are not honored with Clojure ordering semantics"
    },
    %{
      name: "sorted-map",
      status: :candidate,
      description: "Creates sorted map from pairs",
      notes: "pure collection construction"
    },
    %{
      name: "sorted-map-by",
      status: :candidate,
      description: "Creates sorted map with comparator",
      notes: "pure collection construction with custom comparator"
    },
    %{
      name: "sorted-set",
      status: :candidate,
      description: "Creates sorted set from items",
      notes: "pure collection construction"
    },
    %{
      name: "sorted-set-by",
      status: :candidate,
      description: "Creates sorted set with comparator",
      notes: "pure collection construction with custom comparator"
    },
    %{
      name: "sorted?",
      status: :supported,
      description: "Returns true if collection sorted",
      notes: ""
    },
    %{
      name: "spit",
      status: :not_relevant,
      description: "Writes content to file",
      notes: "file I/O"
    },
    %{
      name: "split-at",
      status: :supported,
      description: "Splits seq at index",
      notes:
        "BUG GAP-S79: numeric count coercion rejects floats Clojure accepts. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "split-with",
      status: :supported,
      description: "Splits seq by predicate",
      notes:
        "DIV-36: string sequence predicates receive one-character strings. BUG GAP-S71: map/vector callables are rejected in predicate position. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "str",
      status: :supported,
      description: "Converts to string",
      notes:
        "BUG GAP-S93: regex patterns render as internal tuples instead of source pattern text"
    },
    %{
      name: "string?",
      status: :supported,
      description: "Returns true if string",
      notes: "BUG GAP-S133: character literals return true instead of false"
    },
    %{
      name: "struct",
      status: :not_relevant,
      description: "Creates structure instance",
      notes: "legacy structure system, discouraged/deprecated"
    },
    %{
      name: "struct-map",
      status: :not_relevant,
      description: "Creates structure map from basis",
      notes: "legacy structure system, discouraged/deprecated"
    },
    %{
      name: "subs",
      status: :supported,
      description: "Returns substring",
      notes:
        "DIV-22: returns signal values instead of raising on out-of-range indices; DIV-36: string indexes use Unicode graphemes; BUG GAP-S79: numeric index coercion rejects floats Clojure accepts"
    },
    %{
      name: "subseq",
      status: :candidate,
      description: "Returns subseq of sorted collection",
      notes: "pure operation on sorted collections"
    },
    %{
      name: "subvec",
      status: :supported,
      description: "Returns subvector",
      notes:
        "DIV-26: clamps out-of-range indices instead of raising. BUG GAP-S79: numeric index coercion rejects floats Clojure accepts"
    },
    %{
      name: "supers",
      status: :not_relevant,
      description: "Returns all ancestors of class",
      notes: "relies on Java class hierarchy/interop"
    },
    %{
      name: "swap!",
      status: :not_relevant,
      description: "Updates atom with function",
      notes: "requires mutable state (atom)"
    },
    %{
      name: "swap-vals!",
      status: :not_relevant,
      description: "Updates atom, returns [old new]",
      notes: "requires mutable state (atom)"
    },
    %{
      name: "symbol",
      status: :candidate,
      description: "Coerces to symbol",
      notes: "pure data coercion"
    },
    %{name: "symbol?", status: :supported, description: "Returns true if symbol", notes: ""},
    %{
      name: "take",
      status: :supported,
      description: "Returns first n items",
      notes:
        "BUG GAP-S20: nil input currently raises instead of returning an empty seq; BUG GAP-S32: negative count returns a tail instead of an empty seq; BUG GAP-S79: numeric count coercion rejects floats Clojure accepts"
    },
    %{
      name: "take-last",
      status: :supported,
      description: "Returns last n items",
      notes:
        "nil input returns nil, matching Clojure. BUG GAP-S32: negative count returns an empty vector instead of nil"
    },
    %{
      name: "take-nth",
      status: :not_relevant,
      description: "Returns every nth item",
      notes: "returns a lazy sequence"
    },
    %{
      name: "take-while",
      status: :supported,
      description: "Takes items while predicate true",
      notes:
        "BUG GAP-S71: map/vector callables are rejected in predicate position. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{
      name: "tap>",
      status: :not_relevant,
      description: "Sends value to taps",
      notes: "side-effecting I/O mechanism"
    },
    %{
      name: "test",
      status: :not_relevant,
      description: "Runs tests for namespace",
      notes: "built-in testing framework/REPL tool"
    },
    %{
      name: "throw",
      status: :not_relevant,
      description: "Throws exception",
      notes: "exception handling"
    },
    %{
      name: "time",
      status: :not_relevant,
      description: "Evaluates and prints elapsed time",
      notes: "side-effecting I/O and timing"
    },
    %{
      name: "to-array",
      status: :not_relevant,
      description: "Converts to object array",
      notes: "Java interop for array creation"
    },
    %{
      name: "to-array-2d",
      status: :not_relevant,
      description: "Converts to 2D array",
      notes: "Java interop for array creation"
    },
    %{
      name: "trampoline",
      status: :not_relevant,
      description: "Mutual recursion without stack overflow",
      notes: "lazy/mutual-recursion utility outside PTC-Lisp's small evaluator surface"
    },
    %{
      name: "transduce",
      status: :candidate,
      description: "Reduces with transducer",
      notes: "Pure data transformation utility"
    },
    %{
      name: "transient",
      status: :not_relevant,
      description: "Creates transient collection",
      notes: "Mutable state/transients are not supported"
    },
    %{
      name: "tree-seq",
      status: :supported,
      description: "Depth-first seq from root",
      notes: "BUG GAP-S77: string roots can recurse until heap limit"
    },
    %{name: "true?", status: :supported, description: "Returns true if value is true", notes: ""},
    %{
      name: "try",
      status: :not_relevant,
      description: "Exception handling",
      notes: "Exception handling is not supported"
    },
    %{
      name: "type",
      status: :supported,
      description: "Returns type of value",
      notes: "DIV-28: returns stable PTC type keywords instead of host JVM classes"
    },
    %{
      name: "unchecked-add",
      status: :not_relevant,
      description: "Adds without overflow check",
      notes: "Java-specific math optimization"
    },
    %{
      name: "unchecked-add-int",
      status: :not_relevant,
      description: "Adds ints without overflow check",
      notes: "Java-specific math optimization"
    },
    %{
      name: "unchecked-byte",
      status: :not_relevant,
      description: "Casts to byte without check",
      notes: "Java-specific primitive casting"
    },
    %{
      name: "unchecked-char",
      status: :not_relevant,
      description: "Casts to char without check",
      notes: "Relies on Java primitive casting/low-level JVM semantics"
    },
    %{
      name: "unchecked-dec",
      status: :not_relevant,
      description: "Decrements without overflow check",
      notes: "Relies on Java primitive casting/low-level JVM semantics"
    },
    %{
      name: "unchecked-dec-int",
      status: :not_relevant,
      description: "Decrements int without check",
      notes: "Relies on Java primitive casting/low-level JVM semantics"
    },
    %{
      name: "unchecked-divide-int",
      status: :not_relevant,
      description: "Divides ints without check",
      notes: "Relies on Java primitive casting/low-level JVM semantics"
    },
    %{
      name: "unchecked-double",
      status: :not_relevant,
      description: "Casts to double without check",
      notes: "Relies on Java primitive casting/low-level JVM semantics"
    },
    %{
      name: "unchecked-float",
      status: :not_relevant,
      description: "Casts to float without check",
      notes: "Relies on Java primitive casting/low-level JVM semantics"
    },
    %{
      name: "unchecked-inc",
      status: :not_relevant,
      description: "Increments without overflow check",
      notes: "Relies on Java primitive casting/low-level JVM semantics"
    },
    %{
      name: "unchecked-inc-int",
      status: :not_relevant,
      description: "Increments int without check",
      notes: "Relies on Java primitive casting/low-level JVM semantics"
    },
    %{
      name: "unchecked-int",
      status: :not_relevant,
      description: "Casts to int without check",
      notes: "Relies on Java primitive casting/low-level JVM semantics"
    },
    %{
      name: "unchecked-long",
      status: :not_relevant,
      description: "Casts to long without check",
      notes: "Relies on Java primitive casting/low-level JVM semantics"
    },
    %{
      name: "unchecked-multiply",
      status: :not_relevant,
      description: "Multiplies without overflow check",
      notes: "relies on JVM-specific primitive behavior/overflow semantics"
    },
    %{
      name: "unchecked-multiply-int",
      status: :not_relevant,
      description: "Multiplies ints without check",
      notes: "relies on JVM-specific primitive behavior/overflow semantics"
    },
    %{
      name: "unchecked-negate",
      status: :not_relevant,
      description: "Negates without overflow check",
      notes: "relies on JVM-specific primitive behavior/overflow semantics"
    },
    %{
      name: "unchecked-negate-int",
      status: :not_relevant,
      description: "Negates int without check",
      notes: "relies on JVM-specific primitive behavior/overflow semantics"
    },
    %{
      name: "unchecked-remainder-int",
      status: :not_relevant,
      description: "Remainder without check",
      notes: "relies on JVM-specific primitive behavior/overflow semantics"
    },
    %{
      name: "unchecked-short",
      status: :not_relevant,
      description: "Casts to short without check",
      notes: "relies on Java type casting/interop"
    },
    %{
      name: "unchecked-subtract",
      status: :not_relevant,
      description: "Subtracts without overflow check",
      notes: "relies on JVM-specific primitive behavior/overflow semantics"
    },
    %{
      name: "unchecked-subtract-int",
      status: :not_relevant,
      description: "Subtracts ints without check",
      notes: "relies on JVM-specific primitive behavior/overflow semantics"
    },
    %{
      name: "underive",
      status: :not_relevant,
      description: "Removes hierarchical relationship",
      notes: "requires global hierarchy/multimethod infrastructure"
    },
    %{
      name: "unreduced",
      status: :candidate,
      description: "Unwraps from reduced",
      notes: "pure transformation used for handling reduced values in reductions"
    },
    %{
      name: "unsigned-bit-shift-right",
      status: :not_relevant,
      description: "Unsigned right shift",
      notes:
        "no defined meaning on BEAM — integers are arbitrary-precision two's-complement with no fixed width to zero-fill from"
    },
    %{
      name: "update",
      status: :supported,
      description: "Applies function to map value at key",
      notes:
        "BUG GAP-S19: nil map root currently raises instead of building a map. BUG GAP-S83: vector append at count index raises instead of following assoc semantics"
    },
    %{
      name: "update-in",
      status: :supported,
      description: "Applies function to nested map value",
      notes:
        "An empty or nil path updates the value at the nil key, matching Clojure's recursive update-in definition; BUG GAP-S83: vector append at count index raises instead of following assoc semantics"
    },
    %{
      name: "update-keys",
      status: :supported,
      description: "Applies function to map keys",
      notes:
        "BUG GAP-S24: nil map currently returns nil instead of an empty map. BUG GAP-S71: map/set/vector callables are rejected as key transforms. BUG GAP-S75: vector inputs are rejected"
    },
    %{
      name: "update-proxy",
      status: :not_relevant,
      description: "Updates proxy method implementations",
      notes: "relies on Java interop/proxy class system"
    },
    %{
      name: "update-vals",
      status: :supported,
      description: "Applies function to map values",
      notes:
        "BUG GAP-S24: nil map currently returns nil instead of an empty map. BUG GAP-S71: map/set/vector callables are rejected as value transforms. BUG GAP-S75: vector inputs are rejected"
    },
    %{
      name: "val",
      status: :supported,
      description: "Returns value of map entry",
      notes: "BUG GAP-S17: currently accepts plain vectors/list pairs as map entries"
    },
    %{
      name: "vals",
      status: :supported,
      description: "Returns map values",
      notes:
        "DIV-38: map views are sorted by key instead of preserving Clojure map iteration order"
    },
    %{
      name: "var-get",
      status: :not_relevant,
      description: "Gets value of var",
      notes: "relies on specific var/namespace system"
    },
    %{
      name: "var-set",
      status: :not_relevant,
      description: "Sets var in thread-local binding",
      notes: "relies on mutable thread-local bindings"
    },
    %{
      name: "var?",
      status: :not_relevant,
      description: "Returns true if var",
      notes: "relies on var data structure absent in PTC-Lisp"
    },
    %{
      name: "vary-meta",
      status: :not_relevant,
      description: "Returns value with transformed metadata",
      notes: "relies on metadata feature"
    },
    %{
      name: "vec",
      status: :supported,
      description: "Converts to vector",
      notes:
        "BUG GAP-S40: nil input currently returns nil instead of an empty vector. BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    },
    %{name: "vector", status: :supported, description: "Creates vector from items", notes: ""},
    %{
      name: "vector?",
      status: :supported,
      description: "Returns true if vector",
      notes: "DIV-25 for list alias behavior"
    },
    %{
      name: "volatile!",
      status: :not_relevant,
      description: "Creates volatile with initial value",
      notes: "relies on mutable state"
    },
    %{
      name: "volatile?",
      status: :not_relevant,
      description: "Returns true if volatile",
      notes: "relies on mutable state"
    },
    %{
      name: "vreset!",
      status: :not_relevant,
      description: "Sets volatile value",
      notes: "relies on mutable state"
    },
    %{
      name: "vswap!",
      status: :not_relevant,
      description: "Updates volatile with function",
      notes: "involves mutable state (volatiles)"
    },
    %{
      name: "when",
      status: :supported,
      description: "Evaluates body if test true",
      notes: "Bodyless form returns nil, matching Clojure"
    },
    %{
      name: "when-first",
      status: :supported,
      description: "Evaluates body if seq non-empty",
      notes: "BUG GAP-S145: extra binding-vector forms are rejected instead of ignored"
    },
    %{
      name: "when-let",
      status: :supported,
      description: "Binds if truthy, evaluates body",
      notes:
        "DIV-14: destructuring bindings are intentionally unsupported. BUG GAP-S145: extra binding-vector forms are rejected instead of ignored"
    },
    %{
      name: "when-not",
      status: :supported,
      description: "Evaluates body if test false",
      notes: "Bodyless form returns nil, matching Clojure"
    },
    %{
      name: "when-some",
      status: :supported,
      description: "Binds if not nil, evaluates body",
      notes:
        "DIV-14: destructuring bindings are intentionally unsupported. BUG GAP-S145: extra binding-vector forms are rejected instead of ignored"
    },
    %{
      name: "while",
      status: :not_relevant,
      description: "Repeats body while test true",
      notes: "imperative looping construct typically relying on side effects"
    },
    %{
      name: "with-bindings",
      status: :not_relevant,
      description: "Executes body with thread-local bindings",
      notes: "relies on thread-local state which is not supported in the BEAM model for PTC-Lisp"
    },
    %{
      name: "with-in-str",
      status: :not_relevant,
      description: "Evaluates body with string as input",
      notes: "relies on I/O streams"
    },
    %{
      name: "with-local-vars",
      status: :not_relevant,
      description: "Evaluates body with local var bindings",
      notes: "requires mutable local vars"
    },
    %{
      name: "with-meta",
      status: :not_relevant,
      description: "Returns value with new metadata",
      notes: "metadata is not supported"
    },
    %{
      name: "with-open",
      status: :not_relevant,
      description: "Opens resources, closes on exit",
      notes: "relies on I/O and resource management"
    },
    %{
      name: "with-out-str",
      status: :not_relevant,
      description: "Captures output to string",
      notes: "relies on capturing side-effecting I/O"
    },
    %{
      name: "with-precision",
      status: :not_relevant,
      description: "Sets decimal precision for body",
      notes:
        "relies on specific BigDecimal support and dynamic binding context not present in PTC-Lisp"
    },
    %{
      name: "with-redefs",
      status: :not_relevant,
      description: "Redefines vars for body duration",
      notes:
        "modifies global var bindings, which is not supported in a functional, immutable sandbox"
    },
    %{
      name: "xml-seq",
      status: :not_relevant,
      description: "Lazy seq of XML elements",
      notes: "relies on lazy sequences and I/O-related parsing"
    },
    %{
      name: "zero?",
      status: :supported,
      description: "Returns true if number is zero",
      notes: "DIV-31: returns false for nil/non-numeric inputs instead of raising"
    },
    %{
      name: "zipmap",
      status: :supported,
      description: "Creates map from keys and values seqs",
      notes:
        "BUG GAP-S130: character literals are treated as one-character strings instead of raising"
    }
  ],
  clojure_string_audit: [
    %{
      name: "blank?",
      status: :supported,
      description: "True if s is nil, empty, or contains only whitespace",
      notes:
        "BUG GAP-S50: Unicode whitespace classification differs from Clojure for U+00A0 and U+2003; BUG GAP-S116: character inputs are accepted instead of raising"
    },
    %{
      name: "capitalize",
      status: :candidate,
      description: "Converts first character to upper-case, rest to lower-case",
      notes: "pure string transformation"
    },
    %{
      name: "ends-with?",
      status: :supported,
      description: "True if s ends with substr",
      notes:
        "BUG GAP-S116: character substring arguments are accepted instead of raising. BUG GAP-S139: numeric receivers raise instead of being stringified"
    },
    %{
      name: "escape",
      status: :candidate,
      description: "Return a new string applying cmap to each character",
      notes: "pure character mapping"
    },
    %{
      name: "includes?",
      status: :supported,
      description: "True if s includes substr",
      notes:
        "BUG GAP-S116: character substring arguments are accepted instead of raising. BUG GAP-S139: numeric receivers raise instead of being stringified"
    },
    %{
      name: "index-of",
      status: :supported,
      description: "Return index of value in string",
      notes:
        "DIV-36: returns grapheme offsets instead of JVM UTF-16 code-unit offsets; BUG GAP-S124: finite numeric from-index arguments are rejected instead of coerced. BUG GAP-S139: numeric receivers raise instead of being stringified"
    },
    %{
      name: "join",
      status: :supported,
      description: "Returns a string of elements joined by separator",
      notes:
        "BUG GAP-S26: nil collections, nil separators, string collections, and map collections currently raise instead of joining"
    },
    %{
      name: "last-index-of",
      status: :supported,
      description: "Return last index of value in string",
      notes:
        "DIV-36: returns grapheme offsets instead of JVM UTF-16 code-unit offsets; BUG GAP-S80: negative from-index returns 0 instead of nil; BUG GAP-S124: finite numeric from-index arguments are rejected instead of coerced. BUG GAP-S139: numeric receivers raise instead of being stringified"
    },
    %{
      name: "lower-case",
      status: :supported,
      description: "Converts string to all lower-case",
      notes: "BUG GAP-S139: numeric inputs raise instead of being stringified"
    },
    %{
      name: "re-quote-replacement",
      status: :not_relevant,
      description: "Escapes special characters in replacement string",
      notes: "Java regex-specific utility"
    },
    %{
      name: "replace",
      status: :supported,
      description: "Replaces all instances of match in s",
      notes:
        "BUG GAP-S27: replacement function form is not implemented. BUG GAP-S73: regex replacement string group references are not honored. BUG GAP-S116: character match/replacement arguments are accepted instead of raising for mismatched replacement types. BUG GAP-S139: numeric receivers raise instead of being stringified"
    },
    %{
      name: "replace-first",
      status: :candidate,
      description: "Replaces first instance of match in s",
      notes: "pure string transformation"
    },
    %{
      name: "reverse",
      status: :candidate,
      description: "Returns s with characters reversed",
      notes: "pure string transformation"
    },
    %{
      name: "split",
      status: :supported,
      description: "Splits string on regex",
      notes:
        "BUG GAP-S15: empty regex currently keeps a trailing empty element; BUG GAP-S25: 3-arity limit form is not implemented; BUG GAP-S74: plain string delimiter is accepted even though Clojure requires a regex; BUG GAP-S95: trailing empty fields and empty input differ from Clojure split. BUG GAP-S116: character delimiters are accepted instead of raising"
    },
    %{
      name: "split-lines",
      status: :supported,
      description: "Splits string on \\n or \\r\\n",
      notes: "BUG GAP-S51: empty string currently returns [] instead of [\"\"]"
    },
    %{
      name: "starts-with?",
      status: :supported,
      description: "True if s starts with substr",
      notes:
        "BUG GAP-S116: character substring arguments are accepted instead of raising. BUG GAP-S139: numeric receivers raise instead of being stringified"
    },
    %{
      name: "trim",
      status: :supported,
      description: "Removes whitespace from both ends of string",
      notes:
        "BUG GAP-S50: Unicode whitespace classification differs from Clojure for U+00A0 and U+2003"
    },
    %{
      name: "trim-newline",
      status: :supported,
      description: "Removes all trailing newline or return characters",
      notes: "BUG GAP-S116: character inputs are accepted instead of raising"
    },
    %{
      name: "triml",
      status: :supported,
      description: "Removes whitespace from the left side of string",
      notes:
        "BUG GAP-S50: Unicode whitespace classification differs from Clojure for U+00A0 and U+2003"
    },
    %{
      name: "trimr",
      status: :supported,
      description: "Removes whitespace from the right side of string",
      notes:
        "BUG GAP-S50: Unicode whitespace classification differs from Clojure for U+00A0 and U+2003"
    },
    %{
      name: "upper-case",
      status: :supported,
      description: "Converts string to all upper-case",
      notes: "BUG GAP-S139: numeric inputs raise instead of being stringified"
    }
  ],
  clojure_set_audit: [
    %{
      name: "difference",
      status: :supported,
      description: "Return a set that is the first set without elements of the remaining sets",
      notes:
        "BUG GAP-S30: nil and finite seqable inputs currently raise instead of following Clojure behavior"
    },
    %{
      name: "index",
      status: :candidate,
      description: "Returns a map of the distinct values of ks mapped to sets of maps",
      notes: "pure set/map operation"
    },
    %{
      name: "intersection",
      status: :supported,
      description: "Return a set that is the intersection of the input sets",
      notes:
        "BUG GAP-S30: nil, finite map-entry, and finite seqable inputs currently raise instead of following Clojure behavior"
    },
    %{
      name: "join",
      status: :candidate,
      description: "When passed 2 rels, returns the rel corresponding to the natural join",
      notes: "relational algebra operation"
    },
    %{
      name: "map-invert",
      status: :candidate,
      description: "Returns the map with vals mapped to keys",
      notes: "pure map transformation"
    },
    %{
      name: "project",
      status: :candidate,
      description: "Returns a rel of the elements of xrel with only the keys in ks",
      notes: "relational algebra operation"
    },
    %{
      name: "rename",
      status: :candidate,
      description: "Returns a rel with the keys in kmap renamed",
      notes: "relational algebra operation"
    },
    %{
      name: "rename-keys",
      status: :candidate,
      description: "Returns the map with keys renamed according to kmap",
      notes: "pure map transformation"
    },
    %{
      name: "select",
      status: :candidate,
      description: "Returns a set of the elements for which pred is true",
      notes: "pure set filtering"
    },
    %{
      name: "subset?",
      status: :candidate,
      description: "Is set1 a subset of set2?",
      notes: "pure set predicate"
    },
    %{
      name: "superset?",
      status: :candidate,
      description: "Is set1 a superset of set2?",
      notes: "pure set predicate"
    },
    %{
      name: "union",
      status: :supported,
      description: "Return a set that is the union of the input sets",
      notes:
        "BUG GAP-S30: nil, map, and non-set seqable inputs currently raise instead of following Clojure union behavior"
    }
  ],
  clojure_walk_audit: [
    %{
      name: "keywordize-keys",
      status: :candidate,
      description: "Recursively transforms all map keys from strings to keywords",
      notes: "pure recursive map transformation"
    },
    %{
      name: "macroexpand-all",
      status: :not_relevant,
      description: "Recursively performs all possible macroexpansions in form",
      notes: "macros are not supported in PTC-Lisp"
    },
    %{
      name: "postwalk",
      status: :supported,
      description: "Performs a depth-first, post-order traversal of form",
      notes: "BUG GAP-S71: map/set callables are rejected as transform functions"
    },
    %{
      name: "postwalk-demo",
      status: :not_relevant,
      description: "Demonstrates postwalk by printing each form as it is walked",
      notes: "debug/demo side-effect helper"
    },
    %{
      name: "postwalk-replace",
      status: :candidate,
      description: "Recursively replaces keys in smap with their values, leaves first",
      notes: "pure recursive data transformation"
    },
    %{
      name: "prewalk",
      status: :supported,
      description: "Performs a pre-order traversal of form",
      notes: "BUG GAP-S71: map/set callables are rejected as transform functions"
    },
    %{
      name: "prewalk-demo",
      status: :not_relevant,
      description: "Demonstrates prewalk by printing each form as it is walked",
      notes: "debug/demo side-effect helper"
    },
    %{
      name: "prewalk-replace",
      status: :candidate,
      description: "Recursively replaces keys in smap with their values, root first",
      notes: "pure recursive data transformation"
    },
    %{
      name: "stringify-keys",
      status: :candidate,
      description: "Recursively transforms all map keys from keywords to strings",
      notes: "pure recursive map transformation"
    },
    %{
      name: "walk",
      status: :supported,
      description: "Traverses form by applying inner to children and outer to the result",
      notes:
        "BUG GAP-S71: map/set/vector callables are rejected as inner/outer functions. BUG GAP-S91: invalid transformed map-entry shapes are accepted instead of raising"
    }
  ],
  java_math_audit: [
    %{
      name: "abs",
      status: :supported,
      description: "Returns the absolute value",
      notes:
        "DIV-45: uses PTC-Lisp arbitrary-precision integers, so abs returns the mathematically correct positive value and accepts BigInt input rather than reproducing Java long-overflow/overload artifacts"
    },
    %{
      name: "acos",
      status: :candidate,
      description: "Returns the arc cosine of a value",
      notes: "pure math"
    },
    %{
      name: "addExact",
      status: :not_relevant,
      description: "Returns sum, throwing on overflow",
      notes: "Java overflow semantics not applicable on BEAM"
    },
    %{
      name: "asin",
      status: :candidate,
      description: "Returns the arc sine of a value",
      notes: "pure math"
    },
    %{
      name: "atan",
      status: :candidate,
      description: "Returns the arc tangent of a value",
      notes: "pure math"
    },
    %{
      name: "atan2",
      status: :candidate,
      description: "Returns angle theta from (x,y) to polar (r,theta)",
      notes: "pure math"
    },
    %{
      name: "cbrt",
      status: :candidate,
      description: "Returns the cube root of a value",
      notes: "pure math"
    },
    %{
      name: "ceil",
      status: :supported,
      description: "Returns the smallest integer >= argument",
      notes:
        "DIV-42: integer-returning PTC-Lisp extension, so finite results render as integers rather than Java's double shape"
    },
    %{
      name: "copySign",
      status: :not_relevant,
      description: "Returns first arg with sign of second arg",
      notes: "low-level IEEE 754 manipulation"
    },
    %{
      name: "cos",
      status: :candidate,
      description: "Returns the trigonometric cosine of an angle",
      notes: "pure math"
    },
    %{
      name: "cosh",
      status: :candidate,
      description: "Returns the hyperbolic cosine of a value",
      notes: "pure math"
    },
    %{
      name: "decrementExact",
      status: :not_relevant,
      description: "Returns argument decremented by one, throwing on overflow",
      notes: "Java overflow semantics not applicable on BEAM"
    },
    %{
      name: "exp",
      status: :candidate,
      description: "Returns Euler's number e raised to the power of a",
      notes: "pure math"
    },
    %{
      name: "expm1",
      status: :not_relevant,
      description: "Returns e^x - 1",
      notes: "specialized numerical precision, low demand"
    },
    %{
      name: "floor",
      status: :supported,
      description: "Returns the largest integer <= argument",
      notes:
        "DIV-42: integer-returning PTC-Lisp extension, so finite results render as integers rather than Java's double shape"
    },
    %{
      name: "floorDiv",
      status: :not_relevant,
      description: "Returns floor of integer division",
      notes: "Java integer division semantics; use quot + floor"
    },
    %{
      name: "floorMod",
      status: :not_relevant,
      description: "Returns floor modulus of arguments",
      notes: "Java integer semantics; use mod"
    },
    %{
      name: "fma",
      status: :not_relevant,
      description: "Fused multiply-add",
      notes: "specialized numerical precision"
    },
    %{
      name: "getExponent",
      status: :not_relevant,
      description: "Returns unbiased exponent of a float/double",
      notes: "low-level IEEE 754 inspection"
    },
    %{
      name: "hypot",
      status: :candidate,
      description: "Returns sqrt(x^2 + y^2) without intermediate overflow",
      notes: "pure math"
    },
    %{
      name: "IEEEremainder",
      status: :not_relevant,
      description: "Returns IEEE 754 remainder",
      notes: "low-level IEEE 754 semantics; use rem/mod"
    },
    %{
      name: "incrementExact",
      status: :not_relevant,
      description: "Returns argument incremented by one, throwing on overflow",
      notes: "Java overflow semantics not applicable on BEAM"
    },
    %{
      name: "log",
      status: :candidate,
      description: "Returns the natural logarithm (base e) of a value",
      notes: "pure math"
    },
    %{
      name: "log10",
      status: :candidate,
      description: "Returns the base 10 logarithm of a value",
      notes: "pure math"
    },
    %{
      name: "log1p",
      status: :not_relevant,
      description: "Returns ln(1 + x)",
      notes: "specialized numerical precision, low demand"
    },
    %{
      name: "max",
      status: :supported,
      description: "Returns the greater of two values",
      notes:
        "DIV-44: max is the Clojure-named variadic helper (Math/max is an alias), not Java's two-argument primitive. DIV-45: mixed numeric and total-ordering comparisons are accepted via PTC-Lisp's generic value model rather than Java's primitive overloads"
    },
    %{
      name: "min",
      status: :supported,
      description: "Returns the smaller of two values",
      notes:
        "DIV-44: min is the Clojure-named variadic helper (Math/min is an alias), not Java's two-argument primitive. DIV-45: mixed numeric and total-ordering comparisons are accepted via PTC-Lisp's generic value model rather than Java's primitive overloads"
    },
    %{
      name: "multiplyExact",
      status: :not_relevant,
      description: "Returns product, throwing on overflow",
      notes: "Java overflow semantics not applicable on BEAM"
    },
    %{
      name: "multiplyHigh",
      status: :not_relevant,
      description: "Returns high 64 bits of 128-bit product",
      notes: "low-level 64-bit arithmetic"
    },
    %{
      name: "negateExact",
      status: :not_relevant,
      description: "Returns negation, throwing on overflow",
      notes: "Java overflow semantics not applicable on BEAM"
    },
    %{
      name: "nextAfter",
      status: :not_relevant,
      description: "Returns adjacent floating-point value",
      notes: "low-level IEEE 754 manipulation"
    },
    %{
      name: "nextDown",
      status: :not_relevant,
      description: "Returns adjacent floating-point value towards negative infinity",
      notes: "low-level IEEE 754 manipulation"
    },
    %{
      name: "nextUp",
      status: :not_relevant,
      description: "Returns adjacent floating-point value towards positive infinity",
      notes: "low-level IEEE 754 manipulation"
    },
    %{
      name: "pow",
      status: :supported,
      description: "Returns the value of a raised to the power of b",
      notes:
        "Follows java.lang.Math.pow's IEEE 754 special-case table, returning :nan / :infinity / :negative_infinity as recoverable signal values instead of raising (e.g. (pow -1 0.5) => NaN, (pow 0 -1) => Inf)"
    },
    %{
      name: "random",
      status: :candidate,
      description: "Returns a pseudorandom double between 0.0 and 1.0",
      notes: "pure (non-deterministic but side-effect free)"
    },
    %{
      name: "rint",
      status: :not_relevant,
      description: "Returns closest double to argument that is a mathematical integer",
      notes: "use round instead"
    },
    %{
      name: "round",
      status: :supported,
      description: "Returns the closest long/int to the argument",
      notes:
        "DIV-43: round-half-away-from-zero, integer result, and special values (NaN/infinity) are preserved rather than Java's floor(x+0.5) and long saturation. DIV-45: integer and BigInt arguments are accepted (returned unchanged) via PTC-Lisp's value model rather than Java's float/double-only overloads"
    },
    %{
      name: "scalb",
      status: :not_relevant,
      description: "Returns d × 2^scaleFactor",
      notes: "low-level IEEE 754 manipulation"
    },
    %{
      name: "signum",
      status: :candidate,
      description: "Returns the signum function of the argument",
      notes: "pure math"
    },
    %{
      name: "sin",
      status: :candidate,
      description: "Returns the trigonometric sine of an angle",
      notes: "pure math"
    },
    %{
      name: "sinh",
      status: :candidate,
      description: "Returns the hyperbolic sine of a value",
      notes: "pure math"
    },
    %{
      name: "sqrt",
      status: :supported,
      description: "Returns the positive square root of a value",
      notes: ""
    },
    %{
      name: "subtractExact",
      status: :not_relevant,
      description: "Returns difference, throwing on overflow",
      notes: "Java overflow semantics not applicable on BEAM"
    },
    %{
      name: "tan",
      status: :candidate,
      description: "Returns the trigonometric tangent of an angle",
      notes: "pure math"
    },
    %{
      name: "tanh",
      status: :candidate,
      description: "Returns the hyperbolic tangent of a value",
      notes: "pure math"
    },
    %{
      name: "toDegrees",
      status: :candidate,
      description: "Converts an angle from radians to degrees",
      notes: "pure math"
    },
    %{
      name: "toIntExact",
      status: :not_relevant,
      description: "Returns long narrowed to int, throwing on overflow",
      notes: "Java type narrowing not applicable on BEAM"
    },
    %{
      name: "toRadians",
      status: :candidate,
      description: "Converts an angle from degrees to radians",
      notes: "pure math"
    },
    %{
      name: "ulp",
      status: :not_relevant,
      description: "Returns size of an ulp of the argument",
      notes: "low-level IEEE 754 inspection"
    }
  ]
}
