defmodule PtcRunner.Lisp.SourceAtoms do
  @moduledoc """
  Bounded vocabulary of atoms the parser is allowed to produce from
  source text.

  Why this exists: `String.to_atom/1` on parser input is an
  unbounded-atom leak (issue #953). Using `String.to_existing_atom/1`
  instead "works" but is a footgun — it consults the *global VM atom
  table*, so the same source can parse differently depending on which
  other modules happen to be loaded.

  This module is the explicit allowlist. Names in the table become
  atoms (so the analyzer's atom-literal dispatch keeps working).
  Names NOT in the table stay as binaries (no permanent atom is created).

  ## What's in the table

    1. Every key of `PtcRunner.Lisp.Env.initial/0` — all builtin
       functions (`map`, `filter`, `+`, `str`, etc.).
    2. Analyzer special forms — `let`, `fn`, `def`, `if`, `case`, etc.
    3. Bounded keyword modifiers used by `for`/`doseq`/destructuring —
       `:else`, `:keys`, `:as`, etc.
    4. Bounded namespaces — `data`, `tool`, `catalog`, `budget`,
       `json`, `mcp`, plus Clojure aliases like `clojure.string`.
    5. Symbol special names — operator-like atoms that appear in
       analyzer pattern matches.

  ## What's NOT in the table

  User-defined names: var bindings from `let`, `fn` params, `def`
  bindings, custom keywords like `:my_kw`, namespaced keys like
  `data/foo_42`. These stay as binaries in the AST.

  ## Cache

  Table is built lazily on first call and cached in `:persistent_term`.
  Read cost after first call is one `:persistent_term.get/1` (no copy).
  """

  alias PtcRunner.Lisp.Env

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
  # Bounded vocabulary (in addition to Env.initial keys)
  # ============================================================

  # Special forms that the analyzer dispatches via atom-literal
  # pattern match. Keep in sync with eval/helpers.ex @special_forms
  # and analyzer dispatch_list_form clauses.
  @special_forms ~w(
    return fail
    let fn def defn defonce defmacro
    if when when-let when-some when-first if-let if-some
    cond case condp do
    and or not
    -> ->> as-> cond-> cond->> some-> some->>
    loop recur
    try catch throw finally
    doseq for while dotimes
    comment
  )a

  # Keyword modifiers used by for/doseq and destructuring.
  @keyword_modifiers ~w(
    when let while else
    keys strs syms as default or
  )a

  # Bounded namespace prefixes used in `ns/key` syntax. The analyzer
  # pattern-matches these as atom literals in `{:ns_symbol, ns, _}`.
  @bounded_namespaces ~w(
    data tool catalog budget json mcp
    str string set regex
    Math Interop System
    LocalDate Instant
    clojure.core clojure.string clojure.set
    core
  )a

  # Common qualified keys analyzer dispatches on (e.g. `(catalog/summary)`,
  # `(budget/remaining)`). The atom_str-suffix-split path in analyze.ex's
  # @qualified_namespace_tables auto-intern these from Env.initial, but
  # short-form analyzer clauses also use atom literals like :"list-tools".
  @qualified_keys ~w(
    summary remaining list-servers list-tools describe-tool
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
    builtins =
      Env.initial()
      |> Map.keys()

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
