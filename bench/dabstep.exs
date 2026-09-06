Code.require_file("support/dabstep.exs", __DIR__)
Code.require_file("support/heap.exs", __DIR__)

defmodule PtcRunner.Bench.Dabstep do
  @moduledoc false

  alias PtcRunner.Kernel.{CommandEngine, ManifestRepl, ReplSession}

  @page ~S|(let [page (dabstep.payments/read-page nil ["ip_country" "eur_amount" "has_fraudulent_dispute"])] (count (get page "rows")))|
  @scan ~S|(loop [cursor nil rows 0 pages 0] (let [page (dabstep.payments/read-page cursor ["ip_country" "eur_amount" "has_fraudulent_dispute"]) rows (+ rows (count (get page "rows"))) pages (inc pages) next (get page "next_cursor")] (if next (recur next rows pages) {"rows" rows "pages" pages})))|

  def run(args) do
    {opts, [], []} =
      OptionParser.parse(args,
        strict: [mode: :string, samples: :integer, profile: :string]
      )

    mode = Keyword.get(opts, :mode, "page")
    samples = Keyword.get(opts, :samples, 5)
    root = Path.expand("examples/dabstep-fraud")
    true = mode in ["page", "scan", "replay"] and samples > 0
    true = File.regular?(Path.join(root, "data/payments.csv"))

    table = :ets.new(:dabstep_benchmark, [:public, :set])
    handler = {__MODULE__, self()}

    :ok =
      :telemetry.attach(
        handler,
        [:ptc_runner, :capability, :stop],
        &PtcRunner.Bench.DabstepSupport.capability/4,
        table
      )

    try do
      if profile = opts[:profile] do
        profile(root, mode, profile)
      else
        measure(root, mode, samples, table)
      end
    after
      :telemetry.detach(handler)
      :ets.delete(table)
    end
  end

  defp measure(root, "replay", samples, table) do
    for sample <- 1..samples do
      measured(table, %{mode: "replay", sample: sample}, fn -> replay(root) end)
    end
  end

  defp measure(root, mode, samples, table) do
    {open_us, session} = :timer.tc(fn -> open(root) end)
    emit(%{mode: mode, open_ms: open_us / 1000})

    try do
      measured(table, %{mode: mode, sample: "cold"}, fn -> evaluate(session, mode) end)

      for sample <- 1..samples do
        measured(table, %{mode: mode, sample: sample}, fn -> evaluate(session, mode) end)
      end
    after
      ReplSession.close(session)
    end
  end

  defp measured(table, labels, fun) do
    :ets.delete_all_objects(table)
    {gc_before, words_before, _} = :erlang.statistics(:garbage_collection)
    {micros, result} = :timer.tc(fun)
    {gc_after, words_after, _} = :erlang.statistics(:garbage_collection)

    capabilities =
      Enum.map(:ets.tab2list(table), fn {name, calls, duration} ->
        %{name: name, calls: calls, duration_ms: duration}
      end)

    emit(
      Map.merge(labels, %{
        wall_ms: micros / 1000,
        vm_gc_count: gc_after - gc_before,
        vm_gc_reclaimed_words: words_after - words_before,
        capabilities: capabilities,
        result: result
      })
    )
  end

  defp profile(root, mode, "heap") do
    PtcRunner.Bench.Heap.measure(fn -> work(root, mode) end) |> emit()
  end

  defp profile(root, mode, type), do: trace_profile(root, mode, type)

  defp trace_profile(root, mode, type) do
    type =
      case type do
        "time" -> :call_time
        "memory" -> :call_memory
      end

    [to_string(:code.root_dir()), "lib", "tools-*", "ebin"]
    |> Path.join()
    |> Path.wildcard()
    |> hd()
    |> Code.append_path()

    apply(:tprof, :profile, [
      fn -> work(root, mode) end,
      %{type: type, rootset: :all, report: :total}
    ])
  end

  defp work(root, "replay"), do: replay(root)

  defp work(root, mode) do
    session = open(root)

    try do
      evaluate(session, mode)
    after
      ReplSession.close(session)
    end
  end

  defp open(root) do
    {:ok, session} =
      ManifestRepl.open(
        Path.join(root, "ptc.json"),
        Path.join(root, "ptc-host.replay.json"),
        mission: "analysis",
        input_mode: :eval
      )

    session
  end

  defp evaluate(session, mode) do
    {:ok, result, _session} =
      ReplSession.eval(session, if(mode == "page", do: @page, else: @scan))

    expected = if mode == "page", do: 2847, else: %{"rows" => 138_236, "pages" => 49}
    ^expected = result.return
    result.return
  end

  defp replay(root) do
    {:ok, outcome} =
      CommandEngine.dispatch([
        "run",
        Path.join(root, "ptc-project.replay.json"),
        "--input",
        "inputs/luna.json"
      ])

    0 = outcome.exit_status
    %{"value" => "B. BE", "agreed" => true} = outcome.envelope["result"]["value"]
    outcome.envelope["result"]["value"]
  end

  defp emit(value), do: IO.puts(Jason.encode!(value))
end

PtcRunner.Bench.Dabstep.run(System.argv())
