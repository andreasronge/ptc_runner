defmodule PtcRunner.Lisp.Prelude.PromptInventory do
  @moduledoc """
  Deterministic, bounded prompt-inventory renderer for a compiled prelude
  (Capability Prelude V1, plan §9).

  The renderer is fed by the SAME `%PtcRunner.Lisp.Prelude.Export{}` records the
  analyzer, evaluator, and discovery forms consult — there is no separate
  prompt/discovery registry. It produces a compact, domain-blind-at-the-core
  block that a deployment-specific prelude fills with its own namespace and
  export names. The block is inserted into the SubAgent system prompt through
  dynamic context assembly, NOT by editing static core prompt templates.

  ## What it renders

    * a per-namespace summary (namespace name + docstring) for namespaces that
      have at least one `:prompt`-visible export;
    * for each such namespace, up to `per_namespace_cap/0` prompt-visible
      exports, each with its signature, short doc, and — only for an inferred
      `:read`/`:write` backing — an effect hint (`:unknown` is omitted as noise,
      but stays available via `(meta ...)` / `(ns-publics ...)`);
    * a "more via `(ns-publics 'ns)`" line when a namespace has more
      prompt-visible exports than the cap;
    * a discovery hint noting that additional `:discoverable` exports (omitted
      from the inventory by design) can be found through `doc`/`dir`/`apropos`/
      `ns-publics`;
    * a compact existing-ledger summary (`Tool calls made` / `Tool call
      errors`) when ledger data is supplied.

  ## Determinism + bounds

  Output is fully determined by the export records and the supplied ledger
  counts: namespaces and exports are sorted, and per-namespace export rendering
  is capped at `per_namespace_cap/0`. `render/2` returns `nil` when there is no
  prelude or no `:prompt`-visible export, so callers can filter the section out
  of prompt assembly.
  """

  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Export

  # Per-namespace cap on the number of prompt-visible exports rendered in
  # detail. Pinned in `prompt_inventory_test.exs`. The remaining exports are
  # summarized with a `(ns-publics 'ns)` discovery hint rather than dropped.
  @per_namespace_cap 5

  @doc "The per-namespace cap on rendered prompt-visible exports."
  @spec per_namespace_cap() :: pos_integer()
  def per_namespace_cap, do: @per_namespace_cap

  @typedoc """
  Ledger summary input. Either a precomputed `%{tool_calls: n, tool_errors: m}`
  map or the raw `tool_calls` list (records carrying an `:error` field that is
  `nil` on success), from which counts are derived.
  """
  @type ledger :: %{tool_calls: non_neg_integer(), tool_errors: non_neg_integer()} | [map()]

  @doc """
  Renders the prompt inventory for `prelude`.

  ## Options

    * `:ledger` — a `%{tool_calls: n, tool_errors: m}` map or a raw `tool_calls`
      list; when present, a compact ledger summary is appended.

  Returns the rendered block string, or `nil` when there is no prelude or no
  `:prompt`-visible export to show.
  """
  @spec render(Prelude.t() | nil, keyword()) :: String.t() | nil
  def render(prelude, opts \\ [])

  def render(nil, _opts), do: nil

  def render(%Prelude{} = prelude, opts) do
    prompt_exports = Prelude.prompt_exports(prelude)

    if prompt_exports == [] do
      nil
    else
      ledger_summary = ledger_lines(Keyword.get(opts, :ledger))

      namespace_blocks =
        prompt_exports
        |> Enum.group_by(& &1.namespace)
        |> Enum.sort_by(fn {namespace, _} -> namespace end)
        |> Enum.map(fn {namespace, exports} ->
          namespace_block(namespace, exports, namespace_doc(prelude, namespace))
        end)

      [
        ";; === prelude capabilities ===",
        "Curated, deployment-defined APIs. Call them as `(ns/name ...)`.",
        Enum.join(namespace_blocks, "\n\n"),
        discovery_hint(),
        ledger_summary
      ]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join("\n\n")
    end
  end

  # ------------------------------------------------------------------
  # Namespace + export rendering
  # ------------------------------------------------------------------

  defp namespace_block(namespace, exports, doc) do
    sorted = Enum.sort_by(exports, & &1.symbol)
    shown = Enum.take(sorted, @per_namespace_cap)
    omitted = length(sorted) - length(shown)

    header =
      case doc do
        nil -> ";; #{namespace}"
        "" -> ";; #{namespace}"
        text -> ";; #{namespace} — #{compact(text)}"
      end

    export_lines = Enum.map(shown, &export_line(&1))

    more_line =
      if omitted > 0 do
        ["  ;; +#{omitted} more — discover via (ns-publics '#{namespace})"]
      else
        []
      end

    Enum.join([header | export_lines] ++ more_line, "\n")
  end

  # `crm/get-user (get-user arg1) [read] — Return a CRM user by id.`
  #
  # The `[effect]` hint is rendered only for an inferred `:read`/`:write`
  # backing. `:unknown` carries no usable signal — it is the fallback for both a
  # pure local export AND a dynamic `tool/call` whose effect could not be
  # inferred — so rendering it would either over-warn (on a pure helper) or
  # under-warn (on a dynamic write). It is omitted to keep the inventory compact
  # and honest; the effect stays available via `(meta ...)` / `(ns-publics ...)`.
  defp export_line(%Export{} = export) do
    base = "  #{export.ref} #{signature(export)}#{effect_hint(export.effect)}"

    case compact(export.doc) do
      "" -> base
      doc -> base <> " — " <> doc
    end
  end

  defp effect_hint(:unknown), do: ""
  defp effect_hint(effect), do: " [#{effect}]"

  defp signature(%Export{symbol: symbol, arity: :variadic}), do: "(#{symbol} & args)"

  defp signature(%Export{symbol: symbol, arity: arity}) when is_integer(arity) do
    args = Enum.map_join(1..arity//1, " ", fn i -> "arg#{i}" end)
    if args == "", do: "(#{symbol})", else: "(#{symbol} #{args})"
  end

  defp namespace_doc(%Prelude{metadata: metadata}, namespace) do
    metadata
    |> Map.get(:namespaces, %{})
    |> Map.get(namespace, %{})
    |> Map.get(:doc)
  end

  # ------------------------------------------------------------------
  # Discovery hint + ledger summary
  # ------------------------------------------------------------------

  defp discovery_hint do
    ";; More prelude exports may be available than shown here. " <>
      "Use (ns-publics 'ns), (dir 'ns), (doc 'ns/name), or (apropos \"...\") to discover them."
  end

  defp ledger_lines(nil), do: nil

  defp ledger_lines(ledger) do
    {calls, errors} = ledger_counts(ledger)

    Enum.join(
      [
        ";; === execution state ===",
        ";; Tool calls made: #{calls}",
        ";; Tool call errors: #{errors}"
      ],
      "\n"
    )
  end

  defp ledger_counts(%{} = ledger) when not is_struct(ledger) do
    calls = Map.get(ledger, :tool_calls) || Map.get(ledger, "tool_calls") || 0
    errors = Map.get(ledger, :tool_errors) || Map.get(ledger, "tool_errors") || 0
    {calls, errors}
  end

  defp ledger_counts(tool_calls) when is_list(tool_calls) do
    errors = Enum.count(tool_calls, fn call -> Map.get(call, :error) not in [nil, false] end)
    {length(tool_calls), errors}
  end

  defp ledger_counts(_), do: {0, 0}

  # ------------------------------------------------------------------
  # Text helpers
  # ------------------------------------------------------------------

  defp compact(nil), do: ""

  defp compact(text) when is_binary(text) do
    text
    |> String.split()
    |> Enum.join(" ")
  end
end
