defmodule PtcRunner.Kernel.RunConfig do
  @moduledoc """
  The complete host-constructed configuration for one Kernel run.

  A configuration is one-shot: terminal publication finalizes its event sink,
  and a later `PtcRunner.Kernel.run/2` with the same value fails with
  `:event_sink_error`. Build a fresh configuration and sink for every run.

  The required fields are:

  - `workflow_environment` — trusted outer workflow code and capabilities;
  - `missions` — zero to sixteen confined subordinate environments;
  - `input` — a JSON-like map exposed as the workflow evaluation context;
  - `limits` — normalized positive runtime ceilings;
  - `event_sink` — the bounded owner of canonical run events.

  An event sink must be open and use these exact limits. A normal sink carries
  the standard two-event measured terminal reserve, must leave room for the
  assembled `run-started` event, and must have a payload ceiling large enough
  for the bounded loss summary and the maximum complete Runner/REPL usage
  projection. Private sinks reserve no lossy terminal slots but retain the same
  terminal-payload check.

  Construction derives and freezes an inventory for every mission from its
  environment and the limits. Each contains both the authoritative versioned
  structured inventory and a separately versioned compact model rendering,
  each with distinct hashes and byte counts. Hosts cannot supply mutable
  inventory text.

  `provider_session` is the single owner-backed provider cleanup boundary.
  Its optional absolute `run_deadline` is derived from that sealed session so
  active preflight and later Kernel execution consume one budget rather than
  anchoring independent durations.
  Before callbacks can start, execution binds it to the Runner or REPL session
  owner and to the run state whose provider tasks it tracks.
  `connector_snapshots` and closed `provider_warnings` are bounded safe metadata
  copied into `run-started`; neither field is visible to Lisp.

  `result_contract` is an optional sealed, compiled application contract
  exposed only through the reserved workflow validator used by `agent.main`.
  Its optional `result_contract_source` is the portable logical document name
  used only for an attested result-contract diagnostic. Final publication
  enforcement remains the responsibility of `RunBuilder`.

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

  alias PtcRunner.Kernel.ApplicationSource
  alias PtcRunner.Kernel.CommandWarning
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.MissionInventory
  alias PtcRunner.Kernel.ModelContract
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.ProviderTaskTracker
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.TerminalUsage
  alias PtcRunner.Kernel.ValueContract
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.Lisp.RetainedSize

  @enforce_keys [
    :workflow_environment,
    :missions,
    :input,
    :limits,
    :event_sink,
    :event_sink_owner,
    :run_deadline,
    :claim_id
  ]
  defstruct [
    :workflow_environment,
    :missions,
    :input,
    :limits,
    :event_sink,
    :event_sink_owner,
    :run_deadline,
    :claim_id,
    result_contract: nil,
    result_contract_source: nil,
    phase_return_contracts: %{},
    result_projection: :native,
    inspection_sink: nil,
    inspection_sink_owner: nil,
    provider_session: nil,
    connector_snapshots: [],
    provider_warnings: [],
    session_profile: nil,
    labels: %{},
    run_started_metadata: %{},
    inspect_only: false
  ]

  @type t :: %__MODULE__{
          workflow_environment: WorkflowEnvironment.t(),
          missions: %{binary() => %{environment: MissionEnvironment.t(), inventory: term()}},
          input: map(),
          limits: Limits.t(),
          event_sink: EventSink.t(),
          event_sink_owner: pid(),
          run_deadline: Deadline.t() | nil,
          claim_id: reference(),
          result_contract: ValueContract.t() | nil,
          result_contract_source: binary() | nil,
          phase_return_contracts: %{binary() => map()},
          result_projection: :native | :json,
          inspection_sink: InspectionSink.t() | nil,
          inspection_sink_owner: pid() | nil,
          provider_session: ProviderSession.t() | nil,
          connector_snapshots: [map()],
          provider_warnings: [CommandWarning.t()],
          session_profile: map() | nil,
          labels: map(),
          run_started_metadata: map(),
          inspect_only: boolean()
        }

  @spec new(keyword()) ::
          {:ok, t()}
          | {:error,
             :invalid_run_config
             | :mission_inventory_exceeded
             | :run_started_metadata_exceeded
             | {:terminal_payload_capacity_exceeded, pos_integer(), pos_integer()}}
  @doc "Constructs a run configuration and rejects missing or unknown fields."
  def new(opts) when is_list(opts) do
    with false <-
           Keyword.keys(opts) --
             [
               :workflow_environment,
               :missions,
               :input,
               :limits,
               :event_sink,
               :result_contract,
               :result_contract_source,
               :phase_return_contracts,
               :result_projection,
               :inspection_sink,
               :provider_session,
               :connector_snapshots,
               :provider_warnings,
               :session_profile,
               :labels,
               :component_overrides,
               :inspect_only
             ] !=
             [],
         %WorkflowEnvironment{} = workflow <- Keyword.get(opts, :workflow_environment),
         true <- WorkflowEnvironment.valid?(workflow),
         true <- JSONValue.map?(Keyword.get(opts, :input)),
         %Limits{} = limits <- Keyword.get(opts, :limits),
         {:ok, missions} <- build_missions(Keyword.get(opts, :missions), limits),
         %EventSink{} = sink <- Keyword.get(opts, :event_sink),
         true <- valid_event_sink_contract?(sink, limits),
         true <- result_contract?(Keyword.get(opts, :result_contract)),
         true <-
           result_contract_source?(
             Keyword.get(opts, :result_contract),
             Keyword.get(opts, :result_contract_source)
           ),
         true <- result_projection?(Keyword.get(opts, :result_projection, :native)),
         true <- phase_return_contracts?(Keyword.get(opts, :phase_return_contracts, %{})),
         true <-
           contract_prompt_projections?(
             Keyword.get(opts, :result_contract),
             Keyword.get(opts, :phase_return_contracts, %{})
           ),
         {:ok, event_sink_owner} <- EventSink.owner(sink),
         true <- inspection?(Keyword.get(opts, :inspection_sink)),
         {:ok, inspection_sink_owner} <-
           inspection_owner(Keyword.get(opts, :inspection_sink)),
         provider_session = Keyword.get(opts, :provider_session),
         true <- provider_session?(provider_session, limits),
         {:ok, run_deadline} <- provider_run_deadline(provider_session),
         true <- connector_snapshots?(Keyword.get(opts, :connector_snapshots, [])),
         true <- provider_warnings?(Keyword.get(opts, :provider_warnings, [])),
         {:ok, session_profile} <- session_profile(Keyword.get(opts, :session_profile)),
         true <- Keyword.get(opts, :inspect_only, false) in [true, false],
         {:ok, labels} <- SafeMetadata.normalize_labels(Keyword.get(opts, :labels, %{})),
         {:ok, component_overrides} <-
           component_overrides(Keyword.get(opts, :component_overrides, [])),
         {:ok, run_started_metadata} <-
           run_started_metadata(
             workflow,
             missions,
             Keyword.get(opts, :connector_snapshots, []),
             Keyword.get(opts, :provider_warnings, []),
             session_profile,
             labels,
             component_overrides,
             limits
           ),
         true <- EventSink.begin_capacity?(sink, run_started_metadata),
         :ok <- terminal_usage_capacity(sink, limits, workflow, missions) do
      {:ok,
       %__MODULE__{
         workflow_environment: workflow,
         missions: missions,
         input: Keyword.fetch!(opts, :input),
         limits: limits,
         event_sink: sink,
         event_sink_owner: event_sink_owner,
         run_deadline: run_deadline,
         claim_id: make_ref(),
         result_contract: Keyword.get(opts, :result_contract),
         result_contract_source: Keyword.get(opts, :result_contract_source),
         phase_return_contracts: Keyword.get(opts, :phase_return_contracts, %{}),
         result_projection: Keyword.get(opts, :result_projection, :native),
         inspection_sink: Keyword.get(opts, :inspection_sink),
         inspection_sink_owner: inspection_sink_owner,
         provider_session: provider_session,
         connector_snapshots: Keyword.get(opts, :connector_snapshots, []),
         provider_warnings: Keyword.get(opts, :provider_warnings, []),
         session_profile: session_profile,
         labels: labels,
         run_started_metadata: run_started_metadata,
         inspect_only: Keyword.get(opts, :inspect_only, false)
       }}
    else
      {:error, :mission_inventory_exceeded} = error -> error
      {:error, :run_started_metadata_exceeded} = error -> error
      {:error, {:terminal_payload_capacity_exceeded, _payload, _required}} = error -> error
      _ -> {:error, :invalid_run_config}
    end
  end

  # A payload ceiling that cannot hold this application's own `run-stopped`
  # event is a limits decision the caller can act on, so it keeps its two
  # numbers instead of collapsing into the internal catch-all below.
  defp terminal_usage_capacity(sink, limits, workflow, missions) do
    usage = maximum_terminal_usage(workflow, missions, limits)

    case EventSink.required_terminal_payload_bytes(sink, usage) do
      required when is_integer(required) ->
        if limits.event_payload_bytes >= required,
          do: :ok,
          else:
            {:error, {:terminal_payload_capacity_exceeded, limits.event_payload_bytes, required}}

      :error ->
        {:error, :invalid_run_config}
    end
  end

  defp build_missions(environments, limits)
       when is_map(environments) and map_size(environments) <= 16 do
    Enum.reduce_while(environments, {:ok, %{}, 0, 0}, &build_mission(&1, &2, limits))
    |> case do
      {:ok, missions, _inventory_bytes, _model_bytes} -> {:ok, missions}
      {:error, _reason} = error -> error
    end
  end

  defp build_missions(_environments, _limits), do: {:error, :invalid_run_config}

  defp build_mission(
         {name, %MissionEnvironment{} = environment},
         {:ok, acc, inventory_bytes, model_bytes},
         limits
       ) do
    with true <- mission_name?(name),
         true <- MissionEnvironment.valid?(environment),
         {:ok, inventory} <- MissionInventory.build(environment, limits) do
      retain_mission(name, environment, inventory, acc, inventory_bytes, model_bytes)
    else
      _invalid -> {:halt, {:error, :invalid_run_config}}
    end
  end

  defp build_mission(_entry, _acc, _limits), do: {:halt, {:error, :invalid_run_config}}

  defp retain_mission(name, environment, inventory, acc, inventory_bytes, model_bytes) do
    next_inventory_bytes = inventory_bytes + inventory.bytes
    next_model_bytes = model_bytes + inventory.model_bytes

    if next_inventory_bytes <= 262_144 and next_model_bytes <= 262_144 do
      {:cont,
       {:ok, Map.put(acc, name, %{environment: environment, inventory: inventory}),
        next_inventory_bytes, next_model_bytes}}
    else
      {:halt, {:error, :mission_inventory_exceeded}}
    end
  end

  defp mission_name?(name) when is_binary(name),
    do:
      byte_size(name) in 1..128 and
        Regex.match?(~r/\A[a-z][a-z0-9._-]*\z/, name)

  defp mission_name?(_name), do: false

  defp result_contract?(nil), do: true
  defp result_contract?(%ValueContract{} = contract), do: ValueContract.sealed?(contract)
  defp result_contract?(_contract), do: false

  defp result_contract_source?(nil, nil), do: true
  defp result_contract_source?(%ValueContract{}, nil), do: true

  defp result_contract_source?(%ValueContract{}, source),
    do: ApplicationSource.valid_name?(source)

  defp result_contract_source?(_contract, _source), do: false

  defp phase_return_contracts?(contracts) when is_map(contracts) and map_size(contracts) <= 16 do
    Enum.all?(contracts, fn
      {name,
       %{contract: %ValueContract{} = contract, source: source, projection: projection} = binding}
      when is_binary(name) and is_binary(source) ->
        not is_struct(binding) and
          Enum.sort(Map.keys(binding)) == [:contract, :projection, :source] and
          ValueContract.sealed?(contract) and
          byte_size(name) in 1..128 and
          Regex.match?(~r/\A[a-z][a-z0-9._-]*\z/, name) and
          ApplicationSource.valid_name?(source) and
          match?({:ok, ^projection}, ModelContract.value_contract(contract))

      _binding ->
        false
    end)
  end

  defp phase_return_contracts?(_contracts), do: false

  defp contract_prompt_projections?(result_contract, phase_contracts) do
    projections =
      if is_nil(result_contract) do
        []
      else
        case ModelContract.value_contract(result_contract) do
          {:ok, projection} -> [projection]
          {:error, _reason} -> [:invalid]
        end
      end ++ Enum.map(phase_contracts, fn {_name, binding} -> binding.projection end)

    Enum.reduce_while(projections, 0, fn projection, aggregate ->
      case ModelContract.projection_bytes(projection) do
        {:ok, bytes} when bytes <= 262_144 and aggregate + bytes <= 1_048_576 ->
          {:cont, aggregate + bytes}

        _invalid ->
          {:halt, :invalid}
      end
    end) != :invalid
  end

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
  # workflow and mission prelude projections, inventory fingerprints, and connector
  # snapshots — and measures it with the sink's retained-size rule against
  # the selected event-payload ceiling. A successful build therefore cannot
  # knowingly begin with a `run-started` payload its configured sink must
  # reject; the sink remains the final runtime authority.
  defp run_started_metadata(
         workflow,
         missions,
         snapshots,
         warnings,
         session_profile,
         labels,
         component_overrides,
         limits
       ) do
    with {:ok, workflow_prelude} <- FrozenBundle.trace_metadata(workflow.bundle),
         {:ok, mission_metadata} <- mission_metadata(missions) do
      payload =
        %{
          labels: labels,
          workflow_prelude: workflow_prelude,
          missions: mission_metadata,
          connector_snapshots: snapshots,
          warnings: Enum.map(warnings, &CommandWarning.to_map/1),
          installation_config_digests: installation_config_digests(snapshots)
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

  defp provider_warnings?(warnings) when is_list(warnings) and length(warnings) <= 128,
    do: Enum.all?(warnings, &CommandWarning.valid?/1)

  defp provider_warnings?(_warnings), do: false

  defp mission_metadata(missions) do
    Enum.reduce_while(missions |> Enum.sort_by(&elem(&1, 0)), {:ok, %{}}, fn
      {name, %{environment: environment, inventory: inventory}}, {:ok, acc} ->
        case FrozenBundle.trace_metadata(environment.bundle) do
          {:ok, prelude} ->
            metadata = %{
              prelude: prelude,
              inventory_hash: inventory.hash,
              inventory_bytes: inventory.bytes,
              model_context_hash: inventory.model_hash,
              model_context_bytes: inventory.model_bytes
            }

            {:cont, {:ok, Map.put(acc, name, metadata)}}

          {:error, _reason} ->
            {:halt, {:error, :invalid_run_config}}
        end
    end)
  end

  @spec close_provider_session(t()) :: :ok | {:error, :provider_cleanup_failed}
  @doc """
  Closes the one provider session and its reverse-order cleanup stack.

  Cleanup is bounded by the session's sealed limit. Exceptions, timeouts, and
  non-success results are normalized to `:provider_cleanup_failed` without
  exposing provider details.
  """
  def close_provider_session(%__MODULE__{provider_session: nil}), do: :ok

  def close_provider_session(%__MODULE__{provider_session: session}),
    do: ProviderSession.close(session)

  @doc false
  @spec bind_provider_session(t(), pid(), pid(), ProviderTaskTracker.t()) ::
          :ok | {:error, :provider_session_unavailable}
  def bind_provider_session(%__MODULE__{provider_session: nil}, owner, run_state, _tracker)
      when is_pid(owner) and is_pid(run_state),
      do: :ok

  def bind_provider_session(%__MODULE__{provider_session: session}, owner, run_state, tracker)
      when is_pid(owner) and is_pid(run_state),
      do: ProviderSession.bind_lifecycle(session, owner, run_state, tracker)

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

  defp provider_session?(nil, _limits), do: true

  defp provider_session?(session, limits),
    do: ProviderSession.compatible_limits?(session, limits)

  defp provider_run_deadline(nil), do: {:ok, nil}
  defp provider_run_deadline(session), do: ProviderSession.execution_deadline(session)

  defp connector_snapshots?(snapshots) do
    is_list(snapshots) and length(snapshots) <= 128 and
      Enum.all?(snapshots, &JSONValue.map?/1) and
      byte_size(:erlang.term_to_binary(snapshots)) <= 262_144
  end

  defp installation_config_digests(snapshots) do
    snapshots
    |> Enum.filter(&is_binary(&1["installation_config_digest"]))
    |> Map.new(&{&1["provider"], &1["installation_config_digest"]})
  end

  defp maximum_terminal_usage(workflow, missions, limits) do
    mission_capabilities =
      missions
      |> Enum.flat_map(fn {_name, mission} -> mission.environment.capabilities end)
      |> Map.new()

    TerminalUsage.maximum(
      workflow.capabilities,
      mission_capabilities,
      Map.keys(missions),
      limits
    )
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

  defp inspection?(nil), do: true
  defp inspection?(%InspectionSink{}), do: true

  defp inspection?(_sink), do: false

  defp inspection_owner(nil), do: {:ok, nil}
  defp inspection_owner(%InspectionSink{} = sink), do: InspectionSink.owner(sink)
end
