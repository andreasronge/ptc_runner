defmodule PtcRunner.OneShotFrontend do
  @moduledoc false

  alias PtcRunner.ReplFrontend
  alias PtcRunner.TranscriptFrontend
  alias PtcRunner.ViewerFrontend

  @doc false
  def run(%{command: :repl} = arguments, runtime, frontend_opts),
    do: ReplFrontend.run(arguments, runtime, frontend_opts)

  def run(%{command: :transcript} = arguments, runtime, _frontend_opts),
    do: TranscriptFrontend.run(arguments, runtime)

  def run(%{command: :viewer} = arguments, runtime, _frontend_opts),
    do: ViewerFrontend.run(arguments, runtime)
end
