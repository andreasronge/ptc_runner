defmodule PtcRunner.Lisp.Analyze.PreludeScope do
  @moduledoc """
  Process-local scope for the compiled prelude consulted during a single
  analysis pass (Capability Prelude V1, plan §4 / §2).

  The analyzer's `do_analyze/2` is deeply mutually-recursive across ~80
  clauses; threading the prelude artifact through every clause would be a
  cascading refactor for a value only the qualified-`ns_symbol` clauses and the
  qualified-definition (protected-write) clauses need. Instead the prelude is
  stashed in the process dictionary for the duration of one `analyze/2` call
  (set on entry, restored on exit via `with_prelude/2`). Analysis runs in a
  fresh bounded sandbox process per `PtcRunner.Lisp.run`, so this state is
  naturally request-scoped and never shared across runs.

  Two questions this module answers for qualified names like `crm/get-user`,
  where `ns`/`symbol` arrive STRING-backed (unknown namespaces are not in
  `SourceAtoms` so they intern as `{:ns_symbol, "crm", "get-user"}` — fact #1):

    * `fetch_export/2` — is `ns/symbol` a PUBLIC prelude export, and what is its
      arity? Private helpers (`defn-`) have no export record, so they are
      absent here and stay unreachable by qualified user calls (plan §5 / §8).
    * `protected_namespace?/1` — is `ns` a protected namespace (a reserved host
      namespace or one declared by the attached prelude)? Used to reject
      `(def ns/x ...)` / `(defn ns/f ...)` writes with a protection fault rather
      than a generic invalid-qualified-name syntax error (plan §2).
  """

  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Export
  alias PtcRunner.Lisp.ProtectedNamespaces

  @key :__ptc_analyze_prelude__

  @doc """
  Runs `fun` with `prelude` installed as the analysis-pass prelude scope,
  restoring any previously installed scope afterward.
  """
  @spec with_prelude(Prelude.t() | nil, (-> result)) :: result when result: term()
  def with_prelude(prelude, fun) when is_function(fun, 0) do
    previous = Process.get(@key, :__none__)
    Process.put(@key, prelude)

    try do
      fun.()
    after
      case previous do
        :__none__ -> Process.delete(@key)
        prev -> Process.put(@key, prev)
      end
    end
  end

  @doc "The prelude installed for the current analysis pass, or `nil`."
  @spec current() :: Prelude.t() | nil
  def current do
    case Process.get(@key, nil) do
      %Prelude{} = prelude -> prelude
      _ -> nil
    end
  end

  @doc """
  Looks up `ns/symbol` (both STRING-backed) in the current prelude's PUBLIC
  export table. Returns `{:ok, %Export{}}` or `:error`.
  """
  @spec fetch_export(term(), term()) :: {:ok, Export.t()} | :error
  def fetch_export(ns, symbol) do
    with %Prelude{} = prelude <- current(),
         ns_str when is_binary(ns_str) <- to_string_or_nil(ns),
         symbol_str when is_binary(symbol_str) <- to_string_or_nil(symbol) do
      Prelude.fetch_export(prelude, "#{ns_str}/#{symbol_str}")
    else
      _ -> :error
    end
  end

  @doc """
  Whether `ns` is a protected namespace for the current analysis pass: a
  reserved host namespace, or one declared by the attached prelude. Used to
  reject writes (`def`/`defn`) into protected namespaces (plan §2).
  """
  @spec protected_namespace?(term()) :: boolean()
  def protected_namespace?(ns) do
    case to_string_or_nil(ns) do
      nil ->
        false

      ns_str ->
        ProtectedNamespaces.reserved?(ns_str) or
          MapSet.member?(ProtectedNamespaces.protected(current()), ns_str)
    end
  end

  @doc """
  Whether `ns` is a namespace DECLARED by the attached prelude (not the
  reserved host namespaces). Used to turn a qualified call into a known
  namespace's unknown export into an actionable discovery hint.
  """
  @spec prelude_namespace?(term()) :: boolean()
  def prelude_namespace?(ns) do
    with %Prelude{} = prelude <- current(),
         ns_str when is_binary(ns_str) <- to_string_or_nil(ns) do
      ns_str in Prelude.namespaces(prelude)
    else
      _ -> false
    end
  end

  defp to_string_or_nil(value) when is_binary(value), do: value

  defp to_string_or_nil(value) when is_atom(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp to_string_or_nil(_), do: nil
end
