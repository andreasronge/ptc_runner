defmodule PtcRunner.Kernel.RunConfig do
  @moduledoc """
  The complete host-constructed configuration for one Kernel run.

  A configuration is one-shot: terminal publication finalizes its event sink,
  and a later `PtcRunner.Kernel.run/2` with the same value fails with
  `:event_sink_error`. Build a fresh configuration and sink for every run.

  The required fields are:

  - `workflow_environment` — trusted outer workflow code and capabilities;
  - `mission_environment` — confined subordinate code and capabilities;
  - `input` — a JSON-like map exposed as the workflow evaluation context;
  - `limits` — normalized positive runtime ceilings;
  - `event_sink` — the bounded owner of canonical run events.

  An event sink must be open and use these exact limits. A normal sink carries
  the standard two-event measured terminal reserve, must leave room for the
  assembled `run-started` event, and must have a payload ceiling large enough
  for the bounded loss summary and the maximum complete Runner/REPL usage
  projection. Private sinks reserve no lossy terminal slots but retain the same
  terminal-payload check.

  Construction derives and freezes `mission_inventory` from the mission
  environment and limits. It contains both the authoritative versioned
  structured inventory and a separately versioned compact model rendering,
  each with distinct hashes and byte counts. Hosts cannot supply mutable
  inventory text.

  `provider_resources` are opaque idempotent close functions owned by the host.
  `connector_snapshots` are bounded safe metadata copied into `run-started`;
  neither field is visible to Lisp.

  `result_contract` is an optional sealed, compiled application contract
  exposed only through the reserved workflow validator used by `agent.main`. Final
  publication enforcement remains the responsibility of `RunBuilder`.

  `labels` is an optional closed safe-metadata map. Caller-defined identifier
  fields become SHA-256 fingerprints and tags use finite enumerated values
  before the map enters `run-started`.
  `session_profile` is an optional closed profile ID and SHA-256 digest used by
  server-owned interactive mission sessions; it grants no authority and is
  copied only into safe `run-started` metadata.
  Constructing a config validates shape, recorder readiness, and ownership
  objects but performs no execution and grants no authority beyond the supplied
  environments.
  """

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.MissionInventory
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderResources
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.ValueContract
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.Lisp.RetainedSize

  @maximum_repl_errors 4_294_967_295

  @enforce_keys [
    :workflow_environment,
    :mission_environment,
    :input,
    :limits,
    :event_sink,
    :event_sink_owner,
    :mission_inventory,
    :claim_id
  ]
  defstruct [
    :workflow_environment,
    :mission_environment,
    :input,
    :limits,
    :event_sink,
    :event_sink_owner,
    :mission_inventory,
    :claim_id,
    result_contract: nil,
    result_projection: :native,
    inspection_sink: nil,
    inspection_sink_owner: nil,
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
          event_sink_owner: pid(),
          mission_inventory: MissionInventory.t(),
          claim_id: reference(),
          result_contract: ValueContract.t() | nil,
          result_projection: :native | :json,
          inspection_sink: InspectionSink.t() | nil,
          inspection_sink_owner: pid() | nil,
          inspection_path: binary() | nil,
          provider_resources: [ProviderRegistry.close()],
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
               :result_contract,
               :result_projection,
               :inspection_sink,
               :inspection_path,
               :provider_resources,
               :connector_snapshots,
               :session_profile,
               :labels,
               :component_overrides
             ] !=
             [],
         %WorkflowEnvironment{} = workflow <- Keyword.get(opts, :workflow_environment),
         %MissionEnvironment{} = mission <- Keyword.get(opts, :mission_environment),
         true <- JSONValue.map?(Keyword.get(opts, :input)),
         %Limits{} = limits <- Keyword.get(opts, :limits),
         %EventSink{} = sink <- Keyword.get(opts, :event_sink),
         true <- valid_event_sink_contract?(sink, limits),
         true <- result_contract?(Keyword.get(opts, :result_contract)),
         true <- result_projection?(Keyword.get(opts, :result_projection, :native)),
         {:ok, event_sink_owner} <- EventSink.owner(sink),
         true <-
           inspection?(Keyword.get(opts, :inspection_sink), Keyword.get(opts, :inspection_path)),
         {:ok, inspection_sink_owner} <-
           inspection_owner(Keyword.get(opts, :inspection_sink)),
         true <- provider_resources?(Keyword.get(opts, :provider_resources, [])),
         true <- connector_snapshots?(Keyword.get(opts, :connector_snapshots, [])),
         {:ok, session_profile} <- session_profile(Keyword.get(opts, :session_profile)),
         {:ok, labels} <- SafeMetadata.normalize_labels(Keyword.get(opts, :labels, %{})),
         {:ok, component_overrides} <-
           component_overrides(Keyword.get(opts, :component_overrides, [])),
         {:ok, mission_inventory} <- MissionInventory.build(mission, limits),
         {:ok, run_started_metadata} <-
           run_started_metadata(
             workflow,
             mission,
             mission_inventory,
             Keyword.get(opts, :connector_snapshots, []),
             session_profile,
             labels,
             component_overrides,
             limits
           ),
         true <- EventSink.begin_capacity?(sink, run_started_metadata),
         true <-
           EventSink.terminal_usage_capacity?(
             sink,
             limits,
             maximum_terminal_usage(workflow, mission, limits)
           ) do
      {:ok,
       %__MODULE__{
         workflow_environment: workflow,
         mission_environment: mission,
         input: Keyword.fetch!(opts, :input),
         limits: limits,
         event_sink: sink,
         event_sink_owner: event_sink_owner,
         mission_inventory: mission_inventory,
         claim_id: make_ref(),
         result_contract: Keyword.get(opts, :result_contract),
         result_projection: Keyword.get(opts, :result_projection, :native),
         inspection_sink: Keyword.get(opts, :inspection_sink),
         inspection_sink_owner: inspection_sink_owner,
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

  defp result_contract?(nil), do: true
  defp result_contract?(%ValueContract{} = contract), do: ValueContract.sealed?(contract)
  defp result_contract?(_contract), do: false

  defp result_projection?(projection), do: projection in [:native, :json]

  defp valid_event_sink_contract?(%EventSink{policy: :normal} = sink, limits) do
    reserve = EventSink.terminal_reserve(:normal, limits)

    limits.normal_event_count > reserve.count and limits.normal_event_bytes > reserve.bytes and
      match?(
        {:ok,
         %{
           terminal_reserve: ^reserve,
           limits: ^limits,
           ready?: true,
           begun?: false,
           event_count: 0,
           event_bytes: 0,
           dropped?: false
         }},
        EventSink.session_contract(sink)
      )
  end

  defp valid_event_sink_contract?(%EventSink{policy: :private} = sink, limits) do
    match?(
      {:ok,
       %{
         terminal_reserve: %{count: 0, bytes: 0},
         limits: ^limits,
         ready?: true,
         begun?: false,
         event_count: 0,
         event_bytes: 0,
         dropped?: false
       }},
      EventSink.session_contract(sink)
    )
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
         component_overrides,
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
        |> maybe_put_component_overrides(component_overrides)

      limit = limits.event_payload_bytes
      bytes = RetainedSize.bytes_with_cap(payload, limit)

      if is_integer(bytes) and bytes <= limit,
        do: {:ok, payload},
        else: {:error, :run_started_metadata_exceeded}
    else
      {:error, :invalid_bundle} -> {:error, :invalid_run_config}
    end
  end

  @spec close_provider_resources(t()) :: :ok | {:error, :provider_cleanup_failed}
  @doc """
  Closes opaque provider resources in their stored reverse-build order.

  Every resource is attempted. Exceptions and non-success results are
  normalized to `:provider_cleanup_failed` without exposing provider details.
  """
  def close_provider_resources(%__MODULE__{provider_resources: resources}) do
    ProviderResources.close(resources)
  end

  # A trial artifact has to name the base a candidate replaced, not only the
  # candidate itself. The effective bundle hash already changes when source
  # changes, but it cannot say which component was overridden or what base the
  # candidate was verified against, so an evaluation could not tell a
  # candidate run from an ordinary one. Hashes and the component ID are safe;
  # candidate source is not and never appears here.
  defp maybe_put_component_overrides(payload, []), do: payload

  defp maybe_put_component_overrides(payload, overrides),
    do: Map.put(payload, :component_overrides, overrides)

  defp component_overrides(overrides) when is_list(overrides) and length(overrides) <= 16 do
    if Enum.all?(overrides, &JSONValue.map?/1),
      do: {:ok, overrides},
      else: {:error, :invalid_run_config}
  end

  defp component_overrides(_overrides), do: {:error, :invalid_run_config}

  defp provider_resources?(resources),
    do: is_list(resources) and Enum.all?(resources, &is_function(&1, 0))

  defp connector_snapshots?(snapshots) do
    is_list(snapshots) and length(snapshots) <= 128 and
      Enum.all?(snapshots, &JSONValue.map?/1) and
      byte_size(:erlang.term_to_binary(snapshots)) <= 262_144
  end

  defp maximum_terminal_usage(workflow, mission, limits) do
    %{
      closed?: true,
      remaining_ms: limits.run_duration_ms,
      capability_calls: %{
        workflow:
          maximum_call_map(
            workflow.capabilities,
            limits.workflow_capability_calls,
            limits.workflow_capability_calls_per_name
          ),
        mission:
          maximum_call_map(
            mission.capabilities,
            limits.mission_capability_calls,
            limits.mission_capability_calls_per_name
          )
      },
      subordinate_evaluations: limits.subordinate_evaluations,
      protocol_errors: limits.protocol_errors + 1,
      evaluation_memory_bytes: limits.evaluation_memory_bytes,
      evaluation_history_bytes: limits.evaluation_history_bytes,
      evaluation_continuation_bytes:
        limits.evaluation_memory_bytes + limits.evaluation_history_bytes,
      evaluation_busy?: true,
      errors: @maximum_repl_errors
    }
  end

  defp maximum_call_map(capabilities, total_limit, per_name_limit) do
    maximum_count = min(total_limit, per_name_limit)

    capabilities
    |> Map.keys()
    |> Enum.sort_by(&{-retained_name_bytes(&1), &1})
    |> Enum.take(total_limit)
    |> Map.new(&{&1, maximum_count})
  end

  defp retained_name_bytes(name) do
    case RetainedSize.bytes(name) do
      bytes when is_integer(bytes) -> bytes
      :oversized -> 9_223_372_036_854_775_807
    end
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

  defp inspection_owner(nil), do: {:ok, nil}
  defp inspection_owner(%InspectionSink{} = sink), do: InspectionSink.owner(sink)
end
