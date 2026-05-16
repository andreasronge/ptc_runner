# Function-level profile of a tight loop of short PtcRunner.Lisp runs.
# Answers "where does the per-program time go" — parse, analyze, sandbox
# process spawn, eval, env construction, telemetry.
#
# Run:  mix run bench/lisp_profile.exs
#
# Uses OTP `:tprof` (call_time + call_count). `:tprof` traces across all
# processes spawned during the measured fun, so the per-run sandbox
# process is included.

alias PtcRunner.Lisp

# `mix run` prunes the code path to the project's apps; the OTP `tools`
# application (which owns `:tprof`) is not included. Locate its ebin
# under the Erlang install and add it so `:tprof` can be loaded.
tools_ebin =
  [to_string(:code.root_dir()), "lib", "tools-*", "ebin"]
  |> Path.join()
  |> Path.wildcard()
  |> List.first()

if tools_ebin, do: Code.append_path(tools_ebin)

unless Code.ensure_loaded?(:tprof) do
  IO.puts("ERROR: could not load :tprof (OTP tools app). Looked in: #{inspect(tools_ebin)}")
  System.halt(1)
end

rep = "(reduce + 0 (map (fn [x] (* x x)) (range 0 20)))"
iterations = String.to_integer(System.get_env("PROFILE_ITERS", "3000"))

# Warm caches so module loading / persistent_term init is not profiled.
for _ <- 1..300, do: Lisp.run(rep)

work = fn ->
  for _ <- 1..iterations, do: Lisp.run(rep)
  :ok
end

IO.puts("\n=== :tprof call_time — #{iterations} short Lisp.run/2 calls ===")
IO.puts("Program: #{rep}")
IO.puts("(time = total tracked us; per-call columns are per traced call)\n")

:tprof.profile(work, %{type: :call_time, report: :total})

IO.puts("\n=== :tprof call_count — same workload ===\n")

:tprof.profile(work, %{type: :call_count, report: :total})
