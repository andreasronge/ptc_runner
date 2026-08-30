defmodule PtcRunner.Kernel.AnalysisResources do
  @moduledoc false

  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.RunCatalogSnapshot
  alias PtcRunner.Kernel.TraceSnapshot

  @public_profile "run-analysis-v1"
  @private_profile "private-run-analysis-v2"
  @catalog_profile "private-run-catalog-v1"

  @enforce_keys [:profile_id, :handles]
  defstruct [:profile_id, :handles]

  @type t :: %__MODULE__{
          profile_id: binary(),
          handles:
            %{
              required(:traces) => TraceSnapshot.t(),
              optional(:inspection) => InspectionSnapshot.t()
            }
            | %{required(:catalog) => RunCatalogSnapshot.t()}
        }

  @doc false
  @spec new(binary(), map()) :: {:ok, t()} | {:error, :invalid_analysis_resources}
  def new(@public_profile, %{traces: %TraceSnapshot{} = traces} = handles)
      when map_size(handles) == 1 do
    resources = %__MODULE__{profile_id: @public_profile, handles: %{traces: traces}}

    if valid?(resources), do: {:ok, resources}, else: {:error, :invalid_analysis_resources}
  end

  def new(
        @private_profile,
        %{
          traces: %TraceSnapshot{} = traces,
          inspection: %InspectionSnapshot{} = inspection
        } = handles
      )
      when map_size(handles) == 2 do
    resources = %__MODULE__{
      profile_id: @private_profile,
      handles: %{traces: traces, inspection: inspection}
    }

    if valid?(resources), do: {:ok, resources}, else: {:error, :invalid_analysis_resources}
  end

  def new(@catalog_profile, %{catalog: catalog} = handles)
      when map_size(handles) == 1 do
    resources = %__MODULE__{profile_id: @catalog_profile, handles: %{catalog: catalog}}

    if valid?(resources), do: {:ok, resources}, else: {:error, :invalid_analysis_resources}
  end

  def new(_profile_id, _handles), do: {:error, :invalid_analysis_resources}

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{
        profile_id: @public_profile,
        handles: %{traces: %TraceSnapshot{} = traces} = handles
      }) do
    map_size(handles) == 1 and
      TraceSnapshot.source(traces) == {:ok, :ptc_trace_snapshot}
  end

  def valid?(%__MODULE__{
        profile_id: @private_profile,
        handles:
          %{
            traces: %TraceSnapshot{} = traces,
            inspection: %InspectionSnapshot{} = inspection
          } = handles
      }) do
    map_size(handles) == 2 and
      TraceSnapshot.source(traces) == {:ok, :ptc_private_trace_snapshot} and
      InspectionSnapshot.valid?(inspection)
  end

  def valid?(%__MODULE__{
        profile_id: @catalog_profile,
        handles: %{catalog: catalog} = handles
      }) do
    map_size(handles) == 1 and RunCatalogSnapshot.valid?(catalog) and
      match?({:ok, %{source: :ptc_run_catalog}}, RunCatalogSnapshot.info(catalog))
  end

  def valid?(_resources), do: false

  @doc false
  @spec handle(t(), :traces | :inspection | :catalog) ::
          TraceSnapshot.t() | InspectionSnapshot.t() | RunCatalogSnapshot.t() | nil
  def handle(%__MODULE__{handles: handles}, name) when name in [:traces, :inspection, :catalog],
    do: Map.get(handles, name)

  @doc false
  @spec info(t()) :: {:ok, map()} | {:error, atom()}
  def info(%__MODULE__{profile_id: @public_profile} = resources) do
    resources
    |> handle(:traces)
    |> TraceSnapshot.info()
  end

  def info(%__MODULE__{profile_id: @private_profile} = resources) do
    with {:ok, trace_info} <- resources |> handle(:traces) |> TraceSnapshot.info(),
         {:ok, inspection_info} <-
           resources |> handle(:inspection) |> InspectionSnapshot.info() do
      {:ok, %{traces: trace_info, inspection: inspection_info}}
    end
  end

  def info(%__MODULE__{profile_id: @catalog_profile} = resources) do
    resources
    |> handle(:catalog)
    |> RunCatalogSnapshot.info()
  end

  def info(_resources), do: {:error, :invalid_analysis_resources}

  @doc false
  @spec transfer_owner(t(), pid()) :: :ok | {:error, atom()}
  def transfer_owner(
        %__MODULE__{profile_id: @public_profile, handles: %{traces: traces}} = resources,
        owner
      )
      when is_pid(owner) do
    with true <- valid?(resources),
         :ok <- TraceSnapshot.transfer_owner(traces, owner) do
      :ok
    else
      false -> {:error, :invalid_analysis_resources}
      {:error, _reason} = error -> error
    end
  end

  def transfer_owner(
        %__MODULE__{profile_id: @catalog_profile, handles: %{catalog: catalog}} = resources,
        owner
      )
      when is_pid(owner) do
    with true <- valid?(resources),
         :ok <- RunCatalogSnapshot.transfer_owner(catalog, owner) do
      :ok
    else
      false -> {:error, :invalid_analysis_resources}
      {:error, _reason} = error -> error
    end
  end

  def transfer_owner(
        %__MODULE__{
          profile_id: @private_profile,
          handles: %{traces: traces, inspection: inspection}
        } = resources,
        owner
      )
      when is_pid(owner) do
    with true <- valid?(resources),
         :ok <- InspectionSnapshot.transfer_owner(inspection, owner),
         :ok <- TraceSnapshot.transfer_owner(traces, owner) do
      :ok
    else
      false -> {:error, :invalid_analysis_resources}
      {:error, _reason} = error -> error
    end
  end

  def transfer_owner(_resources, _owner), do: {:error, :invalid_analysis_resources}

  @doc false
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{profile_id: @public_profile, handles: %{traces: traces}}) do
    TraceSnapshot.stop(traces)
    :ok
  end

  def stop(%__MODULE__{
        profile_id: @private_profile,
        handles: %{traces: traces, inspection: inspection}
      }) do
    InspectionSnapshot.stop(inspection)
    TraceSnapshot.stop(traces)
    :ok
  end

  def stop(%__MODULE__{profile_id: @catalog_profile, handles: %{catalog: catalog}}) do
    RunCatalogSnapshot.stop(catalog)
    :ok
  end

  def stop(_resources), do: :ok

  @doc false
  @spec alive?(t()) :: boolean()
  def alive?(%__MODULE__{profile_id: @public_profile, handles: %{traces: traces}}),
    do: TraceSnapshot.alive?(traces)

  def alive?(%__MODULE__{
        profile_id: @private_profile,
        handles: %{traces: traces, inspection: inspection}
      }),
      do: TraceSnapshot.alive?(traces) or InspectionSnapshot.alive?(inspection)

  def alive?(%__MODULE__{profile_id: @catalog_profile, handles: %{catalog: catalog}}),
    do: RunCatalogSnapshot.alive?(catalog)

  def alive?(_resources), do: false
end
