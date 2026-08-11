defmodule Mix.Tasks.Bench.Heap do
  @shortdoc "Measure PtcRunner heap use cases against a committed baseline"
  @moduledoc """
  Measures the heap cost of the PtcRunner embedding units and compares them
  against `bench/baselines/heap.json`.

      mix bench.heap                  # measure, compare, fail on regression
      mix bench.heap --write-baseline # re-record the committed baseline
      mix bench.heap --report         # measure and print, never fail

  `mix bench.check` calls `report/1` to print the same table informationally
  alongside the eval-reduction gate. This task is the gating entry point; run
  it deliberately, at release time or from the scheduled `Soak` workflow.

  ## Rows

  | row | what it sizes |
  |---|---|
  | `floor_no_mix_idle` | resident cost of a started `:ptc_runner` with no Mix on the path |
  | `floor_no_mix_warm` | the same child after one `Lisp.run/2`, so lazy loading has happened |
  | `lisp_trivial` | the cheapest possible `Lisp.run/2` unit |
  | `lisp_collection_hofs` | allocation-heavy builtins |
  | `lisp_large_binary` | refc-binary construction and its residual |
  | `compile_bundle_1` | per-artifact resident cost of a compiled bundle |
  | `compile_bundle_20` | whether bundle cost scales linearly in components |
  | `kernel_run` | the real embedding unit |
  | `kernel_run_capabilities_events` | the same unit with a capability and an event sink |
  | `concurrency_N` | heap per concurrent `Kernel.run`, for N in 1/8/32/64/128 |

  ## Metrics

  * `unit_bytes` — the workload's own heap at return, before any GC. For the
    `lisp_*` rows this is `step.usage.memory_bytes`, the sandbox child's
    `Process.info(self(), :memory)` (`sandbox.ex`). For the `compile_*` and
    `kernel_*` rows it is the same reading taken in a dedicated driver process.
    **`PtcRunner.Kernel.run/2` spawns its own sandbox children, so the
    `kernel_*` driver figure excludes them** — `concurrency_*` is the row that
    sees the whole system.
  * `retained_bytes` — the retained size of the durable artifact the row
    produces, from PtcRunner.Lisp.RetainedSize, or `null` when that module
    answers `:oversized`.
  * `residual_bytes_per_iter` — repeated-batch residual. K equal batches of N
    iterations with a system-wide GC at each boundary; the reported rate is
    `(endpoint_K - endpoint_1) / ((K - 1) * N)` over `:erlang.memory(:total)`.
    Batch 1 is deliberately excluded: it carries lazy module loading and
    first-use interning, and a single before/after delta cannot tell that
    one-shot cost apart from a linear leak. **At these iteration counts the
    metric has no resolution below roughly half a kilobyte per iteration** —
    see `@metric_floors`. It is here to be read as a trend; the soak suite is
    where residual growth is hard-asserted, because only there is the workload
    repeated enough for a slope to outrun the VM's own drift.
  * `worker_heap_bytes_total` / `worker_heap_bytes_median` — `concurrency_*`
    only. Each concurrent worker reports its own heap at return, so these are
    deterministic and are what this row gates on. Like the `kernel_*` rows they
    exclude the sandbox children.
  * `peak_total_bytes` / `peak_bytes_per_run` — `concurrency_*` only, from a
    sampling process reading `:erlang.memory(:total)`. This is the only sample
    that sees the sandbox children, and it is **diagnostic, never compared**:
    `:erlang.memory/0` walks every allocator, so the sampler lands ~10 reads on
    a sub-millisecond run and the figure moved by more than 2x between runs of
    the unchanged workload. `samples_observed` records that coverage.

  Every figure is a heap figure, not RSS. Allocator carrier fragmentation and
  resident-set growth are invisible here by construction; the plan puts both in
  the diagnostic tier, and neither is sampled at all by this task.
  """

  use Mix.Task

  alias PtcRunner.Bench.Baseline
  alias PtcRunner.Bench.Floor
  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.RetainedSize

  @default_baseline Path.join(["bench", "baselines", "heap.json"])

  # Memory is noisier than reductions, and every row here is a whole-VM
  # measurement rather than a counter read out of one process. The ratio gate
  # is paired with an absolute floor per metric so a row whose baseline is a
  # handful of bytes cannot fail on rounding.
  @default_threshold 1.25
  @default_batches 3

  # `unit_bytes` is a single process's heap at one instant, so it lands wherever
  # that process's last GC left it. A 7-sample median still swung by ~30 KB
  # between runs of the unchanged `lisp_collection_hofs` workload; 25 settles it.
  @median_samples 25

  # Absolute slack added on top of `baseline * threshold`, per metric. Below
  # these magnitudes a "regression" is measurement noise, not a signal. Each
  # number comes from repeated runs of the unchanged workload, not from
  # rounding: six clean `--report` runs put `residual_bytes_per_iter` anywhere
  # in -445..+444 B/iter on rows whose true residual is ~0, so anything under
  # half a kilobyte per iteration is indistinguishable from the VM's own drift
  # at these iteration counts.
  @metric_floors %{
    "unit_bytes" => 16_384,
    "retained_bytes" => 4_096,
    "residual_bytes_per_iter" => 512,
    "worker_heap_bytes_total" => 262_144,
    "worker_heap_bytes_median" => 16_384,
    "total_bytes" => 4_194_304,
    "processes_bytes" => 2_097_152,
    "code_bytes" => 2_097_152,
    "ets_bytes" => 524_288,
    "atom_bytes" => 262_144,
    "atom_count" => 4_000,
    "loaded_modules" => 40,
    "ptc_modules" => 40,
    "process_count" => 20
  }

  # `mix_modules` deliberately has no floor. Its baseline is 0, so the ratio
  # gate fails on the first Mix module the child loads — which is the only
  # thing that would invalidate the floor rows.

  # Recorded and printed, never compared. `peak_*` come from a sampler that
  # gets ~10 reads per run and moved by more than 2x between runs of the
  # unchanged workload; `samples_observed` is that sampler's own coverage, and
  # `iterations_per_batch`/`batches` are the harness configuration rather than
  # anything the runtime can regress.
  @diagnostic_metrics ~w(peak_total_bytes peak_bytes_per_run samples_observed
                         iterations_per_batch batches)

  @lisp_rows [
    %{
      name: "lisp_trivial",
      program: "(+ 1 (* 2 3) (- 10 4) (* (+ 1 1) 5))",
      iterations: 200
    },
    %{
      name: "lisp_collection_hofs",
      program: "(reduce + 0 (map (fn [x] (* x x)) (filter odd? (range 0 200))))",
      iterations: 200
    },
    %{
      name: "lisp_large_binary",
      program: ~S|(clojure.string/join "," (map str (range 0 4000)))|,
      iterations: 150
    }
  ]

  @concurrency_levels [1, 8, 32, 64, 128]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    opts = parse_args!(args)

    cond do
      opts[:write_baseline] -> write_baseline!(opts)
      opts[:report] -> report(baseline: opts[:baseline], batches: opts[:batches])
      true -> check!(opts)
    end
  end

  @doc """
  Measures every row and prints the comparison table without failing.

  This is what `mix bench.check` calls: the heap table is informational there,
  because a re-baseline reflex is the failure mode a byte gate invites, and the
  hard assertions live in the soak suite where the workload is repeated enough
  for a slope to mean something.
  """
  @spec report(keyword()) :: :ok
  def report(opts \\ []) do
    path = Keyword.get(opts, :baseline, @default_baseline)
    baseline = Baseline.read!(path)
    rows = measure_all(Keyword.get(opts, :batches, @default_batches))

    regressions = compare(rows, baseline)
    print_table(rows, baseline, "informational")

    if regressions == [] do
      Mix.shell().info("Heap rows within baseline (informational).")
    else
      Mix.shell().info([
        IO.ANSI.yellow(),
        "Heap regression (informational, not gating):\n" <> Enum.join(regressions, "\n"),
        IO.ANSI.reset()
      ])
    end

    :ok
  end

  defp check!(opts) do
    baseline = Baseline.read!(opts[:baseline])
    rows = measure_all(opts[:batches])
    regressions = compare(rows, baseline, opts[:threshold])
    print_table(rows, baseline, "gating at #{opts[:threshold]}x")

    if regressions != [] do
      Mix.raise("heap regression detected:\n" <> Enum.join(regressions, "\n"))
    end

    Mix.shell().info("Heap check passed.")
  end

  defp write_baseline!(opts) do
    rows = measure_all(opts[:batches])

    Baseline.write!(opts[:baseline], %{
      "version" => 1,
      "threshold" => opts[:threshold],
      "batches" => opts[:batches],
      "provenance" => Baseline.provenance(),
      "rows" => rows
    })
  end

  # ── argument handling ────────────────────────────────────────────────────

  defp parse_args!(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          baseline: :string,
          threshold: :float,
          batches: :integer,
          write_baseline: :boolean,
          report: :boolean
        ],
        aliases: [b: :baseline]
      )

    if rest != [] or invalid != [] do
      Mix.raise("invalid arguments: #{Enum.join(args, " ")}")
    end

    parsed = [
      baseline: Keyword.get(opts, :baseline, @default_baseline),
      threshold: Keyword.get(opts, :threshold, @default_threshold),
      batches: Keyword.get(opts, :batches, @default_batches),
      write_baseline: Keyword.get(opts, :write_baseline, false),
      report: Keyword.get(opts, :report, false)
    ]

    cond do
      not is_float(parsed[:threshold]) or parsed[:threshold] < 1.0 ->
        Mix.raise("--threshold must be a float >= 1.0")

      # Two batches would leave a single interval, so the residual rate would
      # rest entirely on the batch that still carries warmup effects.
      not is_integer(parsed[:batches]) or parsed[:batches] < 3 ->
        Mix.raise("--batches must be an integer >= 3")

      parsed[:write_baseline] and parsed[:report] ->
        Mix.raise("--write-baseline and --report are mutually exclusive")

      true ->
        parsed
    end
  end

  # ── measurement ──────────────────────────────────────────────────────────

  defp measure_all(batches) do
    Mix.shell().info("==> measuring PtcRunner heap use cases (#{batches} batches per row)")

    floor_rows() ++
      Enum.map(@lisp_rows, &lisp_row(&1, batches)) ++
      [
        compile_row("compile_bundle_1", 1, 200, batches),
        compile_row("compile_bundle_20", 20, 100, batches),
        kernel_row("kernel_run", :plain, 150, batches),
        kernel_row("kernel_run_capabilities_events", :capabilities, 150, batches)
      ] ++
      Enum.map(@concurrency_levels, &concurrency_row/1)
  end

  # Row 1. The floor an embedder budgets first. `mix run` keeps Mix and the
  # compiler resident, so measuring it in this VM would report a floor no
  # embedded host ever pays. A child `elixir` boots the application with the
  # same code path and no Mix, and reports back what it actually loaded.
  defp floor_rows do
    floor = Floor.measure!()

    [
      %{
        "name" => "floor_no_mix_idle",
        "note" => "started :ptc_runner in a child `elixir` VM; Mix is not on the path",
        "metrics" => Map.fetch!(floor, "idle")
      },
      %{
        "name" => "floor_no_mix_warm",
        "note" => "the same child after one Lisp.run/2, so lazy module loading has happened",
        "metrics" => Map.fetch!(floor, "warm")
      }
    ]
  end

  defp lisp_row(%{name: name, program: program, iterations: iterations}, batches) do
    unit = fn ->
      {:ok, step} = Lisp.run(program)
      step
    end

    warmup(unit)

    unit_bytes =
      Baseline.median(for _ <- 1..@median_samples, do: Map.fetch!(unit.().usage, :memory_bytes))

    %{
      "name" => name,
      "note" => "sandbox child heap at return; #{iterations} iterations per batch",
      "metrics" =>
        Map.merge(
          %{"unit_bytes" => unit_bytes},
          batch_residual(fn -> unit.() end, iterations, batches)
        )
    }
  end

  defp compile_row(name, component_count, iterations, batches) do
    components = components(component_count)

    unit = fn ->
      {:ok, bundle} = Kernel.compile_bundle(components)
      bundle
    end

    warmup(unit)

    %{
      "name" => name,
      "note" => "#{component_count} component(s); #{iterations} iterations per batch",
      "metrics" =>
        %{
          "unit_bytes" => driver_heap_bytes(unit),
          "retained_bytes" => retained_bytes(unit.())
        }
        |> Map.merge(batch_residual(unit, iterations, batches))
    }
  end

  defp kernel_row(name, shape, iterations, batches) do
    unit = kernel_unit(shape)
    warmup(unit)

    %{
      "name" => name,
      "note" =>
        "driver heap at return, excluding the sandbox children Kernel.run spawns; " <>
          "#{iterations} iterations per batch",
      "metrics" =>
        %{
          "unit_bytes" => driver_heap_bytes(unit),
          "retained_bytes" => retained_bytes(unit.())
        }
        |> Map.merge(batch_residual(unit, iterations, batches))
    }
  end

  # Row 9. The only row that sees the whole system — and the only place a
  # sampler is unavoidable, because the sandbox children `Kernel.run` spawns
  # are gone by the time anything can ask them how big they got.
  #
  # `:erlang.memory(:total)` costs tens of microseconds because it walks every
  # allocator, and a concurrency-1 run finishes in well under a millisecond, so
  # the sampler manages ~10 reads per run. That is a lottery, not a measurement:
  # across repeated runs of the unchanged workload the sampled peak moved by
  # more than 2x. The sampled figures are therefore recorded and printed but
  # never compared — the plan's diagnostic tier — and the gating metric for
  # this row is the deterministic one below.
  defp concurrency_row(concurrency) do
    unit = kernel_unit(:plain)
    warmup(unit)

    trials = for _ <- 1..9, do: sample_concurrent_peak(unit, concurrency)
    peak = Baseline.median(Enum.map(trials, & &1.peak_delta_bytes))

    %{
      "name" => "concurrency_#{concurrency}",
      "note" =>
        "worker_* gate and are deterministic; peak_* are sampled diagnostics " <>
          "(median of 9 trials) and exclude nothing but resolve nothing either",
      "metrics" => %{
        "worker_heap_bytes_total" => Baseline.median(Enum.map(trials, & &1.worker_heap_total)),
        "worker_heap_bytes_median" => Baseline.median(Enum.map(trials, & &1.worker_heap_median)),
        "peak_total_bytes" => peak,
        "peak_bytes_per_run" => div(peak, concurrency),
        "samples_observed" => Baseline.median(Enum.map(trials, & &1.samples))
      }
    }
  end

  defp warmup(unit) do
    for _ <- 1..20, do: unit.()
    gc_everywhere()
  end

  # The repeated-batch residual. A one-shot cost shows up in batch 1 only; a
  # linear leak shows up in every batch, so the rate is taken across the
  # batch-1..batch-K endpoints with batch 1 as the origin rather than as a
  # measurement.
  defp batch_residual(unit, iterations, batches) do
    endpoints =
      for _batch <- 1..batches do
        for _ <- 1..iterations, do: unit.()
        gc_everywhere()
        :erlang.memory(:total)
      end

    first = List.first(endpoints)
    last = List.last(endpoints)

    %{
      "residual_bytes_per_iter" => (last - first) / ((batches - 1) * iterations),
      "iterations_per_batch" => iterations,
      "batches" => batches
    }
  end

  # `Process.info(self(), :memory)` taken inside a dedicated process the
  # instant the workload returns — the same definition `Sandbox` uses for
  # `usage.memory_bytes`, so the rows stay comparable.
  defp driver_heap_bytes(unit) do
    Baseline.median(for _ <- 1..@median_samples, do: driver_heap_once(unit))
  end

  defp driver_heap_once(unit) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        _value = unit.()
        {:memory, bytes} = Process.info(self(), :memory)
        send(parent, {ref, bytes})
      end)

    receive do
      {^ref, bytes} ->
        Process.demonitor(monitor, [:flush])
        bytes

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        Mix.raise("heap driver process died: #{inspect(reason)}")
    end
  end

  defp sample_concurrent_peak(unit, concurrency) do
    gc_everywhere()
    base = :erlang.memory(:total)
    parent = self()
    ref = make_ref()
    sampler = spawn_link(fn -> sample_loop(parent, base, 0, 0) end)

    workers =
      for _ <- 1..concurrency do
        spawn_monitor(fn ->
          _value = unit.()
          {:memory, bytes} = Process.info(self(), :memory)
          send(parent, {ref, bytes})
        end)
      end

    # Each worker reports its own heap at return, so the deterministic figures
    # do not depend on catching the workers alive. The monitor is what proves
    # every worker actually finished — a missing report would otherwise just
    # shrink the total and read as an improvement.
    worker_heaps =
      Enum.map(workers, fn {pid, monitor} ->
        receive do
          {:DOWN, ^monitor, :process, ^pid, :normal} ->
            receive do
              {^ref, bytes} -> bytes
            after
              0 -> Mix.raise("concurrent worker exited normally without reporting its heap")
            end

          {:DOWN, ^monitor, :process, ^pid, reason} ->
            Mix.raise("concurrent worker died: #{inspect(reason)}")
        end
      end)

    send(sampler, {:stop, self()})

    receive do
      {:peak, ^sampler, peak, samples} ->
        %{
          peak_delta_bytes: max(peak, 0),
          samples: samples,
          worker_heap_total: Enum.sum(worker_heaps),
          worker_heap_median: Baseline.median(worker_heaps)
        }
    end
  end

  defp sample_loop(parent, base, peak, samples) do
    peak = max(peak, :erlang.memory(:total) - base)

    receive do
      {:stop, ^parent} -> send(parent, {:peak, self(), peak, samples + 1})
    after
      0 -> sample_loop(parent, base, peak, samples + 1)
    end
  end

  defp gc_everywhere do
    Enum.each(Process.list(), &:erlang.garbage_collect/1)
    :erlang.garbage_collect()
    :ok
  end

  defp retained_bytes(value) do
    case RetainedSize.bytes(value) do
      bytes when is_integer(bytes) -> bytes
      # `:oversized` is a real answer for anything holding builtin closures;
      # recording it as a number would invent a measurement.
      :oversized -> nil
    end
  end

  # ── workloads ────────────────────────────────────────────────────────────

  # Generic and domain-blind, per the repository prompt rules: the component
  # bodies name nothing but their own index.
  defp components(count) do
    Enum.map(0..(count - 1), fn index ->
      {:ok, component} =
        Component.new(
          id: "bench.c#{index}",
          source: """
          (ns bench.c#{index})
          (defn value [x] (+ x #{index}))
          (defn twice [x] (value (value x)))
          """,
          origin: "bench"
        )

      component
    end)
  end

  defp kernel_entry(:plain), do: "(return (bench.c0/twice data/seed))"
  defp kernel_entry(:capabilities), do: ~S|(return (bench.cap/probe data/seed))|

  # The bundle and both environments are durable host artifacts, built once and
  # reused across runs; only the sink and the one-shot `RunConfig` are per-run.
  # Compiling the bundle inside the loop would make this row a `compile_bundle`
  # row wearing a different name.
  #
  # `EventSink.stop/1` is part of the unit. `Runner` finalizes the sink but
  # never stops it — the sink outlives the run precisely so the host can read
  # its events, and it only dies with its owner. A loop that never stops one
  # accumulates a process per run, and the residual would measure this
  # harness's omission rather than anything about PtcRunner.
  defp kernel_unit(shape) do
    {:ok, bundle} = Kernel.compile_bundle(bundle_components(shape))
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: capabilities(shape))
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    entry = kernel_entry(shape)

    fn ->
      {:ok, sink} = EventSink.start(:normal, limits, run_id: "bench-heap")

      {:ok, config} =
        RunConfig.new(
          workflow_environment: workflow,
          missions: %{"default" => mission},
          input: %{"seed" => 3},
          limits: limits,
          event_sink: sink
        )

      {:ok, result} = Kernel.run(entry, config)
      :ok = EventSink.stop(sink)
      result
    end
  end

  defp bundle_components(:plain), do: components(1)

  defp bundle_components(:capabilities) do
    {:ok, component} =
      Component.new(
        id: "bench.cap",
        source: """
        (ns bench.cap)
        (defn probe [x] (tool/bench-probe {"seed" x}))
        """,
        origin: "bench"
      )

    [component]
  end

  defp capabilities(:plain), do: []

  defp capabilities(:capabilities) do
    {:ok, capability} =
      Capability.new(
        name: "bench-probe",
        description: "Echoes its argument back to the caller.",
        effect: :read,
        input_schema: %{"type" => "object"},
        callback: fn arguments -> {:ok, arguments} end
      )

    [capability]
  end

  # ── comparison and printing ──────────────────────────────────────────────

  defp compare(rows, baseline, threshold \\ nil) do
    threshold = threshold || baseline["threshold"] || @default_threshold
    by_name = Map.new(baseline["rows"], &{&1["name"], &1})

    Enum.flat_map(rows, fn row ->
      case Map.fetch(by_name, row["name"]) do
        :error ->
          ["#{row["name"]}: no baseline row (run mix bench.heap --write-baseline)"]

        {:ok, expected} ->
          compare_metrics(row, expected["metrics"] || %{}, threshold)
      end
    end)
  end

  defp compare_metrics(row, expected_metrics, threshold) do
    Enum.flat_map(row["metrics"], fn {metric, actual} ->
      expected = Map.get(expected_metrics, metric)

      if comparable?(actual, expected) and exceeds?(actual, expected, metric, threshold) do
        [
          "#{row["name"]} #{metric}: #{fmt(actual)} > #{fmt(allowed(expected, metric, threshold))} " <>
            "(baseline #{fmt(expected)})"
        ]
      else
        []
      end
    end)
  end

  defp comparable?(actual, expected),
    do: is_number(actual) and is_number(expected)

  defp exceeds?(actual, expected, metric, threshold),
    do: metric not in @diagnostic_metrics and actual > allowed(expected, metric, threshold)

  # `max(expected, 0)` because a residual rate is legitimately negative on a
  # quiet run. Multiplying a negative baseline by the threshold would *tighten*
  # the allowance the further below zero the baseline sat, which is backwards;
  # a negative baseline should contribute no slack and take none away.
  defp allowed(expected, metric, threshold),
    do: max(expected, 0) * threshold + Map.get(@metric_floors, metric, 0)

  defp print_table(rows, baseline, mode) do
    Mix.shell().info("")
    Mix.shell().info("Heap baseline (#{mode}); recorded on #{provenance_line(baseline)}")
    Mix.shell().info("")
    Mix.shell().info("| Row | Metric | Measured | Baseline |")
    Mix.shell().info("|---|---|---:|---:|")

    by_name = Map.new(baseline["rows"] || [], &{&1["name"], &1})

    Enum.each(rows, fn row ->
      expected = get_in(by_name, [row["name"], "metrics"]) || %{}

      row["metrics"]
      |> Enum.sort_by(fn {metric, _} -> metric end)
      |> Enum.each(fn {metric, actual} ->
        Mix.shell().info(
          "| #{row["name"]} | #{metric} | #{fmt(actual)} | #{fmt(Map.get(expected, metric))} |"
        )
      end)
    end)

    Mix.shell().info("")
  end

  defp provenance_line(baseline) do
    provenance = baseline["provenance"] || %{}

    "OTP #{provenance["otp"] || "?"} / #{provenance["architecture"] || "?"} / " <>
      "#{provenance["schedulers_online"] || "?"} schedulers / commit " <>
      String.slice(to_string(provenance["commit"] || "unknown"), 0, 8)
  end

  defp fmt(nil), do: "-"
  defp fmt(value) when is_integer(value), do: Integer.to_string(value)
  defp fmt(value) when is_float(value), do: Float.to_string(Float.round(value, 3))
  defp fmt(value), do: inspect(value)
end
