defmodule PtcRunner.Kernel.LLMUsageSummary do
  @moduledoc false

  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.LLMUsage
  alias PtcRunner.Kernel.ProviderSnapshot
  alias PtcRunner.Kernel.ResultLimit

  @max_terminal_events 65_536
  @max_rows 128
  @max_result_bytes 1_000_000
  @total_keys ~w(input output total_cost)
  @event_keys ~w(schema_version run_id trace_id sequence timestamp type data)
  @event_type ~r/\A[a-z][a-z0-9-]{0,127}\z/
  @name ~r/\A[a-z][a-z0-9._-]{0,127}\z/

  @type summary :: %{
          required(String.t()) => [map()] | non_neg_integer()
        }

  # Terminal accounting pairs `llm-request` starts and stops by
  # `capability_id`. An unmatched start is an observed call with unknown
  # usage; it is not synthesized into a stop event.
  @spec terminal([map()]) :: {:ok, summary()} | {:error, :invalid_event_batch}
  def terminal(events) when is_list(events) do
    with true <- length(events) <= @max_terminal_events,
         {:ok, normalized} <- normalize_events(events),
         true <- JSONValue.value?(normalized),
         :ok <- validate_terminal_batch(normalized),
         :ok <- validate_accounting_retention(normalized),
         {:ok, calls} <- reconcile_llm_calls(normalized),
         summary <- summarize_calls(calls, normalized),
         true <- length(summary["llm_usage"]) <= @max_rows,
         true <- length(summary["llm_usage_by_model"]) <= @max_rows,
         :ok <- ResultLimit.validate(summary, @max_result_bytes) do
      {:ok, summary}
    else
      _invalid -> {:error, :invalid_event_batch}
    end
  rescue
    _exception -> {:error, :invalid_event_batch}
  end

  def terminal(_events), do: {:error, :invalid_event_batch}

  @spec summarize([map()], [map()] | nil) :: summary()
  def summarize(events, attribution_events \\ nil) when is_list(events) do
    attribution_events = attribution_events || events

    events
    |> Enum.filter(&llm_usage_event?/1)
    |> Enum.map(&call_from_stop/1)
    |> summarize_calls(attribution_events)
  end

  @doc """
  Builds alias-attributed rows from calls that carry no event stream.

  `doctor --connect` bills one request per probed occurrence and never publishes
  a trace, so it has the calls but not the events `summarize/2` reduces. The row
  shape, the counters, and the rule that drops `total_cost` unless every call
  priced its own are the ones a run reports, because a caller comparing the two
  is comparing the same measurement.
  """
  @spec alias_rows([{binary(), binary(), map() | nil}]) :: [map()]
  def alias_rows(calls) when is_list(calls) do
    calls
    |> Enum.reduce(%{}, fn {alias_name, revision, usage}, counters ->
      accumulate(counters, alias_name, revision, :ok, usage)
    end)
    |> rows()
  end

  @doc """
  Records one LLM call into a bounded `{alias, revision}` accumulator.

  Unlike `alias_rows/1`, this preserves failed calls so live spend can use the
  same classification terminal accounting does: count every call, withhold
  pricing only when a successful call lacks priced usage.
  """
  @spec accumulate(map(), binary(), binary(), atom() | binary(), map() | nil) :: map()
  def accumulate(counters, alias_name, revision, status, usage)
      when is_map(counters) and is_binary(alias_name) and is_binary(revision) do
    update_counter(
      counters,
      {alias_name, revision},
      Map.merge(empty_row(), %{
        "alias" => alias_name,
        "installation_revision" => revision
      }),
      %{
        alias: alias_name,
        revision: revision,
        outcome: if(stringify(status) == "ok", do: :ok, else: :error),
        usage: usage
      }
    )
  end

  @doc """
  Projects live spend from an `accumulate/5` map.

  Exactly four states, and none of `unpriced`, `incomplete`, or `empty` may
  render as zero cost:

  * `available` — successful usage complete and priced
  * `unpriced` — successful usage exists, tokens valid, cost absent
  * `incomplete` — at least one successful call has missing or invalid usage
  * `empty` — no successful LLM call yet
  """
  @spec spend(map()) :: map()
  def spend(counters) when is_map(counters) do
    {successful, missing, cost_complete?, usage} =
      Enum.reduce(counters, {0, 0, true, %{}}, fn {_key, {row, row_complete?}},
                                                  {successful, missing, complete?, usage} ->
        {successful + Map.fetch!(row, "successful_calls"),
         missing + Map.fetch!(row, "missing_usage_calls"), complete? and row_complete?,
         sum_usage(usage, Map.fetch!(row, "usage"))}
      end)

    cond do
      successful == 0 ->
        %{"state" => "empty"}

      missing > 0 ->
        %{"state" => "incomplete"}

      cost_complete? ->
        Map.put(Map.take(usage, @total_keys), "state", "available")

      true ->
        Map.put(Map.take(usage, ~w(input output)), "state", "unpriced")
    end
  end

  @spec totals([map()]) :: map()
  def totals(events) when is_list(events) do
    terminal? = Enum.any?(events, &(field(&1, "type") == "run-stopped"))
    dropped? = Enum.any?(events, &(field(&1, "type") == "events-dropped"))

    if not terminal? or dropped? do
      %{}
    else
      successful =
        Enum.filter(events, fn event ->
          llm_usage_event?(event) and stringify(field(event, "data", "status")) == "ok"
        end)

      Map.new(@total_keys, fn key -> {key, complete_total(successful, key)} end)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
    end
  end

  defp complete_total([], _key), do: nil

  defp complete_total(events, key) do
    Enum.reduce_while(events, 0, fn event, total ->
      with usage when is_map(usage) <- field(event, "data", "usage"),
           {:ok, normalized} <- LLMUsage.normalize(usage),
           {:ok, value} <- Map.fetch(normalized, key) do
        {:cont, total + value}
      else
        _missing_or_invalid -> {:halt, nil}
      end
    end)
  end

  defp summarize_calls(calls, attribution_events) do
    {alias_counters, model_counters, unattributed} =
      reduce_calls(calls, model_lookup(attribution_events))

    %{
      "llm_usage" => rows(alias_counters),
      "llm_usage_by_model" => rows(model_counters),
      "unattributed_model_calls" => unattributed
    }
  end

  # Dropped start or stop events can hide an in-flight LLM request. Named
  # drop buckets are authoritative; `$overflow` means further types were
  # dropped and those types are unknown, so accounting fails closed.
  defp validate_accounting_retention(events) do
    dropped? =
      Enum.any?(events, fn event ->
        field(event, "type") == "events-dropped" and
          accounting_relevant_drop?(field(event, "data", "counts"))
      end)

    if dropped?, do: {:error, :invalid_event_batch}, else: :ok
  end

  defp accounting_relevant_drop?(counts) when is_map(counts) do
    positive_count?(counts, "capability-started") or
      positive_count?(counts, "capability-stopped") or
      positive_count?(counts, "$overflow")
  end

  defp accounting_relevant_drop?(_counts), do: false

  defp positive_count?(counts, key) do
    case field(counts, key) do
      count when is_integer(count) and count > 0 -> true
      _absent -> false
    end
  end

  defp reconcile_llm_calls(events) do
    case Enum.reduce_while(
           events,
           %{open: %{}, seen: MapSet.new(), calls: []},
           &reconcile_event/2
         ) do
      {:error, :invalid_event_batch} = error ->
        error

      state ->
        unmatched =
          Enum.flat_map(state.open, fn
            {_id, %{llm?: true} = start} -> [%{start | outcome: :unknown, usage: nil}]
            {_id, _foreign} -> []
          end)

        {:ok, Enum.reverse(state.calls, unmatched)}
    end
  end

  defp reconcile_event(event, state) do
    case llm_accounting_event(event) do
      :ignore ->
        {:cont, state}

      {:error, :invalid_event_batch} = error ->
        {:halt, error}

      {:start, id, record} ->
        occupy(state, id, record)

      {:occupy, id} ->
        occupy(state, id, %{llm?: false})

      {:stop, id, stop} ->
        reconcile_llm_stop(state, id, stop)

      {:foreign_stop, id} ->
        reconcile_foreign_stop(state, id)
    end
  end

  defp occupy(state, id, record) do
    if occupied?(state, id) do
      {:halt, {:error, :invalid_event_batch}}
    else
      {:cont, %{state | open: Map.put(state.open, id, record)}}
    end
  end

  defp reconcile_llm_stop(state, id, stop) do
    case Map.pop(state.open, id) do
      {nil, _open} ->
        {:halt, {:error, :invalid_event_batch}}

      {%{llm?: false}, _open} ->
        {:halt, {:error, :invalid_event_batch}}

      {start, open} ->
        if start.alias == stop.alias and start.revision == stop.revision and
             start.environment == stop.environment do
          call = %{start | outcome: stop.outcome, usage: stop.usage}

          {:cont,
           %{
             state
             | open: open,
               seen: MapSet.put(state.seen, id),
               calls: [call | state.calls]
           }}
        else
          {:halt, {:error, :invalid_event_batch}}
        end
    end
  end

  defp reconcile_foreign_stop(state, id) do
    cond do
      MapSet.member?(state.seen, id) ->
        {:halt, {:error, :invalid_event_batch}}

      match?(%{llm?: true}, Map.get(state.open, id)) ->
        {:halt, {:error, :invalid_event_batch}}

      true ->
        {_record, open} = Map.pop(state.open, id)
        {:cont, %{state | open: open, seen: MapSet.put(state.seen, id)}}
    end
  end

  defp occupied?(state, id),
    do: Map.has_key?(state.open, id) or MapSet.member?(state.seen, id)

  defp llm_accounting_event(event) do
    type = field(event, "type")
    name = stringify(field(event, "data", "name"))

    cond do
      type == "capability-started" and name == "llm-request" ->
        parse_llm_identity(event, :start)

      type == "capability-stopped" and name == "llm-request" ->
        parse_llm_identity(event, :stop)

      type == "capability-started" ->
        occupy_foreign_id(event)

      type == "capability-stopped" ->
        foreign_stop_id(event)

      true ->
        :ignore
    end
  end

  defp occupy_foreign_id(event) do
    id = field(event, "data", "capability_id")
    if valid_id?(id), do: {:occupy, id}, else: :ignore
  end

  defp foreign_stop_id(event) do
    id = field(event, "data", "capability_id")
    if valid_id?(id), do: {:foreign_stop, id}, else: :ignore
  end

  defp parse_llm_identity(event, kind) do
    id = field(event, "data", "capability_id")
    alias_name = field(event, "data", "alias")
    revision = field(event, "data", "installation_revision")

    if valid_id?(id) and valid_llm_name?(alias_name) and valid_llm_name?(revision) do
      record = %{
        llm?: true,
        run_id: field(event, "run_id"),
        alias: alias_name,
        revision: revision,
        environment: stringify(field(event, "data", "environment")),
        outcome: stop_outcome(event),
        usage: field(event, "data", "usage")
      }

      {kind, id, record}
    else
      {:error, :invalid_event_batch}
    end
  end

  defp valid_llm_name?(value), do: is_binary(value) and value =~ @name

  defp stop_outcome(event) do
    if stringify(field(event, "data", "status")) == "ok", do: :ok, else: :error
  end

  defp call_from_stop(event) do
    %{
      run_id: field(event, "run_id"),
      alias: field(event, "data", "alias"),
      revision: field(event, "data", "installation_revision"),
      outcome: stop_outcome(event),
      usage: field(event, "data", "usage")
    }
  end

  defp reduce_calls(calls, model_lookup) do
    Enum.reduce(calls, {%{}, %{}, 0}, fn call, {aliases, models, unattributed} ->
      alias_key = {call.alias, call.revision}

      aliases =
        update_counter(
          aliases,
          alias_key,
          Map.merge(empty_row(), %{
            "alias" => call.alias,
            "installation_revision" => call.revision
          }),
          call
        )

      lookup_key = {call.run_id, call.alias, call.revision}

      case Map.get(model_lookup, lookup_key) do
        {model, 1} ->
          models =
            update_counter(
              models,
              model,
              Map.put(empty_row(), "resolved_model", model),
              call
            )

          {aliases, models, unattributed}

        _missing_or_ambiguous ->
          {aliases, models, unattributed + 1}
      end
    end)
  end

  defp rows(counters) do
    counters
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_key, {row, cost_complete?}} ->
      if cost_complete?,
        do: row,
        else: update_in(row, ["usage"], &Map.delete(&1, "total_cost"))
    end)
  end

  defp llm_usage_event?(event) do
    field(event, "type") == "capability-stopped" and
      field(event, "data", "name") == "llm-request" and
      is_binary(field(event, "data", "alias")) and
      is_binary(field(event, "data", "installation_revision"))
  end

  defp empty_row do
    %{
      "calls" => 0,
      "successful_calls" => 0,
      "usage_calls" => 0,
      "missing_usage_calls" => 0,
      "usage" => %{}
    }
  end

  defp update_counter(counters, key, initial, call) do
    {current, cost_complete?} = Map.get(counters, key, {initial, true})

    row =
      current
      |> Map.update!("calls", &(&1 + 1))
      |> Map.update!("successful_calls", &(&1 + if(call.outcome == :ok, do: 1, else: 0)))

    Map.put(counters, key, update_usage(row, cost_complete?, call))
  end

  defp update_usage(row, cost_complete?, %{outcome: :ok, usage: usage}) when is_map(usage) do
    case LLMUsage.normalize(usage) do
      {:ok, normalized} ->
        row =
          row
          |> Map.update!("usage_calls", &(&1 + 1))
          |> Map.update!("usage", &sum_usage(&1, normalized))

        {row, cost_complete? and Map.has_key?(normalized, "total_cost")}

      {:error, :invalid_llm_usage} ->
        {Map.update!(row, "missing_usage_calls", &(&1 + 1)), false}
    end
  end

  defp update_usage(row, _cost_complete?, %{outcome: outcome})
       when outcome in [:ok, :unknown],
       do: {Map.update!(row, "missing_usage_calls", &(&1 + 1)), false}

  defp update_usage(row, cost_complete?, %{outcome: :error}), do: {row, cost_complete?}

  defp sum_usage(left, right),
    do: Map.merge(left, right, fn _key, first, second -> first + second end)

  defp model_lookup(events) do
    events
    |> Enum.filter(&(field(&1, "type") == "run-started"))
    |> Enum.reduce(%{}, fn event, lookup ->
      snapshots =
        case field(event, "data", "connector_snapshots") do
          value when is_list(value) -> value
          _invalid -> []
        end

      Enum.reduce(snapshots, lookup, &put_snapshot(&2, field(event, "run_id"), &1))
    end)
  end

  defp put_snapshot(lookup, run_id, snapshot) do
    case ProviderSnapshot.llm_identity(snapshot) do
      {:ok, %{alias: alias_name, installation_revision: revision, resolved_model: model}} ->
        key = {run_id, alias_name, revision}
        Map.update(lookup, key, {model, 1}, fn {existing, count} -> {existing, count + 1} end)

      :error ->
        lookup
    end
  end

  defp validate_terminal_batch([first | _rest] = events) do
    last = List.last(events)
    run_id = field(first, "run_id")
    trace_id = field(first, "trace_id")

    with true <- field(first, "type") == "run-started",
         true <- field(last, "type") == "run-stopped",
         true <- Enum.count(events, &(field(&1, "type") == "run-started")) == 1,
         true <- Enum.count(events, &(field(&1, "type") == "run-stopped")) == 1,
         true <- valid_id?(run_id) and valid_id?(trace_id),
         :ok <- validate_events(events, run_id, trace_id, 0) do
      :ok
    else
      _invalid -> {:error, :invalid_event_batch}
    end
  end

  defp validate_terminal_batch(_events), do: {:error, :invalid_event_batch}

  defp validate_events([], _run_id, _trace_id, _previous), do: :ok

  defp validate_events([event | rest], run_id, trace_id, previous) do
    sequence = field(event, "sequence")
    type = field(event, "type")
    data = field(event, "data")

    with true <- Enum.sort(Map.keys(event)) == Enum.sort(@event_keys),
         true <- field(event, "schema_version") == 2,
         true <- field(event, "run_id") == run_id,
         true <- field(event, "trace_id") == trace_id,
         true <- is_integer(sequence) and sequence > previous,
         true <- is_binary(type) and type =~ @event_type,
         true <- is_map(data) and not is_struct(data),
         true <- valid_timestamp?(field(event, "timestamp")),
         true <- valid_llm_identity_fields?(event) do
      validate_events(rest, run_id, trace_id, sequence)
    else
      _invalid -> {:error, :invalid_event_batch}
    end
  end

  defp valid_llm_identity_fields?(event) do
    if llm_usage_event?(event) do
      field(event, "data", "alias") =~ @name and
        field(event, "data", "installation_revision") =~ @name
    else
      true
    end
  end

  defp valid_id?(value),
    do: is_binary(value) and byte_size(value) in 1..256 and String.valid?(value)

  defp valid_timestamp?(value) when is_binary(value),
    do: match?({:ok, _datetime, 0}, DateTime.from_iso8601(value))

  defp valid_timestamp?(_value), do: false

  defp normalize_events(events) do
    events
    |> Enum.map(&normalize_timestamp/1)
    |> JSONValue.normalize()
  end

  defp normalize_timestamp(event) when is_map(event) do
    case field(event, "timestamp") do
      %DateTime{} = timestamp ->
        key = if Map.has_key?(event, :timestamp), do: :timestamp, else: "timestamp"
        Map.put(event, key, DateTime.to_iso8601(timestamp))

      _other ->
        event
    end
  end

  defp normalize_timestamp(event), do: event

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, existing_atom(key))

  defp field(_value, _key), do: nil

  # Events arrive with either string or atom keys, so a string lookup falls
  # back to the atom form. `String.to_existing_atom/1` raises when nothing has
  # created that atom yet, which depends on which modules the VM happens to
  # have loaded — so this crashed or not purely on test and load ordering. An
  # atom that does not exist cannot be a key in the map either, so the honest
  # answer is that the field is absent.
  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp field(map, outer, inner), do: map |> field(outer) |> field(inner)

  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end
