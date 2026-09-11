# Summarises the JSON lines that PtcRunner.TestSupport.RunRecord appends per
# suite run: how many runs failed, which tests failed how often and under
# which seeds, and the wall/async/sync spread. Invoked by flake-hunt.sh; runs
# under plain `elixir` so it needs nothing from the project.

# Exit status is the hunt's verdict: 0 only when every expected run left a
# record, every recorded exit status is zero, and no test failed.

defmodule FlakeHuntSummary do
  def main([path | options]) do
    opts = parse(options, %{expected: 0, verdicts: []})

    case File.read(path) do
      {:ok, contents} ->
        records =
          contents
          |> String.split("\n", trim: true)
          |> Enum.map(&:json.decode/1)

        report(records, opts)

      {:error, reason} ->
        IO.puts("flake-hunt: no run records at #{path} (#{:file.format_error(reason)})")
        System.halt(65)
    end
  end

  def main(_argv), do: usage()

  defp parse([], opts), do: opts
  defp parse(["--expected", n | rest], opts), do: parse(rest, %{opts | expected: String.to_integer(n)})

  defp parse(["--verdicts", file | rest], opts) do
    verdicts =
      file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        [run, status] = String.split(line, " ")
        {String.to_integer(run), String.to_integer(status)}
      end)

    parse(rest, %{opts | verdicts: verdicts})
  end

  defp parse(_other, _opts), do: usage()

  defp usage do
    IO.puts("usage: elixir flake_hunt_summary.exs RUNS.jsonl [--expected RUNS] [--verdicts FILE]")
    System.halt(64)
  end

  defp report([], _opts) do
    IO.puts("flake-hunt: the record file is empty")
    System.halt(65)
  end

  defp report(records, opts) do
    # Each record names its run (PTC_TEST_RUN_INDEX); records from a plain
    # `mix test` are numbered by position. Verdicts and records are then
    # paired per run, never by subtracting aggregate counts.
    records =
      records
      |> Enum.with_index(1)
      |> Enum.map(fn {record, position} -> Map.put_new_lazy(record, "run", fn -> position end) end)
      |> Enum.map(fn record -> if is_integer(record["run"]), do: record, else: %{record | "run" => nil} end)

    by_run = Map.new(records, &{&1["run"], &1})
    verdicts = Map.new(opts.verdicts)
    expected = max(opts.expected, records |> Enum.map(& &1["run"]) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> 0 end))
    schedulers = records |> Enum.map(& &1["schedulers"]) |> Enum.uniq() |> Enum.join(",")

    # A run that dies before `suite_finished` -- a compile error, a VM crash,
    # a killed job -- leaves no record, and Mix can report a failed run after
    # a failure-free record -- a warning under --warnings-as-errors, a crash
    # on shutdown. Both are failed runs, and a table that counted only the
    # survivors would hide exactly the runs a flake investigation most wants.
    runs =
      for run <- 1..expected//1 do
        record = by_run[run]
        status = Map.get(verdicts, run, 0)

        cond do
          is_nil(record) -> {run, :no_record, status}
          record["failures"] != [] -> {run, :failed, status}
          status != 0 -> {run, :nonzero_exit, status}
          true -> {run, :passed, status}
        end
      end

    failed_runs = Enum.count(runs, fn {_run, outcome, _status} -> outcome != :passed end)

    IO.puts(
      "flake-hunt: #{length(records)} runs, #{schedulers} schedulers, " <>
        "#{failed_runs} with failures"
    )

    for {run, :no_record, status} <- runs do
      IO.puts("  run #{run} left no record (exit #{status}): it ended before the suite finished")
    end

    for {run, :nonzero_exit, status} <- runs do
      IO.puts("  run #{run} exited #{status} with a failure-free record")
    end

    records
    |> Enum.flat_map(fn record ->
      Enum.map(record["failures"], &{&1["file"], &1["line"], &1["module"], &1["name"], record["seed"], &1["message"]})
    end)
    |> Enum.group_by(fn {file, line, module, name, _seed, _message} -> {file, line, module, name} end)
    |> Enum.map(fn {key, hits} -> {length(hits), key, hits} end)
    |> Enum.sort_by(fn {count, {file, line, _, _}, _} -> {-count, file, line} end)
    |> Enum.each(fn {count, {file, line, module, name}, hits} ->
      seeds = hits |> Enum.map(&elem(&1, 4)) |> Enum.join(", ")
      {_, _, _, _, _, message} = hd(hits)
      IO.puts("  #{count}x  #{file}:#{line}  #{module}  #{name}")
      IO.puts("       seeds: #{seeds}")
      IO.puts("       #{message}")
    end)

    for {label, key} <- [{"wall", "wall_ms"}, {"async", "async_ms"}, {"sync", "sync_ms"}] do
      values = records |> Enum.map(& &1[key]) |> Enum.sort()
      median = Enum.at(values, div(length(values), 2))

      IO.puts(
        "  #{String.pad_trailing(label, 5)} min #{seconds(hd(values))}  " <>
          "median #{seconds(median)}  max #{seconds(List.last(values))}"
      )
    end

    if failed_runs > 0, do: System.halt(1)
  end

  defp seconds(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 1) <> "s"
end

FlakeHuntSummary.main(System.argv())
