directory = __DIR__
Code.require_file("support/mutations.exs", directory)
Code.require_file("support/inputs.exs", directory)
Code.require_file("support/lab.exs", directory)

{options, arguments, invalid} =
  OptionParser.parse(System.argv(),
    strict: [
      phase: :integer,
      subject: :string,
      seed: :integer,
      executions: :integer,
      output: :string
    ]
  )

if arguments != [] or invalid != [] or Keyword.get(options, :phase) != 0 do
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

{:ok, results} =
  PtcRunner.Labs.PreludeSearch.run(
    output: output,
    subjects: subjects,
    seed: Keyword.get(options, :seed, 20_260_917),
    executions: Keyword.get(options, :executions, 100)
  )

IO.puts("| subject | executions | equal | unequal | milliseconds per re-execution |")
IO.puts("| --- | ---: | ---: | ---: | ---: |")

Enum.each(results, fn result ->
  IO.puts(
    "| #{result.subject} | #{result.executions} | #{result.equal} | #{length(result.unequal)} | #{result.milliseconds_per_reexecution} |"
  )
end)

IO.puts("\nArtifacts: #{Path.expand(output)}")

case Enum.flat_map(results, & &1.unequal) do
  [] -> :ok
  findings -> raise "unequal re-executions: #{inspect(findings)}"
end
