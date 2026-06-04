defmodule PtcRunner.Lisp.Prelude.Export do
  @moduledoc """
  Per-export public projection consulted by the analyzer, evaluator,
  discovery forms, and the prompt renderer (Capability Prelude V1).

  An export record is **derived** from compiled prelude facts plus host
  policy. It is not an independent source of authority — host policy and
  runtime facts win (see plan §10 Metadata Precedence). Only `:prompt` and
  `:discoverable` exports get records here; private prelude helpers
  (`defn-`) do not (plan §8).

  ## Host-boundary string-backing

  `ref`, `namespace`, and `symbol` are kept as binaries to avoid leaking
  atoms from deployment-authored prelude source (plan §3, Implementation
  Notes). `provider_ref` and each `requires` entry are canonical backing
  ids (also binaries). Only the curated, bounded fields `visibility` and
  `effect` are atoms.

  ## Minimal shape (plan §3)

    * `ref` — Lisp-facing export ref, e.g. `"crm/get-user"`.
    * `namespace` — declaring namespace, e.g. `"crm"`.
    * `symbol` — bare export symbol, e.g. `"get-user"` (curated kebab-case).
    * `arity` — non-negative integer arity, or `:variadic`.
    * `doc` — docstring binary, or `nil`.
    * `visibility` — `:prompt` (prompt inventory + discoverable) or
      `:discoverable` (discovery-only).
    * `effect` — resolved effect hint: `:read`, `:write`, or `:unknown`.
    * `provider_ref` — backing provider/operation id, e.g.
      `"upstream:crm/get_user"`, or `nil`.
    * `requires` — list of canonical backing ids the export needs, validated
      against the selected runtime at attach time (not here).
    * `tool_refs` — sorted typed-tool names (binaries) this export invokes,
      computed transitively over same-namespace private helpers. The
      pre-execution tool guard (`check_undefined_tools`) unions these in when a
      program references the export, so a wrapped `(tool/call ...)` cannot slip
      past the guard and cause a partial side effect.
    * `min_arity` — minimum number of arguments a call must supply. For a
      fixed-arity export this equals `arity`; for a `:variadic` export it is the
      count of required leading params before `&`. The analyzer rejects calls
      with fewer args than this, so a too-few-args call fails at analysis time
      rather than at runtime after earlier side effects.
    * `kind` — `:function` for a `defn` export (invoked when called) or
      `:constant` for a `def` export (a plain value, even if that value is a
      function). A call `(cfg/answer)` of a constant YIELDS the value rather
      than applying it.
  """

  @type visibility :: :prompt | :discoverable
  @type effect :: :read | :write | :unknown
  @type export_arity :: non_neg_integer() | :variadic
  @type kind :: :function | :constant

  @type t :: %__MODULE__{
          ref: String.t(),
          namespace: String.t(),
          symbol: String.t(),
          arity: export_arity(),
          doc: String.t() | nil,
          visibility: visibility(),
          effect: effect(),
          provider_ref: String.t() | nil,
          requires: [String.t()],
          tool_refs: [String.t()],
          min_arity: non_neg_integer(),
          kind: kind()
        }

  @enforce_keys [:ref, :namespace, :symbol, :arity, :visibility]
  defstruct ref: nil,
            namespace: nil,
            symbol: nil,
            arity: nil,
            doc: nil,
            visibility: :prompt,
            effect: :unknown,
            provider_ref: nil,
            requires: [],
            tool_refs: [],
            min_arity: 0,
            kind: :function

  @valid_visibilities [:prompt, :discoverable]

  @doc "Valid visibility values for a public export."
  @spec valid_visibilities() :: [visibility()]
  def valid_visibilities, do: @valid_visibilities

  @doc "Whether `value` is a valid export visibility."
  @spec valid_visibility?(term()) :: boolean()
  def valid_visibility?(value), do: value in @valid_visibilities
end
