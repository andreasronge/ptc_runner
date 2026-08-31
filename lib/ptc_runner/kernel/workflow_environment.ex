defmodule PtcRunner.Kernel.WorkflowEnvironment do
  @moduledoc """
  Frozen authority for the trusted outer workflow.

  The workflow environment contains an optional compiled bundle, explicit
  host capabilities, and JSON-like data. The Kernel adds reserved runtime
  routes such as subordinate evaluation and workflow annotation during a run;
  callers cannot replace those names.

  Construction validates the bundle attestation, duplicate or reserved
  capability names, JSON-like data, and every tool requirement recorded by the
  bundle. It never imports capabilities from a mission environment. A verified
  workflow override of the shipped `agent.core` retains that library's fixed
  private diagnostic routes; other local or replacement components cannot
  acquire them.
  """
  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.Environment
  @enforce_keys [:bundle, :capabilities, :data, :private_capabilities]
  defstruct @enforce_keys ++ [attestation: nil]
  @field_keys Enum.sort([:__struct__, :attestation | @enforce_keys])

  @type t :: %__MODULE__{
          bundle: PtcRunner.Kernel.FrozenBundle.t() | nil,
          capabilities: %{binary() => PtcRunner.Kernel.Capability.t()},
          data: map(),
          private_capabilities: [binary()],
          attestation: binary()
        }
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  @doc """
  Assembles a workflow environment from optional `:bundle`, `:capabilities`,
  and JSON-like `:data` options. Unknown options are rejected.
  """
  def new(opts) when is_list(opts), do: assemble(opts, %{})

  @doc false
  @spec new_for_package(keyword(), ApplicationPackage.t()) :: {:ok, t()} | {:error, term()}
  def new_for_package(opts, %ApplicationPackage{} = package) when is_list(opts) do
    if ApplicationPackage.valid?(package) do
      assemble(opts, %{
        component_kinds: package.workflow_component_kinds,
        component_overrides: package.component_overrides
      })
    else
      {:error, :invalid_application_package}
    end
  end

  def new_for_package(_opts, _package), do: {:error, :invalid_application_package}

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = environment),
    do:
      Attestation.valid_struct?(__MODULE__, environment, @field_keys, fn ->
        payload(environment)
      end)

  def valid?(_environment), do: false

  @doc false
  @spec private_capability_granted?(term(), binary()) :: boolean()
  def private_capability_granted?(%__MODULE__{} = environment, name) when is_binary(name),
    do: valid?(environment) and name in environment.private_capabilities

  def private_capability_granted?(_environment, _name), do: false

  defp assemble(opts, authorization) do
    with false <- Keyword.keys(opts) -- [:bundle, :capabilities, :data] != [],
         {:ok, attributes} <-
           Environment.assemble(
             Keyword.get(opts, :bundle),
             Keyword.get(opts, :capabilities, []),
             Keyword.get(opts, :data, %{}),
             :workflow,
             authorization
           ) do
      environment = struct!(__MODULE__, attributes)
      {:ok, %{environment | attestation: Attestation.attest(__MODULE__, payload(environment))}}
    else
      true -> {:error, :unknown_environment_field}
      error -> error
    end
  end

  defp payload(environment) do
    environment
    |> Map.from_struct()
    |> Map.delete(:attestation)
  end
end
