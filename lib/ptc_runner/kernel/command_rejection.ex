defmodule PtcRunner.Kernel.CommandRejection do
  @moduledoc """
  Closed phase-1 parser rejection.

  Unknown switches are deliberately not retained. The value may carry only a
  declaration-owned accepted list or a declaration-owned retired switch and
  replacement. Destination failures and collisions retain only
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
    :retired,
    :replacement,
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
            | :retired_switch
            | :invalid_destination
            | :destination_collision
            | :init_destination_collision,
          accepted: [binary()],
          retired: binary() | nil,
          replacement: binary() | nil,
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
      retired: nil,
      replacement: nil,
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
      retired: nil,
      replacement: nil,
      destination: nil,
      conflicts: []
    }
  end

  defp accepted_switches(command, _frontend) when command in [:help, :version], do: []

  defp accepted_switches(command, frontend),
    do: CommandDeclaration.accepted_switches(command, frontend)

  @spec retired_switch(
          CommandDeclaration.command(),
          binary(),
          binary(),
          CommandDeclaration.frontend()
        ) :: t()
  def retired_switch(command, switch, replacement, frontend) do
    {:ok, ^replacement} = CommandDeclaration.retired_switch(command, switch)

    %__MODULE__{
      command: command,
      code: :invalid_arguments,
      kind: :retired_switch,
      accepted: CommandDeclaration.accepted_switches(command, frontend),
      retired: switch,
      replacement: replacement,
      destination: nil,
      conflicts: []
    }
  end

  @spec invalid_destination(
          CommandDeclaration.command(),
          :envelope,
          CommandDeclaration.frontend()
        ) :: t()
  def invalid_destination(command, :envelope, frontend)
      when command in [:validate, :run, :doctor, :models, :init] do
    %__MODULE__{
      command: command,
      code: :invalid_arguments,
      kind: :invalid_destination,
      accepted: [],
      retired: nil,
      replacement: nil,
      destination: CommandDeclaration.option_switch!(command, frontend, :envelope),
      conflicts: []
    }
  end

  @spec destination_collision(
          CommandDeclaration.command(),
          atom(),
          CommandDeclaration.frontend()
        ) :: t()
  def destination_collision(command, key, frontend)
      when command == :run and key in @destination_keys do
    conflicting = CommandDeclaration.option_switch!(command, frontend, key)
    envelope = CommandDeclaration.option_switch!(command, frontend, :envelope)

    %__MODULE__{
      command: command,
      code: :conflicting_arguments,
      kind: :destination_collision,
      accepted: [],
      retired: nil,
      replacement: nil,
      destination: nil,
      conflicts: [conflicting, envelope]
    }
  end

  @spec init_destination_collision(CommandDeclaration.frontend()) :: t()
  def init_destination_collision(frontend) do
    %__MODULE__{
      command: :init,
      code: :conflicting_arguments,
      kind: :init_destination_collision,
      accepted: [],
      retired: nil,
      replacement: nil,
      destination: nil,
      conflicts: [CommandDeclaration.option_switch!(:init, frontend, :envelope)]
    }
  end
end
