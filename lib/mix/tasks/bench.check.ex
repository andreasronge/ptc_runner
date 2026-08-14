defmodule Mix.Tasks.Bench.Check do
  @shortdoc "Check deterministic Lisp eval performance against a baseline"
  @moduledoc """
  Checks deterministic PTC-Lisp eval metrics against a committed baseline.

      mix bench.check
      mix bench.check --write-baseline --reason "accepted cause"
      mix bench.check --skip-heap

  This task gates `eval_reductions` collected from the sandbox child process.
  Its scenario matrix covers the raw evaluator and the public-prelude,
  strict-transitive, and private-tool authority paths. Before measuring, the
  task requires the baseline's Mix environment, Elixir, OTP, ERTS, emulator
  flavor, and word size to match the current runtime; reduction counts from a
  different BEAM execution shape are not a valid comparison.

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
  alias PtcRunner.Lisp.Prelude.Compiler

  @default_baseline Path.join(["bench", "baselines", "lisp_eval.json"])
  @default_threshold 1.07
  @default_samples 7
  @default_warmup 20
  @runtime_provenance_fields ~w(mix_env elixir otp erts emu_flavor wordsize_bytes)

  @public_prelude """
  (ns bench "Benchmark helpers." {:visibility :prompt})
  (defn square "Squares a number." [x] (* x x))
  """

  @private_tool_prelude """
  (ns bench "Benchmark private-tool helpers." {:visibility :prompt})
  (defn private-value "Reads a value through a private tool." [x]
    (tool/private_echo {:value x}))
  """

  @scenarios [
    %{
      name: "arithmetic",
      program: "(+ 1 (* 2 3) (- 10 4) (* (+ 1 1) 5))",
      config: %{opts: []}
    },
    %{
      name: "collection_hofs",
      program: "(reduce + 0 (map (fn [x] (* x x)) (filter odd? (range 0 40))))",
      config: %{opts: []}
    },
    %{
      name: "map_string",
      program:
        ~S|(let [m {:a "alpha" :b "beta" :c "gamma"}] (clojure.string/join "," (map clojure.string/upper-case [(:a m) (:b m) (:c m)])))|,
      config: %{opts: []}
    },
    %{
      name: "closure_apply",
      program: "(let [mk (fn [x] (fn [y] (+ x y)))] (reduce + 0 (map (mk 10) [1 2 3 4 5])))",
      config: %{opts: []}
    },
    %{
      name: "context_filter",
      program: "(->> data/orders (filter #(> (:total %) 20)) (map :total) (reduce + 0))",
      config: %{
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
    },
    %{
      name: "public_prelude",
      program: "(reduce + 0 (map bench/square (range 0 40)))",
      policy: :public_prelude,
      config: %{prelude_source: @public_prelude}
    },
    %{
      name: "strict_transitive_prelude",
      program: "(reduce + 0 (map bench/square (range 0 40)))",
      policy: :strict_transitive_prelude,
      config: %{
        prelude_source: @public_prelude,
        strict_transitive_calls: true,
        direct_namespaces: ["bench"]
      }
    },
    %{
      name: "private_tool_prelude",
      program: "(reduce + 0 (map bench/private-value [1 2 3 4 5]))",
      policy: :private_tool_prelude,
      config: %{
        prelude_source: @private_tool_prelude,
        tools: %{
          "private_echo" => %{implementation: :return_value_argument, visibility: :private}
        }
      }
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
    reason = opts[:reason]

    baseline =
      unless opts[:write_baseline] do
        baseline_path
        |> Baseline.read!()
        |> validate_provenance!()
        |> validate_scenario_identity!()
      end

    results = measure_all(samples, warmup)

    # The heap table runs before the reductions gate can raise, so a reductions
    # regression does not hide the heap numbers a reader would want next to it.
    unless opts[:skip_heap], do: Heap.report()

    if opts[:write_baseline] do
      write_baseline!(baseline_path, threshold, samples, warmup, reason, results)
    else
      check_baseline!(baseline, threshold, results)
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
          reason: :string,
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
      reason: Keyword.get(opts, :reason),
      write_baseline: Keyword.get(opts, :write_baseline, false),
      skip_heap: Keyword.get(opts, :skip_heap, false)
    ]
    |> validate_opts!()
  end

  defp validate_opts!(opts) do
    threshold = opts[:threshold]
    samples = opts[:samples]
    warmup = opts[:warmup]
    reason = opts[:reason]
    write_baseline? = opts[:write_baseline]

    cond do
      not is_float(threshold) or threshold < 1.0 ->
        Mix.raise("--threshold must be a float >= 1.0")

      not is_integer(samples) or samples < 1 ->
        Mix.raise("--samples must be a positive integer")

      not is_integer(warmup) or warmup < 0 ->
        Mix.raise("--warmup must be a non-negative integer")

      write_baseline? and (not is_binary(reason) or String.trim(reason) == "") ->
        Mix.raise("--write-baseline requires a non-empty --reason")

      not write_baseline? and not is_nil(reason) ->
        Mix.raise("--reason may only be used with --write-baseline")

      true ->
        opts
    end
  end

  defp measure_all(samples, warmup) do
    Mix.shell().info("==> measuring PTC-Lisp eval performance")

    @scenarios
    |> prepare_scenarios!()
    |> Enum.map(fn scenario ->
      warmup!(scenario, warmup)

      measurements =
        for _ <- 1..samples do
          measure_once!(scenario)
        end

      %{
        name: scenario.name,
        policy: Map.get(scenario, :policy, :raw),
        program: scenario.program,
        identity_sha256: scenario_identity_sha256(scenario),
        samples: samples,
        eval_reductions: Baseline.median(Enum.map(measurements, & &1.eval_reductions)),
        memory_bytes: Enum.max(Enum.map(measurements, & &1.memory_bytes)),
        duration_ms: Baseline.median(Enum.map(measurements, & &1.duration_ms))
      }
    end)
  end

  defp prepare_scenarios!(scenarios) do
    preludes =
      scenarios
      |> Enum.flat_map(fn scenario ->
        case scenario.config do
          %{prelude_source: source} -> [source]
          _config -> []
        end
      end)
      |> Enum.uniq()
      |> Map.new(&{&1, compile_prelude!(&1)})

    Enum.map(scenarios, fn scenario ->
      Map.put(scenario, :opts, scenario_opts(scenario.config, preludes))
    end)
  end

  defp scenario_opts(%{opts: opts}, _preludes), do: opts

  defp scenario_opts(%{prelude_source: source} = config, preludes) do
    opts = [prelude: Map.fetch!(preludes, source)]

    opts =
      if config[:strict_transitive_calls] do
        Keyword.merge(opts,
          strict_transitive_calls: true,
          direct_namespaces: Map.fetch!(config, :direct_namespaces)
        )
      else
        opts
      end

    case config[:tools] do
      nil -> opts
      tools -> Keyword.put(opts, :tools, prepare_tools!(tools))
    end
  end

  defp prepare_tools!(tools) do
    Map.new(tools, fn
      {name, %{implementation: :return_value_argument, visibility: visibility}} ->
        {name, {fn args -> args["value"] end, visibility: visibility}}
    end)
  end

  defp scenario_identity_sha256(scenario) do
    scenario
    |> Map.take([:name, :program, :policy, :config])
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp compile_prelude!(source) do
    case Compiler.compile(source) do
      {:ok, prelude} -> prelude
      {:error, error} -> Mix.raise("benchmark prelude failed to compile: #{error.message}")
    end
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

  defp write_baseline!(path, threshold, samples, warmup, reason, results) do
    Baseline.write!(path, %{
      "version" => 2,
      "threshold" => threshold,
      "samples" => samples,
      "warmup" => warmup,
      "reason" => String.trim(reason),
      "provenance" => Baseline.provenance() |> Map.delete("commit"),
      "scenarios" => Enum.map(results, &encode_result/1)
    })
  end

  defp validate_provenance!(baseline) do
    recorded = baseline["provenance"]
    current = Baseline.provenance()

    unless baseline["version"] == 2 and is_binary(baseline["reason"]) and
             String.trim(baseline["reason"]) != "" do
      Mix.raise(
        "benchmark baseline has no written acceptance reason; " <>
          "regenerate it with mix bench.check --write-baseline --reason \"accepted cause\""
      )
    end

    unless is_map(recorded) do
      Mix.raise(
        "benchmark baseline has no runtime provenance; " <>
          "regenerate it with mix bench.check --write-baseline"
      )
    end

    mismatches =
      Enum.flat_map(@runtime_provenance_fields, fn field ->
        expected = recorded[field]
        actual = current[field]

        if expected == actual do
          []
        else
          ["#{field}: baseline #{inspect(expected)}, current #{inspect(actual)}"]
        end
      end)

    if mismatches != [] do
      Mix.raise(
        "benchmark baseline runtime does not match the current toolchain:\n" <>
          Enum.join(mismatches, "\n")
      )
    end

    baseline
  end

  defp check_baseline!(baseline, threshold, results) do
    baseline_by_name = Map.new(baseline["scenarios"], &{&1["name"], &1})

    expected_names = baseline_by_name |> Map.keys() |> Enum.sort()
    actual_names = results |> Enum.map(& &1.name) |> Enum.sort()

    if expected_names != actual_names do
      Mix.raise(
        "benchmark scenario set differs from the baseline; " <>
          "expected #{inspect(expected_names)}, got #{inspect(actual_names)}"
      )
    end

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

  defp validate_scenario_identity!(baseline) do
    recorded =
      Enum.map(
        baseline["scenarios"] || [],
        &Map.take(&1, ~w(name policy program identity_sha256))
      )

    current =
      Enum.map(@scenarios, fn scenario ->
        %{
          "name" => scenario.name,
          "policy" => scenario |> Map.get(:policy, :raw) |> Atom.to_string(),
          "program" => scenario.program,
          "identity_sha256" => scenario_identity_sha256(scenario)
        }
      end)

    if Enum.sort_by(recorded, & &1["name"]) != Enum.sort_by(current, & &1["name"]) do
      Mix.raise(
        "benchmark scenario definitions differ from the baseline; " <>
          "regenerate it only after reviewing the program and policy changes"
      )
    end

    baseline
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
    Mix.shell().info("| Scenario | Policy | Eval reductions | Memory bytes | Duration ms |")
    Mix.shell().info("|---|---|---:|---:|---:|")

    Enum.each(results, fn result ->
      baseline = Map.fetch!(baseline_by_name, result.name)

      Mix.shell().info(
        "| #{result.name} | #{result.policy} | " <>
          "#{format_metric(result.eval_reductions, baseline["eval_reductions"], threshold)} | " <>
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
      "policy" => Atom.to_string(result.policy),
      "program" => result.program,
      "identity_sha256" => result.identity_sha256,
      "eval_reductions" => result.eval_reductions,
      "memory_bytes" => result.memory_bytes,
      "duration_ms" => result.duration_ms
    }
  end
end
