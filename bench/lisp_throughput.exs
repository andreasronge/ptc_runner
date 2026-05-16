# Throughput / latency benchmark for PtcRunner.Lisp — focused on the cost
# of creating and running many *short* PTC-Lisp programs, and how that
# cost scales under concurrency.
#
# Run:  mix run bench/lisp_throughput.exs
#
# Three suites:
#   1. Pipeline stages — splits one short run into parse / parse+analyze /
#      full run, so the fixed per-program overhead is attributable.
#   2. Archetypes — full Lisp.run/2 across representative short programs.
#   3. Concurrency — the same short run with `parallel: N`, to expose
#      contention as concurrent load rises (proxy for many sessions).

alias PtcRunner.Lisp
alias PtcRunner.Lisp.{Analyze, Parser}

# A representative "short program" — a little of everything an LLM emits.
rep = "(reduce + 0 (map (fn [x] (* x x)) (range 0 20)))"

archetypes = %{
  "arithmetic        (+ - * nested)" => "(+ 1 (* 2 3) (- 10 4) (* (+ 1 1) 5))",
  "let bindings" => "(let [a 1 b 2 c 3] (+ a b c (* a b c)))",
  "collection HOFs   (map/filter/reduce)" => rep,
  "string ops" => ~S|(clojure.string/upper-case (clojure.string/join "-" ["a" "b" "c"]))|,
  "closure + apply" => "(let [add (fn [x] (fn [y] (+ x y)))] ((add 10) 5))",
  "map literal + access" => "(let [m {:a 1 :b 2 :c 3}] (+ (:a m) (:b m) (:c m)))"
}

schedulers = System.schedulers_online()
IO.puts("\n# schedulers online: #{schedulers}\n")

# Warm caches (Env.initial/0, persistent_term, module loading).
for _ <- 1..200, do: Lisp.run(rep)

{:ok, rep_ast} = Parser.parse(rep)

IO.puts("=== Suite 1: pipeline stages (single short program) ===")

Benchee.run(
  %{
    "parse only" => fn -> Parser.parse(rep) end,
    "parse + analyze" => fn ->
      {:ok, ast} = Parser.parse(rep)
      Analyze.analyze(ast)
    end,
    "analyze only (pre-parsed)" => fn -> Analyze.analyze(rep_ast) end,
    "full Lisp.run/2" => fn -> Lisp.run(rep) end
  },
  time: 3,
  warmup: 1,
  memory_time: 1,
  print: [fast_warning: false]
)

IO.puts("\n=== Suite 2: full Lisp.run/2 by archetype ===")

Benchee.run(
  Map.new(archetypes, fn {name, src} -> {name, fn -> Lisp.run(src) end} end),
  time: 3,
  warmup: 1,
  memory_time: 1,
  print: [fast_warning: false]
)

IO.puts("\n=== Suite 3: concurrency scaling (full run, parallel: N) ===")
IO.puts("Same job; `parallel: N` runs N copies in parallel processes.")
IO.puts("If per-call ips holds flat as N rises, the path scales; if it")
IO.puts("drops, there is contention (atom table, persistent_term, GC, spawn).\n")

for p <- [1, 2, 4, schedulers, schedulers * 2] do
  IO.puts("--- parallel: #{p} ---")

  Benchee.run(
    %{"full Lisp.run/2" => fn -> Lisp.run(rep) end},
    time: 2,
    warmup: 1,
    parallel: p,
    print: [fast_warning: false, configuration: false]
  )
end
