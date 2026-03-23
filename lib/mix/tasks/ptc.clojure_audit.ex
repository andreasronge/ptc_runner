defmodule Mix.Tasks.Ptc.ClojureAudit do
  @shortdoc "Audit PTC-Lisp coverage of Clojure/Java namespaces"
  @moduledoc """
  Generates markdown reports comparing PTC-Lisp builtins against Clojure and Java namespaces.

  ## Usage

      mix ptc.clojure_audit                    # Audit all namespaces
      mix ptc.clojure_audit --namespace core   # Audit only clojure.core
      mix ptc.clojure_audit --namespace string # Audit only clojure.string
      mix ptc.clojure_audit --namespace set    # Audit only clojure.set
      mix ptc.clojure_audit --namespace math   # Audit only java.lang.Math
      mix ptc.clojure_audit --skip-llm         # Skip LLM classification
      mix ptc.clojure_audit --model MODEL_ID   # Use a specific model
      mix ptc.clojure_audit --chunk-size N     # Vars per LLM request (default: 10)
      mix ptc.clojure_audit --limit N          # Only classify first N unmatched vars

  ## Output

  Writes audit markdown files:
  - `docs/clojure-core-audit.md` — clojure.core vars
  - `docs/clojure-string-audit.md` — clojure.string vars
  - `docs/clojure-set-audit.md` — clojure.set vars
  - `docs/java-math-audit.md` — java.lang.Math methods

  Status legend:
  - ✅ supported — implemented in PTC-Lisp
  - ❌ not-relevant — not applicable (lazy seqs, Java interop, concurrency, etc.)
  - 🔲 candidate — could be useful to implement
  - ❓ unknown — not yet classified
  """
  use Mix.Task

  alias PtcRunner.Lisp.Analyze
  alias PtcRunner.Lisp.Env

  @default_model "openrouter:google/gemini-3.1-flash-lite-preview"
  @default_chunk_size 10

  @namespace_configs %{
    "core" => %{
      output: "docs/clojure-core-audit.md",
      title: "Clojure Core Audit for PTC-Lisp",
      description: "Comparison of `clojure.core` vars against PTC-Lisp builtins.",
      vars_fn: :clojure_core_vars,
      match_fn: :match_core
    },
    "string" => %{
      output: "docs/clojure-string-audit.md",
      title: "Clojure String Audit for PTC-Lisp",
      description: "Comparison of `clojure.string` vars against PTC-Lisp builtins.",
      vars_fn: :clojure_string_vars,
      match_fn: :match_by_category
    },
    "set" => %{
      output: "docs/clojure-set-audit.md",
      title: "Clojure Set Audit for PTC-Lisp",
      description: "Comparison of `clojure.set` vars against PTC-Lisp builtins.",
      vars_fn: :clojure_set_vars,
      match_fn: :match_by_category
    },
    "math" => %{
      output: "docs/java-math-audit.md",
      title: "Java Math Audit for PTC-Lisp",
      description: "Comparison of `java.lang.Math` methods against PTC-Lisp builtins.",
      vars_fn: :java_math_vars,
      match_fn: :match_by_category
    }
  }

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          skip_llm: :boolean,
          model: :string,
          chunk_size: :integer,
          limit: :integer,
          namespace: :string
        ],
        aliases: [s: :skip_llm, m: :model, c: :chunk_size, l: :limit, n: :namespace]
      )

    model = opts[:model] || @default_model
    chunk_size = opts[:chunk_size] || @default_chunk_size
    skip_llm = opts[:skip_llm] || false
    limit = opts[:limit]

    namespaces =
      case opts[:namespace] do
        nil -> Map.keys(@namespace_configs)
        ns when is_map_key(@namespace_configs, ns) -> [ns]
        other -> Mix.raise("Unknown namespace: #{other}. Use: core, string, set, math")
      end

    unless skip_llm do
      Mix.Task.run("app.start")
    end

    Enum.each(namespaces, fn ns ->
      config = @namespace_configs[ns]
      Mix.shell().info("\n=== Auditing #{config.title} ===")
      audit_namespace(config, model, chunk_size, skip_llm, limit)
    end)
  end

  defp audit_namespace(config, model, chunk_size, skip_llm, limit) do
    vars = apply(__MODULE__, config.vars_fn, [])
    supported = apply(__MODULE__, config.match_fn, [vars])

    {matched, unmatched} =
      Enum.split_with(vars, fn {name, _desc} -> MapSet.member?(supported, name) end)

    Mix.shell().info("Total vars: #{length(vars)}")
    Mix.shell().info("Auto-matched: #{length(matched)}")
    Mix.shell().info("Unmatched: #{length(unmatched)}")

    {to_classify, skipped} =
      if limit do
        Mix.shell().info("Limiting to first #{limit} unmatched vars")
        Enum.split(unmatched, limit)
      else
        {unmatched, []}
      end

    classified =
      if skip_llm do
        Enum.map(to_classify, fn {name, desc} -> {name, desc, "unknown", ""} end)
      else
        classify_with_llm(to_classify, model, chunk_size)
      end

    skipped_entries =
      Enum.map(skipped, fn {name, desc} -> {name, desc, "unknown", ""} end)

    matched_entries =
      Enum.map(matched, fn {name, desc} -> {name, desc, "supported", ""} end)

    all_entries =
      (matched_entries ++ classified ++ skipped_entries)
      |> Enum.sort_by(fn {name, _, _, _} -> name end)

    markdown = generate_markdown(all_entries, config)
    File.write!(config.output, markdown)

    counts = Enum.frequencies_by(all_entries, fn {_, _, status, _} -> status end)

    Mix.shell().info("\n--- Summary ---")
    Mix.shell().info("✅ supported:     #{counts["supported"] || 0}")
    Mix.shell().info("🔲 candidate:     #{counts["candidate"] || 0}")
    Mix.shell().info("❌ not-relevant:  #{counts["not-relevant"] || 0}")
    Mix.shell().info("❓ unknown:       #{counts["unknown"] || 0}")
    Mix.shell().info("\nReport written to #{config.output}")
  end

  @doc false
  def match_core(_vars) do
    builtin_keys = Env.initial() |> Map.keys()
    special_form_list = Analyze.supported_forms()
    all = builtin_keys ++ special_form_list
    MapSet.new(Enum.map(all, &to_string/1))
  end

  @doc false
  def match_by_category(vars) do
    implemented = PtcRunner.Lisp.Registry.implemented()
    var_names = MapSet.new(Enum.map(vars, fn {name, _} -> name end))

    implemented
    |> Enum.filter(fn entry -> MapSet.member?(var_names, entry.name) end)
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  defp classify_with_llm(vars, model, chunk_size) do
    chunks = Enum.chunk_every(vars, chunk_size)
    total = length(chunks)

    chunks
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {chunk, idx} ->
      Mix.shell().info("Classifying chunk #{idx}/#{total}...")
      classify_chunk(chunk, model)
    end)
  end

  defp classify_chunk(vars, model) do
    var_list =
      vars
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {{name, desc}, i} ->
        "#{i}. `#{name}` — #{desc}"
      end)

    system = """
    You are classifying Clojure/Java functions for relevance to PTC-Lisp, a sandboxed Lisp for LLM tool orchestration running on the BEAM (Erlang VM).

    PTC-Lisp supports: pure data transformations, collection operations, map/filter/reduce, string manipulation, math, predicates, destructuring, loop/recur, threading macros, and tool calling.

    PTC-Lisp does NOT have: lazy sequences, Java interop, mutable state (atoms/refs/agents/volatiles), namespaces, multimethods, protocols, macros, metadata, exception handling (try/catch/throw), I/O (file/network/stdin/stdout), REPL features, compilation, class generation, transients, concurrency primitives (futures/promises/locking), or reader macros.

    Classify each var as exactly one of:
    - `not-relevant` — relies on unsupported features (lazy seqs, Java, mutability, I/O, etc.)
    - `candidate` — pure function operating on data that would be useful in PTC-Lisp

    Respond with ONLY a JSON array. Each element: {"name": "var-name", "status": "not-relevant" or "candidate", "reason": "brief reason"}
    """

    messages = [%{role: :user, content: "Classify these vars:\n\n#{var_list}"}]

    case PtcRunner.LLM.call(model, %{system: system, messages: messages}) do
      {:ok, %{content: content}} ->
        parse_classification(content, vars)

      {:error, reason} ->
        Mix.shell().error("LLM error: #{inspect(reason, pretty: true, limit: :infinity)}")
        Enum.map(vars, fn {name, desc} -> {name, desc, "unknown", "LLM error"} end)
    end
  end

  defp parse_classification(content, vars) do
    json_str =
      content
      |> String.replace(~r/```json\s*/, "")
      |> String.replace(~r/```\s*$/, "")
      |> String.trim()

    case Jason.decode(json_str) do
      {:ok, results} when is_list(results) ->
        var_map = Map.new(vars)

        Enum.map(results, fn item ->
          name = item["name"]
          status = item["status"]
          reason = item["reason"] || ""
          desc = Map.get(var_map, name, "")
          {name, desc, status, reason}
        end)

      _ ->
        Mix.shell().error("Failed to parse LLM response: #{String.slice(content, 0, 200)}")
        Enum.map(vars, fn {name, desc} -> {name, desc, "unknown", "parse error"} end)
    end
  end

  defp generate_markdown(entries, config) do
    counts = Enum.frequencies_by(entries, fn {_, _, status, _} -> status end)

    header = """
    # #{config.title}

    Auto-generated #{config.description}

    ## Summary

    | Status | Count |
    |--------|-------|
    | ✅ Supported | #{counts["supported"] || 0} |
    | 🔲 Candidate | #{counts["candidate"] || 0} |
    | ❌ Not Relevant | #{counts["not-relevant"] || 0} |
    | ❓ Unknown | #{counts["unknown"] || 0} |
    | **Total** | **#{length(entries)}** |

    ## Details

    | Var | Status | Description | Notes |
    |-----|--------|-------------|-------|
    """

    rows =
      Enum.map_join(entries, "\n", fn {name, desc, status, reason} ->
        icon = status_icon(status)
        "| `#{name}` | #{icon} #{status} | #{desc} | #{reason} |"
      end)

    header <> rows <> "\n"
  end

  defp status_icon("supported"), do: "✅"
  defp status_icon("candidate"), do: "🔲"
  defp status_icon("not-relevant"), do: "❌"
  defp status_icon(_), do: "❓"

  # ── Namespace var lists ──────────────────────────────────────────────

  @doc false
  def clojure_core_vars do
    [
      {"*", "Multiplies numbers; returns 1 with no args"},
      {"*'", "Multiplies numbers with arbitrary precision"},
      {"+", "Adds numbers; returns 0 with no args"},
      {"+'", "Adds numbers with arbitrary precision"},
      {"-", "Subtracts numbers or negates single argument"},
      {"-'", "Subtracts numbers with arbitrary precision"},
      {"->", "Threads expression as second argument through forms"},
      {"->>", "Threads expression as last argument through forms"},
      {".", "Java member access and method calls"},
      {"..", "Chains member access operations"},
      {"/", "Divides numbers"},
      {"<", "Returns true if numbers monotonically increase"},
      {"<=", "Returns true if numbers non-decreasing"},
      {"=", "Equality comparison"},
      {"==", "Type-independent numeric equality"},
      {">", "Returns true if numbers monotonically decrease"},
      {">=", "Returns true if numbers non-increasing"},
      {"abs", "Returns absolute value of number"},
      {"accessor", "Returns function accessing structmap value at key"},
      {"aclone", "Returns clone of Java array"},
      {"add-tap", "Adds function to receive tap> values"},
      {"add-watch", "Adds watch function to reference"},
      {"agent", "Creates agent with initial value"},
      {"agent-error", "Returns exception from failed agent"},
      {"aget", "Returns value at Java array index"},
      {"alength", "Returns length of Java array"},
      {"alias", "Adds namespace alias"},
      {"all-ns", "Returns all namespaces"},
      {"alter", "Sets ref value in transaction"},
      {"alter-meta!", "Atomically sets metadata via function"},
      {"alter-var-root", "Atomically alters var root binding"},
      {"amap", "Maps expression across Java array"},
      {"ancestors", "Returns parents of tag via hierarchy"},
      {"and", "Short-circuit logical AND"},
      {"any?", "Returns true for any argument"},
      {"apply", "Applies function to argument sequence"},
      {"areduce", "Reduces expression across Java array"},
      {"array-map", "Constructs array-map from key-value pairs"},
      {"as->", "Binds name to expr, threads through forms"},
      {"aset", "Sets value in Java array at index"},
      {"assert", "Throws AssertionError if expr false"},
      {"assoc", "Returns map/vector with added key-value pairs"},
      {"assoc!", "Sets value in transient collection"},
      {"assoc-in", "Associates value in nested structure"},
      {"associative?", "Returns true if coll implements Associative"},
      {"atom", "Creates atom with initial value"},
      {"await", "Blocks until agent actions complete"},
      {"await-for", "Blocks with timeout for agent actions"},
      {"bases", "Returns immediate superclass and interfaces"},
      {"bean", "Returns map based on JavaBean properties"},
      {"bigdec", "Coerces to BigDecimal"},
      {"bigint", "Coerces to BigInt"},
      {"biginteger", "Coerces to BigInteger"},
      {"binding", "Binds vars to new values for body duration"},
      {"bit-and", "Bitwise AND"},
      {"bit-and-not", "Bitwise AND with complement"},
      {"bit-clear", "Clears bit at index"},
      {"bit-flip", "Flips bit at index"},
      {"bit-not", "Bitwise complement"},
      {"bit-or", "Bitwise OR"},
      {"bit-set", "Sets bit at index"},
      {"bit-shift-left", "Bitwise left shift"},
      {"bit-shift-right", "Bitwise right shift"},
      {"bit-test", "Tests bit at index"},
      {"bit-xor", "Bitwise exclusive OR"},
      {"boolean", "Coerces to boolean"},
      {"boolean-array", "Creates boolean Java array"},
      {"boolean?", "Returns true if value is Boolean"},
      {"booleans", "Casts to boolean array"},
      {"bound-fn", "Returns function with call-site bindings"},
      {"bound-fn*", "Returns function applying creation-context bindings"},
      {"bound?", "Returns true if all vars have bound value"},
      {"bounded-count", "Counts up to n elements"},
      {"butlast", "Returns all but last item"},
      {"byte", "Coerces to byte"},
      {"byte-array", "Creates byte Java array"},
      {"bytes", "Casts to byte array"},
      {"bytes?", "Returns true if value is byte array"},
      {"case", "Constant-time dispatch on expression value"},
      {"cast", "Throws ClassCastException if not instance"},
      {"cat", "Transducer concatenating input collections"},
      {"char", "Coerces to char"},
      {"char-array", "Creates char Java array"},
      {"char?", "Returns true if value is Character"},
      {"chars", "Casts to char array"},
      {"class", "Returns class of value"},
      {"class?", "Returns true if value is Class instance"},
      {"clojure-version", "Returns Clojure version string"},
      {"coll?", "Returns true if implements IPersistentCollection"},
      {"comment", "Ignores body, yields nil"},
      {"commute", "Sets ref value via commutative function"},
      {"comp", "Composes functions right-to-left"},
      {"comparator", "Returns Comparator from predicate"},
      {"compare", "Compares values returning neg/zero/pos"},
      {"compare-and-set!", "Atomically sets atom if current equals old"},
      {"compile", "Compiles namespace into classfiles"},
      {"complement", "Returns function with opposite truth value"},
      {"completing", "Returns reducing function with completion"},
      {"concat", "Returns lazy seq concatenating collections"},
      {"cond", "Multi-way conditional"},
      {"cond->", "Threads through forms where tests true"},
      {"cond->>", "Threads as last arg where tests true"},
      {"condp", "Predicate dispatch against expression"},
      {"conj", "Returns collection with items added"},
      {"conj!", "Adds item to transient collection"},
      {"cons", "Returns seq with item prepended"},
      {"constantly", "Returns function ignoring args, returning value"},
      {"contains?", "Returns true if key present in collection"},
      {"count", "Returns number of items in collection"},
      {"counted?", "Returns true if constant-time count"},
      {"create-ns", "Creates or returns namespace"},
      {"create-struct", "Returns structure basis object"},
      {"cycle", "Returns infinite lazy seq repeating collection"},
      {"dec", "Returns number minus one"},
      {"dec'", "Decrements with arbitrary precision"},
      {"decimal?", "Returns true if BigDecimal"},
      {"declare", "Defines var names with no bindings"},
      {"dedupe", "Removes consecutive duplicates"},
      {"def", "Creates and interns global var"},
      {"definterface", "Creates Java interface"},
      {"defmacro", "Defines macro"},
      {"defmethod", "Creates multimethod implementation"},
      {"defmulti", "Creates multimethod with dispatch function"},
      {"defn", "Defines named function"},
      {"defn-", "Defines private function"},
      {"defonce", "Defines var only if not already defined"},
      {"defprotocol", "Creates protocol with method signatures"},
      {"defrecord", "Creates record type with fields"},
      {"defstruct", "Creates structure type"},
      {"deftype", "Creates custom type with fields"},
      {"delay", "Defers expression evaluation"},
      {"delay?", "Returns true if value is delay"},
      {"deliver", "Delivers result to promise"},
      {"denominator", "Returns denominator of ratio"},
      {"deref", "Dereferences ref/delay/future/promise"},
      {"derive", "Establishes hierarchical relationship"},
      {"descendants", "Returns all descendants of tag"},
      {"disj", "Returns set with item removed"},
      {"disj!", "Removes from transient set"},
      {"dissoc", "Returns map with key removed"},
      {"dissoc!", "Removes from transient map"},
      {"distinct", "Returns seq removing duplicates"},
      {"distinct?", "Returns true if all args distinct"},
      {"do", "Evaluates expressions, returns last"},
      {"doall", "Realizes entire lazy seq"},
      {"dorun", "Realizes lazy seq, returns nil"},
      {"doseq", "Iterates over sequences for side effects"},
      {"dosync", "Executes body in STM transaction"},
      {"dotimes", "Executes body n times with counter"},
      {"doto", "Calls methods on object, returns object"},
      {"double", "Coerces to double"},
      {"double-array", "Creates double Java array"},
      {"double?", "Returns true if Double"},
      {"doubles", "Casts to double array"},
      {"drop", "Returns seq skipping first n items"},
      {"drop-last", "Returns seq without last n items"},
      {"drop-while", "Drops items while predicate true"},
      {"eduction", "Returns reducible wrapper of transducer"},
      {"empty", "Returns empty collection of same type"},
      {"empty?", "Returns true if collection empty"},
      {"ensure", "Ensures ref not written by other transaction"},
      {"ensure-reduced", "Wraps in reduced if not already"},
      {"enumeration-seq", "Lazy seq from Java Enumeration"},
      {"error-handler", "Returns agent error handler"},
      {"error-mode", "Returns agent error mode"},
      {"eval", "Evaluates form in current namespace"},
      {"even?", "Returns true if number is even"},
      {"every-pred", "Returns combined predicate (all must be true)"},
      {"every?", "Returns true if pred true for all items"},
      {"ex-cause", "Returns cause of exception"},
      {"ex-data", "Returns data map of exception"},
      {"ex-info", "Creates exception with message and data"},
      {"ex-message", "Returns exception message string"},
      {"extend", "Adds protocol implementations for type"},
      {"extend-protocol", "Extends protocol to types"},
      {"extend-type", "Extends type to implement protocol"},
      {"extenders", "Returns types extending protocol"},
      {"extends?", "Returns true if type extends protocol"},
      {"false?", "Returns true if value is false"},
      {"ffirst", "First of first item"},
      {"file-seq", "Lazy seq of files in directory tree"},
      {"filter", "Returns items where predicate true"},
      {"filterv", "Returns vector of items where pred true"},
      {"find", "Returns map entry for key or nil"},
      {"find-keyword", "Returns keyword with ns and name"},
      {"find-ns", "Returns namespace or nil"},
      {"find-var", "Returns var or nil"},
      {"first", "Returns first item"},
      {"flatten", "Flattens nested collections"},
      {"float", "Coerces to float"},
      {"float-array", "Creates float Java array"},
      {"float?", "Returns true if Float"},
      {"floats", "Casts to float array"},
      {"flush", "Flushes output writer"},
      {"fn", "Defines anonymous function"},
      {"fn?", "Returns true if value is function"},
      {"fnext", "First of next item"},
      {"fnil", "Returns function with nil defaults"},
      {"for", "List comprehension from nested iteration"},
      {"force", "Forces evaluation of delay"},
      {"format", "Returns formatted string"},
      {"frequencies", "Returns map of item frequencies"},
      {"future", "Async computation"},
      {"future-call", "Calls function asynchronously"},
      {"future-cancel", "Cancels future"},
      {"future-cancelled?", "Returns true if future cancelled"},
      {"future-done?", "Returns true if future complete"},
      {"future?", "Returns true if value is future"},
      {"gensym", "Returns unique symbol"},
      {"get", "Returns value for key or nil"},
      {"get-in", "Returns value at nested key path"},
      {"get-method", "Returns multimethod implementation"},
      {"get-proxy-class", "Returns proxy class"},
      {"get-thread-bindings", "Returns thread-local bindings"},
      {"get-validator", "Returns reference validator"},
      {"group-by", "Groups items by function result"},
      {"halt-when", "Transducer halting on predicate"},
      {"hash", "Returns hash code"},
      {"hash-map", "Creates hash map from pairs"},
      {"hash-ordered-coll", "Returns hash of ordered collection"},
      {"hash-set", "Creates hash set from items"},
      {"hash-unordered-coll", "Returns hash of unordered collection"},
      {"ident?", "Returns true if keyword or symbol"},
      {"identical?", "Returns true if same object"},
      {"identity", "Returns argument unchanged"},
      {"if", "Conditional branch"},
      {"if-let", "Conditional with binding"},
      {"if-not", "Negated conditional"},
      {"if-some", "Binds if not nil"},
      {"ifn?", "Returns true if invokable"},
      {"import", "Imports Java classes"},
      {"in-ns", "Changes current namespace"},
      {"inc", "Returns number plus one"},
      {"inc'", "Increments with arbitrary precision"},
      {"indexed?", "Returns true if supports indexed access"},
      {"infinite?", "Returns true if number infinite"},
      {"inst-ms", "Milliseconds since epoch for instant"},
      {"inst?", "Returns true if instant"},
      {"instance?", "Returns true if instance of class"},
      {"int", "Coerces to int"},
      {"int-array", "Creates int Java array"},
      {"int?", "Returns true if Integer"},
      {"integer?", "Returns true if integer"},
      {"interleave", "Interleaves items from collections"},
      {"intern", "Creates or returns var in namespace"},
      {"interpose", "Inserts separator between items"},
      {"into", "Conjoins items from source into target"},
      {"into-array", "Creates Java array from items"},
      {"ints", "Casts to int array"},
      {"isa?", "Returns true if child is parent instance"},
      {"iterate", "Lazy seq of repeated function application"},
      {"iteration", "Reducible wrapper of iterator"},
      {"iterator-seq", "Lazy seq from Java Iterator"},
      {"juxt", "Applies multiple functions, collects results"},
      {"keep", "Keeps non-nil results of function"},
      {"keep-indexed", "Keeps non-nil results with index"},
      {"key", "Returns key of map entry"},
      {"keys", "Returns map keys"},
      {"keyword", "Coerces to keyword"},
      {"keyword?", "Returns true if keyword"},
      {"last", "Returns last item"},
      {"lazy-cat", "Lazy concatenation of expressions"},
      {"lazy-seq", "Creates lazy sequence from expression"},
      {"let", "Local variable bindings"},
      {"letfn", "Binds function names for mutual recursion"},
      {"line-seq", "Lazy seq of lines from reader"},
      {"list", "Creates list from items"},
      {"list*", "Creates list with seq appended"},
      {"list?", "Returns true if list"},
      {"load", "Loads Clojure file from classpath"},
      {"load-file", "Loads Clojure file from path"},
      {"load-reader", "Loads code from reader"},
      {"load-string", "Loads code from string"},
      {"locking", "Acquires monitor lock, executes body"},
      {"long", "Coerces to long"},
      {"long-array", "Creates long Java array"},
      {"longs", "Casts to long array"},
      {"loop", "Loop with recur for tail recursion"},
      {"macroexpand", "Recursively expands macro"},
      {"macroexpand-1", "Expands macro one level"},
      {"make-array", "Creates Java array"},
      {"make-hierarchy", "Returns empty hierarchy"},
      {"map", "Applies function to each item"},
      {"map-entry?", "Returns true if map entry"},
      {"map-indexed", "Applies function with index to items"},
      {"map?", "Returns true if map"},
      {"mapcat", "Maps then concatenates results"},
      {"mapv", "Returns vector from mapping function"},
      {"max", "Returns greatest number"},
      {"max-key", "Returns item with greatest function value"},
      {"memfn", "Returns function calling Java method"},
      {"memoize", "Caches function results by arguments"},
      {"merge", "Merges maps"},
      {"merge-with", "Merges maps with combining function"},
      {"meta", "Returns metadata"},
      {"methods", "Returns multimethod implementations"},
      {"min", "Returns least number"},
      {"min-key", "Returns item with least function value"},
      {"mod", "Returns modulo"},
      {"name", "Returns name string of symbol/keyword"},
      {"namespace", "Returns namespace of symbol/keyword"},
      {"nat-int?", "Returns true if non-negative integer"},
      {"neg-int?", "Returns true if negative integer"},
      {"neg?", "Returns true if number negative"},
      {"newline", "Writes newline to output"},
      {"next", "Returns seq after first item"},
      {"nfirst", "Next of first item"},
      {"nil?", "Returns true if nil"},
      {"nnext", "Next of next item"},
      {"not", "Logical complement"},
      {"not-any?", "Returns true if pred false for all"},
      {"not-empty", "Returns collection or nil if empty"},
      {"not-every?", "Returns true if pred false for some"},
      {"not=", "Returns true if not equal"},
      {"nth", "Returns item at index"},
      {"nthnext", "Returns nth next"},
      {"nthrest", "Returns rest after nth item"},
      {"num", "Coerces to number"},
      {"number?", "Returns true if number"},
      {"numerator", "Returns numerator of ratio"},
      {"object-array", "Creates object Java array"},
      {"odd?", "Returns true if number odd"},
      {"or", "Short-circuit logical OR"},
      {"parents", "Returns immediate parents of tag"},
      {"parse-boolean", "Parses string to boolean"},
      {"parse-double", "Parses string to double"},
      {"parse-long", "Parses string to long"},
      {"parse-uuid", "Parses string to UUID"},
      {"partial", "Fixes supplied arguments to function"},
      {"partition", "Partitions items into groups of n"},
      {"partition-all", "Partitions without dropping partial group"},
      {"partition-by", "Partitions by change in function value"},
      {"pcalls", "Parallel calls to zero-arity functions"},
      {"peek", "Returns first/last without removing"},
      {"persistent!", "Converts transient to persistent"},
      {"pmap", "Parallel map over collection"},
      {"pop", "Returns collection without first/last"},
      {"pop!", "Removes from transient collection"},
      {"pos-int?", "Returns true if positive integer"},
      {"pos?", "Returns true if number positive"},
      {"pr", "Prints value in readable form"},
      {"pr-str", "Returns readable string of value"},
      {"prefer-method", "Prefers multimethod implementation"},
      {"prefers", "Returns multimethod preferences"},
      {"print", "Prints value without quoting"},
      {"print-str", "Returns printed string of value"},
      {"printf", "Prints formatted output"},
      {"println", "Prints with newline"},
      {"promise", "Creates promise"},
      {"proxy", "Creates proxy implementing interfaces"},
      {"push-thread-bindings", "Installs thread-local bindings"},
      {"qualified-ident?", "Returns true if ident has namespace"},
      {"qualified-keyword?", "Returns true if keyword has namespace"},
      {"qualified-symbol?", "Returns true if symbol has namespace"},
      {"quot", "Returns integer division quotient"},
      {"quote", "Returns form unevaluated"},
      {"rand", "Returns random float 0-1"},
      {"rand-int", "Returns random int less than arg"},
      {"rand-nth", "Returns random item from seq"},
      {"random-sample", "Returns random sample of items"},
      {"random-uuid", "Returns random UUID"},
      {"range", "Returns sequence of numbers"},
      {"ratio?", "Returns true if ratio"},
      {"rational?", "Returns true if rational number"},
      {"rationalize", "Coerces to ratio"},
      {"re-find", "Returns first regex match"},
      {"re-groups", "Returns regex match groups"},
      {"re-matcher", "Returns matcher for pattern"},
      {"re-matches", "Returns full regex match or nil"},
      {"re-pattern", "Returns compiled regex pattern"},
      {"re-seq", "Returns seq of regex matches"},
      {"read", "Reads next form from reader"},
      {"read-line", "Reads line from input"},
      {"read-string", "Reads form from string"},
      {"realized?", "Returns true if delay/future complete"},
      {"record?", "Returns true if record"},
      {"recur", "Rebinds loop vars and jumps to loop start"},
      {"reduce", "Reduces collection with function"},
      {"reduce-kv", "Reduces map with key-value function"},
      {"reduced", "Wraps value indicating reduction complete"},
      {"reduced?", "Returns true if wrapped in reduced"},
      {"reductions", "Returns intermediate reduction results"},
      {"ref", "Creates STM reference"},
      {"ref-set", "Sets ref value in transaction"},
      {"reify", "Creates instance implementing protocols"},
      {"rem", "Returns remainder of division"},
      {"remove", "Returns items where predicate false"},
      {"remove-all-methods", "Removes all multimethod impls"},
      {"remove-method", "Removes multimethod impl"},
      {"remove-ns", "Removes namespace"},
      {"remove-tap", "Removes function from tap set"},
      {"remove-watch", "Removes watch from reference"},
      {"repeat", "Returns infinite seq repeating value"},
      {"repeatedly", "Returns seq calling function repeatedly"},
      {"replace", "Replaces values by map mapping"},
      {"require", "Requires namespace"},
      {"requiring-resolve", "Requires ns and resolves symbol"},
      {"reset!", "Sets atom value"},
      {"reset-meta!", "Sets metadata"},
      {"reset-vals!", "Sets atom, returns [old new]"},
      {"resolve", "Resolves symbol in namespace"},
      {"rest", "Returns seq after first item"},
      {"restart-agent", "Restarts failed agent"},
      {"reverse", "Reverses order of items"},
      {"reversible?", "Returns true if collection reversible"},
      {"rseq", "Returns reverse seq of sorted collection"},
      {"rsubseq", "Returns reverse subseq of sorted coll"},
      {"run!", "Runs side effects, returns nil"},
      {"satisfies?", "Returns true if type satisfies protocol"},
      {"second", "Returns second item"},
      {"select-keys", "Returns map with only specified keys"},
      {"send", "Dispatches action to agent"},
      {"send-off", "Dispatches blocking action to agent"},
      {"send-via", "Sends action via executor to agent"},
      {"seq", "Returns sequence or nil if empty"},
      {"seq?", "Returns true if value is sequence"},
      {"seqable?", "Returns true if implements Seqable"},
      {"sequence", "Returns seq applying transducer"},
      {"sequential?", "Returns true if sequential"},
      {"set", "Creates set from items"},
      {"set!", "Sets thread-local var value"},
      {"set?", "Returns true if set"},
      {"short", "Coerces to short"},
      {"short-array", "Creates short Java array"},
      {"shorts", "Casts to short array"},
      {"shuffle", "Returns items in random order"},
      {"shutdown-agents", "Shuts down agent thread pool"},
      {"simple-ident?", "Returns true if ident has no namespace"},
      {"simple-keyword?", "Returns true if keyword has no ns"},
      {"simple-symbol?", "Returns true if symbol has no ns"},
      {"slurp", "Reads entire contents of file/URL"},
      {"some", "Returns first truthy result or nil"},
      {"some->", "Threads through forms while non-nil"},
      {"some->>", "Threads as last arg while non-nil"},
      {"some-fn", "Returns pred true if any fn truthy"},
      {"some?", "Returns true if not nil"},
      {"sort", "Returns sorted sequence"},
      {"sort-by", "Returns seq sorted by function result"},
      {"sorted-map", "Creates sorted map from pairs"},
      {"sorted-map-by", "Creates sorted map with comparator"},
      {"sorted-set", "Creates sorted set from items"},
      {"sorted-set-by", "Creates sorted set with comparator"},
      {"sorted?", "Returns true if collection sorted"},
      {"spit", "Writes content to file"},
      {"split-at", "Splits seq at index"},
      {"split-with", "Splits seq by predicate"},
      {"str", "Converts to string"},
      {"string?", "Returns true if string"},
      {"struct", "Creates structure instance"},
      {"struct-map", "Creates structure map from basis"},
      {"subs", "Returns substring"},
      {"subseq", "Returns subseq of sorted collection"},
      {"subvec", "Returns subvector"},
      {"supers", "Returns all ancestors of class"},
      {"swap!", "Updates atom with function"},
      {"swap-vals!", "Updates atom, returns [old new]"},
      {"symbol", "Coerces to symbol"},
      {"symbol?", "Returns true if symbol"},
      {"take", "Returns first n items"},
      {"take-last", "Returns last n items"},
      {"take-nth", "Returns every nth item"},
      {"take-while", "Takes items while predicate true"},
      {"tap>", "Sends value to taps"},
      {"test", "Runs tests for namespace"},
      {"throw", "Throws exception"},
      {"time", "Evaluates and prints elapsed time"},
      {"to-array", "Converts to object array"},
      {"to-array-2d", "Converts to 2D array"},
      {"trampoline", "Mutual recursion without stack overflow"},
      {"transduce", "Reduces with transducer"},
      {"transient", "Creates transient collection"},
      {"tree-seq", "Depth-first seq from root"},
      {"true?", "Returns true if value is true"},
      {"try", "Exception handling"},
      {"type", "Returns type of value"},
      {"unchecked-add", "Adds without overflow check"},
      {"unchecked-add-int", "Adds ints without overflow check"},
      {"unchecked-byte", "Casts to byte without check"},
      {"unchecked-char", "Casts to char without check"},
      {"unchecked-dec", "Decrements without overflow check"},
      {"unchecked-dec-int", "Decrements int without check"},
      {"unchecked-divide-int", "Divides ints without check"},
      {"unchecked-double", "Casts to double without check"},
      {"unchecked-float", "Casts to float without check"},
      {"unchecked-inc", "Increments without overflow check"},
      {"unchecked-inc-int", "Increments int without check"},
      {"unchecked-int", "Casts to int without check"},
      {"unchecked-long", "Casts to long without check"},
      {"unchecked-multiply", "Multiplies without overflow check"},
      {"unchecked-multiply-int", "Multiplies ints without check"},
      {"unchecked-negate", "Negates without overflow check"},
      {"unchecked-negate-int", "Negates int without check"},
      {"unchecked-remainder-int", "Remainder without check"},
      {"unchecked-short", "Casts to short without check"},
      {"unchecked-subtract", "Subtracts without overflow check"},
      {"unchecked-subtract-int", "Subtracts ints without check"},
      {"underive", "Removes hierarchical relationship"},
      {"unreduced", "Unwraps from reduced"},
      {"unsigned-bit-shift-right", "Unsigned right shift"},
      {"update", "Applies function to map value at key"},
      {"update-in", "Applies function to nested map value"},
      {"update-keys", "Applies function to map keys"},
      {"update-proxy", "Updates proxy method implementations"},
      {"update-vals", "Applies function to map values"},
      {"val", "Returns value of map entry"},
      {"vals", "Returns map values"},
      {"var-get", "Gets value of var"},
      {"var-set", "Sets var in thread-local binding"},
      {"var?", "Returns true if var"},
      {"vary-meta", "Returns value with transformed metadata"},
      {"vec", "Converts to vector"},
      {"vector", "Creates vector from items"},
      {"vector?", "Returns true if vector"},
      {"volatile!", "Creates volatile with initial value"},
      {"volatile?", "Returns true if volatile"},
      {"vreset!", "Sets volatile value"},
      {"vswap!", "Updates volatile with function"},
      {"when", "Evaluates body if test true"},
      {"when-first", "Evaluates body if seq non-empty"},
      {"when-let", "Binds if truthy, evaluates body"},
      {"when-not", "Evaluates body if test false"},
      {"when-some", "Binds if not nil, evaluates body"},
      {"while", "Repeats body while test true"},
      {"with-bindings", "Executes body with thread-local bindings"},
      {"with-in-str", "Evaluates body with string as input"},
      {"with-local-vars", "Evaluates body with local var bindings"},
      {"with-meta", "Returns value with new metadata"},
      {"with-open", "Opens resources, closes on exit"},
      {"with-out-str", "Captures output to string"},
      {"with-precision", "Sets decimal precision for body"},
      {"with-redefs", "Redefines vars for body duration"},
      {"xml-seq", "Lazy seq of XML elements"},
      {"zero?", "Returns true if number is zero"},
      {"zipmap", "Creates map from keys and values seqs"}
    ]
  end

  @doc false
  def clojure_string_vars do
    [
      {"blank?", "True if s is nil, empty, or contains only whitespace"},
      {"capitalize", "Converts first character to upper-case, rest to lower-case"},
      {"ends-with?", "True if s ends with substr"},
      {"escape", "Return a new string applying cmap to each character"},
      {"includes?", "True if s includes substr"},
      {"index-of", "Return index of value in string"},
      {"join", "Returns a string of elements joined by separator"},
      {"last-index-of", "Return last index of value in string"},
      {"lower-case", "Converts string to all lower-case"},
      {"re-quote-replacement", "Escapes special characters in replacement string"},
      {"replace", "Replaces all instances of match in s"},
      {"replace-first", "Replaces first instance of match in s"},
      {"reverse", "Returns s with characters reversed"},
      {"split", "Splits string on regex or string"},
      {"split-lines", "Splits string on \\n or \\r\\n"},
      {"starts-with?", "True if s starts with substr"},
      {"trim", "Removes whitespace from both ends of string"},
      {"trim-newline", "Removes all trailing newline or return characters"},
      {"triml", "Removes whitespace from the left side of string"},
      {"trimr", "Removes whitespace from the right side of string"},
      {"upper-case", "Converts string to all upper-case"}
    ]
  end

  @doc false
  def clojure_set_vars do
    [
      {"difference", "Return a set that is the first set without elements of the remaining sets"},
      {"index", "Returns a map of the distinct values of ks mapped to sets of maps"},
      {"intersection", "Return a set that is the intersection of the input sets"},
      {"join", "When passed 2 rels, returns the rel corresponding to the natural join"},
      {"map-invert", "Returns the map with vals mapped to keys"},
      {"project", "Returns a rel of the elements of xrel with only the keys in ks"},
      {"rename", "Returns a rel with the keys in kmap renamed"},
      {"rename-keys", "Returns the map with keys renamed according to kmap"},
      {"select", "Returns a set of the elements for which pred is true"},
      {"subset?", "Is set1 a subset of set2?"},
      {"superset?", "Is set1 a superset of set2?"},
      {"union", "Return a set that is the union of the input sets"}
    ]
  end

  @doc false
  def java_math_vars do
    [
      {"abs", "Returns the absolute value"},
      {"acos", "Returns the arc cosine of a value"},
      {"addExact", "Returns sum, throwing on overflow"},
      {"asin", "Returns the arc sine of a value"},
      {"atan", "Returns the arc tangent of a value"},
      {"atan2", "Returns angle theta from (x,y) to polar (r,theta)"},
      {"cbrt", "Returns the cube root of a value"},
      {"ceil", "Returns the smallest integer >= argument"},
      {"copySign", "Returns first arg with sign of second arg"},
      {"cos", "Returns the trigonometric cosine of an angle"},
      {"cosh", "Returns the hyperbolic cosine of a value"},
      {"decrementExact", "Returns argument decremented by one, throwing on overflow"},
      {"exp", "Returns Euler's number e raised to the power of a"},
      {"expm1", "Returns e^x - 1"},
      {"floor", "Returns the largest integer <= argument"},
      {"floorDiv", "Returns floor of integer division"},
      {"floorMod", "Returns floor modulus of arguments"},
      {"fma", "Fused multiply-add"},
      {"getExponent", "Returns unbiased exponent of a float/double"},
      {"hypot", "Returns sqrt(x^2 + y^2) without intermediate overflow"},
      {"IEEEremainder", "Returns IEEE 754 remainder"},
      {"incrementExact", "Returns argument incremented by one, throwing on overflow"},
      {"log", "Returns the natural logarithm (base e) of a value"},
      {"log10", "Returns the base 10 logarithm of a value"},
      {"log1p", "Returns ln(1 + x)"},
      {"max", "Returns the greater of two values"},
      {"min", "Returns the smaller of two values"},
      {"multiplyExact", "Returns product, throwing on overflow"},
      {"multiplyHigh", "Returns high 64 bits of 128-bit product"},
      {"negateExact", "Returns negation, throwing on overflow"},
      {"nextAfter", "Returns adjacent floating-point value"},
      {"nextDown", "Returns adjacent floating-point value towards negative infinity"},
      {"nextUp", "Returns adjacent floating-point value towards positive infinity"},
      {"pow", "Returns the value of a raised to the power of b"},
      {"random", "Returns a pseudorandom double between 0.0 and 1.0"},
      {"rint", "Returns closest double to argument that is a mathematical integer"},
      {"round", "Returns the closest long/int to the argument"},
      {"scalb", "Returns d × 2^scaleFactor"},
      {"signum", "Returns the signum function of the argument"},
      {"sin", "Returns the trigonometric sine of an angle"},
      {"sinh", "Returns the hyperbolic sine of a value"},
      {"sqrt", "Returns the positive square root of a value"},
      {"subtractExact", "Returns difference, throwing on overflow"},
      {"tan", "Returns the trigonometric tangent of an angle"},
      {"tanh", "Returns the hyperbolic tangent of a value"},
      {"toDegrees", "Converts an angle from radians to degrees"},
      {"toIntExact", "Returns long narrowed to int, throwing on overflow"},
      {"toRadians", "Converts an angle from degrees to radians"},
      {"ulp", "Returns size of an ulp of the argument"}
    ]
  end
end
