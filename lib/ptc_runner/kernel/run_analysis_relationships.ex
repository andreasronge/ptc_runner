defmodule PtcRunner.Kernel.RunAnalysisRelationships do
  @moduledoc false

  @type collections :: map()

  @spec attach(collections(), map()) :: collections()
  def attach(collections, trace_facts) when is_map(collections) and is_map(trace_facts) do
    turns_by_run = Enum.group_by(collections.turns, & &1["run_id"])

    turn_evidence_by_run =
      Map.new(collections.turns_by_run_id, fn {run_id, projection} ->
        {run_id, projection.evidence}
      end)

    preludes_by_run = Enum.group_by(collections.effective_preludes, & &1["run_id"])
    sources_by_run = Enum.group_by(collections.generated_sources, & &1["run_id"])

    effective_preludes =
      Enum.map(collections.effective_preludes, fn prelude ->
        Map.put(
          prelude,
          "relationships",
          dependency_relations(prelude, trace_facts, preludes_by_run)
        )
      end)

    generated_sources =
      Enum.map(collections.generated_sources, fn source ->
        relationships =
          [producing_turn_relation(source, turns_by_run, turn_evidence_by_run)] ++
            prelude_relations(source, preludes_by_run)

        Map.put(source, "relationships", relationships)
      end)

    execution_errors =
      Enum.map(collections.execution_errors, fn error ->
        facts = Map.get(trace_facts, error["run_id"], %{})

        sources = Map.get(sources_by_run, error["run_id"], [])

        Map.put(error, "relationships", error_relations(error, facts, sources))
      end)

    generated_relationships = relationships_by_generated_key(generated_sources)

    %{
      collections
      | effective_preludes: effective_preludes,
        generated_sources: generated_sources,
        execution_errors: execution_errors,
        turns: mirror_generated_relationships(collections.turns, generated_relationships),
        turns_by_run_id:
          Map.new(collections.turns_by_run_id, fn {run_id, projection} ->
            {run_id,
             Map.replace_lazy(
               projection,
               :items,
               &mirror_generated_relationships(&1, generated_relationships)
             )}
          end)
    }
  end

  # A turn embeds the same generated-source items the `generated_sources`
  # collection publishes, but `ConversationProjection` builds them before this
  # module runs, so they used to carry identity without the relationship
  # objects. A generic walker then needed an extra exact read by
  # `evaluation_id` just to obtain followable links. Mirror the already
  # computed relationships onto the embedded copies instead of recomputing
  # them: one projection, one implementation, and `producing_turn` on an
  # embedded entry resolves back to the turn that carries it.
  defp mirror_generated_relationships(turns, generated_relationships) do
    Enum.map(turns, fn turn ->
      Map.replace_lazy(turn, "generated", fn generated ->
        Enum.map(generated, &mirror_generated_entry(&1, generated_relationships))
      end)
    end)
  end

  defp mirror_generated_entry(entry, generated_relationships) do
    case Map.fetch(generated_relationships, generated_key(entry)) do
      {:ok, relations} -> Map.put(entry, "relationships", relations)
      :error -> entry
    end
  end

  # `{run_id, sequence}` is the private-inspection identity of one retained
  # evaluation-source record. A repeated key can only come from malformed
  # input, so drop it rather than attach another item's links.
  defp relationships_by_generated_key(generated_sources) do
    generated_sources
    |> Enum.group_by(&generated_key/1, & &1["relationships"])
    |> Enum.flat_map(fn
      {key, [relations]} -> [{key, relations}]
      {_key, _ambiguous} -> []
    end)
    |> Map.new()
  end

  defp generated_key(item), do: {item["run_id"], item["sequence"]}

  # A component ID is not an occurrence identity: the same component can be
  # frozen into the workflow environment and into several missions, each with
  # its own dependency edges. Qualify every dependency edge with the
  # occurrence that owns it, and refuse to guess when the frozen positional
  # graph does not hold.
  defp dependency_relations(prelude, trace_facts, preludes_by_run) do
    with {:ok, graph} <- prelude_graph(prelude, trace_facts),
         {:ok, component_ids, dependency_indices} <- validated_graph(graph),
         index when is_integer(index) <-
           Enum.find_index(component_ids, &(&1 == prelude["component_id"])) do
      dependency_indices
      |> Enum.at(index)
      |> Enum.map(fn dependency_index ->
        filters = prelude_filters(prelude, Enum.at(component_ids, dependency_index))

        state =
          preludes_by_run
          |> Map.get(prelude["run_id"], [])
          |> Enum.count(&prelude_matches?(&1, filters))
          |> relation_state()

        relation("dependency_prelude_source", "dependency", "prelude_sources", filters, state)
      end)
    else
      _unknown ->
        [
          relation(
            "dependency_prelude_source",
            "dependency",
            "prelude_sources",
            nil,
            "incomplete"
          )
        ]
    end
  end

  defp prelude_graph(%{"run_id" => run_id, "environment" => "workflow"}, trace_facts),
    do: fetch_graph(get_in(trace_facts, [run_id, "workflow_prelude"]))

  defp prelude_graph(
         %{"run_id" => run_id, "environment" => "mission", "mission_name" => mission_name},
         trace_facts
       )
       when is_binary(mission_name),
       do: fetch_graph(get_in(trace_facts, [run_id, "missions", mission_name, "prelude"]))

  defp prelude_graph(_prelude, _trace_facts), do: :error

  defp fetch_graph(graph) when is_map(graph), do: {:ok, graph}
  defp fetch_graph(_graph), do: :error

  # The trace-log schema only requires `dependency_indices` to be lists of
  # non-negative integers, but the frozen-bundle contract is stronger: the
  # outer list is positionally aligned with `component_ids`, and each entry
  # holds unique ascending indices strictly earlier than its own position.
  # Reading a graph that violates any of that would silently attribute one
  # component's dependencies to another, so validate the whole contract before
  # relying on any single row.
  defp validated_graph(%{"component_ids" => component_ids} = graph)
       when is_list(component_ids) do
    dependency_indices = graph["dependency_indices"]

    valid? =
      Enum.all?(component_ids, &(is_binary(&1) and &1 != "")) and
        component_ids == Enum.uniq(component_ids) and
        is_list(dependency_indices) and
        length(dependency_indices) == length(component_ids) and
        dependency_indices |> Enum.with_index() |> Enum.all?(&valid_dependency_row?/1)

    if valid?, do: {:ok, component_ids, dependency_indices}, else: :error
  end

  defp validated_graph(_graph), do: :error

  defp valid_dependency_row?({indices, position}) when is_list(indices) do
    Enum.all?(indices, &(is_integer(&1) and &1 >= 0 and &1 < position)) and
      indices == Enum.sort(indices) and indices == Enum.uniq(indices)
  end

  defp valid_dependency_row?(_row), do: false

  defp prelude_filters(prelude, component_id) do
    %{"component_id" => component_id, "environment" => prelude["environment"]}
    |> maybe_put("mission_name", prelude["mission_name"])
  end

  defp prelude_matches?(prelude, filters) do
    prelude["component_id"] == filters["component_id"] and
      prelude["environment"] == filters["environment"] and
      prelude["mission_name"] == filters["mission_name"]
  end

  defp relation_state(0), do: "unavailable"
  defp relation_state(1), do: "complete"
  defp relation_state(_many), do: "ambiguous"

  defp error_relations(error, trace_facts, generated_sources) do
    workflow_evaluation_id = error["evaluation_id"]
    canonical_state = if complete_canonical?(trace_facts), do: "complete", else: "incomplete"

    {boundary_state, boundary_filters} =
      boundary_failure_state_and_filters(
        trace_facts,
        workflow_evaluation_id,
        canonical_state
      )

    [
      relation(
        "boundary_failure",
        "causation",
        "activity",
        boundary_filters,
        boundary_state
      ),
      relation(
        "child_evaluations",
        "nesting",
        "activity",
        %{"parent_evaluation_id" => workflow_evaluation_id},
        canonical_state
      )
      | producer_relations(error, trace_facts, boundary_state, generated_sources)
    ]
  end

  defp complete_canonical?(trace_facts) do
    Map.get(trace_facts, "terminal?", false) and
      not Map.get(trace_facts, "events_dropped?", false)
  end

  defp boundary_failure_state_and_filters(trace_facts, evaluation_id, canonical_state) do
    case get_in(trace_facts, ["evaluation_statuses", evaluation_id]) do
      "error" ->
        {canonical_state, %{"evaluation_id" => evaluation_id, "status" => "error"}}

      status when is_binary(status) ->
        {"unavailable", nil}

      _missing when canonical_state == "complete" ->
        {"unavailable", nil}

      _missing ->
        {"incomplete", nil}
    end
  end

  defp producer_relations(error, trace_facts, boundary_state, generated_sources) do
    producer = get_in(error, ["details", "boundary_producer"])
    evaluation_ids = if is_map(producer), do: producer["evaluation_ids"], else: nil
    complete? = is_map(producer) and producer["complete?"] == true

    case evaluation_ids do
      [evaluation_id] when is_binary(evaluation_id) ->
        {producer_state, filters} =
          producer_state_and_filters(
            error,
            trace_facts,
            boundary_state,
            evaluation_id,
            complete?
          )

        {source_state, source_filters} =
          source_state_and_filters(
            generated_sources,
            evaluation_id,
            complete?,
            producer_state,
            filters
          )

        [
          relation(
            "direct_boundary_producer",
            "causation",
            "activity",
            filters,
            producer_state
          ),
          relation(
            "generated_source",
            "association",
            "generated_sources",
            source_filters,
            source_state
          )
        ]

      evaluation_ids when is_list(evaluation_ids) and evaluation_ids != [] ->
        Enum.flat_map(evaluation_ids, fn evaluation_id ->
          producer_candidate_relations(
            error,
            trace_facts,
            boundary_state,
            generated_sources,
            evaluation_id,
            complete?
          )
        end)

      _other ->
        [
          relation(
            "direct_boundary_producer",
            "causation",
            "activity",
            nil,
            if(boundary_state == "unavailable" or complete?,
              do: "unavailable",
              else: "incomplete"
            )
          )
        ]
    end
  end

  defp producer_candidate_relations(
         error,
         trace_facts,
         boundary_state,
         generated_sources,
         evaluation_id,
         complete?
       )
       when is_binary(evaluation_id) do
    {producer_state, filters} =
      producer_state_and_filters(
        error,
        trace_facts,
        boundary_state,
        evaluation_id,
        complete?
      )

    candidate_state = if producer_state == "complete", do: "ambiguous", else: producer_state

    {source_state, source_filters} =
      source_state_and_filters(
        generated_sources,
        evaluation_id,
        complete?,
        candidate_state,
        filters
      )

    [
      relation(
        "direct_boundary_producer",
        "causation",
        "activity",
        filters,
        candidate_state
      ),
      relation(
        "generated_source",
        "association",
        "generated_sources",
        source_filters,
        source_state
      )
    ]
  end

  defp producer_candidate_relations(
         _error,
         _trace_facts,
         _boundary_state,
         _generated_sources,
         _evaluation_id,
         _complete?
       ),
       do: []

  defp producer_state_and_filters(
         error,
         trace_facts,
         boundary_state,
         evaluation_id,
         complete?
       ) do
    status = get_in(trace_facts, ["evaluation_statuses", evaluation_id])

    canonical_producer? =
      get_in(trace_facts, ["parent_evaluation_ids", evaluation_id]) == error["evaluation_id"] and
        status in ["returned", "continued"]

    cond do
      boundary_state == "unavailable" ->
        {"unavailable", nil}

      not complete? ->
        {"incomplete", maybe_status_filter(evaluation_id, status)}

      boundary_state == "complete" and canonical_producer? ->
        {"complete", %{"evaluation_id" => evaluation_id, "status" => status}}

      boundary_state == "complete" ->
        {"unavailable", nil}

      true ->
        {"incomplete", maybe_status_filter(evaluation_id, status)}
    end
  end

  defp maybe_status_filter(evaluation_id, status) when is_binary(status),
    do: %{"evaluation_id" => evaluation_id, "status" => status}

  defp maybe_status_filter(evaluation_id, _status), do: %{"evaluation_id" => evaluation_id}

  defp source_state_and_filters(
         _generated_sources,
         _evaluation_id,
         _complete?,
         "unavailable",
         _producer_filters
       ),
       do: {"unavailable", nil}

  defp source_state_and_filters(
         _generated_sources,
         evaluation_id,
         false,
         _producer_state,
         _producer_filters
       ),
       do: {"incomplete", %{"evaluation_id" => evaluation_id}}

  defp source_state_and_filters(
         generated_sources,
         evaluation_id,
         true,
         producer_state,
         _producer_filters
       ) do
    case Enum.count(generated_sources, &(&1["evaluation_id"] == evaluation_id)) do
      0 -> {"unavailable", nil}
      1 -> {producer_state, %{"evaluation_id" => evaluation_id}}
      _many -> {"ambiguous", %{"evaluation_id" => evaluation_id}}
    end
  end

  defp producing_turn_relation(source, turns_by_run, evidence_by_run) do
    matches =
      turns_by_run
      |> Map.get(source["run_id"], [])
      |> Enum.filter(fn turn ->
        Enum.any?(turn["generated"], &(&1["evaluation_id"] == source["evaluation_id"]))
      end)

    evidence_complete? =
      evidence_by_run
      |> Map.get(source["run_id"], %{})
      |> Map.get("complete?", false)

    state =
      cond do
        matches == [] and evidence_complete? -> "unavailable"
        matches == [] -> "incomplete"
        ambiguous_turn_match?(matches, source["evaluation_id"]) -> "ambiguous"
        not evidence_complete? -> "incomplete"
        true -> "complete"
      end

    relation(
      "producing_turn",
      "association",
      "turns",
      %{"evaluation_id" => source["evaluation_id"]},
      state
    )
  end

  defp ambiguous_turn_match?([turn], evaluation_id) do
    turn["generated"]
    |> Enum.filter(&(&1["evaluation_id"] == evaluation_id))
    |> Enum.any?(& &1["association_ambiguous?"])
  end

  defp ambiguous_turn_match?(_matches, _evaluation_id), do: true

  defp prelude_relations(%{"prelude_calls_available?" => false}, _preludes_by_run) do
    [relation("referenced_prelude_source", "association", "prelude_sources", nil, "incomplete")]
  end

  defp prelude_relations(source, preludes_by_run) do
    source
    |> Map.get("prelude_calls", [])
    |> Enum.map(& &1["component_id"])
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn component_id ->
      filters =
        %{
          "component_id" => component_id,
          "environment" => source["environment"]
        }
        |> maybe_put("mission_name", source["mission_name"])

      matches =
        preludes_by_run
        |> Map.get(source["run_id"], [])
        |> Enum.count(fn prelude ->
          prelude["component_id"] == component_id and
            prelude["environment"] == source["environment"] and
            prelude["mission_name"] == source["mission_name"]
        end)

      state =
        case matches do
          0 -> "unavailable"
          1 -> "complete"
          _many -> "ambiguous"
        end

      relation("referenced_prelude_source", "association", "prelude_sources", filters, state)
    end)
  end

  defp relation(rel, semantics, target_collection, filters, state) do
    %{
      "rel" => rel,
      "semantics" => semantics,
      "target_collection" => target_collection,
      "filters" => filters,
      "state" => state
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
