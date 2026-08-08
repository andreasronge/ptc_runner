defmodule Mix.Tasks.Bench.Check do
  @shortdoc "Check deterministic Lisp eval performance against a baseline"
  @moduledoc """
  Checks deterministic PTC-Lisp eval metrics against a committed baseline.

      mix bench.check
      mix bench.check --write-baseline
      mix bench.check --skip-heap

  This task gates `eval_reductions` collected from the sandbox child process.
  Child `memory_bytes` and wall-clock duration are reported as informational
  metrics: runner timing noise is too large for a gate, and a single per-call
  `memory_bytes` sample cannot separate a leak from one-shot warmup. Repeated
  churn growth is the soak suite's job — `mix soak`, run weekly by the scheduled
  `Soak` workflow.

  It then prints the `mix bench.heap` table against `bench/baselines/heap.json`,
  **informationally**. Heap figures are whole-VM measurements with real noise,
  and a byte gate on a per-commit path invites the reflexive re-baseline that
  the reductions baseline has already seen once. `mix bench.heap` is the gating
  entry point for anyone who wants the check to fail, and the soak suite is
  where repeated-churn growth is hard-asserted.
  """

  use Mix.Task

  alias Mix.Tasks.Bench.Heap
  alias PtcRunner.Bench.Baseline
  alias PtcRunner.Lisp

  @default_baseline Path.join(["bench", "baselines", "lisp_eval.json"])
  @default_threshold 1.07
  @default_samples 7
  @default_warmup 20

  @scenarios [
    %{
      name: "arithmetic",
      program: "(+ 1 (* 2 3) (- 10 4) (* (+ 1 1) 5))"
    },
    %{
      name: "collection_hofs",
      program: "(reduce + 0 (map (fn [x] (* x x)) (filter odd? (range 0 40))))"
    },
    %{
      name: "map_string",
      program:
        ~S|(let [m {:a "alpha" :b "beta" :c "gamma"}] (clojure.string/join "," (map clojure.string/upper-case [(:a m) (:b m) (:c m)])))|
    },
    %{
      name: "closure_apply",
      program: "(let [mk (fn [x] (fn [y] (+ x y)))] (reduce + 0 (map (mk 10) [1 2 3 4 5])))"
    },
    %{
      name: "context_filter",
      program: "(->> data/orders (filter #(> (:total %) 20)) (map :total) (reduce + 0))",
      opts: [
        context: %{
          "orders" => [
            %{"id" => 1, "total" => 10},
            %{"id" => 2, "total" => 25},
            %{"id" => 3, "total" => 40}
          ]
        }
      ]
    }
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    opts = parse_args!(args)
    baseline_path = opts[:baseline]
    threshold = opts[:threshold]
    samples = opts[:samples]
    warmup = opts[:warmup]

    results = measure_all(samples, warmup)

    # The heap table runs before the reductions gate can raise, so a reductions
    # regression does not hide the heap numbers a reader would want next to it.
    unless opts[:skip_heap], do: Heap.report()

    if opts[:write_baseline] do
      write_baseline!(baseline_path, threshold, samples, warmup, results)
    else
      check_baseline!(baseline_path, threshold, results)
    end
  end

  defp parse_args!(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          baseline: :string,
          threshold: :float,
          samples: :integer,
          warmup: :integer,
          write_baseline: :boolean,
          skip_heap: :boolean
        ],
        aliases: [b: :baseline]
      )

    if rest != [] or invalid != [] do
      Mix.raise("invalid arguments: #{Enum.join(args, " ")}")
    end

    [
      baseline: Keyword.get(opts, :baseline, @default_baseline),
      threshold: Keyword.get(opts, :threshold, @default_threshold),
      samples: Keyword.get(opts, :samples, @default_samples),
      warmup: Keyword.get(opts, :warmup, @default_warmup),
      write_baseline: Keyword.get(opts, :write_baseline, false),
      skip_heap: Keyword.get(opts, :skip_heap, false)
    ]
    |> validate_opts!()
  end

  defp validate_opts!(opts) do
    threshold = opts[:threshold]
    samples = opts[:samples]
    warmup = opts[:warmup]

    cond do
      not is_float(threshold) or threshold < 1.0 ->
        Mix.raise("--threshold must be a float >= 1.0")

      not is_integer(samples) or samples < 1 ->
        Mix.raise("--samples must be a positive integer")

      not is_integer(warmup) or warmup < 0 ->
        Mix.raise("--warmup must be a non-negative integer")

      true ->
        opts
    end
  end

  defp measure_all(samples, warmup) do
    Mix.shell().info("==> measuring PTC-Lisp eval performance")

    Enum.map(@scenarios, fn scenario ->
      warmup!(scenario, warmup)

      measurements =
        for _ <- 1..samples do
          measure_once!(scenario)
        end

      %{
        name: scenario.name,
        program: scenario.program,
        samples: samples,
        eval_reductions: Baseline.median(Enum.map(measurements, & &1.eval_reductions)),
        memory_bytes: Enum.max(Enum.map(measurements, & &1.memory_bytes)),
        duration_ms: Baseline.median(Enum.map(measurements, & &1.duration_ms))
      }
    end)
  end

  defp warmup!(_scenario, 0), do: :ok

  defp warmup!(scenario, warmup) do
    for _ <- 1..warmup, do: measure_once!(scenario)
    :ok
  end

  defp measure_once!(scenario) do
    case Lisp.run(scenario.program, Map.get(scenario, :opts, [])) do
      {:ok, step} ->
        %{
          eval_reductions: Map.fetch!(step.usage, :eval_reductions),
          memory_bytes: Map.fetch!(step.usage, :memory_bytes),
          duration_ms: Map.fetch!(step.usage, :duration_ms)
        }

      {:error, step} ->
        Mix.raise("benchmark scenario #{scenario.name} failed: #{step.fail.message}")
    end
  end

  defp write_baseline!(path, threshold, samples, warmup, results) do
    Baseline.write!(path, %{
      "version" => 1,
      "threshold" => threshold,
      "samples" => samples,
      "warmup" => warmup,
      # This baseline keeps its original `elixir`/`otp` keys rather than moving
      # to the richer `provenance` block `bench.heap` writes. Reformatting it
      # would mean rewriting the committed reduction numbers, and those are only
      # ever bumped with a written cause.
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "scenarios" => Enum.map(results, &encode_result/1)
    })
  end

  defp check_baseline!(path, threshold, results) do
    baseline = Baseline.read!(path)
    baseline_by_name = Map.new(baseline["scenarios"], &{&1["name"], &1})

    failures =
      results
      |> Enum.flat_map(fn result ->
        expected = Map.fetch!(baseline_by_name, result.name)
        check_result(result, expected, threshold)
      end)

    print_results(results, baseline_by_name, threshold)

    if failures != [] do
      Mix.raise("performance regression detected:\n" <> Enum.join(failures, "\n"))
    end

    Mix.shell().info("Performance check passed.")
  end

  defp check_result(result, expected, threshold) do
    Enum.flat_map([:eval_reductions], fn metric ->
      actual = Map.fetch!(result, metric)
      baseline = Map.fetch!(expected, Atom.to_string(metric))
      allowed = Float.ceil(baseline * threshold, 1)

      if actual <= allowed do
        []
      else
        ["#{result.name} #{metric}: #{actual} > #{allowed} (baseline #{baseline})"]
      end
    end)
  end

  defp print_results(results, baseline_by_name, threshold) do
    Mix.shell().info("")
    Mix.shell().info("| Scenario | Eval reductions | Memory bytes | Duration ms |")
    Mix.shell().info("|---|---:|---:|---:|")

    Enum.each(results, fn result ->
      baseline = Map.fetch!(baseline_by_name, result.name)

      Mix.shell().info(
        "| #{result.name} | #{format_metric(result.eval_reductions, baseline["eval_reductions"], threshold)} | " <>
          "#{format_informational(result.memory_bytes, baseline["memory_bytes"])} | #{result.duration_ms} |"
      )
    end)

    Mix.shell().info("")
  end

  defp format_metric(actual, baseline, threshold) do
    allowed = Float.ceil(baseline * threshold, 1)
    "#{actual} (baseline #{baseline}, max #{allowed})"
  end

  defp format_informational(actual, baseline), do: "#{actual} (baseline #{baseline}, info)"

  defp encode_result(result) do
    %{
      "name" => result.name,
      "program" => result.program,
      "eval_reductions" => result.eval_reductions,
      "memory_bytes" => result.memory_bytes,
      "duration_ms" => result.duration_ms
    }
  end
end
