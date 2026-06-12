defmodule PtcRunner.Lisp.SourceAtoms do
  @moduledoc """
  Bounded vocabulary — the set of names the parser is allowed to
  intern as atoms.

  More precisely: this is the set of source-text names the
  analyzer/evaluator currently pattern-matches as atom literals.
  Builtin function names + special forms + bounded namespaces +
  destructuring modifiers + qualified analyzer keys + short-fn
  param atoms. Everything else stays as a binary in the AST so the
  global atom table never grows from user input (issue #953).

  Why an explicit allowlist instead of `String.to_existing_atom/1`:
  the global VM atom table is non-deterministic — unrelated modules
  loading later can change how the same source parses. Codex's
  pushback on the bug thread covers this in detail.

  ## What's in the table

    1. Every env-dispatched builtin name from
       `PtcRunner.Lisp.BuiltinNames.env_names/0` — all builtin
       functions (`map`, `filter`, `+`, `str`, etc.). These equal the
       keys of `PtcRunner.Lisp.Env.initial/0` but are derived from the
       compile-time registry so `SourceAtoms` stays out of the Lisp
       runtime cycle (issue #1051).
    2. Analyzer special forms — `let`, `fn`, `def`, `if`, `case`, etc.
       Only forms that the analyzer currently dispatches on. No
       aspirational Clojure entries.
    3. Bounded keyword modifiers used by `for`/`doseq`/destructuring —
       `:else`, `:keys`, `:as`, `:or`, etc.
    4. Bounded namespaces — `data`, `tool`, `budget`,
       `json`, `mcp`, plus Clojure aliases (`clojure.string`),
       and fully-qualified Java namespaces from `Env.clojure_namespaces`
       (`java.time.LocalDate`, etc.).
    5. Qualified analyzer keys such as `servers` and JSON member
       names matched as atom literals in `dispatch_list_form` clauses.
    6. Short-fn param atoms `:p1`..`:p20` synthesized by the
       short-fn analyzer.

  ## What's NOT in the table

  User-defined names: var bindings from `let`, `fn` params, `def`
  bindings, custom keywords like `:my_kw`, namespaced keys like
  `data/foo_42`. These stay as binaries in the AST.

  ## Cache

  Table is built lazily on first call and cached in `:persistent_term`.
  Read cost after first call is one `:persistent_term.get/1` (no copy).
  """

  alias PtcRunner.Lisp.BuiltinNames

  @doc """
  Returns the atom for `name` if it's in the bounded vocabulary,
  otherwise returns the binary unchanged.

  This is the only function the parser should call to convert a
  source-text name into its AST representation.
  """
  @spec intern(String.t()) :: atom() | String.t()
  def intern(name) when is_binary(name) do
    Map.get(table(), name, name)
  end

  @doc """
  Returns the full lookup table — binary names → atoms.

  Cached in `:persistent_term` after first call.
  """
  @spec table() :: %{String.t() => atom()}
  def table do
    case :persistent_term.get({__MODULE__, :table}, :unset) do
      :unset ->
        t = build_table()
        :persistent_term.put({__MODULE__, :table}, t)
        t

      t ->
        t
    end
  end

  # ============================================================
  # Bounded vocabulary (in addition to BuiltinNames.env_names)
  # ============================================================

  # Special forms that the analyzer dispatches via atom-literal
  # pattern match. Sourced from `eval/helpers.ex @special_forms` plus
  # forms the analyzer uses but `eval/helpers.ex` doesn't list as
  # closure-error hints. Audited 2026-05-15: no aspirational entries.
  @special_forms ~w(
    return fail
    task step-done task-reset
    let fn def defn defonce
    if if-let if-not if-some
    when when-let when-not when-some when-first
    cond case condp do
    and or not
    -> ->> as-> cond-> cond->> some-> some->>
    loop recur
    doseq for
    comment
    juxt pmap pcalls
    quote apropos dir doc meta ns-publics all-ns ns-name
    .
  )a

  # Keyword modifiers used by for/doseq and destructuring.
  # `:while` is a for/doseq modifier. `:keys`/`:strs`/`:or`/`:as` are
  # destructuring forms. `:else` is the cond/case fallthrough key.
  @keyword_modifiers ~w(
    when let while else
    keys strs as or
  )a

  # Bounded namespace prefixes used in `ns/key` syntax. The analyzer
  # pattern-matches these as atom literals in `{:ns_symbol, ns, _}`.
  # Fully-qualified Java namespaces are included verbatim because
  # `parse_namespaced_symbol` doesn't split them — `java.time.LocalDate`
  # is one atom, not `java.time` + `LocalDate`.
  @bounded_namespaces ~w(
    data tool budget json mcp
    str string set regex
    walk
    Math System Boolean Double Float Integer Long
    LocalDate Instant Duration
    java.time.LocalDate java.time.Instant java.time.Duration java.util.Date.
    clojure.core clojure.string clojure.set clojure.walk
    core
  )a

  # Qualified analyzer keys — atom literals after `ns/` in dispatch
  # clauses (e.g. `(tool/servers)` and other REPL discovery forms).
  # Verified via `rg ':"[a-z-]+"' lib/ptc_runner/lisp/analyze.ex`.
  @qualified_keys ~w(
    summary remaining servers
    parse-string parse-lines generate-string between text json
    re-pattern
  )a

  # Symbol special names appearing in analyzer pattern matches that
  # are NOT function names (so not in Env.initial). E.g. `&` for variadic
  # `rest` markers, parameter sigils.
  @special_symbols ~w(
    & rest
  )a

  # Short-fn synthesized param atoms (#(...) macro expands to
  # `(fn [p1 p2 ...] body)`). Arity is bounded.
  @short_fn_params for i <- 1..20, do: String.to_atom("p#{i}")

  # Turn history references — handled outside the parser path
  # (AST.symbol returns {:turn_history, n} directly), so not needed
  # here, but included for documentation completeness.

  defp build_table do
    builtins = BuiltinNames.env_names()

    explicit =
      @special_forms ++
        @keyword_modifiers ++
        @bounded_namespaces ++
        @qualified_keys ++
        @special_symbols ++
        @short_fn_params

    (builtins ++ explicit)
    |> Enum.uniq()
    |> Map.new(fn atom -> {Atom.to_string(atom), atom} end)
  end
end
