# Folding vs Direct Encoding: Matched Comparison
#
# Runs both representations through identical conditions and compares:
# - Neutral mutation rate (phenotype + behavioral)
# - Mutation effect spectrum (neutral/small/large/beneficial/lethal)
# - Crossover preservation
# - Complexity distribution
#
# Usage:
#   cd demo && mix run scripts/folding_vs_direct.exs
#   cd demo && mix run scripts/folding_vs_direct.exs -- --lengths 10,20,50 --n_mutations 100

alias PtcRunner.Folding.{Alphabet, Individual, DirectIndividual, Metrics}

defmodule CompareHelpers do
  def pct(f), do: "#{Float.round(f * 100, 1)}%"

  def print_side_by_side(label, folding_val, direct_val) do
    IO.puts("  #{String.pad_trailing(label, 22)} Folding: #{String.pad_trailing(pct(folding_val), 8)} Direct: #{pct(direct_val)}")
  end
end

# Parse CLI args
{opts, _} =
  System.argv()
  |> OptionParser.parse!(
    strict: [lengths: :string, n_mutations: :integer, n_crossovers: :integer, pop_size: :integer]
  )

lengths =
  case Keyword.get(opts, :lengths) do
    nil -> [10, 20, 30, 50]
    s -> s |> String.split(",") |> Enum.map(&String.to_integer/1)
  end

n_mutations = Keyword.get(opts, :n_mutations, 50)
n_crossovers = Keyword.get(opts, :n_crossovers, 100)
pop_size = Keyword.get(opts, :pop_size, 40)

# 3 context variations
contexts = [
  %{
    "products" => [%{"price" => 100}, %{"price" => 200}],
    "employees" => [%{"name" => "A", "department" => "eng"}],
    "orders" => [%{"amount" => 50}],
    "expenses" => [%{"amount" => 10}, %{"amount" => 20}]
  },
  %{
    "products" => [%{"price" => 100}, %{"price" => 200}, %{"price" => 300}],
    "employees" => [
      %{"name" => "A", "department" => "eng"},
      %{"name" => "B", "department" => "sales"},
      %{"name" => "C", "department" => "eng"}
    ],
    "orders" => [%{"amount" => 50}, %{"amount" => 75}, %{"amount" => 100}],
    "expenses" => [%{"amount" => 10}]
  },
  %{
    "products" => [
      %{"price" => 50},
      %{"price" => 150},
      %{"price" => 250},
      %{"price" => 350},
      %{"price" => 450}
    ],
    "employees" => [
      %{"name" => "X", "department" => "sales"},
      %{"name" => "Y", "department" => "eng"}
    ],
    "orders" => [%{"amount" => 200}, %{"amount" => 300}],
    "expenses" => [%{"amount" => 5}, %{"amount" => 15}, %{"amount" => 25}, %{"amount" => 35}]
  }
]

IO.puts("╔══════════════════════════════════════════════════════════════╗")
IO.puts("║  Folding vs Direct Encoding: Matched Comparison            ║")
IO.puts("╚══════════════════════════════════════════════════════════════╝")
IO.puts("")
IO.puts("Lengths: #{inspect(lengths)}")
IO.puts("Population: #{pop_size}, Mutations: #{n_mutations}, Crossovers: #{n_crossovers}")
IO.puts("Contexts: #{length(contexts)}")
IO.puts("")

metric_opts_f = [n_mutations: n_mutations, n_crossovers: n_crossovers]
metric_opts_d = [n_mutations: n_mutations, n_crossovers: n_crossovers, individual_module: DirectIndividual]

results =
  Enum.map(lengths, fn len ->
    IO.puts("━━━ Length #{len} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    # Same genotypes for both representations
    genotypes = Enum.map(1..pop_size, fn _ -> Alphabet.random_genotype(len) end)

    folding_pop = Enum.map(genotypes, &Individual.from_genotype/1)
    direct_pop = Enum.map(genotypes, &DirectIndividual.from_genotype/1)

    # Neutral mutation
    nf = Metrics.neutral_mutation_rate(folding_pop, contexts, metric_opts_f)
    nd = Metrics.neutral_mutation_rate(direct_pop, contexts, metric_opts_d)

    IO.puts("\n  Neutral Mutation Rate:")
    CompareHelpers.print_side_by_side("Phenotype", nf.phenotype, nd.phenotype)
    CompareHelpers.print_side_by_side("Behavioral", nf.behavioral, nd.behavioral)

    # Mutation spectrum
    sf = Metrics.mutation_spectrum(folding_pop, contexts, metric_opts_f)
    sd = Metrics.mutation_spectrum(direct_pop, contexts, metric_opts_d)

    IO.puts("\n  Mutation Spectrum:")
    CompareHelpers.print_side_by_side("Neutral", sf.neutral, sd.neutral)
    CompareHelpers.print_side_by_side("Small change", sf.small_change, sd.small_change)
    CompareHelpers.print_side_by_side("Large break", sf.large_break, sd.large_break)
    CompareHelpers.print_side_by_side("Beneficial", sf.beneficial, sd.beneficial)
    CompareHelpers.print_side_by_side("Lethal", sf.lethal, sd.lethal)

    # Crossover
    xf = Metrics.crossover_preservation(folding_pop, contexts, metric_opts_f)
    xd = Metrics.crossover_preservation(direct_pop, contexts, metric_opts_d)

    IO.puts("\n  Crossover Preservation:")
    CompareHelpers.print_side_by_side("Valid", xf.valid_rate, xd.valid_rate)
    CompareHelpers.print_side_by_side("Behavior preserved", xf.behavior_preserved, xd.behavior_preserved)

    # Complexity
    cf = Metrics.complexity_distribution(folding_pop)
    cd = Metrics.complexity_distribution(direct_pop)

    IO.puts("\n  Complexity:")
    IO.puts("  #{String.pad_trailing("Avg program size", 22)} Folding: #{String.pad_trailing(to_string(Float.round(cf.avg_program_size, 1)), 8)} Direct: #{Float.round(cd.avg_program_size, 1)}")
    IO.puts("  #{String.pad_trailing("Unique phenotypes", 22)} Folding: #{String.pad_trailing(to_string(cf.unique_phenotypes), 8)} Direct: #{cd.unique_phenotypes}")
    IO.puts("  #{String.pad_trailing("Valid", 22)} Folding: #{String.pad_trailing(to_string(cf.valid_count), 8)} Direct: #{cd.valid_count}")
    IO.puts("")

    %{
      length: len,
      folding: %{neutral: nf, spectrum: sf, crossover: xf, complexity: cf},
      direct: %{neutral: nd, spectrum: sd, crossover: xd, complexity: cd}
    }
  end)

# Summary table
IO.puts("")
IO.puts("╔═══════════════════════════════════════════════════════════════════════════════════════╗")
IO.puts("║                           Summary: Folding vs Direct                                 ║")
IO.puts("╠═════╤═════════╤══════════════╤══════════════╤═══════════╤═══════════╤════════╤════════╣")
IO.puts("║ Len │ Repr    │ Neut(phenot) │ Neut(behav)  │ LargeBreak│ Xover(beh)│ AvgSz  │ Uniq   ║")
IO.puts("╠═════╪═════════╪══════════════╪══════════════╪═══════════╪═══════════╪════════╪════════╣")

for r <- results do
  f = r.folding
  d = r.direct

  for {label, data} <- [{"fold", f}, {"direct", d}] do
    np = data.neutral.phenotype * 100 |> Float.round(1)
    nb = data.neutral.behavioral * 100 |> Float.round(1)
    lb = data.spectrum.large_break * 100 |> Float.round(1)
    xb = data.crossover.behavior_preserved * 100 |> Float.round(1)
    sz = data.complexity.avg_program_size |> Float.round(1)
    uq = data.complexity.unique_phenotypes

    IO.puts(
      "║ #{String.pad_leading(to_string(r.length), 3)} │ " <>
        "#{String.pad_trailing(label, 7)} │ " <>
        "#{String.pad_leading(to_string(np), 10)}% │ " <>
        "#{String.pad_leading(to_string(nb), 10)}% │ " <>
        "#{String.pad_leading(to_string(lb), 7)}% │ " <>
        "#{String.pad_leading(to_string(xb), 7)}% │ " <>
        "#{String.pad_leading(to_string(sz), 6)} │ " <>
        "#{String.pad_leading(to_string(uq), 6)} ║"
    )
  end

  IO.puts("╠═════╪═════════╪══════════════╪══════════════╪═══════════╪═══════════╪════════╪════════╣")
end

IO.puts("╚═════╧═════════╧══════════════╧══════════════╧═══════════╧═══════════╧════════╧════════╝")
