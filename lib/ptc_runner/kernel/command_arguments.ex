defmodule PtcRunner.Kernel.CommandArguments do
  @moduledoc """
  Parsed standalone command arguments.

  Acquisition paths remain confined to this command-boundary value and are
  consumed before `RunCoordinator`. Artifact destinations are captured against
  the invocation working directory after parsing and move only into the sealed
  phase-6 command continuation.
  """

  @enforce_keys [:command, :application, :directory, :options]
  defstruct @enforce_keys

  @type command :: :help | :version | :init | :validate | :run | :doctor | :models
  @type t :: %__MODULE__{
          command: command(),
          application: binary() | nil,
          directory: binary() | nil,
          options: map()
        }
end
