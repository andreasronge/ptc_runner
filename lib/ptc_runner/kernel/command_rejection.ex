defmodule PtcRunner.Kernel.CommandRejection do
  @moduledoc """
  Closed phase-1 parser rejection.

  Unknown switches are deliberately not retained. The value may carry only a
  declaration-owned accepted list. Missing-value, destination, and collision
  failures retain only declaration-owned switch names, never caller-owned paths.
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
    :option,
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
            | :missing_switch_value
            | :positional_arity
            | :invalid_destination
            | :destination_exists
            | :destination_collision
            | :private_output_recovery_collision
            | :init_destination_collision
            | :project_host_undeclared,
          accepted: [binary()],
          option: binary() | nil,
          destination: binary() | nil,
          conflicts: [binary()]
        }

  @doc """
  Builds the rejection for a project document that declares no host.

  Restricted to the two commands that need one, so `generic/2` cannot mint a
  command/code pair the envelope contract refuses and `CommandOutcome` would
  raise on.
  """
  @spec undeclared_project_host(:models | :doctor) :: t()
  def undeclared_project_host(command) when command in [:models, :doctor] do
    %__MODULE__{
      command: command,
      code: :project_host_undeclared,
      kind: :generic,
      accepted: [],
      option: nil,
      destination: nil,
      conflicts: []
    }
  end

  @spec generic(atom(), atom()) :: t()
  def generic(command, code) when command in @commands and code in @codes do
    %__MODULE__{
      command: command,
      code: code,
      kind: :generic,
      accepted: [],
      option: nil,
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
      option: nil,
      destination: nil,
      conflicts: []
    }
  end

  defp accepted_switches(command, _frontend) when command in [:help, :version], do: []

  defp accepted_switches(command, frontend),
    do: CommandDeclaration.accepted_switches(command, frontend)

  @spec missing_switch_value(
          CommandDeclaration.command(),
          binary(),
          CommandDeclaration.frontend()
        ) ::
          t()
  def missing_switch_value(command, switch, frontend) do
    option = CommandDeclaration.canonical_switch(command, frontend, switch)

    if is_binary(option) do
      %__MODULE__{
        command: command,
        code: :invalid_arguments,
        kind: :missing_switch_value,
        accepted: [],
        option: option,
        destination: nil,
        conflicts: []
      }
    else
      generic(command, :invalid_arguments)
    end
  end

  @spec positional_arity(CommandDeclaration.command()) :: t()
  def positional_arity(command) do
    %__MODULE__{
      command: command,
      code: :invalid_arguments,
      kind: :positional_arity,
      accepted: [],
      option: nil,
      destination: nil,
      conflicts: []
    }
  end

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
      option: nil,
      destination: CommandDeclaration.option_switch!(command, frontend, destination),
      conflicts: []
    }
  end

  @doc """
  Builds the rejection for an envelope destination that already exists.

  The reserve behind every published artifact refuses to clobber, so an
  existing envelope path is a failure however late it is discovered. Discovering
  it at admission is the difference between refusing a command and refusing it
  after the workflow has executed and been billed. The caller's path is not
  retained; the switch name is declaration-owned.
  """
  @spec envelope_destination_exists(
          CommandDeclaration.command(),
          CommandDeclaration.frontend()
        ) :: t()
  def envelope_destination_exists(command, frontend)
      when command in [:validate, :run, :doctor, :models, :init] do
    %__MODULE__{
      command: command,
      code: :envelope_destination_exists,
      kind: :destination_exists,
      accepted: [],
      option: nil,
      destination: CommandDeclaration.option_switch!(command, frontend, :envelope),
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
      option: nil,
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
      option: nil,
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
      option: nil,
      destination: nil,
      conflicts: [CommandDeclaration.option_switch!(:init, frontend, :envelope)]
    }
  end
end
