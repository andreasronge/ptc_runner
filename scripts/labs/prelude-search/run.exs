directory = __DIR__
Code.require_file("support/mutations.exs", directory)
Code.require_file("support/inputs.exs", directory)
Code.require_file("support/lab.exs", directory)
Code.require_file("support/statistics.exs", directory)
Code.require_file("support/phase1.exs", directory)

{options, arguments, invalid} =
  OptionParser.parse(System.argv(),
    strict: [
      phase: :integer,
      instances: :integer,
      budget_microusd: :integer,
      replay: :boolean,
      partial_replay: :boolean,
      request_timeout_ms: :integer,
      fixtures: :string,
      replay_artifacts: :string,
      subject: :string,
      seed: :integer,
      executions: :integer,
      output: :string
    ]
  )

if arguments != [] or invalid != [] or
     (Keyword.get(options, :phase) not in [0, 1] and
        not Keyword.has_key?(options, :replay_artifacts)) do
  raise "usage: mix run scripts/labs/prelude-search/run.exs --phase 0 [--subject NAME] [--seed N] [--executions N] [--output DIRECTORY]"
end

subjects =
  case Keyword.get(options, :subject) do
    nil -> PtcRunner.Labs.PreludeSearch.subjects()
    subject -> [subject]
  end

output =
  Keyword.get_lazy(options, :output, fn ->
    suffix = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    Path.join(System.tmp_dir!(), "ptc-prelude-search-#{suffix}")
  end)

if Keyword.get(options, :phase) == 1 do
  results =
    PtcRunner.Labs.PreludeSearch.Phase1.run(
      Keyword.merge(options, output: output, subjects: subjects)
    )

  IO.puts(Jason.encode!(PtcRunner.Labs.PreludeSearch.Phase1.report(results), pretty: true))
  IO.puts("Artifacts: #{output}")
  summary = output |> Path.join("summary.json") |> File.read!() |> Jason.decode!()

  if summary["stop_reason"],
    do: raise("experiment stopped: #{summary["stop_reason"]}; evidence finalized in #{output}")
else
  {:ok, results} =
    case Keyword.fetch(options, :replay_artifacts) do
      {:ok, directory} ->
        PtcRunner.Labs.PreludeSearch.replay(Path.expand(directory))

      :error ->
        PtcRunner.Labs.PreludeSearch.run(
          output: output,
          subjects: subjects,
          seed: Keyword.get(options, :seed, 20_260_917),
          executions: Keyword.get(options, :executions, 100)
        )
    end

  IO.puts("| subject | executions | equal | unequal | milliseconds per re-execution |")
  IO.puts("| --- | ---: | ---: | ---: | ---: |")

  Enum.each(results, fn result ->
    IO.puts(
      "| #{result.subject} | #{result.executions} | #{result.equal} | #{length(result.unequal)} | #{result.milliseconds_per_reexecution} |"
    )
  end)

  IO.puts("\nArtifacts: #{Path.expand(Keyword.get(options, :replay_artifacts, output))}")

  case Enum.flat_map(results, & &1.unequal) do
    [] -> :ok
    findings -> raise "unequal re-executions: #{inspect(findings)}"
  end
end
