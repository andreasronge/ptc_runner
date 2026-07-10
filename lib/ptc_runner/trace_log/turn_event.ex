defmodule PtcRunner.TraceLog.TurnEvent do
  @moduledoc """
  Shared builder for the canonical *turn* event — the substrate-level record
  of one driver turn, emitted identically by all turn drivers:

  - `PtcRunner.Session` turns (external LLM drives via MCP / `mix ptc.repl`), and
  - the `PtcRunner.SubAgent` loop (the internal loop drives the LLM), and
  - `PtcRunner.Kernel` turns (native tool-call kernel loop).

  Both drivers build their turn record through `build/1` so the top-level shape
  is identical and queryable through the same `PtcRunner.TraceLog.Analyzer`
  calls, regardless of which driver produced it. Driver-specific richness lives
  in the `data` bag; the top-level fields never diverge.

  The map is a v2-flat-compatible envelope (`event: "turn"`, `schema_version: 2`)
  so it rides the existing `PtcRunner.TraceLog` JSONL/in-memory sinks. The sink
  stamps `trace_id`, `timestamp`, and `seq`; this builder never sets them.

  ## Top-level fields

      schema_version, event ("turn"),
      driver ("session" | "sub_agent" | "kernel"),
      session_id, agent_id, agent_name, role, grant_fingerprint,
      turn, attempt, committed, status,
      duration_ms, input_tokens, output_tokens, total_tokens,
      data

  `turn` is the canonical committed-turn counter (advances only when an attempt
  succeeds); `attempt` is the monotonic per-attempt counter (advances on every
  attempt, including failed ones); `committed` flags whether this attempt
  advanced that canonical turn counter. Driver-local state can have finer
  semantics: for example, the kernel may preserve PTC-Lisp memory from an
  explicit `(fail ...)` eval while still recording the turn event as
  `committed: false` because the model attempt did not produce a successful
  kernel turn.

  ## `data` bag

      program, raw_response, result_preview, prints, memory_diff,
      tool_calls, catalog_ops, evidence_reads, limits_hit, preludes,
      prelude_projection, prelude_call_policy, prelude_presentation, fail, turn_type

  Per-driver fields that don't apply are nil/empty. `raw_response` carries what
  the driver's LLM generated when there is no parsed `program` (SubAgent
  parse/text-mode failures); it is nil for session turns and normal turns. The whole bag is run through
  `PtcRunner.TraceLog.Event.sanitize/1`, which bounds large strings/lists/maps —
  that is where prints and other retained diagnostic values get their byte
  bounds. Memory diffs retain changed binding names only; values and value
  fingerprints are deliberately excluded. Older v2 producers may include a
  `memory_diff.values` member. Consumers must treat that legacy member as
  optional; current producers never emit it.
  """

  alias PtcRunner.Evidence.ReadProjection, as: EvidenceReadProjection
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.RuntimeCallable
  alias PtcRunner.PreludeOrigin
  alias PtcRunner.Step.Public, as: PublicStep
  alias PtcRunner.SubAgent.KeyNormalizer
  alias PtcRunner.TraceLog.Event

  @schema_version 2
  @event_name "turn"

  # Bound for the inspected `result_preview` string before sanitize's own cap.
  @preview_limit 4_096
  # Cap collection elements rendered while building a preview, so previewing a
  # large (≤10MB) sandbox result is O(preview size), not O(result size).
  @preview_items 50
  @preview_depth 32

  @typedoc "Normalized attributes accepted by `build/1` (atom-keyed)."
  @type attrs :: map() | keyword()

  @doc """
  Builds the canonical turn-event map from normalized attributes.

  Required: `:driver` (`:session` | `:sub_agent` | `:kernel`). All other keys
  are optional and default to nil / empty. `trace_id`/`timestamp`/`seq` are
  intentionally omitted — the sink stamps them.
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
      "role" => stringify(Map.get(attrs, :role)),
      "grant_fingerprint" => stringify(Map.get(attrs, :grant_fingerprint)),
      "turn" => Map.get(attrs, :turn),
      "attempt" => Map.get(attrs, :attempt),
      "committed" => Map.get(attrs, :committed, false) == true,
      "status" => status_string(Map.get(attrs, :status)),
      "duration_ms" => Map.get(attrs, :duration_ms),
      "input_tokens" => Map.get(attrs, :input_tokens),
      "output_tokens" => Map.get(attrs, :output_tokens),
      "total_tokens" => Map.get(attrs, :total_tokens),
      "tags" => normalize_tags(Map.get(attrs, :tags)),
      "data" => build_data(attrs)
    }
  end

  @doc """
  Renders a bounded, JSON-safe preview string for a turn result value.

  Shared by turn drivers so `result_preview` reads the same regardless of who
  produced the turn.
  """
  @spec preview(term(), keyword()) :: String.t()
  def preview(value, opts \\ [])
  def preview(nil, _opts), do: "nil"

  def preview(value, opts) do
    limit = opts |> Keyword.get(:limit, @preview_limit) |> normalize_preview_limit()

    value
    |> preview_value(limit, 0)
    |> clamp_preview(limit)
  end

  defp normalize_preview_limit(limit) when is_integer(limit), do: max(limit, 0)
  defp normalize_preview_limit(_limit), do: @preview_limit

  defp clamp_preview(preview, limit) do
    cond do
      limit <= 0 ->
        ""

      String.length(preview) <= limit ->
        preview

      limit <= 3 ->
        String.slice(preview, 0, limit)

      true ->
        String.slice(preview, 0, limit - 3) <> "..."
    end
  end

  defp preview_value(_value, _limit, depth) when depth >= @preview_depth, do: "..."

  defp preview_value(nil, _limit, _depth), do: "nil"
  defp preview_value(true, _limit, _depth), do: "true"
  defp preview_value(false, _limit, _depth), do: "false"
  defp preview_value(value, _limit, _depth) when is_integer(value), do: Integer.to_string(value)

  defp preview_value(value, _limit, _depth) when is_float(value),
    do: Float.to_string(value)

  defp preview_value(value, _limit, _depth) when is_atom(value), do: ":#{value}"
  defp preview_value(%LispKeyword{} = value, _limit, _depth), do: inspect(value)

  defp preview_value(%RuntimeCallable{} = value, _limit, _depth),
    do: inspect(PublicStep.value(value))

  defp preview_value(value, limit, _depth) when is_binary(value) do
    {prefix, rest} = String.split_at(value, limit)
    suffix = if rest == "", do: "", else: "..."
    inspect(prefix <> suffix)
  end

  defp preview_value({:closure, params, _body, _env, _turn_history, _metadata}, _limit, _depth) do
    names = Enum.map_join(params, " ", &closure_param_name/1)
    "#fn[#{names}]"
  end

  defp preview_value(%MapSet{} = set, limit, depth) do
    {items, truncated?} = take_preview_items(set)
    body = Enum.map_join(items, " ", &preview_value(&1, limit, depth + 1))
    "\#{#{body}#{truncation_suffix(truncated?)}}"
  end

  defp preview_value(value, limit, depth) when is_list(value) do
    {items, truncated?} = take_preview_items(value)
    body = Enum.map_join(items, " ", &preview_value(&1, limit, depth + 1))
    "[#{body}#{truncation_suffix(truncated?)}]"
  end

  defp preview_value(value, _limit, _depth) when is_tuple(value) and tuple_size(value) == 0,
    do: "[]"

  defp preview_value(value, limit, depth) when is_tuple(value) do
    size = tuple_size(value)
    count = min(size, @preview_items)

    items =
      for index <- 0..(count - 1)//1 do
        value |> elem(index) |> preview_value(limit, depth + 1)
      end

    "[#{Enum.join(items, " ")}#{truncation_suffix(size > count)}]"
  end

  defp preview_value(%_{} = struct, limit, _depth),
    do: inspect(struct, limit: @preview_items, printable_limit: limit)

  defp preview_value(value, limit, depth) when is_map(value) do
    {entries, truncated?} = take_preview_items(value)

    body =
      Enum.map_join(entries, " ", fn {key, inner} ->
        "#{preview_key(key, limit, depth + 1)} #{preview_value(inner, limit, depth + 1)}"
      end)

    "{#{body}#{truncation_suffix(truncated?)}}"
  end

  defp preview_value(value, _limit, _depth), do: inspect(value, limit: @preview_items)

  defp preview_key(nil, _limit, _depth), do: "nil"
  defp preview_key(true, _limit, _depth), do: "true"
  defp preview_key(false, _limit, _depth), do: "false"
  defp preview_key(key, _limit, _depth) when is_atom(key), do: ":#{key}"
  defp preview_key(%LispKeyword{} = key, _limit, _depth), do: inspect(key)
  defp preview_key(key, _limit, _depth) when is_binary(key), do: inspect(key)
  defp preview_key(key, limit, depth), do: preview_value(key, limit, depth)

  defp take_preview_items(enumerable) do
    items = Enum.take(enumerable, @preview_items + 1)
    {Enum.take(items, @preview_items), length(items) > @preview_items}
  end

  defp truncation_suffix(true), do: " ..."
  defp truncation_suffix(false), do: ""

  defp closure_param_name({:var, name}), do: to_string(name)
  defp closure_param_name(_), do: "_"

  @doc """
  Slims a prelude trace summary (`PtcRunner.Lisp.Prelude.trace_summary/1`) to the
  turn-event `preludes` provenance shape — `[%{"source_hash" => ...,
  "namespaces" => ..., "components" => [...]}]`, or `[]` when no prelude was
  attached. The `components` key is omitted for single-source prelude artifacts.

  Shared by turn drivers so the provenance field (the single field that makes
  A/B benchmarking and derivation provenance trivial, per the plan) reads
  identically whether a session or a SubAgent turn produced it.
  """
  @spec prelude_provenance(map() | nil) :: [map()]
  def prelude_provenance(%{source_hash: hash, protected_namespaces: namespaces} = summary) do
    provenance = %{"source_hash" => hash, "namespaces" => namespaces}

    case Map.get(summary, :components, []) do
      [] -> [provenance]
      components -> [Map.put(provenance, "components", stringify_component_keys(components))]
    end
  end

  def prelude_provenance(_), do: []

  defp stringify_component_keys(components) when is_list(components) do
    Enum.map(components, fn
      component when is_map(component) ->
        component
        |> Map.new(fn {key, value} -> {stringify(key), value} end)
        |> sanitize_component_origin()

      other ->
        other
    end)
  end

  defp stringify_component_keys(_), do: []

  defp sanitize_component_origin(%{"origin" => origin} = component) do
    Map.put(component, "origin", PreludeOrigin.sanitize(origin))
  end

  defp sanitize_component_origin(component), do: component

  @doc """
  Computes the changed binding names between the pre-turn and post-turn memory
  maps. Keys whose value is unchanged are excluded. Values and fingerprints are
  not persisted because memory may contain secrets returned by tools. PTC-Lisp
  `def` cannot remove bindings, so this only surfaces additions and rebindings.
  """
  @spec memory_diff(map(), map()) :: %{changed_keys: [String.t()]} | nil
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
      %{changed_keys: changed |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()}
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
    |> maybe_put_evidence_reads(tool, call)
  end

  def tool_call_summary(_), do: %{}

  @doc """
  Builds the credential-free turn-log projection for one discovery/catalog op.

  Discovery arguments are intentionally kept verbatim: they are small
  queries/refs/options, and legible queries are the point of this record —
  measuring discovery overhead and diagnosing failed discovery paths.
  Discovery *results* never enter the `catalog_ops` ledger, so they cannot
  appear here.
  """
  @spec catalog_op_summary(map()) :: map()
  def catalog_op_summary(op) when is_map(op) do
    %{
      "operation" => stringify(get_key(op, :operation)),
      "args" => PublicStep.value(get_key(op, :args) || %{}),
      "outcome" => stringify(get_key(op, :outcome)),
      "reason" => stringify(get_key(op, :reason)),
      "duration_ms" => get_key(op, :duration_ms)
    }
  end

  def catalog_op_summary(_), do: %{}

  # --- private ---

  defp build_data(attrs) do
    %{
      "program" => Map.get(attrs, :program),
      "raw_response" => Map.get(attrs, :raw_response),
      "result_preview" => Map.get(attrs, :result_preview),
      "prints" => Map.get(attrs, :prints) || [],
      "memory_diff" => normalize_memory_diff(Map.get(attrs, :memory_diff)),
      "tool_calls" => Map.get(attrs, :tool_calls) || [],
      "catalog_ops" => Map.get(attrs, :catalog_ops) || [],
      "evidence_reads" => EvidenceReadProjection.normalize(Map.get(attrs, :evidence_reads)),
      "limits_hit" => Map.get(attrs, :limits_hit) || [],
      "preludes" => Map.get(attrs, :preludes) || [],
      "inner_preludes" => Map.get(attrs, :inner_preludes) || [],
      "inner_prelude_projection" => Map.get(attrs, :inner_prelude_projection),
      "inner_prelude_call_counts" => Map.get(attrs, :inner_prelude_call_counts) || %{},
      "prelude_projection" => Map.get(attrs, :prelude_projection),
      "prelude_call_policy" => Map.get(attrs, :prelude_call_policy),
      "prelude_presentation" => Map.get(attrs, :prelude_presentation),
      "fail" => normalize_fail(Map.get(attrs, :fail)),
      "turn_type" => normalize_turn_type(Map.get(attrs, :turn_type))
    }
    |> Event.sanitize()
  end

  defp normalize_memory_diff(%{changed_keys: keys}), do: %{"changed_keys" => keys}

  defp normalize_memory_diff(_), do: nil

  # Stringify `reason` so the in-memory sink and the JSON-round-tripped file
  # sink agree (an atom reason would read back as a string from JSONL).
  defp normalize_fail(%{reason: reason, message: message}) do
    %{"reason" => stringify(reason), "message" => message}
  end

  defp normalize_fail(_), do: nil

  defp maybe_put_evidence_reads(summary, tool, call)
       when tool in ["evidence_read", "evidence_page"] do
    reads =
      case EvidenceReadProjection.normalize(get_key(call, :evidence_reads)) do
        [] -> EvidenceReadProjection.from_result(get_key(call, :result))
        reads -> reads
      end

    case reads do
      [] -> summary
      reads -> Map.put(summary, "evidence_reads", reads)
    end
  end

  defp maybe_put_evidence_reads(summary, _tool, _call), do: summary

  defp normalize_tags(tags) when is_map(tags) do
    Enum.reduce(tags, %{}, fn {key, value}, acc ->
      key = stringify(key)

      if key == "" do
        acc
      else
        Map.put(acc, key, normalize_tag_value(value))
      end
    end)
  end

  defp normalize_tags(_), do: %{}

  defp normalize_tag_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp normalize_tag_value(value), do: stringify(value)

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
