# Concurrency benchmark for the MCP session path — many concurrent
# sessions, each driven through many multi-turn `ptc_session_eval`
# calls. This is the layer above `PtcRunner.Lisp.run/2`: per-session
# GenServer, the begin_eval/commit_eval protocol, projection, and
# limit checks.
#
# Run:  cd mcp_server && mix run bench/session_concurrency.exs
#
# Questions:
#   * How much does the session layer add on top of bare Lisp.run/2?
#   * Do independent sessions scale (they have separate GenServers)?
#   * Where does scheduler time go under concurrent multi-turn load?

alias PtcRunner.Lisp
alias PtcRunnerMcp.Sessions
alias PtcRunnerMcp.Sessions.Config, as: SessionsConfig

rt_ebin =
  [to_string(:code.root_dir()), "lib", "runtime_tools-*", "ebin"]
  |> Path.join()
  |> Path.wildcard()
  |> List.first()

if rt_ebin, do: Code.append_path(rt_ebin)
msacc? = Code.ensure_loaded?(:msacc)

# A short, stateful turn: reads + writes one session-memory binding,
# plus a little compute — representative of a real multi-turn step.
program = "(def acc (+ (or acc 0) (reduce + 0 (range 0 20))))"
cores = System.schedulers_online()

# Raise the session caps well above what the bench needs (defaults are
# 64 total / 16 per owner; all bench sessions share the one stdio owner).
SessionsConfig.set(%{
  enabled: true,
  max_sessions: 200_000,
  max_sessions_per_owner: 200_000
})

:ok = Sessions.ensure_started()

start_session = fn ->
  %{"structuredContent" => %{"session_id" => id}} =
    Sessions.call(%{"name" => "ptc_session_start", "arguments" => %{}})

  id
end

eval = fn id ->
  Sessions.call(%{
    "name" => "ptc_session_eval",
    "arguments" => %{"session_id" => id, "program" => program}
  })
end

close = fn id ->
  Sessions.call(%{"name" => "ptc_session_close", "arguments" => %{"session_id" => id}})
end

# warmup
warm = start_session.()
for _ <- 1..200, do: eval.(warm)
close.(warm)

us = fn fun ->
  t0 = System.monotonic_time(:microsecond)
  fun.()
  System.monotonic_time(:microsecond) - t0
end

median = fn list ->
  sorted = Enum.sort(list)
  Enum.at(sorted, div(length(sorted), 2))
end

# --- session start cost ---------------------------------------------
IO.puts("\n=== Session lifecycle cost ===")

start_samples =
  for _ <- 1..500 do
    t0 = System.monotonic_time(:microsecond)
    id = start_session.()
    elapsed = System.monotonic_time(:microsecond) - t0
    close.(id)
    elapsed
  end

IO.puts("ptc_session_start  median #{median.(start_samples)} us  (start+close cycle)")

# --- per-turn latency: session eval vs bare Lisp.run ----------------
IO.puts("\n=== Per-turn cost: session eval vs bare Lisp.run/2 ===")

sid = start_session.()
turn_samples = for _ <- 1..5000, do: us.(fn -> eval.(sid) end)
close.(sid)

bare_samples = for _ <- 1..5000, do: us.(fn -> Lisp.run(program) end)

IO.puts("ptc_session_eval   median #{median.(turn_samples)} us")
IO.puts("bare Lisp.run/2    median #{median.(bare_samples)} us")
IO.puts("session-layer overhead ≈ #{median.(turn_samples) - median.(bare_samples)} us/turn")

# --- concurrent sessions: aggregate turns/sec vs N ------------------
IO.puts("\n=== Concurrent sessions — aggregate turns/sec vs N ===")
IO.puts("#{cores} schedulers. Each session runs its turns sequentially;")
IO.puts("sessions run concurrently (separate GenServers).\n")

turns_total = 30_000

run_sessions = fn n ->
  per = div(turns_total, n)
  parent = self()
  t0 = System.monotonic_time(:microsecond)

  for _ <- 1..n do
    spawn_link(fn ->
      id = start_session.()
      for _ <- 1..per, do: eval.(id)
      close.(id)
      send(parent, :ok)
    end)
  end

  for _ <- 1..n, do: receive(do: (:ok -> :ok))
  elapsed = System.monotonic_time(:microsecond) - t0
  per * n * 1_000_000 / elapsed
end

IO.puts(
  String.pad_trailing("sessions", 12) <>
    String.pad_trailing("turns/sec", 14) <> "scaling"
)

base = run_sessions.(1)

for n <- Enum.uniq([1, 2, 4, 8, cores, cores * 2]) do
  tput = run_sessions.(n)

  IO.puts(
    String.pad_trailing("#{n}", 12) <>
      String.pad_trailing("#{round(tput)}", 14) <>
      "#{Float.round(tput / base, 2)}× (linear ~#{min(n, cores)}×)"
  )
end

# --- scheduler microstate under concurrent session load ------------
IO.puts("\n=== Scheduler microstate (msacc), #{cores} concurrent sessions ===")

if msacc? do
  :msacc.start()
  parent = self()
  per = div(turns_total, cores)

  for _ <- 1..cores do
    spawn_link(fn ->
      id = start_session.()
      for _ <- 1..per, do: eval.(id)
      close.(id)
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

  totals
  |> Enum.sort_by(fn {_k, v} -> -v end)
  |> Enum.each(fn {state, val} ->
    IO.puts(
      "  #{String.pad_trailing(to_string(state), 12)} #{Float.round(val / grand * 100, 2)}%"
    )
  end)
else
  IO.puts("  :msacc unavailable — skipped")
end
