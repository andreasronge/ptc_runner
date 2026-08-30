defmodule PtcRunner.Kernel.WorkflowEnvironment do
  @moduledoc """
  Frozen authority for the trusted outer workflow.

  The workflow environment contains an optional compiled bundle, explicit
  host capabilities, and JSON-like data. The Kernel adds reserved runtime
  routes such as subordinate evaluation and workflow annotation during a run;
  callers cannot replace those names.

  Construction validates the bundle attestation, duplicate or reserved
  capability names, JSON-like data, and every tool requirement recorded by the
  bundle. It never imports capabilities from a mission environment.
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
  Assembles a workflow environment from optional `:bundle`, `:capabilities`,
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
             :workflow,
             Keyword.get(opts, :shipped_component_ids)
           ) do
      {:ok, struct!(__MODULE__, attributes)}
    else
      true -> {:error, :unknown_environment_field}
      error -> error
    end
  end
end
