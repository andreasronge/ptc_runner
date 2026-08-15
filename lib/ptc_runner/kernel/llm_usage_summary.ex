defmodule PtcRunner.Kernel.LLMUsageSummary do
  @moduledoc false

  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.LLMUsage
  alias PtcRunner.Kernel.ProviderSnapshot
  alias PtcRunner.Kernel.ResultLimit

  @max_terminal_events 65_536
  @max_rows 128
  @max_result_bytes 1_000_000
  @event_keys ~w(schema_version run_id trace_id sequence timestamp type data)
  @event_type ~r/\A[a-z][a-z0-9-]{0,127}\z/
  @name ~r/\A[a-z][a-z0-9._-]{0,127}\z/

  @type summary :: %{
          required(String.t()) => [map()] | non_neg_integer()
        }

  @spec terminal([map()]) :: {:ok, summary()} | {:error, :invalid_event_batch}
  def terminal(events) when is_list(events) do
    with true <- length(events) <= @max_terminal_events,
         {:ok, normalized} <- normalize_events(events),
         true <- JSONValue.value?(normalized),
         :ok <- validate_terminal_batch(normalized),
         summary <- summarize(normalized),
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
    model_lookup = model_lookup(attribution_events)
    {alias_counters, model_counters, unattributed} = reduce(events, model_lookup)

    %{
      "llm_usage" => rows(alias_counters),
      "llm_usage_by_model" => rows(model_counters),
      "unattributed_model_calls" => unattributed
    }
  end

  defp reduce(events, model_lookup) do
    events
    |> Enum.filter(&llm_usage_event?/1)
    |> Enum.reduce({%{}, %{}, 0}, fn event, {aliases, models, unattributed} ->
      alias_name = field(event, "data", "alias")
      revision = field(event, "data", "installation_revision")
      success? = stringify(field(event, "data", "status")) == "ok"
      usage = field(event, "data", "usage")
      alias_key = {alias_name, revision}

      aliases =
        update_counter(
          aliases,
          alias_key,
          Map.merge(empty_row(), %{
            "alias" => alias_name,
            "installation_revision" => revision
          }),
          usage,
          success?
        )

      lookup_key = {field(event, "run_id"), alias_name, revision}

      case Map.get(model_lookup, lookup_key) do
        {model, 1} ->
          models =
            update_counter(
              models,
              model,
              Map.put(empty_row(), "resolved_model", model),
              usage,
              success?
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

  defp update_counter(counters, key, initial, usage, success?) do
    {current, cost_complete?} = Map.get(counters, key, {initial, true})

    row =
      current
      |> Map.update!("calls", &(&1 + 1))
      |> Map.update!("successful_calls", &(&1 + if(success?, do: 1, else: 0)))

    Map.put(counters, key, update_usage(row, cost_complete?, usage, success?))
  end

  defp update_usage(row, cost_complete?, usage, true) when is_map(usage) do
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

  defp update_usage(row, _cost_complete?, _usage, true),
    do: {Map.update!(row, "missing_usage_calls", &(&1 + 1)), false}

  defp update_usage(row, cost_complete?, _usage, false), do: {row, cost_complete?}

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
    do: Map.get(map, key) || Map.get(map, String.to_existing_atom(key))

  defp field(_value, _key), do: nil

  defp field(map, outer, inner), do: map |> field(outer) |> field(inner)

  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end
