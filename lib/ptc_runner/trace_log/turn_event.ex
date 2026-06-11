defmodule PtcRunner.TraceLog.TurnEvent do
  @moduledoc """
  Shared builder for the canonical *turn* event — the substrate-level record
  of one driver turn, emitted identically by both turn drivers (plan D1):

  - `PtcRunner.Session` turns (external LLM drives via MCP / `mix ptc.repl`), and
  - the `PtcRunner.SubAgent` loop (the internal loop drives the LLM).

  Both drivers build their turn record through `build/1` so the top-level shape
  is identical and queryable through the same `PtcRunner.TraceLog.Analyzer`
  calls, regardless of which driver produced it. Driver-specific richness lives
  in the `data` bag; the top-level fields never diverge.

  The map is a v2-flat-compatible envelope (`event: "turn"`, `schema_version: 2`)
  so it rides the existing `PtcRunner.TraceLog` JSONL/in-memory sinks. The sink
  stamps `trace_id`, `timestamp`, and `seq`; this builder never sets them.

  ## Top-level fields

      schema_version, event ("turn"),
      driver ("session" | "sub_agent"),
      session_id, agent_id, agent_name,
      turn, attempt, committed, status,
      duration_ms, input_tokens, output_tokens, total_tokens,
      data

  `turn` is the committed-state counter (advances only when an attempt commits);
  `attempt` is the monotonic per-attempt counter (advances on every attempt,
  including failed ones); `committed` flags whether this attempt advanced
  committed state. Failed/parse-error/budget-stop attempts are recorded with
  `committed: false` so wasted work is visible without mutating driver state
  (plan P2 notes).

  ## `data` bag

      program, raw_response, result_preview, prints, memory_diff,
      tool_calls, limits_hit, preludes, fail, turn_type

  Per-driver fields that don't apply are nil/empty. `raw_response` carries what
  the driver's LLM generated when there is no parsed `program` (SubAgent
  parse/text-mode failures); it is nil for session turns and normal turns. The whole bag is run through
  `PtcRunner.TraceLog.Event.sanitize/1`, which bounds large strings/lists/maps —
  that is where memory-diff values and prints get their byte bounds.
  """

  alias PtcRunner.SubAgent.KeyNormalizer
  alias PtcRunner.TraceLog.Event

  @schema_version 2
  @event_name "turn"

  # Bound for the inspected `result_preview` string before sanitize's own cap.
  @preview_limit 4_096
  # Cap collection elements rendered while building a preview, so previewing a
  # large (≤10MB) sandbox result is O(preview size), not O(result size).
  @preview_items 50

  @typedoc "Normalized attributes accepted by `build/1` (atom-keyed)."
  @type attrs :: map() | keyword()

  @doc """
  Builds the canonical turn-event map from normalized attributes.

  Required: `:driver` (`:session` | `:sub_agent`). All other keys are optional
  and default to nil / empty. `trace_id`/`timestamp`/`seq` are intentionally
  omitted — the sink stamps them.
  """
  @spec build(attrs()) :: map()
  def build(attrs) do
    attrs = Map.new(attrs)

    %{
      "schema_version" => @schema_version,
      "event" => @event_name,
      "driver" => driver_string(Map.fetch!(attrs, :driver)),
      "session_id" => Map.get(attrs, :session_id),
      "agent_id" => Map.get(attrs, :agent_id),
      "agent_name" => Map.get(attrs, :agent_name),
      "turn" => Map.get(attrs, :turn),
      "attempt" => Map.get(attrs, :attempt),
      "committed" => Map.get(attrs, :committed, false) == true,
      "status" => status_string(Map.get(attrs, :status)),
      "duration_ms" => Map.get(attrs, :duration_ms),
      "input_tokens" => Map.get(attrs, :input_tokens),
      "output_tokens" => Map.get(attrs, :output_tokens),
      "total_tokens" => Map.get(attrs, :total_tokens),
      "data" => build_data(attrs)
    }
  end

  @doc """
  Renders a bounded, JSON-safe preview string for a turn result value.

  Shared by both drivers so `result_preview` reads the same regardless of who
  produced the turn.
  """
  @spec preview(term()) :: String.t()
  def preview(nil), do: "nil"

  def preview(value) do
    rendered = inspect(value, limit: @preview_items, printable_limit: @preview_limit)

    if String.length(rendered) > @preview_limit do
      String.slice(rendered, 0, @preview_limit - 3) <> "..."
    else
      rendered
    end
  end

  @doc """
  Slims a prelude trace summary (`PtcRunner.Lisp.Prelude.trace_summary/1`) to the
  turn-event `preludes` provenance shape — `[%{"source_hash" => ...,
  "namespaces" => ...}]`, or `[]` when no prelude was attached.

  Shared by both drivers so the provenance field (the single field that makes
  A/B benchmarking and derivation provenance trivial, per the plan) reads
  identically whether a session or a SubAgent turn produced it.
  """
  @spec prelude_provenance(map() | nil) :: [map()]
  def prelude_provenance(%{source_hash: hash, protected_namespaces: namespaces}) do
    [%{"source_hash" => hash, "namespaces" => namespaces}]
  end

  def prelude_provenance(_), do: []

  @doc """
  Computes a memory diff (`changed_keys` + bounded `values`) between the
  pre-turn and post-turn memory maps. Keys whose value is unchanged are
  excluded. PTC-Lisp `def` cannot remove bindings, so this only surfaces
  additions and rebindings.
  """
  @spec memory_diff(map(), map()) :: %{changed_keys: [String.t()], values: map()} | nil
  def memory_diff(before, after_memory)
      when is_map(before) and is_map(after_memory) do
    changed =
      after_memory
      # Check key presence separately from value equality: a newly added binding
      # whose value is nil (e.g. `(def x nil)`) is a real change even though
      # `Map.get(before, k)` would also be nil for the missing key.
      |> Enum.filter(fn {k, v} -> not Map.has_key?(before, k) or Map.fetch!(before, k) != v end)
      |> Map.new()

    if map_size(changed) == 0 do
      nil
    else
      %{
        changed_keys: changed |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort(),
        values: changed
      }
    end
  end

  def memory_diff(_before, _after), do: nil

  @doc """
  Builds the credential-free turn-log projection for a single tool call.

  The projection intentionally excludes raw arguments and results. It keeps a
  stable `args_hash` derived from the same canonical argument identity used by
  tool caching, so PTC-Lisp log analysis can detect duplicate fetches without
  ingesting potentially large or sensitive payloads.
  """
  @spec tool_call_summary(map()) :: map()
  def tool_call_summary(call) when is_map(call) do
    {server, tool, args} = tool_identity(call)

    %{
      "server" => server,
      "tool" => tool,
      "args_hash" => args_hash(tool, args),
      "duration_ms" => get_key(call, :duration_ms),
      "outcome" => tool_outcome(call)
    }
  end

  def tool_call_summary(_), do: %{}

  # --- private ---

  defp build_data(attrs) do
    %{
      "program" => Map.get(attrs, :program),
      "raw_response" => Map.get(attrs, :raw_response),
      "result_preview" => Map.get(attrs, :result_preview),
      "prints" => Map.get(attrs, :prints) || [],
      "memory_diff" => normalize_memory_diff(Map.get(attrs, :memory_diff)),
      "tool_calls" => Map.get(attrs, :tool_calls) || [],
      "limits_hit" => Map.get(attrs, :limits_hit) || [],
      "preludes" => Map.get(attrs, :preludes) || [],
      "fail" => normalize_fail(Map.get(attrs, :fail)),
      "turn_type" => normalize_turn_type(Map.get(attrs, :turn_type))
    }
    |> Event.sanitize()
  end

  defp normalize_memory_diff(%{changed_keys: keys, values: values}) do
    %{"changed_keys" => keys, "values" => values}
  end

  defp normalize_memory_diff(_), do: nil

  # Stringify `reason` so the in-memory sink and the JSON-round-tripped file
  # sink agree (an atom reason would read back as a string from JSONL).
  defp normalize_fail(%{reason: reason, message: message}) do
    %{"reason" => stringify(reason), "message" => message}
  end

  defp normalize_fail(_), do: nil

  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value)

  defp normalize_turn_type(nil), do: nil
  defp normalize_turn_type(type) when is_atom(type), do: Atom.to_string(type)
  defp normalize_turn_type(type) when is_binary(type), do: type
  defp normalize_turn_type(type), do: inspect(type)

  defp driver_string(driver) when is_atom(driver), do: Atom.to_string(driver)
  defp driver_string(driver) when is_binary(driver), do: driver

  defp status_string(nil), do: nil
  defp status_string(status) when is_atom(status), do: Atom.to_string(status)
  defp status_string(status) when is_binary(status), do: status

  defp tool_identity(call) do
    tool = get_key(call, :name) || get_key(call, :tool)
    args = get_key(call, :args)

    if tool == "call" and is_map(args) do
      upstream_tool = get_key(args, :tool)

      case upstream_tool do
        tool_name when is_binary(tool_name) ->
          {get_key(args, :server), tool_name, get_key(args, :args) || %{}}

        _ ->
          {get_key(call, :server), tool, args}
      end
    else
      {get_key(call, :server), tool, args}
    end
  end

  defp tool_outcome(call) do
    cond do
      truthy?(get_key(call, :error)) -> "error"
      get_key(call, :status) == "error" -> "error"
      get_key(call, :status) == :error -> "error"
      true -> "ok"
    end
  end

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(_), do: true

  defp get_key(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp args_hash(_tool, nil), do: nil

  defp args_hash(tool, args) when is_binary(tool) do
    {_tool, canonical_args} = KeyNormalizer.canonical_cache_key(tool, args)

    :crypto.hash(:sha256, :erlang.term_to_binary(canonical_args))
    |> Base.encode16(case: :lower)
  end

  defp args_hash(_, _), do: nil
end
