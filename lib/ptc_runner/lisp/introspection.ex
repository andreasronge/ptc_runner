defmodule PtcRunner.Lisp.Introspection do
  @moduledoc """
  Read-only introspection over the callable PTC-Lisp surface.

  Backs the `dir`, `apropos`, `doc`, and `export-meta` builtins. `dir` and
  `export-meta` describe the attached prelude. `apropos` and `doc` additionally
  expose fixed built-ins and the bounded Java surface from
  `PtcRunner.Lisp.Registry`. The same
  answers are produced in the REPL, in workflow and mission source, and inside
  a prelude export reading another prelude's documentation — there is no
  REPL-only path.

  ## Attached prelude visibility

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

  ## How the reported effect is bounded

  `Export.effect` joins an export's own declaration with those of the prelude
  helpers it calls, but not with the effects of the *capabilities* it reaches.
  The authoritative value is the mission-resolved effect
  `PtcRunner.Kernel.MissionInventory` publishes, which adds that last join: a
  wrapper declaring `:read` over a capability installed as `:write` resolves to
  `:write`. Producing it needs the mission's capability set, which this layer
  does not have.

  Reporting the raw declaration would therefore let a program read `:read` for
  an operation the inventory calls `:write` — the direction that invites
  repeating an irreversible call. Omitting the effect is no better: the
  inventory covers only `Prelude.prompt_exports/1`, so a `:discoverable` export
  is callable with no effect stated anywhere.

  So the reported effect is deliberately weakened rather than dropped. An export
  that reaches no capability is reported as declared. An export that does reach
  one is reported as `:write` if anything in its chain declares `:write`, and
  `:unknown` otherwise. It can still fall short of a `:write` the inventory
  resolves, but it never calls something `:read` that touches a capability, so
  no answer here presents an unresolved effect as safe.

  ## Misses

  An exact attached export occupies its ref before its visibility filter is
  applied. A hidden attached ref therefore cannot fall through to registry
  documentation for the same spelling. Otherwise `doc` falls back to the
  registry, and `apropos` merges visible attached refs with canonical registry
  names. An unknown or malformed ref is a miss, not a failure.
  """

  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Export
  alias PtcRunner.Lisp.Registry

  @type visible :: (Export.t() -> boolean())
  @type operation :: :dir | :apropos | :doc | :export_meta

  @operations [:dir, :apropos, :doc, :export_meta]
  @arities %{dir: [0, 1], apropos: [1], doc: [1], export_meta: [1]}
  @names %{dir: "dir", apropos: "apropos", doc: "doc", export_meta: "export-meta"}

  @doc "The introspection operations bound as `{:special, op}` builtins."
  @spec operations() :: [operation()]
  def operations, do: @operations

  @doc """
  Validates arguments and answers one introspection call.

  Every call path — direct application and higher-order dispatch — routes
  through here, so argument faults and answers cannot differ between them.
  `doc` answers `{:print, text}` because its text belongs on the print channel
  rather than in the result.
  """
  @spec invoke(operation(), [term()], EvalContext.t()) ::
          {:ok, term()} | {:print, String.t()} | {:error, term()}
  def invoke(:dir, [], %EvalContext{} = context),
    do: {:ok, namespaces(context.prelude, filter(context))}

  def invoke(:dir, [namespace], %EvalContext{} = context) when is_binary(namespace),
    do: {:ok, dir(context.prelude, namespace, filter(context))}

  def invoke(:apropos, [query], %EvalContext{} = context) when is_binary(query),
    do: {:ok, apropos(context.prelude, query, filter(context))}

  def invoke(:export_meta, [ref], %EvalContext{} = context) when is_binary(ref),
    do: {:ok, export_meta(context.prelude, ref, filter(context))}

  def invoke(:doc, [ref], %EvalContext{} = context) when is_binary(ref),
    do: {:print, render_doc(context.prelude, ref, filter(context))}

  def invoke(op, args, %EvalContext{}) when op in @operations do
    name = Map.fetch!(@names, op)
    arities = Map.fetch!(@arities, op)

    if length(args) in arities do
      {:error, {:type_error, "#{name} expects a string reference", args}}
    else
      {:error,
       {:arity_error,
        "#{name} expects #{Enum.join(arities, " or ")} argument(s), got #{length(args)}"}}
    end
  end

  # What a program can discover must equal what it can call. The run's
  # `prelude_export_mask` is the discovery overlay — a namespace absent from it
  # is unrestricted, and a namespace present in it exposes only its listed
  # refs. `prelude_ref_visible?/2` is the same predicate the evaluator's
  # resolution guard applies under `strict_transitive_calls`.
  defp filter(%EvalContext{prelude_export_mask: mask} = context) do
    fn %{ref: ref, namespace: namespace} ->
      mask_visible?(mask, namespace, ref) and EvalContext.prelude_ref_visible?(context, ref)
    end
  end

  defp mask_visible?(nil, _namespace, _ref), do: true

  defp mask_visible?(mask, namespace, ref) when is_map(mask) do
    case Map.fetch(mask, namespace) do
      {:ok, %MapSet{} = refs} -> MapSet.member?(refs, ref)
      {:ok, refs} when is_list(refs) -> ref in refs
      {:ok, _other} -> true
      :error -> true
    end
  end

  defp mask_visible?(_mask, _namespace, _ref), do: true

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
  Sorted visible export refs and canonical registry names matching `query`.

  Matching is a case-insensitive literal substring. Attached exports search
  their ref and docstring; registry entries search their name, signatures,
  description, notes, divergences, and section. A blank query matches nothing
  rather than everything — an empty search is not a request for the whole
  surface.
  """
  @spec apropos(Prelude.t() | nil, String.t(), visible()) :: [String.t()]
  def apropos(prelude, query, visible) when is_binary(query) do
    needle = String.downcase(String.trim(query))

    if needle == "" do
      []
    else
      prelude_matches =
        prelude
        |> visible_exports(visible)
        |> Enum.filter(&matches?(&1, needle))
        |> Enum.map(& &1.ref)

      hidden_registry_names = hidden_registry_names(prelude, visible)

      registry_matches =
        needle
        |> Registry.apropos()
        |> Enum.reject(&MapSet.member?(hidden_registry_names, &1.name))
        |> Enum.map(& &1.name)

      prelude_matches
      |> Kernel.++(registry_matches)
      |> Enum.uniq()
      |> Enum.sort()
    end
  end

  @doc """
  Structured metadata for one visible export, or `nil` on a miss.

  Reports the calling contract: identity, arity, parameter names, call form,
  docstring, visibility, effect, and any declared signature or type. The effect
  is bounded as described in the module documentation. Capability wiring
  (`tool_refs`, `requires`) and compiler internals (`min_arity`,
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
  Rendered human-readable documentation for one visible attached export or
  fixed registry entry.

  Callers print this rather than returning it, so documentation text is charged
  to the print budget instead of the result channel. An attached ref occupies
  its exact spelling before visibility is applied and therefore cannot fall
  through to registry documentation when hidden.
  """
  @spec render_doc(Prelude.t() | nil, String.t(), visible()) :: String.t()
  def render_doc(prelude, ref, visible) when is_binary(ref) do
    case fetch_attached(prelude, ref) do
      %Export{} = export ->
        if visible.(export),
          do: render_export(export),
          else: missing_doc(ref)

      nil ->
        case Registry.doc(ref) do
          nil -> missing_doc(ref)
          entry -> render_registry_entry(entry)
        end
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

  defp fetch_attached(%Prelude{exports: exports}, ref), do: Enum.find(exports, &(&1.ref == ref))
  defp fetch_attached(_prelude, _ref), do: nil

  defp hidden_registry_names(%Prelude{exports: exports}, visible) do
    exports
    |> Enum.reject(visible)
    |> Enum.map(& &1.ref)
    |> MapSet.new()
  end

  defp hidden_registry_names(_prelude, _visible), do: MapSet.new()

  defp missing_doc(ref), do: ~s(No documentation found for "#{ref}".)

  defp render_registry_entry(entry) do
    details =
      [entry.description, entry.notes, entry.divergences]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.map_join("\n", &indent/1)

    (entry.signatures ++ if(details == "", do: [], else: [details]))
    |> Enum.join("\n")
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
      effect: bounded_effect(export)
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
      effect: bounded_effect(export)
    }

    maybe_put(base, :signature, export.signature)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Never present an export that reaches a capability as `:read` — this layer
  # cannot see the capability's installed effect, and a false `:read` is the
  # answer that invites repeating an irreversible call.
  defp bounded_effect(%Export{effect: :write}), do: :write

  defp bounded_effect(%Export{} = export) do
    if reaches_capability?(export), do: :unknown, else: export.effect
  end

  defp reaches_capability?(%Export{tool_refs: tool_refs, requires: requires}) do
    tool_refs != [] or Enum.any?(requires, &String.starts_with?(&1, "tool:"))
  end

  defp render_export(%Export{} = export) do
    [
      export.ref,
      Export.call_form(export),
      contract_line(export),
      "  effect: #{bounded_effect(export)}",
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
