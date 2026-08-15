defmodule PtcRunner.Kernel.CommandRejection do
  @moduledoc """
  Closed phase-1 parser rejection.

  Unknown switches are deliberately not retained. The value may carry only a
  declaration-owned accepted list. Destination failures and collisions retain only
  declaration-owned switch names, never caller-owned paths.
  """

  alias PtcRunner.Kernel.CommandDeclaration

  @commands [:help, :version, :unknown | CommandDeclaration.commands()]
  @codes [:invalid_command, :invalid_arguments, :conflicting_arguments]
  @destination_keys [:trace_dir, :inspect, :output, :private_output]
  @enforce_keys [
    :command,
    :code,
    :kind,
    :accepted,
    :destination,
    :conflicts
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          command: atom(),
          code: atom(),
          kind:
            :generic
            | :unknown_switch
            | :invalid_destination
            | :destination_collision
            | :private_output_recovery_collision
            | :init_destination_collision,
          accepted: [binary()],
          destination: binary() | nil,
          conflicts: [binary()]
        }

  @spec generic(atom(), atom()) :: t()
  def generic(command, code) when command in @commands and code in @codes do
    %__MODULE__{
      command: command,
      code: code,
      kind: :generic,
      accepted: [],
      destination: nil,
      conflicts: []
    }
  end

  @spec unknown_switch(atom(), CommandDeclaration.frontend()) :: t()
  def unknown_switch(command, frontend) do
    %__MODULE__{
      command: command,
      code: :invalid_arguments,
      kind: :unknown_switch,
      accepted: accepted_switches(command, frontend),
      destination: nil,
      conflicts: []
    }
  end

  defp accepted_switches(command, _frontend) when command in [:help, :version], do: []

  defp accepted_switches(command, frontend),
    do: CommandDeclaration.accepted_switches(command, frontend)

  @spec invalid_destination(
          CommandDeclaration.command(),
          atom(),
          CommandDeclaration.frontend()
        ) :: t()
  def invalid_destination(command, destination, frontend)
      when (destination == :envelope and command in [:validate, :run, :doctor, :models, :init]) or
             (command == :transcript and destination == :private_output) or
             (command == :repl and destination in [:output, :private_output]) do
    %__MODULE__{
      command: command,
      code: :invalid_arguments,
      kind: :invalid_destination,
      accepted: [],
      destination: CommandDeclaration.option_switch!(command, frontend, destination),
      conflicts: []
    }
  end

  @spec destination_collision(
          CommandDeclaration.command(),
          atom(),
          atom(),
          CommandDeclaration.frontend()
        ) :: t()
  def destination_collision(command, first, second, frontend)
      when command == :run and first in [:envelope | @destination_keys] and
             second in [:envelope | @destination_keys] and first != second do
    first = CommandDeclaration.option_switch!(command, frontend, first)
    second = CommandDeclaration.option_switch!(command, frontend, second)

    %__MODULE__{
      command: command,
      code: :conflicting_arguments,
      kind: :destination_collision,
      accepted: [],
      destination: nil,
      conflicts: [first, second]
    }
  end

  @spec private_output_recovery_collision(CommandDeclaration.frontend()) :: t()
  def private_output_recovery_collision(frontend) do
    %__MODULE__{
      command: :run,
      code: :conflicting_arguments,
      kind: :private_output_recovery_collision,
      accepted: [],
      destination: nil,
      conflicts: [CommandDeclaration.option_switch!(:run, frontend, :private_output)]
    }
  end

  @spec init_destination_collision(CommandDeclaration.frontend()) :: t()
  def init_destination_collision(frontend) do
    %__MODULE__{
      command: :init,
      code: :conflicting_arguments,
      kind: :init_destination_collision,
      accepted: [],
      destination: nil,
      conflicts: [CommandDeclaration.option_switch!(:init, frontend, :envelope)]
    }
  end
end
