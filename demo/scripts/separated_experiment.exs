# Separated Coevolution: Tester Escalation Experiment
#
# Key question: does the arms race escalate or plateau?
# Tracks solver pass rate over time to detect stalling.
#
# Usage:
#   cd demo && mix run scripts/separated_experiment.exs
#   cd demo && mix run scripts/separated_experiment.exs -- --gens 200 --len 50

alias PtcRunner.Folding.SeparatedCoevolution

{opts, _} =
  System.argv()
  |> OptionParser.parse!(strict: [
    gens: :integer, solver: :integer, tester: :integer, oracle: :integer,
    len: :integer, tester_len: :integer, samples: :integer
  ])

gens = Keyword.get(opts, :gens, 200)
solver_pop = Keyword.get(opts, :solver, 30)
tester_pop = Keyword.get(opts, :tester, 30)
oracle_pop = Keyword.get(opts, :oracle, 30)
len = Keyword.get(opts, :len, 50)
tester_len = Keyword.get(opts, :tester_len, len)
samples = Keyword.get(opts, :samples, 15)

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
IO.puts("║  Tester Escalation Experiment (#{gens} generations)              ║")
IO.puts("╚══════════════════════════════════════════════════════════════╝")
IO.puts("")

result = SeparatedCoevolution.run(contexts,
  generations: gens,
  solver_pop: solver_pop,
  tester_pop: tester_pop,
  oracle_pop: oracle_pop,
  genotype_length: len,
  tester_genotype_length: tester_len,
  samples: samples
)

# === Solver pass rate over time (the key metric) ===
IO.puts("\n╔══════════════════════════════════════════════════════════════╗")
IO.puts("║  Solver Avg Fitness Over Time (lower = testers winning)    ║")
IO.puts("╚══════════════════════════════════════════════════════════════╝")

for g <- result.history do
  bar_len = round(g.solver_avg * 40)
  bar = String.duplicate("█", bar_len) <> String.duplicate("░", 40 - bar_len)
  IO.puts("Gen #{String.pad_leading(to_string(g.generation), 3)}: #{bar} #{Float.round(g.solver_avg, 3)}")
end

# === Tester diversity over time ===
IO.puts("\n╔══════════════════════════════════════════════════════════════╗")
IO.puts("║  Tester Diversity Over Time                                ║")
IO.puts("╚══════════════════════════════════════════════════════════════╝")

for snap <- result.snapshots do
  tester_sources = snap.testers |> Enum.filter(& &1.valid) |> Enum.map(& &1.source) |> Enum.uniq()
  IO.puts("Gen #{String.pad_leading(to_string(snap.generation), 3)}: #{length(tester_sources)} unique tester strategies")
  for s <- Enum.take(tester_sources, 5) do
    IO.puts("    #{s}")
  end
end

# === Final diagnostics ===
IO.puts("\n╔══════════════════════════════════════════════════════════════╗")
IO.puts("║  Final State Diagnostics                                   ║")
IO.puts("╚══════════════════════════════════════════════════════════════╝")

diag = SeparatedCoevolution.diagnose(result, contexts)

pass_rates = Enum.map(diag.tester_diagnostics, & &1.solver_pass_rate)
avg_pass = if pass_rates == [], do: 0.0, else: Enum.sum(pass_rates) / length(pass_rates)
discriminating = Enum.count(pass_rates, fn r -> r >= 0.3 and r <= 0.7 end)

IO.puts("\nAvg solver pass rate: #{Float.round(avg_pass * 100, 1)}%")
IO.puts("Discriminating testers (30-70%): #{discriminating}/#{length(pass_rates)}")

IO.puts("\nTester strategies:")
unique_sources = diag.tester_diagnostics |> Enum.map(& &1.source) |> Enum.uniq() |> Enum.sort()
for s <- unique_sources do
  count = Enum.count(diag.tester_diagnostics, &(&1.source == s))
  td = Enum.find(diag.tester_diagnostics, &(&1.source == s))
  IO.puts("  [#{count}x] pass=#{Float.round(td.solver_pass_rate * 100, 1)}% | #{s}")
end

has_filter = Enum.any?(unique_sources, &String.contains?(&1, "filter"))
has_map = Enum.any?(unique_sources, &String.contains?(&1, "map"))
has_if = Enum.any?(unique_sources, &String.contains?(&1, "if"))
IO.puts("\nComplex ops: filter=#{has_filter} map=#{has_map} if=#{has_if}")

IO.puts("\nSolver strategies:")
for {source, count} <- Enum.sort_by(diag.solver_phenotypes, fn {_, c} -> -c end) |> Enum.take(8) do
  IO.puts("  [#{count}x] #{source}")
end

IO.puts("\nOracle strategies:")
for {source, count} <- Enum.sort_by(diag.oracle_phenotypes, fn {_, c} -> -c end) |> Enum.take(5) do
  IO.puts("  [#{count}x] #{source}")
end

# === Trend analysis ===
IO.puts("\n╔══════════════════════════════════════════════════════════════╗")
IO.puts("║  Trend Analysis                                            ║")
IO.puts("╚══════════════════════════════════════════════════════════════╝")

# Compare first half vs second half solver fitness
half = div(gens, 2)
first_half = Enum.filter(result.history, fn g -> g.generation > 10 and g.generation <= half end)
second_half = Enum.filter(result.history, fn g -> g.generation > half end)

first_avg = if first_half == [], do: 0.0, else: Enum.sum(Enum.map(first_half, & &1.solver_avg)) / length(first_half)
second_avg = if second_half == [], do: 0.0, else: Enum.sum(Enum.map(second_half, & &1.solver_avg)) / length(second_half)

IO.puts("Solver avg fitness gen 11-#{half}: #{Float.round(first_avg, 3)}")
IO.puts("Solver avg fitness gen #{half+1}-#{gens}: #{Float.round(second_avg, 3)}")
IO.puts("Delta: #{Float.round(second_avg - first_avg, 3)}")

if abs(second_avg - first_avg) < 0.03 do
  IO.puts("→ PLATEAU: Arms race has stalled. Tester pressure maxed out.")
else
  if second_avg < first_avg do
    IO.puts("→ ESCALATING: Testers still gaining ground. Arms race active.")
  else
    IO.puts("→ SOLVERS WINNING: Solvers adapting faster than testers innovate.")
  end
end
