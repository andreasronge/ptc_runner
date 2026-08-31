defmodule PtcRunner.Kernel.MissionEnvironment do
  @moduledoc """
  Frozen authority for confined subordinate programs.

  A mission environment contains only its optional bundle, explicitly granted
  capabilities, and JSON-like mission data. Subordinate evaluation is built
  exclusively from this struct and committed evaluation memory/history; it never
  inherits or falls back to the workflow environment.

  Workflow-only reserved routes such as subordinate evaluation and annotation
  are absent. Construction validates the bundle attestation, capability names,
  data, recorded tool requirements, and an optional source catalog attested
  with the bundle so source cannot be paired with a different compiled graph.
  `:shipped_component_ids` records the shipped library selections represented
  by the bundle for exact diagnostic misses.
  """
  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.ComponentCatalog
  alias PtcRunner.Kernel.Environment
  @enforce_keys [:bundle, :capabilities, :data, :shipped_component_ids, :catalog]
  defstruct @enforce_keys ++ [attestation: nil]
  @field_keys Enum.sort([:__struct__, :attestation | @enforce_keys])

  @type t :: %__MODULE__{
          bundle: PtcRunner.Kernel.FrozenBundle.t() | nil,
          capabilities: %{binary() => PtcRunner.Kernel.Capability.t()},
          data: map(),
          shipped_component_ids: [binary()],
          catalog: ComponentCatalog.t(),
          attestation: binary()
        }
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  @doc """
  Assembles a mission environment from optional `:bundle`, `:capabilities`,
  JSON-like `:data`, `:catalog`, and `:shipped_component_ids` options.
  Unknown options are rejected.
  """
  def new(opts) when is_list(opts) do
    with false <-
           Keyword.keys(opts) --
             [:bundle, :capabilities, :data, :catalog, :shipped_component_ids] != [],
         {:ok, attributes} <-
           Environment.assemble(
             Keyword.get(opts, :bundle),
             Keyword.get(opts, :capabilities, []),
             Keyword.get(opts, :data, %{}),
             :mission,
             shipped_component_ids: Keyword.get(opts, :shipped_component_ids)
           ),
         {:ok, catalog} <- ComponentCatalog.bind(Keyword.get(opts, :catalog), attributes.bundle) do
      environment = struct!(__MODULE__, Map.put(attributes, :catalog, catalog))
      {:ok, %{environment | attestation: Attestation.attest(__MODULE__, payload(environment))}}
    else
      true -> {:error, :unknown_environment_field}
      error -> error
    end
  end

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = environment),
    do:
      Attestation.valid_struct?(__MODULE__, environment, @field_keys, fn ->
        payload(environment)
      end)

  def valid?(_environment), do: false

  defp payload(environment) do
    environment
    |> Map.from_struct()
    |> Map.delete(:attestation)
  end
end
