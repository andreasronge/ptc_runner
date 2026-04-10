# Triad Coevolution Experiment: Strict Gating + Per-Role Elitism
#
# Tests whether strict tester gating (test_score=0 without list-of-maps output)
# combined with per-role elitism produces tester breakthrough.
#
# Usage:
#   cd demo && mix run scripts/triad_experiment.exs
#   cd demo && mix run scripts/triad_experiment.exs -- --pop 50 --gens 100 --len 50

alias PtcRunner.Folding.TriadCoevolution

{opts, _} =
  System.argv()
  |> OptionParser.parse!(strict: [pop: :integer, gens: :integer, len: :integer, triples: :integer])

pop = Keyword.get(opts, :pop, 50)
gens = Keyword.get(opts, :gens, 100)
len = Keyword.get(opts, :len, 50)
triples = Keyword.get(opts, :triples, 15)

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
IO.puts("║  Triad Coevolution: Strict Gating + Per-Role Elitism       ║")
IO.puts("╚══════════════════════════════════════════════════════════════╝")
IO.puts("")

result = TriadCoevolution.run(contexts,
  generations: gens,
  population_size: pop,
  genotype_length: len,
  triples_per_individual: triples
)

# Post-run analysis: find tester specialists
IO.puts("\n=== Tester Analysis ===")
testers = Enum.filter(result.population, fn ind ->
  Map.get(ind.metadata, :test_score, 0.0) > 0.0
end)

IO.puts("Individuals with test_score > 0: #{length(testers)}")

for t <- Enum.sort_by(testers, &Map.get(&1.metadata, :test_score, 0.0), :desc) do
  s = Map.get(t.metadata, :solve_score, 0.0)
  ts = Map.get(t.metadata, :test_score, 0.0)
  o = Map.get(t.metadata, :oracle_score, 0.0)
  IO.puts("  test=#{Float.round(ts, 3)} solve=#{Float.round(s, 3)} oracle=#{Float.round(o, 3)} | #{t.source}")
end

# Track when testers first appeared
IO.puts("\n=== Evolution Trajectory ===")
for gen_data <- result.history do
  marker = if gen_data.avg_test > 0.0, do: " ← TESTERS", else: ""
  IO.puts("Gen #{String.pad_leading(to_string(gen_data.generation), 3)}: " <>
    "fit=#{Float.round(gen_data.best_fitness, 3)} " <>
    "solve=#{Float.round(gen_data.avg_solve, 3)} " <>
    "test=#{Float.round(gen_data.avg_test, 3)} " <>
    "oracle=#{Float.round(gen_data.avg_oracle, 3)}" <>
    marker)
end
