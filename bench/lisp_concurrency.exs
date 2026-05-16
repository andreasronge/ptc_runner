# Concurrency diagnostic for PtcRunner.Lisp — measures how aggregate
# throughput of many short programs scales with concurrency, and *why*
# it stops scaling (scheduler microstate + GC).
#
# Run:  mix run bench/lisp_concurrency.exs
#
# For "many concurrent sessions": if aggregate throughput plateaus well
# below `cores × single-core`, the path has a serialization point. The
# msacc / GC breakdown points at the cause.

alias PtcRunner.Lisp

# OTP `runtime_tools` (owns :msacc) is pruned from the `mix run` path.
rt_ebin =
  [to_string(:code.root_dir()), "lib", "runtime_tools-*", "ebin"]
  |> Path.join()
  |> Path.wildcard()
  |> List.first()

if rt_ebin, do: Code.append_path(rt_ebin)
msacc? = Code.ensure_loaded?(:msacc)

rep = "(reduce + 0 (map (fn [x] (* x x)) (range 0 20)))"
cores = System.schedulers_online()

for _ <- 1..500, do: Lisp.run(rep)

# --- aggregate throughput vs concurrency -----------------------------
# Fixed total work, split across C workers; measure wall time. Each
# level is run twice and the better (less noisy) result is kept.
total_runs = 60_000

measure_once = fn concurrency ->
  per = div(total_runs, concurrency)
  actual = per * concurrency
  parent = self()
  t0 = System.monotonic_time(:microsecond)

  for _ <- 1..concurrency do
    spawn_link(fn ->
      for _ <- 1..per, do: Lisp.run(rep)
      send(parent, :ok)
    end)
  end

  for _ <- 1..concurrency, do: receive(do: (:ok -> :ok))
  elapsed = System.monotonic_time(:microsecond) - t0
  actual * 1_000_000 / elapsed
end

measure = fn concurrency ->
  [measure_once.(concurrency), measure_once.(concurrency)] |> Enum.max()
end

IO.puts("\n=== Aggregate throughput vs concurrency ===")
IO.puts("#{cores} schedulers. Program: #{rep}")
IO.puts("Fixed #{total_runs} total runs, split across N workers; best of 2.\n")

IO.puts(
  String.pad_trailing("concurrency", 14) <>
    String.pad_trailing("runs/sec", 14) <>
    String.pad_trailing("scaling", 12) <> "efficiency"
)

base = measure.(1)

for c <- Enum.uniq([1, 2, 4, 8, cores, cores * 2]) do
  tput = measure.(c)
  scale = tput / base
  ideal = min(c, cores)
  eff = Float.round(scale / ideal * 100, 0)

  IO.puts(
    String.pad_trailing("#{c}", 14) <>
      String.pad_trailing("#{round(tput)}", 14) <>
      String.pad_trailing("#{Float.round(scale, 2)}×", 12) <>
      "#{round(eff)}% of linear (~#{ideal}×)"
  )
end

# --- scheduler microstate during a saturating load ------------------
IO.puts("\n=== Scheduler microstate (msacc), #{cores} workers saturating ===")

if msacc? do
  :msacc.start()
  parent = self()
  per = div(total_runs, cores)

  for _ <- 1..cores do
    spawn_link(fn ->
      for _ <- 1..per, do: Lisp.run(rep)
      send(parent, :ok)
    end)
  end

  for _ <- 1..cores, do: receive(do: (:ok -> :ok))
  :msacc.stop()

  totals =
    :msacc.stats()
    |> Enum.filter(&(&1.type == :scheduler))
    |> Enum.reduce(%{}, fn s, acc ->
      Map.merge(acc, s.counters, fn _k, a, b -> a + b end)
    end)

  grand = totals |> Map.values() |> Enum.sum() |> max(1)

  IO.puts("Where normal-scheduler time went (aggregate):\n")

  totals
  |> Enum.sort_by(fn {_k, v} -> -v end)
  |> Enum.each(fn {state, val} ->
    IO.puts(
      "  #{String.pad_trailing(to_string(state), 12)} #{Float.round(val / grand * 100, 2)}%"
    )
  end)

  IO.puts("\n  emulator = running BEAM code | gc = garbage collection")
  IO.puts("  sleep = idle/waiting for work | aux/check_io = VM housekeeping")
else
  IO.puts("  :msacc unavailable — skipped")
end

# --- GC pressure of one run -----------------------------------------
IO.puts("\n=== GC pressure (caller process) ===")

:erlang.garbage_collect()
{gcs0, words0, _} = :erlang.statistics(:garbage_collection)
n = 20_000
for _ <- 1..n, do: Lisp.run(rep)
{gcs1, words1, _} = :erlang.statistics(:garbage_collection)

IO.puts("Over #{n} runs (caller process only; each sandbox process GCs separately):")
IO.puts("  GC runs:          #{gcs1 - gcs0}  (#{Float.round((gcs1 - gcs0) / n, 3)}/run)")

IO.puts(
  "  words reclaimed:  #{words1 - words0}  (~#{round((words1 - words0) * 8 / n)} bytes/run)"
)
