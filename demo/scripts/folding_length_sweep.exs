# Folding Representation Measurement: Genotype Length Sweep
#
# Runs coevolution at different genotype lengths and measures:
# - Neutral mutation rate (phenotype + behavioral levels)
# - Crossover preservation (behavior + complexity)
# - Bond count distribution
# - Phenotype diversity
#
# Usage:
#   cd demo && mix run scripts/folding_length_sweep.exs
#   cd demo && mix run scripts/folding_length_sweep.exs -- --lengths 10,20,50 --generations 30

alias PtcRunner.Folding.{Alphabet, Coevolution, Individual, Metrics}

defmodule SweepHelpers do
  def print_report(report) do
    nm = report.neutral_mutation
    xo = report.crossover
    cx = report.complexity

    IO.puts("  Neutral mutation: phenotype=#{pct(nm.phenotype)} behavioral=#{pct(nm.behavioral)}")

    IO.puts(
      "  Crossover: valid=#{pct(xo.valid_rate)} behavior_preserved=#{pct(xo.behavior_preserved)}"
    )

    IO.puts(
      "    complexity_change=#{Float.round(xo.complexity_change, 2)} increased=#{pct(xo.complexity_increased)} decreased=#{pct(xo.complexity_decreased)}"
    )

    IO.puts(
      "  Bonds: avg=#{Float.round(cx.bond_counts.avg, 2)} max=#{cx.bond_counts.max} dist=#{inspect(cx.bond_counts.distribution)}"
    )

    IO.puts(
      "  Diversity: #{cx.unique_phenotypes} unique phenotypes, avg_size=#{Float.round(cx.avg_program_size, 1)}"
    )
  end

  def pct(f), do: "#{Float.round(f * 100, 1)}%"
end

# Parse CLI args
{opts, _} =
  System.argv()
  |> OptionParser.parse!(
    strict: [
      lengths: :string,
      generations: :integer,
      population_size: :integer,
      n_mutations: :integer,
      n_crossovers: :integer
    ]
  )

lengths =
  case Keyword.get(opts, :lengths) do
    nil -> [10, 20, 30, 50]
    s -> s |> String.split(",") |> Enum.map(&String.to_integer/1)
  end

generations = Keyword.get(opts, :generations, 20)
population_size = Keyword.get(opts, :population_size, 40)
n_mutations = Keyword.get(opts, :n_mutations, 50)
n_crossovers = Keyword.get(opts, :n_crossovers, 100)

# Context variations
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
IO.puts("║  Folding Representation: Genotype Length Sweep              ║")
IO.puts("╚══════════════════════════════════════════════════════════════╝")
IO.puts("")
IO.puts("Lengths: #{inspect(lengths)}")
IO.puts("Generations: #{generations}, Population: #{population_size}")
IO.puts("Mutations/individual: #{n_mutations}, Crossovers: #{n_crossovers}")
IO.puts("Contexts: #{length(contexts)}")
IO.puts("")

# Run sweep
results =
  Enum.map(lengths, fn len ->
    IO.puts("━━━ Length #{len} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    # Baseline: random population before evolution
    random_pop =
      Enum.map(1..population_size, fn _ ->
        Individual.from_genotype(Alphabet.random_genotype(len))
      end)

    baseline =
      Metrics.full_report(random_pop, contexts,
        n_mutations: n_mutations,
        n_crossovers: n_crossovers
      )

    IO.puts("\nBaseline (random, pre-evolution):")
    SweepHelpers.print_report(baseline)

    # Run coevolution
    coevo_result =
      Coevolution.run(contexts,
        generations: generations,
        population_size: population_size,
        genotype_length: len
      )

    # Measure after evolution
    evolved =
      Metrics.full_report(coevo_result.population, contexts,
        n_mutations: n_mutations,
        n_crossovers: n_crossovers
      )

    IO.puts("\nEvolved (post-coevolution):")
    SweepHelpers.print_report(evolved)
    IO.puts("")

    %{length: len, baseline: baseline, evolved: evolved}
  end)

# Summary table
IO.puts("")
IO.puts("╔═════════════════════════════════════════════════════════════════════════════╗")
IO.puts("║                              Summary Table                                ║")
IO.puts("╠═════╤══════════╤══════════╤═══════════╤══════════╤══════════╤══════╤═══════╣")
IO.puts("║ Len │ NeutPhen │ NeutBehv │ XoverBehv │ AvgBonds │ MaxBonds │ Uniq │ Phase ║")
IO.puts("╠═════╪══════════╪══════════╪═══════════╪══════════╪══════════╪══════╪═══════╣")

for r <- results do
  for {label, data} <- [{"base", r.baseline}, {"evol", r.evolved}] do
    np = data.neutral_mutation.phenotype * 100 |> Float.round(1)
    nb = data.neutral_mutation.behavioral * 100 |> Float.round(1)
    xb = data.crossover.behavior_preserved * 100 |> Float.round(1)
    ab = data.complexity.bond_counts.avg |> Float.round(2)
    mb = data.complexity.bond_counts.max
    uq = data.complexity.unique_phenotypes

    IO.puts(
      "║ #{String.pad_leading(to_string(r.length), 3)} │ " <>
        "#{String.pad_leading(to_string(np), 6)}% │ " <>
        "#{String.pad_leading(to_string(nb), 6)}% │ " <>
        "#{String.pad_leading(to_string(xb), 7)}% │ " <>
        "#{String.pad_leading(to_string(ab), 8)} │ " <>
        "#{String.pad_leading(to_string(mb), 8)} │ " <>
        "#{String.pad_leading(to_string(uq), 4)} │ #{label}  ║"
    )
  end

  IO.puts("╠═════╪══════════╪══════════╪═══════════╪══════════╪══════════╪══════╪═══════╣")
end

IO.puts("╚═════╧══════════╧══════════╧═══════════╧══════════╧══════════╧══════╧═══════╝")
