defmodule PtcRunner.Kernel.TraceLog.Query do
  @moduledoc "Canonical run analysis, filtering and bounded pagination over loaded events."

  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.LLMBudget
  alias PtcRunner.Kernel.LLMUsageSummary
  alias PtcRunner.Kernel.ModelCapabilities
  alias PtcRunner.Kernel.QueryCursor
  alias PtcRunner.Kernel.QueryValidation
  alias PtcRunner.Kernel.ResultLimit
  alias PtcRunner.Kernel.RuntimeTools
  alias PtcRunner.Kernel.TraceIsolationPresentation

  @default_limit 20
  @max_limit 100
  @max_cursor_bytes 1_024
  @max_string_bytes 256

  defp maybe_run_isolated(
         {:error, :not_found},
         operation,
         %{"run_id" => run_id},
         known_isolated_run_ids
       )
       when operation in [:get_run, :list_turns] and is_binary(run_id) do
    if MapSet.member?(known_isolated_run_ids, run_id),
      do: {:error, :run_isolated},
      else: {:error, :not_found}
  end

  defp maybe_run_isolated(result, _operation, _arguments, _known_isolated_run_ids), do: result

  @doc false
  @spec query_loaded(
          [map()],
          binary(),
          :list_runs | :get_run | :list_turns | :counters,
          map(),
          pos_integer(),
          :sanitized | :private | %{binary() => :sanitized | :private},
          map(),
          MapSet.t(binary())
        ) :: {:ok, map()} | {:error, atom()}
  def query_loaded(
        events,
        source_id,
        operation,
        arguments,
        max_result_bytes,
        source_kind,
        metadata \\ %{},
        known_isolated_run_ids \\ MapSet.new()
      )

  def query_loaded(
        events,
        source_id,
        operation,
        arguments,
        max_result_bytes,
        source_kind,
        metadata,
        known_isolated_run_ids
      )
      when is_list(events) and is_binary(source_id) and
             operation in [:list_runs, :get_run, :list_turns, :counters] and is_map(arguments) and
             is_integer(max_result_bytes) and max_result_bytes > 0 and
             (source_kind in [:sanitized, :private] or is_map(source_kind)) and is_map(metadata) and
             is_struct(known_isolated_run_ids, MapSet) do
    if valid_query_source_kind?(events, source_kind) do
      operation
      |> execute(events, source_id, arguments, max_result_bytes, source_kind, metadata)
      |> maybe_run_isolated(operation, arguments, known_isolated_run_ids)
    else
      {:error, :invalid_query}
    end
  end

  def query_loaded(
        _events,
        _source_id,
        _operation,
        _arguments,
        _max_result_bytes,
        _source_kind,
        _metadata,
        _known_isolated_run_ids
      ),
      do: {:error, :invalid_query}

  @doc false
  @spec source_presence_metadata(atom(), map()) :: map()
  # Only the two operations that answer "what does this source hold" carry the
  # exclusion count. A run-scoped answer would attach it to a single run,
  # where it would state nothing true about that run.
  def source_presence_metadata(operation, metadata)
      when operation in [:list_runs, :counters] and is_map(metadata),
      do: metadata

  def source_presence_metadata(_operation, _metadata), do: %{}

  @doc false
  @spec directory_source_metadata(map()) :: map()
  def directory_source_metadata(%{
        excluded_trace_files: excluded,
        isolated_components: components,
        known_isolated_run_ids: known_run_ids
      }) do
    Map.merge(excluded, TraceIsolationPresentation.metadata(components, known_run_ids))
  end

  def directory_source_metadata(%{excluded_trace_files: excluded}), do: excluded

  @doc false
  @spec compile_analysis([map()], :sanitized | :private | map()) :: map()
  def compile_analysis(events, source_kind) when is_list(events) do
    summaries = runs(events, source_kind)
    summaries_by_id = Map.new(summaries, &{&1["run_id"], &1})

    facts =
      events
      |> Enum.group_by(& &1["run_id"])
      |> Map.new(fn {run_id, run_events} ->
        summary = Map.fetch!(summaries_by_id, run_id)

        expected_model_exchanges =
          run_events
          |> Enum.filter(fn event ->
            event["type"] == "capability-started" and
              stringify(event_data(event, "environment")) == "workflow" and
              ModelCapabilities.chat?(event_data(event, "name"))
          end)
          |> Enum.map(&event_data(&1, "capability_id"))
          |> Enum.filter(&is_binary/1)
          |> Enum.uniq()
          |> Enum.sort()

        parent_evaluation_ids =
          run_events
          |> Enum.filter(&(&1["type"] == "evaluation-started"))
          |> Map.new(fn event ->
            {event_data(event, "evaluation_id"), event_data(event, "parent_evaluation_id")}
          end)
          |> Map.reject(fn {evaluation_id, parent_evaluation_id} ->
            not is_binary(evaluation_id) or not is_binary(parent_evaluation_id)
          end)

        evaluation_statuses =
          run_events
          |> Enum.filter(&(&1["type"] == "evaluation-stopped"))
          |> Map.new(fn event ->
            {event_data(event, "evaluation_id"), stringify(event_data(event, "status"))}
          end)
          |> Map.reject(fn {evaluation_id, status} ->
            not is_binary(evaluation_id) or not is_binary(status)
          end)

        capabilities =
          run_events
          |> Enum.filter(&(&1["type"] == "capability-started"))
          |> Map.new(fn event ->
            {event_data(event, "capability_id"),
             %{
               "environment" => stringify(event_data(event, "environment")),
               "mission_name" => event_data(event, "mission_name"),
               "name" => event_data(event, "name")
             }}
          end)
          |> Map.reject(fn {id, _value} -> not is_binary(id) end)

        evaluations =
          run_events
          |> Enum.filter(&(&1["type"] == "evaluation-started"))
          |> Map.new(fn event ->
            {event_data(event, "evaluation_id"),
             %{
               "environment" => stringify(event_data(event, "environment")),
               "mission_name" => event_data(event, "mission_name"),
               "source_hash" => event_data(event, "source_hash"),
               "source_bytes" => event_data(event, "source_bytes")
             }}
          end)
          |> Map.reject(fn {id, _value} -> not is_binary(id) end)

        {run_id,
         %{
           "trace_id" => summary["trace_id"],
           "capabilities" => capabilities,
           "evaluations" => evaluations,
           "dropped_event_counts" => inspection_dropped_counts(run_events),
           "terminal_result" => inspection_terminal_result(run_events),
           "expected_model_exchange_ids" => expected_model_exchanges,
           "evaluation_statuses" => evaluation_statuses,
           "parent_evaluation_ids" => parent_evaluation_ids,
           "workflow_prelude" => summary["workflow_prelude"],
           "missions" => summary["missions"],
           "terminal?" => Enum.any?(run_events, &(&1["type"] == "run-stopped")),
           "events_dropped?" => Enum.any?(run_events, &(&1["type"] == "events-dropped"))
         }}
      end)

    %{
      runs: summaries,
      runs_by_id: summaries_by_id,
      facts_by_run_id: facts
    }
  end

  defp inspection_dropped_counts(events) do
    marker = Enum.find(events, &(&1["type"] == "events-dropped"))
    terminal = Enum.find(events, &(&1["type"] == "run-stopped"))
    marker_counts = event_data(marker, "counts")
    terminal_counts = get_in(terminal || %{}, ["data", "usage", "events_dropped"])

    if is_map(marker_counts) and marker_counts == terminal_counts,
      do: marker_counts,
      else: %{}
  end

  defp inspection_terminal_result(events) do
    case Enum.filter(events, &(&1["type"] == "run-stopped")) do
      [terminal] ->
        %{
          "outcome" => stringify(event_data(terminal, "outcome")),
          "result_hash" => event_data(terminal, "result_hash")
        }

      _other ->
        nil
    end
  end

  defp valid_query_source_kind?(_events, source_kind)
       when source_kind in [:sanitized, :private],
       do: true

  defp valid_query_source_kind?(events, run_sources) when is_map(run_sources) do
    run_ids = events |> MapSet.new(& &1["run_id"]) |> MapSet.to_list() |> Enum.sort()

    Enum.sort(Map.keys(run_sources)) == run_ids and
      Enum.all?(run_sources, fn {run_id, source_kind} ->
        is_binary(run_id) and source_kind in [:sanitized, :private]
      end)
  end

  @doc false
  defp execute(
         :list_runs,
         events,
         source_id,
         arguments,
         max_result_bytes,
         source_kind,
         metadata
       ) do
    with :ok <-
           validate_keys(
             arguments,
             ~w(limit cursor status run_id trace_id tags name bundle model provider from to)
           ),
         :ok <- validate_run_filters(arguments),
         {:ok, page} <- page_options(arguments, source_id, :list_runs) do
      events
      |> runs(source_kind)
      |> filter_runs(arguments)
      |> paginate(page, source_id, max_result_bytes, metadata)
    end
  end

  defp execute(
         :get_run,
         events,
         _source_id,
         %{"run_id" => run_id} = arguments,
         max_result_bytes,
         source_kind,
         result_metadata
       ) do
    with :ok <- validate_keys(arguments, ["run_id"]),
         :ok <- valid_string(run_id),
         metadata when not is_nil(metadata) <-
           Enum.find(runs(events, source_kind), &(&1["run_id"] == run_id)),
         result = Map.merge(metadata, result_metadata),
         :ok <- ResultLimit.validate(result, max_result_bytes) do
      {:ok, result}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp execute(
         :get_run,
         _events,
         _source_id,
         _arguments,
         _max_result_bytes,
         _source_kind,
         _metadata
       ),
       do: {:error, :invalid_query}

  defp execute(
         :list_turns,
         events,
         source_id,
         %{"run_id" => run_id} = arguments,
         max_result_bytes,
         _source_kind,
         metadata
       ) do
    with :ok <-
           validate_keys(
             arguments,
             ~w(run_id limit cursor status evaluation_id parent_evaluation_id capability mission_name)
           ),
         :ok <- valid_string(run_id),
         :ok <- validate_turn_filters(arguments),
         true <- Enum.any?(events, &(&1["run_id"] == run_id)),
         {:ok, page} <- page_options(arguments, source_id, :list_turns) do
      events
      |> Enum.filter(&(&1["run_id"] == run_id and turn_matches?(&1, arguments)))
      |> Enum.sort_by(& &1["sequence"])
      |> paginate(page, source_id, max_result_bytes, metadata)
    else
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp execute(
         :list_turns,
         _events,
         _source_id,
         _arguments,
         _max_result_bytes,
         _source_kind,
         _metadata
       ),
       do: {:error, :invalid_query}

  defp execute(
         :counters,
         events,
         _source_id,
         arguments,
         max_result_bytes,
         source_kind,
         metadata
       ) do
    with :ok <-
           validate_keys(
             arguments,
             ~w(status run_id trace_id tags name bundle model provider from to mission_name)
           ),
         :ok <- validate_run_filters(arguments),
         :ok <- optional_strings(arguments, ["mission_name"]) do
      selected_ids =
        events |> runs(source_kind) |> filter_runs(arguments) |> MapSet.new(& &1["run_id"])

      selected_run_events =
        Enum.filter(events, &MapSet.member?(selected_ids, &1["run_id"]))

      selected =
        Enum.filter(
          selected_run_events,
          &mission_matches?(&1, arguments["mission_name"])
        )

      aggregate = counters(selected, selected_run_events)

      fit_metadata(metadata, max_result_bytes, &Map.merge(aggregate, &1))
    end
  end

  defp runs(events, source_kind) do
    events
    |> Enum.group_by(& &1["run_id"])
    |> Enum.map(fn {run_id, run_events} ->
      run_metadata(run_id, run_events, run_source_kind(source_kind, run_id))
    end)
    # Parse each timestamp once; comparisons otherwise repeat ISO-8601 parsing
    # across every comparison on every page of a broad cohort query.
    |> Enum.sort_by(&{timestamp_sort_value(&1["start_timestamp"]), &1["run_id"]}, :desc)
  end

  defp run_source_kind(source_kind, _run_id) when source_kind in [:sanitized, :private],
    do: source_kind

  defp run_source_kind(run_sources, run_id), do: Map.fetch!(run_sources, run_id)

  defp run_metadata(run_id, events, source_kind) do
    started = Enum.find(events, &(&1["type"] == "run-started"))
    stopped = events |> Enum.filter(&(&1["type"] == "run-stopped")) |> List.last()
    labels = event_data(started, "labels", %{})
    missions = run_missions(started)
    call_counts = run_call_counts(events, stopped)

    %{
      "run_id" => run_id,
      "trace_id" => event_value(started || List.first(events), "trace_id"),
      "start_timestamp" => event_value(started, "timestamp"),
      "stop_timestamp" => event_value(stopped, "timestamp"),
      "status" => stringify(event_data(stopped, "outcome")),
      "result_hash" => event_data(stopped, "result_hash"),
      "terminal_reason" => event_data(stopped, "reason"),
      "terminal_limit" => event_data(stopped, "limit"),
      "terminal_limit_value" => event_data(stopped, "limit_value"),
      "labels" => labels,
      "tags" => Map.get(labels, "tags", %{}),
      "name" => Map.get(labels, "name"),
      "model" => Map.get(labels, "model"),
      "provider" => Map.get(labels, "provider"),
      "evaluations" => evaluation_count(events),
      "subordinate_evaluations" => evaluation_count(events, "mission"),
      "subordinate_source_checks" => subordinate_source_checks(stopped),
      "workflow_capability_calls" => call_counts.workflow,
      "mission_capability_calls" => call_counts.mission,
      "llm_calls" => call_counts.llm,
      "decision_calls" => call_counts.decision,
      "call_counts_complete" => call_counts.complete?,
      "llm_budget" => terminal_llm_budget(stopped),
      "llm_spend" => terminal_llm_spend(stopped),
      "error_count" => Enum.count(events, &error_event?/1),
      "duration_ms" => duration_ms(started, stopped),
      "workflow_prelude" => event_data(started, "workflow_prelude", empty_prelude()),
      "missions" => missions,
      "component_overrides" => event_data(started, "component_overrides", []),
      "connector_snapshots" => event_data(started, "connector_snapshots", []),
      "installation_config_digests" => event_data(started, "installation_config_digests", %{}),
      "session_profile" => event_data(started, "session_profile"),
      "positions" => event_positions(started),
      "complete" => not is_nil(stopped),
      "truncated" => Enum.any?(events, &(&1["type"] == "events-dropped")),
      "schema_version" => 2,
      "source" => Atom.to_string(source_kind)
    }
    |> Map.merge(LLMUsageSummary.terminal_projection({:ok, events}))
  end

  defp terminal_llm_budget(stopped) do
    case LLMBudget.validate_terminal_projection(event_data(stopped, "usage", %{})["llm_budget"]) do
      {:ok, budget} -> budget
      {:error, :invalid_llm_budget} -> nil
    end
  end

  defp terminal_llm_spend(stopped) do
    case LLMUsageSummary.validate_spend(event_data(stopped, "usage", %{})["llm_spend"]) do
      {:ok, spend} -> spend
      {:error, :invalid_llm_spend} -> nil
    end
  end

  defp run_call_counts(events, stopped) do
    case event_data(stopped, "usage", %{})["capability_calls"] do
      %{"workflow" => workflow, "mission" => mission} = calls
      when map_size(calls) == 2 and is_map(workflow) and is_map(mission) ->
        %{
          workflow: Enum.sum(Map.values(workflow)),
          mission: Enum.sum(Map.values(mission)),
          llm: chat_call_count(workflow),
          decision: Map.get(workflow, "decision-request", 0),
          complete?: true
        }

      calls when is_map(calls) and map_size(calls) > 0 ->
        if Enum.all?(calls, fn {name, count} ->
             is_binary(name) and is_integer(count) and count >= 0
           end) do
          %{
            workflow: scoped_terminal_call_count(calls, "workflow/"),
            mission: scoped_terminal_call_count(calls, "mission/"),
            llm: chat_call_count(calls, "workflow/"),
            decision: Map.get(calls, "workflow/decision-request", 0),
            complete?: true
          }
        else
          observed_call_counts(events)
        end

      calls when is_map(calls) ->
        %{workflow: 0, mission: 0, llm: 0, decision: 0, complete?: true}

      _legacy_or_incomplete ->
        observed_call_counts(events)
    end
  end

  defp observed_call_counts(events) do
    %{
      workflow: quota_backed_capability_call_count(events, "workflow"),
      mission: quota_backed_capability_call_count(events, "mission"),
      llm: capability_name_count(events, "workflow"),
      decision:
        Enum.count(
          events,
          &(&1["type"] == "capability-started" and
              stringify(event_data(&1, "environment")) == "workflow" and
              event_data(&1, "name") == "decision-request")
        ),
      complete?: false
    }
  end

  defp quota_backed_capability_call_count(events, environment) do
    Enum.count(events, fn event ->
      name = event_data(event, "name")

      event["type"] == "capability-started" and
        stringify(event_data(event, "environment")) == environment and
        is_binary(name) and
        not runtime_instrumented_name?(environment, name)
    end)
  end

  defp runtime_instrumented_name?("workflow", name),
    do: RuntimeTools.instrumented_name?(:workflow, name)

  defp runtime_instrumented_name?("mission", name),
    do: RuntimeTools.instrumented_name?(:mission, name)

  defp scoped_terminal_call_count(calls, prefix) do
    Enum.reduce(calls, 0, fn {name, count}, total ->
      if String.starts_with?(name, prefix), do: total + count, else: total
    end)
  end

  # Absent prelude data projects to an empty graph.
  defp empty_prelude,
    do: %{"component_ids" => [], "dependency_indices" => [], "hash" => nil}

  defp run_missions(started), do: event_data(started, "missions", %{})

  defp subordinate_source_checks(%{
         "data" => %{"usage" => %{"subordinate_source_checks" => count}}
       })
       when is_integer(count) and count >= 0,
       do: count

  defp subordinate_source_checks(_stopped), do: 0

  defp event_positions(%{"sequence" => sequence}) when is_integer(sequence) and sequence > 0,
    do: [sequence]

  defp event_positions(_event), do: []

  defp filter_runs(items, arguments) do
    Enum.filter(items, fn item ->
      equal_filter?(item, arguments, "status") and equal_filter?(item, arguments, "run_id") and
        equal_filter?(item, arguments, "trace_id") and equal_filter?(item, arguments, "name") and
        bundle_filter?(item, arguments["bundle"]) and
        equal_filter?(item, arguments, "model") and equal_filter?(item, arguments, "provider") and
        tags_match?(item["tags"], arguments["tags"]) and
        QueryValidation.after_or_equal?(item["start_timestamp"], arguments["from"]) and
        QueryValidation.before_or_equal?(item["start_timestamp"], arguments["to"])
    end)
  end

  defp equal_filter?(item, arguments, key),
    do: is_nil(arguments[key]) or item[key] == arguments[key]

  defp bundle_filter?(_item, nil), do: true

  defp bundle_filter?(item, bundle),
    do: get_in(item, ["workflow_prelude", "hash"]) == bundle

  defp tags_match?(_tags, nil), do: true

  defp tags_match?(tags, expected),
    do: Enum.all?(expected, fn {key, value} -> tags[key] == value end)

  defp timestamp_sort_value(nil), do: -1

  defp timestamp_sort_value(timestamp) do
    {:ok, datetime, 0} = DateTime.from_iso8601(timestamp)
    DateTime.to_unix(datetime, :microsecond)
  end

  defp turn_matches?(event, arguments) do
    status = stringify(event_data(event, "status") || event_data(event, "outcome"))

    (is_nil(arguments["status"]) or status == arguments["status"]) and
      (is_nil(arguments["evaluation_id"]) or
         event_data(event, "evaluation_id") == arguments["evaluation_id"]) and
      (is_nil(arguments["parent_evaluation_id"]) or
         event_data(event, "parent_evaluation_id") == arguments["parent_evaluation_id"]) and
      (is_nil(arguments["capability"]) or event_data(event, "name") == arguments["capability"]) and
      mission_matches?(event, arguments["mission_name"])
  end

  defp mission_matches?(_event, nil), do: true

  defp mission_matches?(event, expected) when is_binary(expected),
    do: event_mission_name(event) == expected

  defp event_mission_name(%{"schema_version" => 2} = event) do
    if stringify(event_data(event, "environment")) == "mission",
      do: event_data(event, "mission_name"),
      else: nil
  end

  defp event_mission_name(_event), do: nil

  defp counters(events, attribution_events) do
    %{
      "events" => length(events),
      "runs" => events |> Enum.map(& &1["run_id"]) |> Enum.uniq() |> length(),
      "errors" => Enum.count(events, &error_event?/1),
      "evaluations" => Enum.count(events, &(&1["type"] == "evaluation-started")),
      "evaluations_by_mission" => evaluations_by_mission(events),
      "workflow_capability_calls" => capability_call_count(events, "workflow"),
      "mission_capability_calls" => capability_call_count(events, "mission")
    }
    |> Map.merge(LLMUsageSummary.summarize(events, attribution_events))
  end

  defp capability_call_count(events, environment) do
    Enum.count(events, fn event ->
      event["type"] == "capability-started" and
        stringify(event_data(event, "environment")) == environment
    end)
  end

  defp chat_call_count(calls, prefix \\ "") do
    Enum.reduce(calls, 0, fn {name, count}, total ->
      if is_binary(name) and String.starts_with?(name, prefix) and
           ModelCapabilities.chat?(String.replace_prefix(name, prefix, "")),
         do: total + count,
         else: total
    end)
  end

  defp capability_name_count(events, environment) do
    Enum.count(events, fn event ->
      event["type"] == "capability-started" and
        stringify(event_data(event, "environment")) == environment and
        ModelCapabilities.chat?(event_data(event, "name"))
    end)
  end

  defp evaluation_count(events), do: Enum.count(events, &(&1["type"] == "evaluation-started"))

  defp evaluation_count(events, environment) do
    Enum.count(events, fn event ->
      event["type"] == "evaluation-started" and
        stringify(event_data(event, "environment")) == environment
    end)
  end

  # The summary has to agree with the transcript a reader opens next, which
  # renders one row per evaluation, capability call and exceeded limit. Counting
  # every event carrying an error status also counted `run-stopped`, so a single
  # failed capability call reported three errors against the rows that show it.
  # The run's own outcome is its status, not a fourth error.
  defp error_event?(event) do
    event["type"] == "limit-exceeded" or
      (event["type"] in ["capability-stopped", "evaluation-stopped"] and
         stringify(event_data(event, "status")) == "error")
  end

  defp duration_ms(nil, _stopped), do: nil
  defp duration_ms(_started, nil), do: nil

  defp duration_ms(started, stopped) do
    with {:ok, started_at, 0} <- DateTime.from_iso8601(started["timestamp"]),
         {:ok, stopped_at, 0} <- DateTime.from_iso8601(stopped["timestamp"]) do
      max(DateTime.diff(stopped_at, started_at, :millisecond), 0)
    else
      _ -> nil
    end
  end

  defp page_options(arguments, source_id, operation) do
    QueryCursor.page_options(
      arguments,
      source_id,
      {operation, Map.drop(arguments, ["cursor", "limit"])},
      @default_limit,
      @max_limit,
      @max_cursor_bytes
    )
  end

  defp paginate(
         items,
         %{limit: limit, offset: offset, query_id: query_id},
         source_id,
         max_result_bytes,
         metadata
       ) do
    selected = items |> Enum.drop(offset) |> Enum.take(limit)
    fit_page(selected, items, offset, source_id, query_id, max_result_bytes, metadata)
  end

  # ex_dna:disable-for-next-line — TraceLog and InspectionQuery intentionally own separate source query implementations.
  defp fit_page(
         selected,
         all_items,
         offset,
         source_id,
         query_id,
         max_result_bytes,
         metadata
       ) do
    full_result = fn fitted_metadata ->
      page_result(selected, all_items, offset, source_id, query_id, fitted_metadata)
    end

    case fit_metadata_result(metadata, max_result_bytes, full_result) do
      {:ok, result, _fitted_metadata} ->
        {:ok, result}

      {:exhausted, fitted_metadata} ->
        fit_page_items(
          selected,
          all_items,
          offset,
          source_id,
          query_id,
          max_result_bytes,
          fitted_metadata
        )
    end
  end

  defp fit_page_items(
         selected,
         all_items,
         offset,
         source_id,
         query_id,
         max_result_bytes,
         metadata
       ) do
    base = page_result([], all_items, offset, source_id, query_id, metadata)

    cond do
      not ResultLimit.within?(base, max_result_bytes) ->
        {:error, :result_limit_exceeded}

      selected == [] ->
        {:ok, base}

      true ->
        context = {all_items, offset, source_id, query_id, max_result_bytes, metadata}
        fit_page_prefix(selected, context, 1, length(selected) - 1, nil)
    end
  end

  defp fit_metadata(metadata, max_result_bytes, build_result) do
    case fit_metadata_result(metadata, max_result_bytes, build_result) do
      {:ok, result, _metadata} -> {:ok, result}
      {:exhausted, _metadata} -> {:error, :result_limit_exceeded}
    end
  end

  defp fit_metadata_result(metadata, max_result_bytes, build_result) do
    result = build_result.(metadata)

    if ResultLimit.within?(result, max_result_bytes) do
      {:ok, result, metadata}
    else
      case TraceIsolationPresentation.shrink(metadata) do
        {:ok, smaller} -> fit_metadata_result(smaller, max_result_bytes, build_result)
        :exhausted -> {:exhausted, metadata}
      end
    end
  end

  # ex_dna:disable-for-next-line — TraceLog and InspectionQuery intentionally own separate source query implementations.
  defp fit_page_prefix(_selected, _context, lower, upper, best)
       when lower > upper do
    if best, do: {:ok, best}, else: {:error, :result_limit_exceeded}
  end

  defp fit_page_prefix(
         selected,
         {all_items, offset, source_id, query_id, max_result_bytes, metadata} = context,
         lower,
         upper,
         best
       ) do
    count = div(lower + upper, 2)

    result =
      page_result(Enum.take(selected, count), all_items, offset, source_id, query_id, metadata)

    if ResultLimit.within?(result, max_result_bytes) do
      fit_page_prefix(
        selected,
        context,
        count + 1,
        upper,
        result
      )
    else
      fit_page_prefix(
        selected,
        context,
        lower,
        count - 1,
        best
      )
    end
  end

  # ex_dna:disable-for-next-line — TraceLog and InspectionQuery intentionally own separate source query implementations.
  defp page_result(selected, all_items, offset, source_id, query_id, metadata) do
    next_offset = offset + length(selected)
    more? = next_offset < length(all_items)

    Map.merge(metadata, %{
      "items" => selected,
      "next_cursor" =>
        if(more?, do: QueryCursor.encode(next_offset, source_id, query_id), else: nil),
      "truncated" => more?,
      "omitted_count" => max(length(all_items) - next_offset, 0)
    })
  end

  defp validate_run_filters(arguments) do
    with :ok <-
           optional_strings(
             arguments,
             ~w(status run_id trace_id name bundle model provider from to)
           ),
         :ok <- valid_tags(arguments["tags"]),
         :ok <- valid_timestamp(arguments["from"]) do
      valid_timestamp(arguments["to"])
    end
  end

  defp validate_turn_filters(arguments),
    do:
      optional_strings(
        arguments,
        ~w(status evaluation_id parent_evaluation_id capability mission_name)
      )

  defp evaluations_by_mission(events) do
    events
    |> Enum.filter(&(&1["type"] == "evaluation-started"))
    |> Enum.map(&event_mission_name/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.frequencies()
  end

  defp optional_strings(arguments, keys) do
    if Enum.all?(keys, &(is_nil(arguments[&1]) or valid_string(arguments[&1]) == :ok)),
      do: :ok,
      else: {:error, :invalid_query}
  end

  defp valid_string(value), do: QueryValidation.string(value, @max_string_bytes)
  defp valid_tags(nil), do: :ok
  defp valid_tags(tags), do: QueryValidation.tags(tags, @max_string_bytes)
  defp valid_timestamp(nil), do: :ok
  defp valid_timestamp(timestamp), do: QueryValidation.timestamp(timestamp)

  defp validate_keys(arguments, allowed) do
    if JSONValue.map?(arguments) and Map.keys(arguments) -- allowed == [],
      do: :ok,
      else: {:error, :invalid_query}
  end

  defp event_data(nil, _key), do: nil
  defp event_data(event, key), do: get_in(event, ["data", key])
  defp event_data(nil, _key, default), do: default
  defp event_data(event, key, default), do: get_in(event, ["data", key]) || default
  defp event_value(nil, _key), do: nil
  defp event_value(event, key), do: event[key]
  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end
