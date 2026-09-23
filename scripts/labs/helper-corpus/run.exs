root = Path.expand("..", __DIR__)
Code.require_file("prelude-search/support/mutations.exs", root)
Code.require_file("prelude-search/support/inputs.exs", root)
Code.require_file("prelude-search/support/lab.exs", root)
Code.require_file("support/corpus.exs", __DIR__)

{opts, args, invalid} =
  OptionParser.parse(System.argv(), strict: [output: :string, replay_artifacts: :string])

if args != [] or invalid != [], do: raise("invalid helper-corpus arguments")

case Keyword.fetch(opts, :replay_artifacts) do
  {:ok, directory} ->
    {:ok, results} = PtcRunner.Labs.PreludeSearch.replay(Path.expand(directory))
    if Enum.any?(results, &(&1.unequal != [])), do: raise("helper corpus replay unequal")
    IO.puts("Replay equal: #{Enum.sum(Enum.map(results, & &1.equal))}")

  :error ->
    output = Path.expand(Keyword.get(opts, :output, Path.join(__DIR__, "corpus")))
    PtcRunner.Labs.HelperCorpus.generate(output)
    IO.puts("Corpus: #{output}")
end
