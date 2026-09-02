# Heap baseline for the PtcRunner embedding units (the nine embedding use
# cases of the retired memory-observability plan).
#
# Run:  mix run bench/heap_baseline.exs             # measure and report
#       mix run bench/heap_baseline.exs --write     # re-record the baseline
#
# The measurement, comparison, and baseline file all live in
# `Mix.Tasks.Bench.Heap`, because `mix bench.check` prints the same table and
# copying either half here would let the two drift. This script is the
# `mix run` entry point the other bench scripts are reached through; the task
# is the gating one.
#
# Re-recording is a deliberate act. A heap baseline invites the reflexive bump
# the moment it goes red, which is how a gate stops meaning anything. Any bump
# needs a written cause in the commit body, same as the reductions baseline.

case System.argv() do
  [] ->
    Mix.Tasks.Bench.Heap.report()

  ["--write"] ->
    Mix.Task.run("bench.heap", ["--write-baseline"])

  other ->
    Mix.raise("usage: mix run bench/heap_baseline.exs [--write]; got #{Enum.join(other, " ")}")
end
