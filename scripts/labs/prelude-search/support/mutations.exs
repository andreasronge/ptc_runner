defmodule PtcRunner.Labs.PreludeSearch.Mutations do
  @moduledoc false

  @mutations %{
    "intervals" => [
      {:comparator_flip, "touches?", "(<= (get next \"start\")", "(< (get next \"start\")"},
      {:boundary_off_by_one, "touches?", "(+ (get current \"end\") tolerance)",
       "(+ (get current \"end\") (- tolerance 1))"},
      {:dropped_edge_case_clause, "ordered", "{\"start\" finish \"end\" start}",
       "{\"start\" start \"end\" finish}"},
      {:swapped_map_key, "extend", "{\"start\" (get current \"start\")\n   \"end\"",
       "{\"end\" (get current \"start\")\n   \"start\""},
      {:wrong_private_default, "merge-with-tolerance", "(get input \"tolerance\" 0)",
       "(get input \"tolerance\" 1)"}
    ],
    "normaliser" => [
      {:comparator_flip, "canonical-token", "(< (count normal) minimum)",
       "(<= (count normal) minimum)"},
      {:boundary_off_by_one, "canonical-token", "minimum) nil normal",
       "(+ minimum 1)) nil normal"},
      {:dropped_edge_case_clause, "finish-token", "(if (= current \"\")", "(if false"},
      {:swapped_map_key, "normalise", "{\"tokens\" (vec normal)\n             \"text\"",
       "{\"text\" (vec normal)\n             \"tokens\""},
      {:wrong_private_default, "normalise", "(get input \"minimum_length\" 1)",
       "(get input \"minimum_length\" 2)"}
    ],
    "reconciliation" => [
      {:comparator_flip, "classify", "(= left-amount right-amount)",
       "(not= left-amount right-amount)"},
      {:boundary_off_by_one, "ledger-map", "(get entry \"amount\" 0)",
       "(+ 1 (get entry \"amount\" 0))"},
      {:dropped_edge_case_clause, "classify", "(= right-amount missing)",
       "(and false (= right-amount missing))"},
      {:swapped_map_key, "classify", "\"left_amount\" left-amount \"right_amount\" right-amount",
       "\"right_amount\" left-amount \"left_amount\" right-amount"},
      {:wrong_private_default, "ledger-map", "(get entry \"amount\" 0)",
       "(get entry \"amount\" 1)"}
    ]
  }

  def apply(source, subject, seed) when is_binary(source) and is_binary(subject) do
    mutations = Map.fetch!(@mutations, subject)

    {operator, function, before, after_text} =
      Enum.at(mutations, Integer.mod(seed, length(mutations)))

    if count(source, before) == 1 do
      mutated = String.replace(source, before, after_text)

      {mutated,
       %{
         "subject" => subject,
         "function" => function,
         "form" => after_text,
         "operator" => Atom.to_string(operator)
       }}
    else
      raise "mutation anchor is not unique for #{subject}/#{function}"
    end
  end

  defp count(source, text), do: source |> String.split(text) |> length() |> Kernel.-(1)
end
