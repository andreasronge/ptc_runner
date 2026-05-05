defmodule PtcRunner.TraceLog.Event do
  @moduledoc """
  Builds v2 flat event envelopes for trace logging.

  Transforms raw telemetry data into a flat, queryable JSON structure where
  commonly-filtered fields (agent_name, turn, tool_name, tokens, duration)
  are promoted to top level. Bulky payloads go into a `data` bag.

  ## V2 Event Shape

  Every event has these top-level fields:

      schema_version, event, trace_id, timestamp, seq,
      span_id, parent_span_id,
      agent_name, agent_id, turn,
      duration_ms, input_tokens, output_tokens, total_tokens,
      cache_creation_tokens, cache_read_tokens,
      tool_name, model, status,
      data

  ## Configuration

  Sanitization limits are runtime-configurable via application config:

  - `:trace_max_string_size` - Maximum string size in bytes before truncation (default: `65_536`)
  - `:trace_max_list_size` - Maximum list length before summarizing (default: `100`)
  - `:trace_max_map_size` - Maximum map size (keys) before summarizing (default: `100`)
  - `:trace_preserve_full_keys` - Map keys whose string values are never truncated (default: `["system_prompt"]`)
  """

  @schema_version 2

  @default_max_string_size 65_536
  @default_max_list_size 100
  @default_max_map_size 100
  @default_preserve_full_keys ["system_prompt"]

  # Fields promoted from metadata to top level (atom keys as emitted by telemetry)
  @promoted_metadata_keys [
    :agent_name,
    :agent_id,
    :turn,
    :tool_name,
    :model,
    :status
  ]

  # Keys stripped from the data bag (already promoted or internal noise)
  @stripped_keys [
    :agent,
    :agent_name,
    :agent_id,
    :turn,
    :tool_name,
    :model,
    :status,
    :span_id,
    :parent_span_id,
    :telemetry_span_context
  ]

  # Measurement keys already promoted to top level (or auto-injected by
  # :telemetry.span). Anything not in this set is merged into the data bag
  # so events with descriptive numeric measurements (e.g. compaction's
  # messages_before / messages_after) don't lose their values to JSONL.
  @promoted_measurement_keys [
    :duration,
    :input_tokens,
    :output_tokens,
    :tokens,
    :cache_creation_tokens,
    :cache_read_tokens,
    :system_time,
    :monotonic_time
  ]

  @doc """
  Returns the current schema version.

  ## Examples

      iex> PtcRunner.TraceLog.Event.schema_version()
      2
  """
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  Creates a v2 flat event map from telemetry data.

  Promotes commonly-queried fields to top level and puts remaining
  metadata into a `data` bag. The `agent_name` field is extracted from
  either `metadata.agent_name` or `metadata.agent.name` (fallback).

  ## Examples

      iex> event = [:ptc_runner, :sub_agent, :run, :start]
      iex> measurements = %{system_time: 1000}
      iex> metadata = %{agent_name: "test", agent_id: "abc123"}
      iex> result = PtcRunner.TraceLog.Event.from_telemetry(event, measurements, metadata, "trace-123")
      iex> result["event"]
      "run.start"
      iex> result["schema_version"]
      2
      iex> result["agent_name"]
      "test"
  """
  @spec from_telemetry(list(), map(), map(), String.t()) :: map()
  def from_telemetry(event, measurements, metadata, trace_id) do
    event_name = event_name(event)

    # Extract promoted fields from metadata
    agent_name = extract_agent_name(metadata)
    agent_id = Map.get(metadata, :agent_id)

    # Extract promoted fields from measurements
    duration_ms = extract_duration_ms(measurements)
    token_fields = extract_tokens(measurements)

    # Build the data bag from metadata (minus promoted/stripped keys),
    # merged with any non-promoted measurements (so descriptive numeric
    # measurements survive into JSONL).
    data = build_data_bag(metadata, measurements)

    # Build flat envelope
    %{
      "schema_version" => @schema_version,
      "event" => event_name,
      "trace_id" => trace_id,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "agent_name" => agent_name,
      "agent_id" => agent_id,
      "turn" => Map.get(metadata, :turn),
      "duration_ms" => duration_ms,
      "input_tokens" => token_fields[:input_tokens],
      "output_tokens" => token_fields[:output_tokens],
      "total_tokens" => token_fields[:total_tokens],
      "cache_creation_tokens" => token_fields[:cache_creation_tokens],
      "cache_read_tokens" => token_fields[:cache_read_tokens],
      "tool_name" => Map.get(metadata, :tool_name),
      "model" => extract_model(metadata),
      "status" => extract_status(metadata),
      "data" => data
    }
  end

  @doc """
  Encodes an event map to a JSON string.

  Returns `{:ok, json}` on success, `{:error, reason}` on failure.
  """
  @spec encode(map()) :: {:ok, String.t()} | {:error, term()}
  def encode(event) do
    Jason.encode(event)
  end

  @doc """
  Encodes an event map to a JSON string, raising on failure.
  """
  @spec encode!(map()) :: String.t()
  def encode!(event) do
    Jason.encode!(event)
  end

  @doc """
  Sanitizes a value for safe JSON encoding.

  Handles:
  - PIDs, refs, ports, functions → `inspect/1` string
  - Non-printable binaries → `%{"__binary__" => true, "size" => N}`
  - Large strings (>64KB by default, configurable) → truncated with preview
  - Large lists (>100 by default, configurable) → `"List(N items)"`
  - Maps → recursively sanitized
  - Structs → converted to maps and sanitized
  - Tuples → converted to lists and sanitized

  ## Examples

      iex> result = PtcRunner.TraceLog.Event.sanitize(self())
      iex> String.starts_with?(result, "#PID<")
      true

      iex> PtcRunner.TraceLog.Event.sanitize(%{a: 1, b: 2})
      %{"a" => 1, "b" => 2}

      iex> PtcRunner.TraceLog.Event.sanitize({:ok, "result"})
      [:ok, "result"]

      iex> PtcRunner.TraceLog.Event.sanitize(<<0, 1, 2, 3>>)
      %{"__binary__" => true, "size" => 4}
  """
  @spec sanitize(term()) :: term()
  def sanitize(value) do
    opts = %{
      max_string_size:
        Application.get_env(:ptc_runner, :trace_max_string_size, @default_max_string_size),
      max_list_size:
        Application.get_env(:ptc_runner, :trace_max_list_size, @default_max_list_size),
      max_map_size: Application.get_env(:ptc_runner, :trace_max_map_size, @default_max_map_size),
      preserve_full_keys:
        Application.get_env(:ptc_runner, :trace_preserve_full_keys, @default_preserve_full_keys)
    }

    do_sanitize(value, opts)
  end

  # --- Private: Field extraction ---

  # Extract agent_name with fallback to metadata.agent.name
  defp extract_agent_name(metadata) do
    case Map.get(metadata, :agent_name) do
      nil ->
        case Map.get(metadata, :agent) do
          %{name: name} -> name
          _ -> nil
        end

      name ->
        name
    end
  end

  # Extract model from metadata.model — sanitize non-string values (e.g., functions)
  defp extract_model(metadata) do
    case Map.get(metadata, :model) do
      nil -> nil
      model when is_binary(model) -> model
      model when is_atom(model) -> Atom.to_string(model)
      other -> inspect(other, limit: 5, printable_limit: 100)
    end
  end

  # Extract status — atom or string
  defp extract_status(metadata) do
    case Map.get(metadata, :status) do
      nil -> nil
      status when is_atom(status) -> Atom.to_string(status)
      status -> status
    end
  end

  # Convert duration from native time to milliseconds
  defp extract_duration_ms(%{duration: duration}) do
    System.convert_time_unit(duration, :native, :millisecond)
  end

  defp extract_duration_ms(_), do: nil

  # Extract token fields from measurements
  defp extract_tokens(measurements) do
    input = Map.get(measurements, :input_tokens)
    output = Map.get(measurements, :output_tokens)
    total = Map.get(measurements, :tokens)
    cache_creation = Map.get(measurements, :cache_creation_tokens)
    cache_read = Map.get(measurements, :cache_read_tokens)

    %{
      input_tokens: input,
      output_tokens: output,
      total_tokens: total,
      cache_creation_tokens: cache_creation,
      cache_read_tokens: cache_read
    }
  end

  # Build the data bag from remaining metadata + non-promoted measurements,
  # sanitized. Measurements that aren't already promoted to top level
  # (duration, token counts) are folded in so events like
  # `compaction.triggered` don't lose `messages_before` / `messages_after`.
  defp build_data_bag(metadata, measurements) do
    remaining_metadata =
      metadata
      |> Map.drop(@stripped_keys)
      |> Map.drop(@promoted_metadata_keys)

    remaining_measurements = Map.drop(measurements, @promoted_measurement_keys)

    # Metadata wins on key collision so emitter intent is preserved.
    remaining = Map.merge(remaining_measurements, remaining_metadata)

    if map_size(remaining) == 0 do
      nil
    else
      sanitize(remaining)
    end
  end

  # --- Private: Event name ---

  defp event_name(event) do
    event
    |> Enum.drop(2)
    |> Enum.map_join(".", &Atom.to_string/1)
  end

  # --- Private: Sanitization ---

  defp do_sanitize(value, _opts) when is_pid(value), do: inspect(value)
  defp do_sanitize(value, _opts) when is_reference(value), do: inspect(value)
  defp do_sanitize(value, _opts) when is_port(value), do: inspect(value)
  defp do_sanitize(value, _opts) when is_function(value), do: inspect(value)

  defp do_sanitize(value, opts) when is_binary(value) do
    if String.printable?(value) do
      size = byte_size(value)

      if size > opts.max_string_size do
        preview = String.slice(value, 0, 200)
        "#{preview}...\n\n[String truncated — #{size} bytes total]"
      else
        value
      end
    else
      %{"__binary__" => true, "size" => byte_size(value)}
    end
  end

  defp do_sanitize(value, opts) when is_list(value) do
    length = length(value)

    if length > opts.max_list_size do
      "List(#{length} items)"
    else
      Enum.map(value, &do_sanitize(&1, opts))
    end
  end

  defp do_sanitize(%_{} = value, opts) do
    value
    |> Map.from_struct()
    |> do_sanitize(opts)
  end

  defp do_sanitize(value, opts) when is_map(value) do
    size = map_size(value)

    if size > opts.max_map_size do
      "Map(#{size} keys)"
    else
      sanitize_map(value, opts)
    end
  end

  defp do_sanitize(value, opts) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> do_sanitize(opts)
  end

  defp do_sanitize(value, _opts) when is_atom(value), do: value
  defp do_sanitize(value, _opts) when is_number(value), do: value
  defp do_sanitize(value, _opts), do: inspect(value)

  defp sanitize_map(value, opts) do
    Map.new(value, fn {k, v} ->
      sk = sanitize_key(k)

      sv =
        if sk in opts.preserve_full_keys and is_binary(v),
          do: v,
          else: do_sanitize(v, opts)

      {sk, sv}
    end)
  end

  defp sanitize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp sanitize_key(key) when is_binary(key), do: key
  defp sanitize_key(key), do: inspect(key)
end
