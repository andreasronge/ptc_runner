defmodule Mix.Tasks.Ptc.Run do
  @shortdoc "Runs one strict PTC Kernel application"
  @moduledoc """
  Runs one V1 Kernel application through the stable shared command boundary.

      mix ptc.run ptc.json
      mix ptc.run ptc.json --input alternate-input.json
      mix ptc.run ptc.json --private-input private-input.json \
        --private-output result.json
      mix ptc.run ptc.json --trace-dir traces --inspect inspection.jsonl
      mix ptc.run ptc.json --output results/answer.json
      mix ptc.run ptc.json --host-config ptc-host.json
      mix ptc.run ptc.json --host-config ptc-host.json --authorize-mcp workspace
      mix ptc.run ptc.json --component-override-descriptor private/candidate.json

  The task delegates startup and its repeatable `--authorize-mcp NAME`
  extension to its Mix-owned adapter, then delegates the stable grammar,
  acquisition, execution, publication, and outcome projection to
  `PtcRunner.Kernel.CommandEngine`. The authorization extension opens
  interactive OAuth for the named selected MCP installation during the
  immediately following run.

  Both successful and failed invocations render the same closed V1 JSON
  envelope. A failed envelope is raised as the `Mix.Error` message so an
  embedding can inspect it without traversing internal failure terms.

  Private values are never rendered. They require `--private-output`; the
  envelope reports only their class and artifact state.
  """
  use Mix.Task

  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.MixRunAdapter

  @impl Mix.Task
  def run(args) do
    {status, outcome} = MixRunAdapter.dispatch(args)
    envelope = outcome |> CommandOutcome.to_map() |> Jason.encode!()

    if status == :ok do
      Mix.shell().info(envelope)
      outcome
    else
      Mix.raise(envelope)
    end
  end
end
