defmodule PtcRunner.Kernel.MissionEnvironment do
  @moduledoc """
  Frozen authority for confined subordinate programs.

  A mission environment contains only its optional bundle, explicitly granted
  capabilities, and JSON-like mission data. Subordinate evaluation is built
  exclusively from this struct and committed evaluation memory/history; it never
  inherits or falls back to the workflow environment.

  Workflow-only reserved routes such as subordinate evaluation and annotation
  are absent. Construction validates the bundle attestation, capability names,
  data, and recorded tool requirements before execution begins.
  """
  alias PtcRunner.Kernel.Environment
  @enforce_keys [:bundle, :capabilities, :data]
  defstruct [:bundle, :capabilities, :data]

  @type t :: %__MODULE__{
          bundle: PtcRunner.Kernel.FrozenBundle.t() | nil,
          capabilities: %{binary() => PtcRunner.Kernel.Capability.t()},
          data: map()
        }
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  @doc """
  Assembles a mission environment from optional `:bundle`, `:capabilities`,
  and JSON-like `:data` options. Unknown options are rejected.

  Returns `{:error, :conflicting_annotation_declaration}` when two of the
  bundle's namespaces declare the same annotation type with different counter
  names. `PtcRunner.Kernel.Component` compilation accepts each declaration on
  its own; only assembling them together can detect the conflict.
  """
  def new(opts) when is_list(opts) do
    with false <- Keyword.keys(opts) -- [:bundle, :capabilities, :data] != [],
         {:ok, attributes} <-
           Environment.assemble(
             Keyword.get(opts, :bundle),
             Keyword.get(opts, :capabilities, []),
             Keyword.get(opts, :data, %{}),
             :mission
           ) do
      {:ok, struct!(__MODULE__, attributes)}
    else
      true -> {:error, :unknown_environment_field}
      error -> error
    end
  end
end
