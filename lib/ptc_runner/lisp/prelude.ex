defmodule PtcRunner.Lisp.Prelude do
  @moduledoc """
  Compiled, stateless deployment prelude artifact (Capability Prelude V1).

  A deployment loads curated PTC-Lisp prelude source that declares protected
  namespaces (e.g. `crm`) and exports functions/constants. The compiler
  (`PtcRunner.Lisp.Prelude.Compiler`) turns that source into one of these
  artifacts, which is then attached to a run and consulted — unchanged —
  across direct Lisp execution, SubAgent execution, and the REPL (plan §1A).

  ## Fields

    * `namespaces` — sorted list of declared namespace-name strings. These are
      the prelude-protected namespaces (host-boundary string-backed).
    * `exports` — list of `%PtcRunner.Lisp.Prelude.Export{}` public export
      records (`:prompt` + `:discoverable`). Private helpers are NOT here.
    * `private_env` — the captured private prelude environment, keyed by
      namespace then bare symbol: `%{namespace => %{symbol => callable}}`
      (`{:closure, ...}` for `defn`). Namespace-scoping keeps same-named
      definitions in different namespaces distinct (e.g. `crm/who` vs
      `hr/who`). Public exports call their own namespace's private helpers
      through this env; user code cannot resolve private helpers by qualified
      symbol (plan §5). The CALLABLE values are the contract slice 2
      (evaluator threading) depends on.
    * `source_hash` — sha256 hex digest of the prelude source (plan §12
      traceability).
    * `metadata` — small map of namespace-level facts for traces/debugging,
      e.g. per-namespace docstring and default visibility.

  ## Private-env capture seam (fact #6)

  `defn`/`defn-` in the prelude desugar through the existing analyze+eval
  pipeline to `{:closure, params, body, captured_env, turn_history, meta}`
  tuples stored under their bare symbol in a `user_ns`-shaped map. The
  compiler captures that whole map as `private_env`. Sibling helpers are NOT
  folded into each closure's `captured_env` — they resolve by name through
  `user_ns` at call time, and `private_env` is exactly that namespace. P2
  therefore threads `private_env` as the user_ns layer (resolver position
  between the mutable `user` namespace and built-ins) when invoking exports:
  a public export resolves qualified (`crm/get-user`) to
  `private_env[symbol]` and runs its body against `private_env`, so private
  helpers resolve, while private symbols stay absent from `exports` and so
  are unreachable by qualified user calls. Proven end-to-end during P0.

  ## Validation errors

  Compile-time failures are returned as
  `{:error, %PtcRunner.Lisp.Prelude.ValidationError{}}`, never raised.
  """

  alias PtcRunner.Lisp.Prelude.Export

  @type t :: %__MODULE__{
          namespaces: [String.t()],
          exports: [Export.t()],
          private_env: %{String.t() => %{String.t() => term()}},
          source_hash: String.t(),
          metadata: map()
        }

  @enforce_keys [:namespaces, :exports, :private_env, :source_hash]
  defstruct namespaces: [],
            exports: [],
            private_env: %{},
            source_hash: nil,
            metadata: %{}

  @doc "The declared (protected) namespace names, sorted."
  @spec namespaces(t()) :: [String.t()]
  def namespaces(%__MODULE__{namespaces: namespaces}), do: namespaces

  @doc """
  Public export records visible in the prompt inventory (`:prompt` only).
  """
  @spec prompt_exports(t()) :: [Export.t()]
  def prompt_exports(%__MODULE__{exports: exports}) do
    Enum.filter(exports, &(&1.visibility == :prompt))
  end

  @doc "Looks up a public export by its Lisp-facing ref (e.g. `\"crm/get-user\"`)."
  @spec fetch_export(t(), String.t()) :: {:ok, Export.t()} | :error
  def fetch_export(%__MODULE__{exports: exports}, ref) when is_binary(ref) do
    case Enum.find(exports, &(&1.ref == ref)) do
      nil -> :error
      export -> {:ok, export}
    end
  end

  @doc """
  The typed-tool names a public export invokes (transitively over same-namespace
  helpers), or `[]` when `ref` is not a public export.

  The pre-execution tool guard unions these in so a prelude-wrapped
  `(tool/call ...)` is validated before any side effect runs (plan §6/§7).
  """
  @spec export_tool_refs(t(), String.t()) :: [String.t()]
  def export_tool_refs(%__MODULE__{exports: exports}, ref) when is_binary(ref) do
    case Enum.find(exports, &(&1.ref == ref)) do
      nil -> []
      export -> export.tool_refs
    end
  end

  @typedoc """
  Trace/debug summary of a compiled prelude (plan §12 Traceability).

  String/atom/list-only, JSON-serializable, and credential-free: it carries
  enough to REPRODUCE the V1 capability environment without leaking captured
  closures, the private prelude env, or any host secret.

    * `source_hash` — sha256 hex of the prelude source.
    * `artifact_hash` — sha256 hex over the compiled artifact's protected
      facts (namespaces + public export records). Lets a trace consumer tell
      whether two runs used the same compiled prelude even when source text is
      unavailable.
    * `protected_namespaces` — the selected protected namespace names (sorted).
    * `host_policy_hash` — host policy hash/id when available; `nil` in V1
      (no first-class host policy yet).
    * `exports` — one `export_summary` per PUBLIC export (no callables/env).
  """
  @type export_summary :: %{
          ref: String.t(),
          namespace: String.t(),
          symbol: String.t(),
          arity: non_neg_integer() | :variadic,
          visibility: Export.visibility(),
          effect: Export.effect(),
          provider_ref: String.t() | nil,
          requires: [String.t()]
        }

  @type trace_summary :: %{
          source_hash: String.t(),
          artifact_hash: String.t(),
          protected_namespaces: [String.t()],
          host_policy_hash: String.t() | nil,
          exports: [export_summary()]
        }

  @doc """
  Builds the trace/debug summary for `prelude` (plan §12).

  Returns `nil` for `nil` (no prelude attached). The result is JSON-serializable
  and contains NO captured closures, private prelude env, or credentials — only
  the protected facts needed to reproduce the capability environment.

  The `host_policy_hash` slot is `nil` in V1; it is reserved for when a host
  policy hash/id becomes available.
  """
  @spec trace_summary(t() | nil) :: trace_summary() | nil
  def trace_summary(nil), do: nil

  def trace_summary(%__MODULE__{} = prelude) do
    export_summaries = Enum.map(prelude.exports, &export_summary/1)

    %{
      source_hash: prelude.source_hash,
      artifact_hash: artifact_hash(prelude.namespaces, export_summaries),
      protected_namespaces: prelude.namespaces,
      host_policy_hash: nil,
      exports: export_summaries
    }
  end

  defp export_summary(%Export{} = export) do
    %{
      ref: export.ref,
      namespace: export.namespace,
      symbol: export.symbol,
      arity: export.arity,
      visibility: export.visibility,
      effect: export.effect,
      provider_ref: export.provider_ref,
      requires: export.requires
    }
  end

  # Deterministic hash over the protected facts: the sorted namespace list and
  # the public export summaries. Uses `:erlang.term_to_binary/2` with a fixed
  # minor version so the digest is stable across runs and never depends on the
  # captured closures or private env.
  defp artifact_hash(namespaces, export_summaries) do
    payload = :erlang.term_to_binary({namespaces, export_summaries}, minor_version: 2)

    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end
end
