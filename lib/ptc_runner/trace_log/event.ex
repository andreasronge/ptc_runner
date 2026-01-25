defmodule PtcRunner.TraceLog.Event do
  @moduledoc """
  Handles safe JSON encoding for telemetry events.

  Transforms telemetry data into JSON-safe formats by:
  - Converting PIDs, refs, functions to string representation
  - Summarizing large strings (>1KB)
  - Summarizing large lists (>100 items)
  - Handling binary data safely
  - Recursively sanitizing nested structures
  """

  @max_string_size 1024
  @max_list_size 100

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
  - Large strings (>1KB) → `"String(N bytes)"`
  - Large lists (>100) → `"List(N items)"`
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
  def sanitize(value) when is_pid(value), do: inspect(value)
  def sanitize(value) when is_reference(value), do: inspect(value)
  def sanitize(value) when is_port(value), do: inspect(value)
  def sanitize(value) when is_function(value), do: inspect(value)

  def sanitize(value) when is_binary(value) do
    if String.printable?(value) do
      size = byte_size(value)

      if size > @max_string_size do
        "String(#{size} bytes)"
      else
        value
      end
    else
      %{"__binary__" => true, "size" => byte_size(value)}
    end
  end

  def sanitize(value) when is_list(value) do
    length = length(value)

    if length > @max_list_size do
      "List(#{length} items)"
    else
      Enum.map(value, &sanitize/1)
    end
  end

  def sanitize(value) when is_map(value) do
    if is_struct(value) do
      value
      |> Map.from_struct()
      |> sanitize()
    else
      Map.new(value, fn {k, v} -> {sanitize_key(k), sanitize(v)} end)
    end
  end

  def sanitize(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> sanitize()
  end

  def sanitize(value) when is_atom(value), do: value
  def sanitize(value) when is_number(value), do: value
  def sanitize(value), do: inspect(value)

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
