defmodule Mix.Tasks.Ptc do
  @shortdoc "Runs the stable PTC command surface"
  @moduledoc """
  Runs any stable PTC command through the shared parser and frontend:

      mix ptc help
      mix ptc init DIRECTORY
      mix ptc run DIRECTORY/ptc-project.json
      mix ptc validate ptc.json
      mix ptc run ptc.json --input alternate-input.json
      mix ptc doctor ptc.json --host-config ptc-host.json --connect
      mix ptc models --host-config ptc-host.json

  Use `mix ptc help COMMAND` to list every switch accepted by a command.
  The task always prints the shared human rendering. `--envelope PATH`
  additionally publishes the machine-readable V2 envelope atomically.
  Complete doctor readiness reports, including `readiness: "failed"`, are
  written to standard output. A failed readiness report retains its nonzero
  exit status; failures without a complete report are written to standard
  error. Runtime logger output, including TLS handshake alerts, is written
  to standard error so standard output remains one JSON document.
  """
  use Mix.Task

  alias PtcRunner.MixCommandAdapter

  @impl Mix.Task
  def run(args), do: MixCommandAdapter.run_task(args).outcome
end
