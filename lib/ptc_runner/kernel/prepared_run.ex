defmodule PtcRunner.Kernel.PreparedRun do
  @moduledoc """
  Sealed provider-inert output of phases 4 and 5.

  It contains no filesystem path, credential, endpoint, provider callback
  result, artifact destination, or arbitrary lower-level failure. Its creating
  process owns the linked activity marker until single-use consumption
  atomically transfers lifecycle ownership to the consumer.
  """

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.RunRequest
  alias PtcRunner.Lisp.Prelude

  @enforce_keys [
    :request,
    :workflow_bundle,
    :mission_bundle,
    :entry_source,
    :provider_activity
  ]
  defstruct @enforce_keys ++ [attestation: nil]
  @field_keys Enum.sort([:__struct__, :attestation | @enforce_keys])

  @type t :: %__MODULE__{
          request: RunRequest.t(),
          workflow_bundle: FrozenBundle.t(),
          mission_bundle: FrozenBundle.t() | nil,
          entry_source: binary(),
          provider_activity: ProviderActivity.t(),
          attestation: binary() | nil
        }

  @spec new(
          RunRequest.t(),
          FrozenBundle.t(),
          FrozenBundle.t() | nil,
          binary(),
          ProviderActivity.t()
        ) :: {:ok, t()} | {:error, :invalid_prepared_run}
  def new(request, workflow_bundle, mission_bundle, entry_source, provider_activity) do
    if RunRequest.valid?(request) and
         provider_free?(request.package.providers) and
         bundle_matches?(workflow_bundle, request.package.workflow_components) and
         mission_bundle_matches?(mission_bundle, request.package.mission_components) and
         entry_callable?(workflow_bundle, request.package.entry) and
         entry_source == expected_entry_source(request) and
         ProviderActivity.claim(provider_activity) == :ok do
      prepared = %__MODULE__{
        request: request,
        workflow_bundle: workflow_bundle,
        mission_bundle: mission_bundle,
        entry_source: entry_source,
        provider_activity: provider_activity
      }

      {:ok, %{prepared | attestation: Attestation.attest(__MODULE__, payload(prepared))}}
    else
      {:error, :invalid_prepared_run}
    end
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{attestation: attestation} = prepared) do
    Enum.sort(Map.keys(prepared)) == @field_keys and
      RunRequest.valid?(prepared.request) and
      provider_free?(prepared.request.package.providers) and
      bundle_matches?(
        prepared.workflow_bundle,
        prepared.request.package.workflow_components
      ) and
      mission_bundle_matches?(
        prepared.mission_bundle,
        prepared.request.package.mission_components
      ) and
      entry_callable?(prepared.workflow_bundle, prepared.request.package.entry) and
      prepared.entry_source == expected_entry_source(prepared.request) and
      ProviderActivity.claimed?(prepared.provider_activity) and
      Attestation.valid?(__MODULE__, payload(prepared), attestation)
  end

  def valid?(_prepared), do: false

  @doc false
  @spec consume(t()) :: :ok | {:error, :invalid_prepared_run}
  def consume(%__MODULE__{} = prepared) do
    if valid?(prepared) and ProviderActivity.consume(prepared.provider_activity) == :ok,
      do: :ok,
      else: {:error, :invalid_prepared_run}
  end

  def consume(_prepared), do: {:error, :invalid_prepared_run}

  @doc "Idempotently releases the prepared run's activity owner."
  @spec close(t()) :: :ok
  def close(%__MODULE__{provider_activity: activity}), do: ProviderActivity.stop(activity)
  def close(_prepared), do: :ok

  defp provider_free?(%{workflow: [], mission: []}), do: true
  defp provider_free?(_providers), do: false

  defp mission_bundle_matches?(nil, []), do: true

  defp mission_bundle_matches?(%FrozenBundle{} = bundle, [_component | _rest] = components),
    do: bundle_matches?(bundle, components)

  defp mission_bundle_matches?(_bundle, _components), do: false

  defp bundle_matches?(%FrozenBundle{} = bundle, components) when is_list(components) do
    with true <- FrozenBundle.valid?(bundle),
         {:ok, actual} <- compiled_projection(bundle.components),
         expected <- Map.new(components, &component_projection/1),
         true <- actual == expected,
         true <- bundle.component_ids == Enum.map(bundle.components, & &1.id) do
      true
    else
      _invalid -> false
    end
  end

  defp bundle_matches?(_bundle, _components), do: false

  defp compiled_projection(components) when is_list(components) do
    Enum.reduce_while(components, {:ok, %{}}, fn
      %{id: id, source_hash: source_hash, dependencies: dependencies}, {:ok, projection}
      when is_binary(id) and is_binary(source_hash) and is_list(dependencies) ->
        if Map.has_key?(projection, id) do
          {:halt, :error}
        else
          {:cont, {:ok, Map.put(projection, id, {source_hash, dependencies})}}
        end

      _component, _projection ->
        {:halt, :error}
    end)
  end

  defp component_projection(%Component{} = component) do
    source_hash =
      component.source
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    {component.id, {source_hash, component.dependencies}}
  end

  @doc false
  @spec entry_callable?(FrozenBundle.t(), binary()) :: boolean()
  def entry_callable?(%FrozenBundle{} = bundle, entry) when is_binary(entry) do
    case Prelude.fetch_export(bundle.prelude, entry) do
      {:ok, %{kind: :function, arity: 1}} ->
        true

      {:ok, %{kind: :function, arity: :variadic, min_arity: min_arity}}
      when min_arity in 0..1 ->
        true

      _missing_or_incompatible ->
        false
    end
  end

  def entry_callable?(_bundle, _entry), do: false

  defp expected_entry_source(request),
    do: "(#{request.package.entry} data/input)"

  defp payload(prepared) do
    {
      prepared.request,
      prepared.workflow_bundle,
      prepared.mission_bundle,
      prepared.entry_source,
      prepared.provider_activity
    }
  end
end
