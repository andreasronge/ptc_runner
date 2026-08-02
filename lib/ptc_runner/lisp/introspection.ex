defmodule PtcRunner.Lisp.Introspection do
  @moduledoc """
  Read-only introspection over the attached prelude's public exports.

  Backs the `dir`, `apropos`, `doc`, and `export-meta` builtins. The same
  answers are produced in the REPL, in workflow and mission source, and inside
  a prelude export reading another prelude's documentation — there is no
  REPL-only path.

  ## What is visible

  Only public export records (`%PtcRunner.Lisp.Prelude.Export{}`), which cover
  both `:prompt` and `:discoverable` visibility. Private `defn-` helpers have no
  export record and are unreachable by qualified call, so they are absent from
  every answer here; `Prelude.form_graph` does carry them and is deliberately
  not the backing store.

  Namespaces are derived from the visible export set rather than from
  `Prelude.namespaces/1`, so a namespace holding only private helpers does not
  appear in `namespaces/2`.

  ## Visibility filter

  Callers pass a predicate over export records rather than any runtime context,
  keeping this module pure. `PtcRunner.Lisp.Eval.Apply` builds it from the
  evaluation context so that what a program can discover matches what it can
  call: `PtcRunner.Lisp.Eval.Context.prelude_ref_visible?/2` supplies the
  `strict_transitive_calls` half, and the run's `prelude_export_mask` supplies
  the discovery half. A narrowed session grant needs no filter here — it hands
  the run a prelude whose `exports` list is already the narrow set.

  ## Misses

  An unknown ref, a malformed ref, or an absent prelude is a miss, not a
  failure: `export_meta/3` answers `nil`, `render_doc/3` answers a "no
  documentation" line, and the listing functions answer `[]`. Asking about
  something that does not exist is a normal part of exploring.
  """

  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Export

  @type visible :: (Export.t() -> boolean())

  @doc "Sorted namespace names holding at least one visible export."
  @spec namespaces(Prelude.t() | nil, visible()) :: [String.t()]
  def namespaces(prelude, visible) do
    prelude
    |> visible_exports(visible)
    |> Enum.map(& &1.namespace)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Sorted visible export refs declared by `namespace`."
  @spec dir(Prelude.t() | nil, String.t(), visible()) :: [String.t()]
  def dir(prelude, namespace, visible) when is_binary(namespace) do
    prelude
    |> visible_exports(visible)
    |> Enum.filter(&(&1.namespace == namespace))
    |> Enum.map(& &1.ref)
    |> Enum.sort()
  end

  @doc """
  Sorted visible export refs whose ref or docstring contains `query`.

  Matching is case-insensitive substring. An export with no docstring is
  matched on its ref alone. A blank query matches nothing rather than
  everything — an empty search is not a request for the whole surface.
  """
  @spec apropos(Prelude.t() | nil, String.t(), visible()) :: [String.t()]
  def apropos(prelude, query, visible) when is_binary(query) do
    needle = String.downcase(String.trim(query))

    if needle == "" do
      []
    else
      prelude
      |> visible_exports(visible)
      |> Enum.filter(&matches?(&1, needle))
      |> Enum.map(& &1.ref)
      |> Enum.sort()
    end
  end

  @doc """
  Structured metadata for one visible export, or `nil` on a miss.

  Reports the calling contract: identity, arity, parameter names, call form,
  docstring, visibility, effect, and any declared signature or type. Capability
  wiring (`tool_refs`, `requires`) and compiler internals (`min_arity`,
  `parsed_signature`, `parsed_type`) stay out.
  """
  @spec export_meta(Prelude.t() | nil, String.t(), visible()) :: map() | nil
  def export_meta(prelude, ref, visible) when is_binary(ref) do
    case fetch(prelude, ref, visible) do
      nil -> nil
      export -> meta_map(export)
    end
  end

  @doc """
  Rendered human-readable documentation for one visible export.

  Callers print this rather than returning it, so documentation text is charged
  to the print budget instead of the result channel.
  """
  @spec render_doc(Prelude.t() | nil, String.t(), visible()) :: String.t()
  def render_doc(prelude, ref, visible) when is_binary(ref) do
    case fetch(prelude, ref, visible) do
      nil -> ~s(No documentation found for "#{ref}".)
      export -> render_export(export)
    end
  end

  # ============================================================
  # Internals
  # ============================================================

  defp visible_exports(%Prelude{exports: exports}, visible) when is_function(visible, 1),
    do: Enum.filter(exports, visible)

  defp visible_exports(_prelude, _visible), do: []

  defp fetch(prelude, ref, visible) do
    prelude
    |> visible_exports(visible)
    |> Enum.find(&(&1.ref == ref))
  end

  defp matches?(%Export{ref: ref, doc: doc}, needle) do
    String.contains?(String.downcase(ref), needle) or
      (is_binary(doc) and String.contains?(String.downcase(doc), needle))
  end

  defp meta_map(%Export{kind: :constant} = export) do
    base = %{
      ref: export.ref,
      namespace: export.namespace,
      symbol: export.symbol,
      kind: :constant,
      call: Export.call_form(export),
      doc: export.doc,
      visibility: export.visibility,
      effect: export.effect
    }

    maybe_put(base, :type, export.type)
  end

  defp meta_map(%Export{} = export) do
    base = %{
      ref: export.ref,
      namespace: export.namespace,
      symbol: export.symbol,
      kind: export.kind,
      arity: export.arity,
      params: export.params,
      call: Export.call_form(export),
      doc: export.doc,
      visibility: export.visibility,
      effect: export.effect
    }

    maybe_put(base, :signature, export.signature)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp render_export(%Export{} = export) do
    [
      export.ref,
      Export.call_form(export),
      contract_line(export),
      "  effect: #{export.effect}",
      doc_block(export)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp contract_line(%Export{kind: :constant, type: type}) when is_binary(type), do: "  #{type}"
  defp contract_line(%Export{kind: :constant}), do: nil

  defp contract_line(%Export{signature: signature}) when is_binary(signature),
    do: "  #{signature}"

  defp contract_line(%Export{}), do: nil

  defp doc_block(%Export{doc: doc}) when is_binary(doc), do: "\n#{indent(doc)}"
  defp doc_block(%Export{}), do: nil

  defp indent(doc) do
    doc
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> "  " <> line
    end)
  end
end
