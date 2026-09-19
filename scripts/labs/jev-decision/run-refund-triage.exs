lab = Path.expand("support/lab.exs", __DIR__)
Code.require_file(lab)

case PtcRunner.Examples.JevDecisionLab.run_refund_triage() do
  {:ok, result} ->
    IO.puts(Jason.encode!(result.value, pretty: true))

  {:error, error} ->
    IO.puts(:stderr, inspect(error, pretty: true))
    System.halt(1)
end
