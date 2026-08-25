defmodule Mix.Tasks.Ptc.MeasureSealedEvidence do
  @shortdoc "Measure the sealed evidence log + ETS index prototype"
  @moduledoc """
  Runs the issue #1646 measurement harness.

      mix ptc.measure_sealed_evidence
      mix ptc.measure_sealed_evidence --full
      mix ptc.measure_sealed_evidence --max-records 10000

  `--full` enables the 128/256/512 MiB payload ladder and the record-count
  ladder up to 1_000_000, stopping at `--max-records` when supplied. Ordinary
  focused tests never invoke this task.
  """

  use Mix.Task

  alias PtcRunner.Research.SealedEvidenceLog.Measure

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [full: :boolean, max_records: :integer])

    result = Measure.run(opts)
    Mix.shell().info(inspect(result, pretty: true, limit: :infinity, printable_limit: :infinity))
    :ok
  end
end
