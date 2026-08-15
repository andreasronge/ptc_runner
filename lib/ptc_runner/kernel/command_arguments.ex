defmodule PtcRunner.Kernel.CommandArguments do
  @moduledoc """
  Parsed standalone command arguments.

  Acquisition paths remain confined to this command-boundary value and are
  consumed before `RunCoordinator`. Artifact destinations are captured against
  the invocation working directory after parsing. `run` destinations move into
  the sealed phase-6 command continuation; one-shot `repl` and `transcript`
  destinations remain on the arguments passed to their dedicated frontends.
  """

  @enforce_keys [
    :command,
    :application,
    :directory,
    :options,
    :ordered_options,
    :frontend,
    :frontend_options
  ]
  defstruct @enforce_keys ++ [project: nil]

  @type command ::
          :help | :version | :init | :validate | :run | :doctor | :models | :transcript | :repl
  @type t :: %__MODULE__{
          command: command(),
          application: binary() | nil,
          directory: binary() | nil,
          options: map(),
          ordered_options: keyword(),
          frontend: :standalone | :mix,
          frontend_options: keyword(),
          project: term()
        }
end
