defmodule Mix.Tasks.Ptc.Repl do
  @shortdoc "Bounded direct or profile-backed PTC-Lisp REPL"
  @moduledoc "Use `mix ptc repl [OPTIONS] [SCRIPT|-]`; this alias uses the same shared parser."
  use Mix.Task

  alias PtcRunner.MixCommandAdapter

  @impl Mix.Task
  def run(args), do: MixCommandAdapter.run_task(["repl" | args], :raise).outcome
end
