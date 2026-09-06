Code.require_file("support/heap.exs", __DIR__)
Code.require_file("support/dabstep.exs", __DIR__)

defmodule PtcRunner.Bench.DabstepScaling do
  @moduledoc false
  alias PtcRunner.Bench.DabstepSupport, as: Bench
  alias PtcRunner.Kernel.{CommandEngine, ManifestRepl, ReplSession}
  @narrow ["ip_country", "eur_amount", "has_fraudulent_dispute"]
  @fold ~S|
  (defn bench-fold [columns step initial]
    (loop [cursor nil acc initial pages 0]
      (let [page (read-page cursor columns)
            value (reduce step acc (get page "rows"))
            next (get page "next_cursor")]
        (if next (recur next value (inc pages))
          {"rows" value "pages" (inc pages)}))))
  |

  def run(args) do
    {opts, [], []} =
      OptionParser.parse(args, strict: [suite: :string, samples: :integer, rows: :integer])

    suite = opts[:suite] || "kernel"
    samples = opts[:samples] || if(suite == "scale", do: 1, else: 2)
    source = File.read!("examples/dabstep-fraud/payments.clj")
    {:ok, file} = File.open("examples/dabstep-fraud/data/payments.csv")
    headers = file |> IO.read(:line) |> String.trim() |> String.split(",")
    File.close(file)

    case suite do
      "kernel" ->
        for {variant, body} <- [{"current", source}, {"prepared", Bench.prepared(source)}] do
          root = fixture(variant, body <> @fold, nil, headers)

          session(root, fn session ->
            for mode <- ["page", "scan", "manual_reduce", "fold"] do
              measure(
                session,
                "#{variant}/#{mode}",
                program(mode, @narrow),
                if(mode == "page", do: 2847, else: 138_236),
                samples
              )
            end
          end)
        end

      "scale" ->
        for rows <- if(opts[:rows], do: [opts[:rows]], else: [20_000, 80_000, 320_000]) do
          root = fixture("synthetic-#{rows}", source <> @fold, rows, headers)

          for columns <- [@narrow, headers] do
            session(root, fn session ->
              measure(
                session,
                "scale/#{rows}/#{length(columns)}",
                program("fold", columns),
                rows,
                samples
              )
            end)
          end
        end

      "replay" ->
        root = fixture("prepared-replay", Bench.prepared(source), nil, headers)

        for sample <- 1..samples do
          if sample == 2 do
            csv = Path.join(root, "data/payments.csv")
            File.rename!(csv, csv <> ".previous")
            File.cp!(csv <> ".previous", csv)
            true = File.stat!(csv).inode != File.stat!(csv <> ".previous").inode
            File.rm!(csv <> ".previous")
          end

          {us, {:ok, outcome}} =
            :timer.tc(fn ->
              CommandEngine.dispatch([
                "run",
                Path.join(root, "ptc-project.replay.json"),
                "--input",
                "inputs/luna.json"
              ])
            end)

          0 = outcome.exit_status

          11 =
            Enum.sum(Enum.map(outcome.envelope["execution"]["usage"]["llm_usage"], & &1["calls"]))

          %{"value" => "B. BE", "agreed" => true} = outcome.envelope["result"]["value"]

          IO.puts(
            Jason.encode!(%{
              experiment: "prepared/replay",
              recorded_model_calls: 11,
              identical_file_replaced: sample == 2,
              sample: sample,
              wall_ms: us / 1000,
              result: outcome.envelope["result"]["value"]
            })
          )
        end

        reject_changed_byte(root)
    end
  end

  defp reject_changed_byte(root) do
    csv = Path.join(root, "data/payments.csv")
    {:ok, file} = :file.open(String.to_charlist(csv), [:read, :write, :binary])
    {:ok, size} = :file.position(file, :eof)
    {:ok, <<byte>>} = :file.pread(file, size - 1, 1)
    :ok = :file.pwrite(file, size - 1, <<Bitwise.bxor(byte, 1)>>)

    try do
      {:error, failed} =
        CommandEngine.dispatch([
          "run",
          Path.join(root, "ptc-project.replay.json"),
          "--input",
          "inputs/luna.json"
        ])

      5 = failed.exit_status
      "explicit_failure" = failed.envelope["error"]["code"]

      IO.puts(
        Jason.encode!(%{
          experiment: "prepared/changed_byte",
          exit_status: failed.exit_status,
          code: failed.envelope["error"]["code"]
        })
      )
    after
      :ok = :file.pwrite(file, size - 1, <<byte>>)
      :file.close(file)
    end
  end

  defp fixture(label, source, rows, headers) do
    original = Path.expand("examples/dabstep-fraud")
    root = Path.expand("tmp/profiling/followup/fixtures/#{label}")
    File.mkdir_p!(Path.join(root, "data"))

    for path <- Path.wildcard(Path.join(original, "*")),
        File.regular?(path),
        do: File.cp!(path, Path.join(root, Path.basename(path)))

    File.cp_r!(Path.join(original, "inputs"), Path.join(root, "inputs"))
    File.write!(Path.join(root, "payments.clj"), source)
    csv = Path.join(root, "data/payments.csv")

    if rows do
      {:ok, file} = File.open(csv, [:write, :binary])
      IO.binwrite(file, Enum.join(headers, ",") <> "\n")
      # Generated rows are streamed to disk; no whole-table host or mission collection.
      for i <- 1..rows do
        values =
          Enum.map(headers, fn
            c when c in ["year", "hour_of_day", "minute_of_hour", "day_of_year"] ->
              Integer.to_string(rem(i, 24))

            "eur_amount" ->
              "#{rem(i, 1000)}.25"

            c when c in ["is_credit", "has_fraudulent_dispute", "is_refused_by_adyen"] ->
              if(rem(i, 2) == 0, do: "True", else: "False")

            _ ->
              "synthetic-value-#{rem(i, 100)}"
          end)

        IO.binwrite(file, Enum.join(values, ",") <> "\n")
      end

      File.close(file)
    else
      File.cp!(Path.join(original, "data/payments.csv"), csv)
    end

    host_path = Path.join(root, "ptc-host.replay.json")
    host = host_path |> File.read!() |> Jason.decode!()
    args = get_in(host, ["install", "payments_data", "transport", "args"])
    ceiling = max(24_000_000, File.stat!(csv).size + 1)

    args =
      Enum.map(args, fn
        "24000000" -> Integer.to_string(ceiling)
        arg -> arg
      end)

    host = put_in(host, ["install", "payments_data", "transport", "args"], args)
    File.write!(host_path, Jason.encode!(host))

    IO.puts(
      Jason.encode!(%{
        fixture: label,
        rows: rows || 138_236,
        bytes: File.stat!(csv).size,
        hash_ceiling_bytes: ceiling,
        mission_heap_words: 5_000_000
      })
    )

    root
  end

  defp session(root, fun) do
    {us, {:ok, session}} =
      :timer.tc(fn ->
        ManifestRepl.open(Path.join(root, "ptc.json"), Path.join(root, "ptc-host.replay.json"),
          mission: "analysis",
          input_mode: :eval
        )
      end)

    IO.puts(Jason.encode!(%{open_ms: us / 1000, fixture: Path.basename(root)}))

    table = :ets.new(:scaling_capabilities, [:public, :set])
    handler = {__MODULE__, self()}

    :ok =
      :telemetry.attach(
        handler,
        [:ptc_runner, :capability, :stop],
        &PtcRunner.Bench.DabstepSupport.capability/4,
        table
      )

    try do
      fun.({session, table})
    after
      :telemetry.detach(handler)
      :ets.delete(table)
      ReplSession.close(session)
    end
  end

  defp measure({session, _table} = measured_session, label, source, expected, samples) do
    if System.get_env("DABSTEP_BENCH_HEAP") == "1" do
      heap =
        PtcRunner.Bench.Heap.measure(fn ->
          {:ok, result, _} = ReplSession.eval(session, source)
          ^expected = result.return["rows"]
        end)

      IO.puts(Jason.encode!(Map.put(heap, :experiment, label)))
    else
      samples(measured_session, label, source, expected, samples)
    end
  end

  defp samples({session, table}, label, source, expected, samples) do
    for sample <- 0..samples do
      :ets.delete_all_objects(table)
      {gc0, words0, _} = :erlang.statistics(:garbage_collection)
      {us, {:ok, result, _}} = :timer.tc(fn -> ReplSession.eval(session, source) end)
      actual = if is_map(result.return), do: result.return["rows"], else: result.return
      ^expected = actual
      {gc1, words1, _} = :erlang.statistics(:garbage_collection)

      IO.puts(
        Jason.encode!(%{
          experiment: label,
          capabilities:
            Enum.map(:ets.tab2list(table), fn {name, calls, ms} ->
              %{name: name, calls: calls, duration_ms: ms}
            end),
          sample: sample,
          wall_ms: us / 1000,
          result: result.return,
          gc_count: gc1 - gc0,
          reclaimed_words: words1 - words0
        })
      )
    end
  end

  defp program("page", columns),
    do: "(count (get (dabstep.payments/read-page nil #{Jason.encode!(columns)}) \"rows\"))"

  defp program("fold", columns),
    do: "(dabstep.payments/bench-fold #{Jason.encode!(columns)} (fn [n row] (inc n)) 0)"

  defp program(mode, columns) do
    value =
      if mode == "scan",
        do: "(+ rows (count (get page \"rows\")))",
        else: "(reduce (fn [n row] (inc n)) rows (get page \"rows\"))"

    "(loop [cursor nil rows 0 pages 0] (let [page (dabstep.payments/read-page cursor #{Jason.encode!(columns)}) rows #{value} pages (inc pages) next (get page \"next_cursor\")] (if next (recur next rows pages) {\"rows\" rows \"pages\" pages})))"
  end
end

PtcRunner.Bench.DabstepScaling.run(System.argv())
