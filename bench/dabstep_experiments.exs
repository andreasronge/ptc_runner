Code.require_file("support/dabstep.exs", __DIR__)

defmodule PtcRunner.Bench.DabstepExperiments do
  @moduledoc false
  import PtcRunner.Bench.DabstepSupport, only: [prepared: 1, measure: 2]
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Prelude.Compiler
  @columns ["ip_country", "eur_amount", "has_fraudulent_dispute"]

  def run do
    source = File.read!("examples/dabstep-fraud/payments.clj")
    page = "tmp/profiling/followup/page.json" |> File.read!() |> Jason.decode!()
    text = Enum.map_join(page["items"], & &1["text"])
    lines = text |> String.split("\n") |> Enum.drop(1) |> Enum.drop(-1)
    headers = text |> String.split("\n", parts: 2) |> hd() |> String.split(",")
    columns = if System.get_env("DABSTEP_BENCH_WIDE") == "1", do: headers, else: @columns
    positions = Enum.map(columns, &Enum.find_index(headers, fn h -> h == &1 end))
    selectors = if length(columns) == 3, do: positions, else: Enum.zip(columns, positions)
    expected = native(lines, selectors)
    emit(%{fixture: %{rows: length(lines), bytes: byte_size(text), columns: columns}})

    variants = [{"current", source}, {"prepared_types", prepared(source)}]

    variants =
      if System.get_env("DABSTEP_BENCH_REVERSE") == "1",
        do: Enum.reverse(variants),
        else: variants

    paired? = System.get_env("DABSTEP_BENCH_PAIRED") == "1"

    prepared_variants =
      for {label, body} <- variants do
        {:ok, prelude} =
          Compiler.compile(
            body <> "\n(defn bench-project [columns lines] (project columns lines))"
          )

        opts = [
          prelude: prelude,
          context: %{"text" => text, "columns" => columns},
          tools: %{"workspace.read" => fn _ -> nil end},
          max_heap: 5_000_000,
          timeout: 60_000
        ]

        {:ok, result} =
          Lisp.run(
            "(dabstep.payments/bench-project data/columns (butlast (rest (split data/text \"\\n\"))))",
            opts
          )

        ^expected = result.return

        unless paired? do
          measure(label <> "/project", fn ->
            checked(
              "(count (dabstep.payments/bench-project data/columns (butlast (rest (split data/text \"\\n\")))))",
              opts,
              length(lines)
            )
          end)
        end

        page = %{
          status: :ok,
          value: %{
            "items" => [%{"text" => text}],
            "next_cursor" => "benchmark-cursor",
            "content_hash" => "benchmark-hash"
          }
        }

        read_opts = Keyword.put(opts, :tools, %{"workspace.read" => fn _ -> page end})

        unless paired? do
          measure(label <> "/read_page_stub", fn ->
            checked(
              "(count (get (dabstep.payments/read-page nil data/columns) \"rows\"))",
              read_opts,
              length(lines)
            )
          end)
        end

        edge_equivalence(prelude, opts, headers)
        {label, read_opts}
      end

    if paired? do
      for sample <- 0..6,
          {label, opts} <-
            if(rem(sample, 2) == 0, do: prepared_variants, else: Enum.reverse(prepared_variants)) do
        PtcRunner.Bench.DabstepSupport.sample("paired/#{label}/#{length(columns)}", sample, fn ->
          checked(
            "(count (get (dabstep.payments/read-page nil data/columns) \"rows\"))",
            opts,
            length(lines)
          )
        end)
      end
    else
      measure("native/split_project_type", fn -> length(native(lines, selectors)) end)

      unless System.get_env("DABSTEP_BENCH_PROFILE") || System.get_env("DABSTEP_BENCH_WIDE") do
        namespace_scaling()
        effect_context()
        cache_model()
      end
    end
  end

  defp edge_equivalence(prelude, opts, headers) do
    # Exercise every conversion kind, nil/empty cells and recoverable failures.
    columns = ["year", "eur_amount", "is_credit", "ip_country"]

    for {values, expected} <- [
          {["2024", "1.25", "True", "BE"], [[2024, 1.25, true, "BE"]]},
          {["", "", "", ""], [[nil, nil, nil, nil]]},
          {["-4", "0.0", "False", "DE"], [[-4, 0.0, false, "DE"]]},
          {["bad", "1.25", "True", "BE"], invalid("year", "invalid-number")},
          {["2024", "bad", "True", "BE"], invalid("eur_amount", "invalid-number")},
          {["2024", "1.25", "bad", "BE"], invalid("is_credit", "invalid-boolean")}
        ] do
      mapping = Map.new(Enum.zip(columns, values))
      line = Enum.map_join(headers, ",", &Map.get(mapping, &1, ""))

      probe_opts =
        Keyword.merge(opts, prelude: prelude, context: %{"lines" => [line], "columns" => columns})

      {:ok, result} =
        Lisp.run("(dabstep.payments/bench-project data/columns data/lines)", probe_opts)

      ^expected = result.return
    end
  end

  defp invalid(column, reason),
    do:
      {:__ptc_fail__,
       %{
         "status" => "error",
         "kind" => "invalid-payments-data",
         "column" => column,
         "reason" => reason
       }}

  defp native(lines, [country, amount, fraud]) do
    Enum.map(lines, fn line ->
      fields = String.split(line, ",")

      [
        Enum.at(fields, country),
        String.to_float(Enum.at(fields, amount)),
        Enum.at(fields, fraud) == "True"
      ]
    end)
  end

  defp native(lines, selectors) do
    Enum.map(lines, fn line ->
      fields = String.split(line, ",")

      Enum.map(selectors, fn {column, index} ->
        value = Enum.at(fields, index)

        cond do
          value in [nil, ""] ->
            nil

          column in ["year", "hour_of_day", "minute_of_hour", "day_of_year"] ->
            String.to_integer(value)

          column == "eur_amount" ->
            String.to_float(value)

          column in ["is_credit", "has_fraudulent_dispute", "is_refused_by_adyen"] ->
            value == "True"

          true ->
            value
        end
      end)
    end)
  end

  defp namespace_scaling do
    for bindings <- [0, 100, 1000, 5000], aliases <- [0, 20] do
      defs =
        if bindings == 0,
          do: "",
          else: Enum.map_join(1..bindings, "\n", &"(def binding#{&1} #{&1})")

      alias_defs =
        if aliases == 0, do: "", else: Enum.map_join(1..aliases, "\n", &"(def alias#{&1} f)")

      {:ok, setup} =
        Lisp.run("(defn f [x] (inc x))\n" <> defs <> "\n" <> alias_defs,
          max_heap: 5_000_000,
          timeout: 60_000
        )

      opts = [memory: setup.memory, max_heap: 5_000_000, timeout: 60_000]

      measure("namespace/#{bindings}/aliases/#{aliases}/builtin", fn ->
        checked("(loop [i 0] (if (< i 1000) (recur (inc i)) i))", opts, 1000)
      end)

      measure("namespace/#{bindings}/aliases/#{aliases}", fn ->
        checked("(loop [i 0] (if (< i 1000) (recur (f i)) i))", opts, 1000)
      end)
    end
  end

  defp effect_context do
    alias PtcRunner.Lisp.Eval.{Capture, Context, Effects, HostContext}
    callback = fn -> 42 end
    evaluator = fn ast, ctx -> {:ok, ast, ctx} end

    measure("host_context/plain_100000", fn ->
      for _ <- 1..100_000, reduce: 0 do
        n -> n + callback.()
      end
    end)

    for entries <- [0, 3, 100] do
      counts = if entries == 0, do: %{}, else: Map.new(1..entries, &{"bench/f#{&1}", 1})
      ctx = %Context{effects: %Effects{prelude_call_counts: counts}}

      work = fn ->
        for _ <- 1..100_000, reduce: 0 do
          n ->
            {:ok, 42, final} = HostContext.run_value(ctx, evaluator, callback)
            ^counts = final.effects.prelude_call_counts
            n + 42
        end
      end

      measure("host_context/#{entries}/100000", work)

      measure("host_context/#{entries}/nested_100000", fn ->
        {:ok, total, _ctx} = Capture.run_value(ctx, work)
        total
      end)
    end
  end

  defp cache_model do
    # Hit-count model only, not an implementation or timing of a real cache.
    for pages <- [49, 184], capacity <- [16, 49, 184] do
      {_, hits, misses} =
        Enum.reduce(1..3, {[], 0, 0}, fn _, state ->
          Enum.reduce(1..pages, state, fn page, {cache, hits, misses} ->
            hit? = page in cache
            cache = Enum.take([page | List.delete(cache, page)], capacity)
            {cache, hits + if(hit?, do: 1, else: 0), misses + if(hit?, do: 0, else: 1)}
          end)
        end)

      emit(%{
        experiment: "lru_hit_model",
        scan_pages: pages,
        capacity_pages: capacity,
        independent_passes: 3,
        hits: hits,
        misses: misses
      })
    end
  end

  defp checked(program, opts, expected) do
    {:ok, result} = Lisp.run(program, opts)
    ^expected = result.return
    Map.take(result.usage, [:eval_reductions, :memory_bytes])
  end

  defp emit(value), do: IO.puts(Jason.encode!(value))
end

PtcRunner.Bench.DabstepExperiments.run()
