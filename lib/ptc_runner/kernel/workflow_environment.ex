defmodule PtcRunner.Kernel.WorkflowEnvironment do
  @moduledoc """
  Frozen authority for the trusted outer workflow.

  The workflow environment contains an optional compiled bundle, explicit
  host capabilities, and JSON-like data. The Kernel adds reserved runtime
  routes such as subordinate evaluation and workflow annotation during a run;
  callers cannot replace those names.

  Construction validates the bundle attestation, duplicate or reserved
  capability names, JSON-like data, and every tool requirement recorded by the
  bundle. An optional `:catalog` is attested with the bundle so source cannot
  be paired with a different compiled graph. `:inspect_only` is attested with
  the environment: a compile-and-inspect assembly that skipped tool
  requirements cannot be placed in an ordinary runnable configuration. It
  never imports capabilities from a mission environment. A verified workflow
  override of the shipped `agent.core` retains that library's fixed private
  diagnostic routes; other local or replacement components cannot acquire them.
  """
  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.ComponentCatalog
  alias PtcRunner.Kernel.Environment

  @enforce_keys [
    :bundle,
    :capabilities,
    :data,
    :private_capabilities,
    :shipped_component_ids,
    :catalog,
    :inspect_only
  ]
  defstruct @enforce_keys ++ [attestation: nil]
  @field_keys Enum.sort([:__struct__, :attestation | @enforce_keys])

  @type t :: %__MODULE__{
          bundle: PtcRunner.Kernel.FrozenBundle.t() | nil,
          capabilities: %{binary() => PtcRunner.Kernel.Capability.t()},
          data: map(),
          private_capabilities: [binary()],
          shipped_component_ids: [binary()],
          catalog: ComponentCatalog.t(),
          inspect_only: boolean(),
          attestation: binary()
        }
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  @doc """
  Assembles a workflow environment from optional `:bundle`, `:capabilities`,
  JSON-like `:data`, `:catalog`, `:shipped_component_ids`, and `:inspect_only`
  options. `:shipped_component_ids` records the shipped library selections
  represented by the bundle for exact diagnostic misses. Unknown options are
  rejected. `:inspect_only` skips recorded tool-requirement checks so a
  compile-and-inspect session can attach source without installing
  capabilities. The resulting environment attests that mode; `RunConfig`
  refuses it unless `inspect_only` is also true.
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
    with false <-
           Keyword.keys(opts) --
             [
               :bundle,
               :capabilities,
               :data,
               :catalog,
               :shipped_component_ids,
               :inspect_only
             ] != [],
         {:ok, attributes} <-
           Environment.assemble(
             Keyword.get(opts, :bundle),
             Keyword.get(opts, :capabilities, []),
             Keyword.get(opts, :data, %{}),
             :workflow,
             authorization: authorization,
             shipped_component_ids: Keyword.get(opts, :shipped_component_ids),
             inspect_only: Keyword.get(opts, :inspect_only) == true
           ),
         {:ok, catalog} <- ComponentCatalog.bind(Keyword.get(opts, :catalog), attributes.bundle) do
      environment = struct!(__MODULE__, Map.put(attributes, :catalog, catalog))
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
