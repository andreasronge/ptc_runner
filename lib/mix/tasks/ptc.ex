defmodule Mix.Tasks.Ptc do
  @shortdoc "Runs the stable PTC command surface"
  @moduledoc """
  Runs any stable PTC command through the shared parser and frontend:

      mix ptc help
      mix ptc init DIRECTORY
      mix ptc validate ptc.json
      mix ptc run ptc.json --input alternate-input.json
      mix ptc doctor ptc.json --host-config ptc-host.json --connect
      mix ptc models --host-config ptc-host.json

  Use `mix ptc help COMMAND` to list every switch accepted by a command.
  `--envelope PATH` atomically publishes the machine-readable V1 envelope;
  without it, the task prints the shared human rendering.
  """
  use Mix.Task

  alias PtcRunner.MixCommandAdapter

  @impl Mix.Task
  def run(args), do: MixCommandAdapter.run_task(args, :exit).outcome
end
