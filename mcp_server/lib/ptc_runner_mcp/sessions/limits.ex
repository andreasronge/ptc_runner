defmodule PtcRunnerMcp.Sessions.Limits do
  @moduledoc """
  Persisted-state limit validation and usage projection for sessions.
  """

  alias PtcRunner.Lisp.Format
  alias PtcRunnerMcp.Credentials.Redactor

  @typedoc "Persisted-state limit map, usually from `Sessions.Config.session_limits/0`."
  @type t :: %{
          max_memory_bytes: pos_integer(),
          max_binding_bytes: pos_integer(),
          max_bindings: pos_integer(),
          max_history_entry_bytes: pos_integer(),
          max_print_entries: pos_integer(),
          max_print_bytes: pos_integer(),
          max_tool_call_entries: pos_integer(),
          max_tool_call_bytes: pos_integer(),
          max_upstream_call_entries: pos_integer(),
          max_upstream_call_bytes: pos_integer(),
          max_idle_ms: pos_integer()
        }

  @doc "Return external-term size, falling back to inspect byte size for exotic terms."
  @spec term_bytes(term()) :: non_neg_integer()
  def term_bytes(term) do
    :erlang.external_size(term)
  rescue
    _ -> byte_size(inspect(term, printable_limit: 200, limit: 50))
  end

  @doc "Build a compact usage map for committed session state."
  @spec usage(map(), list(), list(), list(), list()) :: map()
  def usage(memory, turn_history, prints, tool_calls, upstream_calls) do
    %{
      memory_bytes: term_bytes(memory || %{}),
      binding_count: if(is_map(memory), do: map_size(memory), else: 0),
      history_count: length(turn_history || []),
      history_bytes: term_bytes(turn_history || []),
      print_entries: length(prints || []),
      print_bytes: term_bytes(prints || []),
      tool_call_entries: length(tool_calls || []),
      tool_call_bytes: term_bytes(tool_calls || []),
      upstream_call_entries: length(upstream_calls || []),
      upstream_call_bytes: term_bytes(upstream_calls || [])
    }
  end

  @doc "Project only the fields that should be shown to clients."
  @spec project_limits(t()) :: map()
  def project_limits(limits) when is_map(limits) do
    %{
      max_memory_bytes: limits.max_memory_bytes,
      max_binding_bytes: limits.max_binding_bytes,
      max_bindings: limits.max_bindings,
      max_history_entry_bytes: limits.max_history_entry_bytes,
      max_print_entries: limits.max_print_entries,
      max_print_bytes: limits.max_print_bytes,
      max_tool_call_entries: limits.max_tool_call_entries,
      max_tool_call_bytes: limits.max_tool_call_bytes,
      max_upstream_call_entries: limits.max_upstream_call_entries,
      max_upstream_call_bytes: limits.max_upstream_call_bytes,
      max_idle_ms: limits.max_idle_ms
    }
  end

  @doc """
  Return last-three turn history, replacing oversized entries with markers.
  """
  @spec cap_turn_history([term()], term(), t()) :: {[term()], [map()]}
  def cap_turn_history(current, new_value, limits) do
    {entry, notices} = cap_history_entry(new_value, limits)
    history = [entry | Enum.reverse(current || [])] |> Enum.take(3) |> Enum.reverse()
    {history, notices}
  end

  @doc "Append bounded print lines and keep recent entries under byte/count caps."
  @spec append_prints([String.t()], [term()], t()) :: [String.t()]
  def append_prints(existing, new_prints, limits) do
    new_prints
    |> List.wrap()
    |> Enum.map(&redacted_string/1)
    |> then(&((existing || []) ++ &1))
    |> take_recent_by_limits(limits.max_print_entries, limits.max_print_bytes)
  end

  @doc "Append bounded tool-call metadata and keep recent entries under limits."
  @spec append_tool_calls([map()], [map()], t()) :: [map()]
  def append_tool_calls(existing, new_calls, limits) do
    append_call_history(
      existing,
      new_calls,
      limits.max_tool_call_entries,
      limits.max_tool_call_bytes
    )
  end

  @doc "Append bounded upstream-call metadata and keep recent entries under limits."
  @spec append_upstream_calls([map()], [map()], t()) :: [map()]
  def append_upstream_calls(existing, new_calls, limits) do
    append_call_history(
      existing,
      new_calls,
      limits.max_upstream_call_entries,
      limits.max_upstream_call_bytes
    )
  end

  @doc """
  Validate a complete candidate persisted state.

  Returns `:ok` or a structured reason map that can be included in the MCP
  tool response.
  """
  @spec validate_candidate(map(), t()) :: :ok | {:error, map()}
  def validate_candidate(candidate, limits) when is_map(candidate) and is_map(limits) do
    with :ok <- validate_memory(candidate.memory, limits),
         :ok <-
           validate_bytes(
             :turn_history,
             candidate.turn_history,
             limits.max_history_entry_bytes * 3
           ),
         :ok <- validate_bytes(:prints, candidate.prints, limits.max_print_bytes),
         :ok <- validate_bytes(:tool_calls, candidate.tool_calls, limits.max_tool_call_bytes) do
      validate_bytes(
        :upstream_calls,
        candidate.upstream_calls,
        limits.max_upstream_call_bytes
      )
    end
  end

  @doc "Validate memory total size, binding count, and per-binding size."
  @spec validate_memory(map(), t()) :: :ok | {:error, map()}
  def validate_memory(memory, limits) when is_map(memory) and is_map(limits) do
    cond do
      map_size(memory) > limits.max_bindings ->
        {:error,
         %{
           field: "memory",
           limit: "max_bindings",
           actual: map_size(memory),
           max: limits.max_bindings
         }}

      term_bytes(memory) > limits.max_memory_bytes ->
        {:error,
         %{
           field: "memory",
           limit: "max_memory_bytes",
           actual: term_bytes(memory),
           max: limits.max_memory_bytes
         }}

      true ->
        validate_binding_sizes(memory, limits.max_binding_bytes)
    end
  end

  @doc "Return memory binding keys as sorted strings."
  @spec stored_keys(map()) :: [String.t()]
  def stored_keys(memory) when is_map(memory) do
    memory
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  @doc "Drop named memory bindings without creating atoms from user input."
  @spec drop_bindings(map(), [String.t() | atom()]) :: map()
  def drop_bindings(memory, names) when is_map(memory) and is_list(names) do
    wanted = MapSet.new(Enum.map(names, &to_string/1))

    Map.reject(memory, fn {key, _value} ->
      MapSet.member?(wanted, to_string(key))
    end)
  end

  @doc "Return largest bindings by approximate external size."
  @spec top_bindings(map(), non_neg_integer()) :: [map()]
  def top_bindings(memory, limit) when is_map(memory) and is_integer(limit) and limit >= 0 do
    memory
    |> Enum.map(fn {key, value} -> %{name: to_string(key), bytes: term_bytes(value)} end)
    |> Enum.sort_by(& &1.bytes, :desc)
    |> Enum.take(limit)
  end

  @doc "Build an oversized-history marker that is safe to keep in `*1`."
  @spec history_preview_marker(term(), non_neg_integer(), pos_integer()) :: map()
  def history_preview_marker(value, bytes, max_bytes) do
    {preview, _truncated?} = Format.to_clojure(value, limit: 20, printable_limit: 200)

    full_marker = %{
      ptc_session_preview: true,
      reason: :max_history_entry_bytes,
      bytes: bytes,
      max_bytes: max_bytes,
      preview: preview
    }

    if term_bytes(full_marker) <= max_bytes do
      full_marker
    else
      compact_history_preview_marker(bytes, max_bytes)
    end
  end

  defp compact_history_preview_marker(bytes, max_bytes) do
    marker = %{
      ptc_session_preview: true,
      reason: :max_history_entry_bytes,
      bytes: bytes,
      max_bytes: max_bytes
    }

    if term_bytes(marker) <= max_bytes do
      marker
    else
      %{ptc_session_preview: true}
    end
  end

  defp cap_history_entry(value, limits) do
    bytes = term_bytes(value)

    if bytes <= limits.max_history_entry_bytes do
      {value, []}
    else
      marker = history_preview_marker(value, bytes, limits.max_history_entry_bytes)

      notice = %{
        field: "*1",
        reason: "max_history_entry_bytes",
        bytes: bytes,
        max_bytes: limits.max_history_entry_bytes,
        message: "*1 stored as preview; original value exceeded max_session_history_entry_bytes"
      }

      {marker, [notice]}
    end
  end

  defp append_call_history(existing, new_calls, max_entries, max_bytes) do
    new_calls
    |> List.wrap()
    |> Enum.map(&compact_call/1)
    |> then(&((existing || []) ++ &1))
    |> take_recent_by_limits(max_entries, max_bytes)
  end

  defp compact_call(call) when is_map(call) do
    name =
      call[:name] || call["name"] ||
        case {call[:server] || call["server"], call[:tool] || call["tool"]} do
          {server, tool} when is_binary(server) and is_binary(tool) -> server <> "." <> tool
          {_server, tool} when is_binary(tool) -> tool
          _ -> "unknown"
        end

    %{
      name: redacted_string(name),
      args: scrub(call[:args] || call["args"] || %{}),
      status: scrub(call[:status] || call["status"]),
      error: scrub(call[:error] || call["error"])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp compact_call(other), do: %{name: "unknown", args: scrub(other)}

  defp redacted_string(value), do: value |> to_string() |> Redactor.scrub()

  defp scrub(value) do
    Redactor.scrub_deep(value)
  rescue
    _ -> value
  end

  defp take_recent_by_limits(entries, max_entries, max_bytes) do
    entries
    |> Enum.take(-max_entries)
    |> trim_to_bytes(max_bytes)
  end

  defp trim_to_bytes(entries, max_bytes) do
    if term_bytes(entries) <= max_bytes do
      entries
    else
      case entries do
        [] -> []
        [_ | rest] -> trim_to_bytes(rest, max_bytes)
      end
    end
  end

  defp validate_bytes(field, value, max_bytes) do
    actual = term_bytes(value || [])

    if actual <= max_bytes do
      :ok
    else
      {:error, %{field: Atom.to_string(field), limit: "bytes", actual: actual, max: max_bytes}}
    end
  end

  defp validate_binding_sizes(memory, max_bytes) do
    case Enum.find(memory, fn {_key, value} -> term_bytes(value) > max_bytes end) do
      nil ->
        :ok

      {key, value} ->
        {:error,
         %{
           field: "binding",
           name: to_string(key),
           limit: "max_binding_bytes",
           actual: term_bytes(value),
           max: max_bytes
         }}
    end
  end
end
