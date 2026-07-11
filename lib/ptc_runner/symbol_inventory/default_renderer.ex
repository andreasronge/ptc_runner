defmodule PtcRunner.SymbolInventory.DefaultRenderer do
  @moduledoc "Default compact renderer for sanitized symbol inventory facts."

  @id "default_v1"
  @cap 80
  @name_width 30

  @spec id() :: String.t()
  def id, do: @id

  @spec render([map()], keyword()) :: {String.t() | nil, map()}
  def render(facts, opts \\ []) when is_list(facts) do
    cap = Keyword.get(opts, :cap, @cap)
    pre_omitted = Keyword.get(opts, :omitted_count, 0)
    sorted = Enum.sort_by(facts, fn fact -> {to_string(fact[:source]), fact[:ref]} end)
    shown = Enum.take(sorted, cap)
    omitted = max(length(sorted) - length(shown), 0) + pre_omitted

    text =
      case shown do
        [] ->
          nil

        _ ->
          lines = Enum.map(shown, &line/1)
          omitted_line = if omitted > 0, do: [";; +#{omitted} more symbols omitted"], else: []

          ([
             ";; === available symbols ===",
             "Use value symbols directly, e.g. data/items. Call only function symbols, e.g. (tool/name {:key value}) or (ns/fn arg)."
           ] ++ lines ++ omitted_line)
          |> Enum.join("\n")
      end

    {text,
     %{
       "renderer_id" => @id,
       "fact_count" => length(sorted),
       "rendered_count" => length(shown),
       "omitted_count" => omitted,
       "source_counts" => source_counts(sorted)
     }}
  end

  defp line(fact) do
    label =
      case fact[:kind] do
        :function -> function_label(fact)
        _ -> fact[:ref]
      end

    detail =
      fact
      |> details()
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(", ")

    doc = fact[:doc]
    suffix = if doc in [nil, ""], do: "", else: " - #{doc}"

    "#{String.pad_trailing(label, @name_width)} ; #{detail}#{suffix}"
  end

  defp function_label(%{ref: ref, params: params}) when is_list(params) and params != [] do
    "#{ref} [#{Enum.join(params, " ")}]"
  end

  defp function_label(%{ref: ref}), do: "#{ref} []"

  defp details(%{kind: :function} = fact) do
    ["function", fact[:signature], effect(fact[:effect]), "use: #{fact[:usage]}"]
  end

  defp details(%{kind: :value} = fact) do
    [
      "value #{fact[:type]}",
      sample(fact),
      "use: #{fact[:usage]}"
    ]
  end

  defp details(fact), do: ["#{fact[:kind]}", "use: #{fact[:usage]}"]

  defp sample(%{sample: sample}), do: "sample: #{sample}"
  defp sample(_fact), do: nil

  defp effect(nil), do: nil
  defp effect(effect), do: "[#{effect}]"

  defp source_counts(facts) do
    facts
    |> Enum.frequencies_by(&to_string(&1[:source]))
    |> Enum.sort_by(fn {source, _count} -> source end)
    |> Map.new()
  end
end
