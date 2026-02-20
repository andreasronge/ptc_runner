defmodule PtcRunner.TraceLog.Event do
  @moduledoc """
  Handles safe JSON encoding for telemetry events.

  Transforms telemetry data into JSON-safe formats by:
  - Converting PIDs, refs, functions to string representation
  - Summarizing large strings (>64KB by default)
  - Summarizing large lists (>100 items by default)
  - Summarizing large maps (>100 keys by default)
  - Handling binary data safely
  - Recursively sanitizing nested structures

  ## Configuration

  Sanitization limits are runtime-configurable via application config:

  - `:trace_max_string_size` - Maximum string size in bytes before truncation (default: `65_536`)
  - `:trace_max_list_size` - Maximum list length before summarizing (default: `100`)
  - `:trace_max_map_size` - Maximum map size (keys) before summarizing (default: `100`)
  - `:trace_preserve_full_keys` - Map keys whose string values are never truncated (default: `["system_prompt"]`)

  Example:

      config :ptc_runner,
        trace_max_string_size: 128_000,
        trace_max_list_size: 200,
        trace_preserve_full_keys: ["system_prompt", "custom_prompt"]
  """

  @default_max_string_size 65_536
  @default_max_list_size 100
  @default_max_map_size 100
  @default_preserve_full_keys ["system_prompt"]

  @doc """
  Creates a JSON-encodable event map from telemetry data.

  ## Examples

      iex> event = [:ptc_runner, :sub_agent, :run, :start]
      iex> measurements = %{system_time: 1000}
      iex> metadata = %{agent: %{name: "test"}}
      iex> result = PtcRunner.TraceLog.Event.from_telemetry(event, measurements, metadata, "trace-123")
      iex> result["event"]
      "run.start"
      iex> result["trace_id"]
      "trace-123"
  """
  @spec from_telemetry(list(), map(), map(), String.t()) :: map()
  def from_telemetry(event, measurements, metadata, trace_id) do
    event_name = event_name(event)

    %{
      "event" => event_name,
      "trace_id" => trace_id,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "measurements" => sanitize(measurements),
      "metadata" => sanitize(metadata)
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

  # Private helpers

  defp event_name(event) do
    event
    |> Enum.drop(2)
    |> Enum.map_join(".", &Atom.to_string/1)
  end

  defp sanitize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp sanitize_key(key) when is_binary(key), do: key
  defp sanitize_key(key), do: inspect(key)
end
