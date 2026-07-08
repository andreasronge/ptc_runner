defmodule PtcRunner.Lisp.Prelude.PromptInventory do
  @moduledoc """
  Compatibility wrapper for rendering compiled-prelude prompt exports through
  the shared sanitized symbol inventory.

  The renderer is fed by the same `%PtcRunner.Lisp.Prelude.Export{}` records the
  analyzer, evaluator, and discovery forms consult. Export `kind` is normalized
  to the inventory vocabulary: `:constant` renders as `:value`, while
  `:function` renders as `:function`. Renderer output intentionally does not
  advertise `(source ...)`; source discovery remains governed by D17.
  """

  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.SymbolInventory

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
     * `:export_mask` — optional `%{namespace => refs}` presentation mask for
       prompt inventory only. Unlisted namespaces remain full surface.

  Returns the rendered block string, or `nil` when there is no prelude or no
  `:prompt`-visible export to show.
  """
  @spec render(Prelude.t() | nil, keyword()) :: String.t() | nil
  def render(prelude, opts \\ [])

  def render(nil, _opts), do: nil

  def render(%Prelude{} = prelude, opts) do
    facts =
      SymbolInventory.project(
        prelude: prelude,
        export_mask: Keyword.get(opts, :export_mask)
      )

    if facts == [] do
      nil
    else
      ledger_summary = ledger_lines(Keyword.get(opts, :ledger))

      {bounded_facts, omitted} =
        per_namespace_cap(facts, Keyword.get(opts, :cap, @per_namespace_cap))

      {:ok, rendered, _meta} =
        SymbolInventory.render(bounded_facts, Keyword.get(opts, :renderer, :default),
          cap: length(bounded_facts),
          omitted_count: omitted
        )

      [
        rendered,
        discovery_hint(),
        ledger_summary
      ]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join("\n\n")
    end
  end

  # ------------------------------------------------------------------
  # Ledger summary
  # ------------------------------------------------------------------

  defp per_namespace_cap(facts, cap) when is_integer(cap) and cap > 0 do
    facts
    |> Enum.group_by(&Map.get(&1, :namespace, ""))
    |> Enum.sort_by(fn {namespace, _facts} -> namespace end)
    |> Enum.map_reduce(0, fn {_namespace, namespace_facts}, omitted ->
      sorted = Enum.sort_by(namespace_facts, & &1.ref)
      shown = Enum.take(sorted, cap)
      {shown, omitted + max(length(sorted) - length(shown), 0)}
    end)
    |> then(fn {groups, omitted} -> {List.flatten(groups), omitted} end)
  end

  defp per_namespace_cap(facts, _cap), do: {facts, 0}

  defp discovery_hint do
    ";; More prelude exports may be discoverable with (ns-publics 'ns), " <>
      "(dir 'ns), (doc 'ns/name), or (apropos \"...\")."
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
end
