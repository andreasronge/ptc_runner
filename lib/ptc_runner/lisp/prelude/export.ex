defmodule PtcRunner.Lisp.Prelude.Export do
  @moduledoc """
  Per-export public projection consulted by the analyzer, evaluator,
  bundle validation and prompt rendering.

  An export record is **derived** from compiled prelude facts plus host
  policy. It is not an independent source of authority — host policy and
  runtime facts win. Only `:prompt` and
  `:discoverable` exports get records here; private prelude helpers
  (`defn-`) do not.

  ## Host-boundary string-backing

  `ref`, `namespace`, and `symbol` are kept as binaries to avoid leaking
  atoms from deployment-authored prelude source. Each `requires` entry is a
  canonical tool id (also a binary).
  Only the curated, bounded fields `visibility` and
  `effect` are atoms.

  ## Minimal shape

    * `ref` — Lisp-facing export ref, e.g. `"crm/get-user"`.
    * `namespace` — declaring namespace, e.g. `"crm"`.
    * `symbol` — bare export symbol, e.g. `"get-user"` (curated kebab-case).
    * `arity` — non-negative integer arity, or `:variadic`.
    * `params` — display arglist names captured from the source params vector,
      with `"&"` preserved as the variadic marker. Destructuring params use a
      synthetic `argN` fallback because they have no single display name.
    * `doc` — docstring binary, or `nil`.
    * `visibility` — `:prompt` (prompt inventory + discoverable) or
      `:discoverable` (discovery-only).
    * `effect` — resolved effect hint: `:read`, `:write`, or `:unknown`.
    * `declared_effect` — explicit metadata value, or `nil`; retained for
      introspection while `effect` also includes transitive wrapper declarations.
    * `requires` — list of canonical backing ids the export needs, validated
      against the selected runtime at attach time (not here).
    * `tool_refs` — sorted typed-tool names (binaries) this export invokes,
      computed transitively over same-namespace private helpers. The
      pre-execution tool guard (`check_undefined_tools`) unions these in when a
      program references the export, so a wrapped tool call cannot slip
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
    * `signature` — optional canonical function contract string.
    * `type` — optional canonical constant type string.
    * `parsed_signature` / `parsed_type` — bounded compiled contract values
      retained for runtime validation and structured model projection.
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
          params: [String.t()],
          doc: String.t() | nil,
          visibility: visibility(),
          effect: effect(),
          declared_effect: effect() | nil,
          requires: [String.t()],
          tool_refs: [String.t()],
          min_arity: non_neg_integer(),
          kind: kind(),
          signature: String.t() | nil,
          type: String.t() | nil,
          parsed_signature: PtcRunner.Lisp.Signature.signature() | nil,
          parsed_type: PtcRunner.Lisp.Signature.type() | nil
        }

  @enforce_keys [:ref, :namespace, :symbol, :arity, :visibility]
  defstruct ref: nil,
            namespace: nil,
            symbol: nil,
            arity: nil,
            params: [],
            doc: nil,
            visibility: :prompt,
            effect: :unknown,
            declared_effect: nil,
            requires: [],
            tool_refs: [],
            min_arity: 0,
            kind: :function,
            signature: nil,
            type: nil,
            parsed_signature: nil,
            parsed_type: nil

  @valid_visibilities [:prompt, :discoverable]

  @doc "Valid visibility values for a public export."
  @spec valid_visibilities() :: [visibility()]
  def valid_visibilities, do: @valid_visibilities

  @doc "Whether `value` is a valid export visibility."
  @spec valid_visibility?(term()) :: boolean()
  def valid_visibility?(value), do: value in @valid_visibilities

  @doc """
  Renders the Lisp-facing arglist for an export.

  Uses the parameter names captured from the compiled source.
  """
  @spec signature(t()) :: String.t()
  def signature(%__MODULE__{symbol: symbol, params: params}) do
    args = Enum.join(params, " ")

    if args == "", do: "(#{symbol})", else: "(#{symbol} #{args})"
  end

  @doc """
  Renders the fully-qualified call form for an export, e.g.
  `"(crm/get-user id)"`.

  A `:constant` export yields its bare ref: `(cfg/answer)` would apply the
  value rather than read it, so the ref alone is the correct call form.

  Both the model-facing mission inventory and `PtcRunner.Lisp.Introspection`
  render call forms from here, so the form a program is shown by `(doc ...)` is
  the form the prompt advertises.
  """
  @spec call_form(t()) :: String.t()
  def call_form(%__MODULE__{kind: :constant, ref: ref}), do: ref

  def call_form(%__MODULE__{ref: ref, symbol: symbol} = export) do
    export
    |> signature()
    |> String.replace_prefix("(#{symbol}", "(#{ref}")
  end
end
