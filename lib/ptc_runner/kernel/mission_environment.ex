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
  @enforce_keys [:bundle, :capabilities, :data, :shipped_component_ids]
  defstruct [:bundle, :capabilities, :data, :shipped_component_ids]

  @type t :: %__MODULE__{
          bundle: PtcRunner.Kernel.FrozenBundle.t() | nil,
          capabilities: %{binary() => PtcRunner.Kernel.Capability.t()},
          data: map(),
          shipped_component_ids: [binary()]
        }
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  @doc """
  Assembles a mission environment from optional `:bundle`, `:capabilities`,
  and JSON-like `:data` options. Unknown options are rejected.
  """
  def new(opts) when is_list(opts) do
    with false <-
           Keyword.keys(opts) -- [:bundle, :capabilities, :data, :shipped_component_ids] != [],
         {:ok, attributes} <-
           Environment.assemble(
             Keyword.get(opts, :bundle),
             Keyword.get(opts, :capabilities, []),
             Keyword.get(opts, :data, %{}),
             :mission,
             Keyword.get(opts, :shipped_component_ids)
           ) do
      {:ok, struct!(__MODULE__, attributes)}
    else
      true -> {:error, :unknown_environment_field}
      error -> error
    end
  end
end
