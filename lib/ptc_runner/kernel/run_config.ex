defmodule PtcRunner.Kernel.RunConfig do
  @moduledoc """
  The complete host-constructed configuration for one Kernel run.

  The required fields are:

  - `workflow_environment` — trusted outer workflow code and capabilities;
  - `mission_environment` — confined subordinate code and capabilities;
  - `input` — a JSON-like map exposed as the workflow evaluation context;
  - `limits` — normalized positive runtime ceilings;
  - `event_sink` — the bounded owner of canonical run events.

  Construction derives and freezes `mission_inventory` from the mission
  environment and limits. It contains both the authoritative versioned
  structured inventory and a separately versioned compact model rendering,
  each with distinct hashes and byte counts. Hosts cannot supply mutable
  inventory text.

  `provider_resources` are opaque idempotent close functions owned by the host.
  `connector_snapshots` are bounded safe metadata copied into `run-started`;
  neither field is visible to Lisp.

  `labels` is an optional closed safe-metadata map. Caller-defined identifier
  fields become SHA-256 fingerprints and tags use finite enumerated values
  before the map enters `run-started`.
  `session_profile` is an optional closed profile ID and SHA-256 digest used by
  server-owned interactive mission sessions; it grants no authority and is
  copied only into safe `run-started` metadata.
  Constructing a config validates shape and ownership objects but performs no
  execution and grants no authority beyond the supplied environments.
  """

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.MissionInventory
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.Lisp.RetainedSize

  @enforce_keys [
    :workflow_environment,
    :mission_environment,
    :input,
    :limits,
    :event_sink,
    :mission_inventory
  ]
  defstruct [
    :workflow_environment,
    :mission_environment,
    :input,
    :limits,
    :event_sink,
    :mission_inventory,
    inspection_sink: nil,
    inspection_path: nil,
    provider_resources: [],
    connector_snapshots: [],
    session_profile: nil,
    labels: %{},
    run_started_metadata: %{}
  ]

  @type t :: %__MODULE__{
          workflow_environment: WorkflowEnvironment.t(),
          mission_environment: MissionEnvironment.t(),
          input: map(),
          limits: Limits.t(),
          event_sink: EventSink.t(),
          mission_inventory: MissionInventory.t(),
          inspection_sink: InspectionSink.t() | nil,
          inspection_path: binary() | nil,
          provider_resources: [(-> :ok)],
          connector_snapshots: [map()],
          session_profile: map() | nil,
          labels: map(),
          run_started_metadata: map()
        }

  @spec new(keyword()) ::
          {:ok, t()}
          | {:error,
             :invalid_run_config
             | :mission_inventory_exceeded
             | :run_started_metadata_exceeded}
  @doc "Constructs a run configuration and rejects missing or unknown fields."
  def new(opts) when is_list(opts) do
    with false <-
           Keyword.keys(opts) --
             [
               :workflow_environment,
               :mission_environment,
               :input,
               :limits,
               :event_sink,
               :inspection_sink,
               :inspection_path,
               :provider_resources,
               :connector_snapshots,
               :session_profile,
               :labels
             ] !=
             [],
         %WorkflowEnvironment{} = workflow <- Keyword.get(opts, :workflow_environment),
         %MissionEnvironment{} = mission <- Keyword.get(opts, :mission_environment),
         true <- JSONValue.map?(Keyword.get(opts, :input)),
         %Limits{} = limits <- Keyword.get(opts, :limits),
         %EventSink{} = sink <- Keyword.get(opts, :event_sink),
         true <-
           inspection?(Keyword.get(opts, :inspection_sink), Keyword.get(opts, :inspection_path)),
         true <- provider_resources?(Keyword.get(opts, :provider_resources, [])),
         true <- connector_snapshots?(Keyword.get(opts, :connector_snapshots, [])),
         {:ok, session_profile} <- session_profile(Keyword.get(opts, :session_profile)),
         {:ok, labels} <- SafeMetadata.normalize_labels(Keyword.get(opts, :labels, %{})),
         {:ok, mission_inventory} <- MissionInventory.build(mission, limits),
         {:ok, run_started_metadata} <-
           run_started_metadata(
             workflow,
             mission,
             mission_inventory,
             Keyword.get(opts, :connector_snapshots, []),
             session_profile,
             labels,
             limits
           ) do
      {:ok,
       %__MODULE__{
         workflow_environment: workflow,
         mission_environment: mission,
         input: Keyword.fetch!(opts, :input),
         limits: limits,
         event_sink: sink,
         mission_inventory: mission_inventory,
         inspection_sink: Keyword.get(opts, :inspection_sink),
         inspection_path: Keyword.get(opts, :inspection_path),
         provider_resources: Keyword.get(opts, :provider_resources, []),
         connector_snapshots: Keyword.get(opts, :connector_snapshots, []),
         session_profile: session_profile,
         labels: labels,
         run_started_metadata: run_started_metadata
       }}
    else
      {:error, :mission_inventory_exceeded} = error -> error
      {:error, :run_started_metadata_exceeded} = error -> error
      _ -> {:error, :invalid_run_config}
    end
  end

  # One owner assembles the complete static `run-started` payload — labels,
  # both prelude projections, mission-inventory fingerprints, and connector
  # snapshots — and measures it with the sink's retained-size rule against
  # the selected event-payload ceiling. A successful build therefore cannot
  # knowingly begin with a `run-started` payload its configured sink must
  # reject; the sink remains the final runtime authority.
  defp run_started_metadata(
         workflow,
         mission,
         inventory,
         snapshots,
         session_profile,
         labels,
         limits
       ) do
    with {:ok, workflow_prelude} <- FrozenBundle.trace_metadata(workflow.bundle),
         {:ok, mission_prelude} <- FrozenBundle.trace_metadata(mission.bundle) do
      payload =
        %{
          labels: labels,
          workflow_prelude: workflow_prelude,
          mission_prelude: mission_prelude,
          mission_inventory_hash: inventory.hash,
          mission_inventory_bytes: inventory.bytes,
          mission_model_context_hash: inventory.model_hash,
          mission_model_context_bytes: inventory.model_bytes,
          connector_snapshots: snapshots
        }
        |> maybe_put_session_profile(session_profile)

      limit = limits.event_payload_bytes
      bytes = RetainedSize.bytes_with_cap(payload, limit)

      if is_integer(bytes) and bytes <= limit,
        do: {:ok, payload},
        else: {:error, :run_started_metadata_exceeded}
    else
      {:error, :invalid_bundle} -> {:error, :invalid_run_config}
    end
  end

  @spec close_provider_resources(t()) :: :ok
  @doc "Closes opaque provider resources in their stored reverse-build order."
  def close_provider_resources(%__MODULE__{provider_resources: resources}) do
    Enum.each(resources, fn close ->
      try do
        _ = close.()
      rescue
        _exception -> :ok
      catch
        _kind, _reason -> :ok
      end
    end)

    :ok
  end

  defp provider_resources?(resources),
    do: is_list(resources) and Enum.all?(resources, &is_function(&1, 0))

  defp connector_snapshots?(snapshots) do
    is_list(snapshots) and length(snapshots) <= 128 and
      Enum.all?(snapshots, &JSONValue.map?/1) and
      byte_size(:erlang.term_to_binary(snapshots)) <= 262_144
  end

  defp session_profile(nil), do: {:ok, nil}

  defp session_profile(%{"id" => id, "digest" => "sha256:" <> hash} = profile)
       when map_size(profile) == 2 and is_binary(id) and byte_size(id) in 1..128 and
              byte_size(hash) == 64 do
    if id =~ ~r/\A[a-z][a-z0-9-]*\z/ and hash =~ ~r/\A[0-9a-f]{64}\z/,
      do: {:ok, profile},
      else: {:error, :invalid_run_config}
  end

  defp session_profile(_profile), do: {:error, :invalid_run_config}

  defp maybe_put_session_profile(payload, nil), do: payload

  defp maybe_put_session_profile(payload, profile),
    do: Map.put(payload, :session_profile, profile)

  defp inspection?(nil, nil), do: true

  defp inspection?(%InspectionSink{}, path),
    do: is_binary(path) and String.ends_with?(path, ".inspection.jsonl")

  defp inspection?(_sink, _path), do: false
end
