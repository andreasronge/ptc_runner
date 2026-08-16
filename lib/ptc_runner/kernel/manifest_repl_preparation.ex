defmodule PtcRunner.Kernel.ManifestReplPreparation do
  @moduledoc false

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparationSeal
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderRuntimeServices

  @enforce_keys [
    :prepared_run,
    :catalog,
    :runtime_services,
    :environment_setup_required,
    :environment_setup_aliases,
    :attestation
  ]
  defstruct @enforce_keys
  @field_keys Enum.sort([:__struct__ | @enforce_keys])

  @type t :: %__MODULE__{
          prepared_run: PreparedRun.t(),
          catalog: InstallationCatalog.t(),
          runtime_services: ProviderRuntimeServices.t(),
          environment_setup_required: boolean(),
          environment_setup_aliases: [binary()],
          attestation: binary()
        }

  @doc false
  @spec new(PreparedRun.t(), InstallationCatalog.t(), ProviderRuntimeServices.t(), [binary()]) ::
          {:ok, t()} | {:error, :invalid_manifest_repl_preparation}
  def new(prepared_run, catalog, runtime_services, environment_setup_aliases)
      when is_list(environment_setup_aliases) do
    preparation = %__MODULE__{
      prepared_run: prepared_run,
      catalog: catalog,
      runtime_services: runtime_services,
      environment_setup_required: environment_setup_aliases != [],
      environment_setup_aliases: environment_setup_aliases,
      attestation: <<>>
    }

    if fields_valid?(preparation) do
      {:ok,
       %{
         preparation
         | attestation: Attestation.attest(__MODULE__, payload(preparation))
       }}
    else
      {:error, :invalid_manifest_repl_preparation}
    end
  end

  def new(_prepared_run, _catalog, _runtime_services, _environment_setup_aliases),
    do: {:error, :invalid_manifest_repl_preparation}

  @doc false
  @spec valid?(term()) :: boolean()
  # ex_dna:disable-for-next-line — each sealed preparation supplies its module-specific attestation domain and payload.
  def valid?(preparation),
    do: PreparationSeal.valid?(__MODULE__, preparation, &fields_valid?/1, &payload/1)

  @doc false
  @spec close(t()) :: :ok | {:error, term()}
  def close(%__MODULE__{prepared_run: prepared_run, catalog: catalog}) do
    result = PreparedRun.close(prepared_run)
    InstallationCatalog.close(catalog)
    result
  end

  def close(_preparation), do: :ok

  defp fields_valid?(preparation) do
    Enum.sort(Map.keys(preparation)) == @field_keys and
      PreparedRun.valid?(preparation.prepared_run) and
      InstallationCatalog.valid?(preparation.catalog) and
      preparation.prepared_run.catalog_attestation == preparation.catalog.attestation and
      ProviderRuntimeServices.bound_to?(
        preparation.runtime_services,
        preparation.catalog.runtime_binding
      ) and is_boolean(preparation.environment_setup_required) and
      preparation.environment_setup_aliases ==
        Enum.sort(Enum.uniq(preparation.environment_setup_aliases)) and
      Enum.all?(preparation.environment_setup_aliases, &is_binary/1) and
      preparation.environment_setup_required == (preparation.environment_setup_aliases != [])
  end

  defp payload(preparation),
    do:
      {preparation.prepared_run, preparation.catalog, preparation.runtime_services,
       preparation.environment_setup_required, preparation.environment_setup_aliases}
end
