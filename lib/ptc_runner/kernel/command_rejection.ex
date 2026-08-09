defmodule PtcRunner.Kernel.CommandRejection do
  @moduledoc """
  Closed phase-1 parser rejection.

  Unknown switches are deliberately not retained. The value may carry only a
  declaration-owned accepted list or a declaration-owned retired switch and
  replacement.
  """

  alias PtcRunner.Kernel.CommandDeclaration

  @commands [:help, :version, :unknown | CommandDeclaration.commands()]
  @codes [:invalid_command, :invalid_arguments, :conflicting_arguments]
  @enforce_keys [:command, :code, :kind, :accepted, :retired, :replacement]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          command: atom(),
          code: atom(),
          kind: :generic | :unknown_switch | :retired_switch,
          accepted: [binary()],
          retired: binary() | nil,
          replacement: binary() | nil
        }

  @spec generic(atom(), atom()) :: t()
  def generic(command, code) when command in @commands and code in @codes do
    %__MODULE__{
      command: command,
      code: code,
      kind: :generic,
      accepted: [],
      retired: nil,
      replacement: nil
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
      replacement: nil
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
      replacement: replacement
    }
  end
end
