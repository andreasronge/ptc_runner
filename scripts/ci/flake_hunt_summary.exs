# Summarises the JSON lines that PtcRunner.TestSupport.RunRecord appends per
# suite run: how many runs failed, which tests failed how often and under
# which seeds, and the wall/async/sync spread. Invoked by flake-hunt.sh; runs
# under plain `elixir` so it needs nothing from the project.

defmodule FlakeHuntSummary do
  def main([path]) do
    case File.read(path) do
      {:ok, contents} ->
        records =
          contents
          |> String.split("\n", trim: true)
          |> Enum.map(&:json.decode/1)

        report(records)

      {:error, reason} ->
        IO.puts("flake-hunt: no run records at #{path} (#{:file.format_error(reason)})")
        System.halt(65)
    end
  end

  def main(_argv) do
    IO.puts("usage: elixir flake_hunt_summary.exs RUNS.jsonl")
    System.halt(64)
  end

  defp report([]) do
    IO.puts("flake-hunt: the record file is empty")
    System.halt(65)
  end

  defp report(records) do
    failed_runs = Enum.count(records, &(&1["failures"] != []))
    schedulers = records |> Enum.map(& &1["schedulers"]) |> Enum.uniq() |> Enum.join(",")

    IO.puts(
      "flake-hunt: #{length(records)} runs, #{schedulers} schedulers, " <>
        "#{failed_runs} with failures"
    )

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
  end

  defp seconds(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 1) <> "s"
end

FlakeHuntSummary.main(System.argv())
