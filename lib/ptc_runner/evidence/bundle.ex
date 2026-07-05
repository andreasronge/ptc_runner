defmodule PtcRunner.Evidence.Bundle do
  @moduledoc false

  alias PtcRunner.TraceLog.Analyzer

  @schema_version 1
  @default_max_item_bytes 64 * 1024
  @default_limit 50
  @max_page_limit 100
  @max_fail_reason_bytes 256
  @safe_turn_fields ~w(turn attempt committed status tags)
  @safe_optional_fields ~w(catalog_ops_count tool_calls_count fail.reason)
  @file_kinds ~w(text markdown json)
  @structured_kinds ~w(log_counters log_turns prelude_export)
  @hidden_kinds ~w(answer_key operator_only)

  defstruct bundle_id: nil,
            description: nil,
            bundle_checksum: nil,
            manifest_checksum: nil,
            visible: [],
            items: %{}

  @type t :: %__MODULE__{}

  @spec load!(t() | map() | String.t(), keyword()) :: t()
  def load!(source, opts \\ [])

  def load!(%__MODULE__{} = bundle, _opts), do: bundle

  def load!(path, opts) when is_binary(path) do
    base_dir = path |> Path.expand() |> Path.dirname()
    manifest = path |> File.read!() |> Jason.decode!()
    from_manifest!(manifest, Keyword.put(opts, :base_dir, base_dir))
  end

  def load!(manifest, opts) when is_map(manifest), do: from_manifest!(manifest, opts)

  @spec metadata(t(), map()) :: map()
  def metadata(%__MODULE__{} = bundle, _args \\ %{}) do
    %{
      "schema_version" => @schema_version,
      "bundle_id" => bundle.bundle_id,
      "description" => bundle.description,
      "bundle_checksum" => bundle.bundle_checksum,
      "items" => Enum.map(bundle.visible, &summary/1)
    }
  end

  @spec page(t(), map()) :: map()
  def page(%__MODULE__{} = bundle, args \\ %{}) do
    bundle.visible
    |> Enum.map(&summary/1)
    |> page_items(args)
  end

  @spec read(t(), map()) :: map()
  def read(%__MODULE__{} = bundle, args) when is_map(args) do
    id = Map.get(args, "id") || Map.get(args, :id)

    case Map.fetch(bundle.items, id) do
      {:ok, %{visible?: true} = item} ->
        item.envelope

      {:ok, _hidden} ->
        unknown_item!(id)

      :error ->
        unknown_item!(id)
    end
  end

  def read(_bundle, _args), do: raise(ArgumentError, "evidence_read args must be a map")

  defp unknown_item!(id), do: raise(ArgumentError, "unknown evidence item #{inspect(id)}")

  defp from_manifest!(manifest, opts) do
    unless Map.get(manifest, "schema_version") == @schema_version do
      raise ArgumentError, "evidence bundle schema_version must be #{@schema_version}"
    end

    base_dir = opts |> Keyword.get(:base_dir, File.cwd!()) |> Path.expand()
    root = realpath!(base_dir, "bundle root")

    allowed_log_roots =
      Enum.map(Keyword.get(opts, :allowed_log_roots, []), &realpath!(&1, "allowed log root"))

    max_item_bytes = Map.get(manifest, "max_item_bytes", @default_max_item_bytes)

    bundle_id = required_string!(manifest, "bundle_id")

    items =
      manifest
      |> Map.get("items", [])
      |> Enum.map(&build_item!(&1, root, allowed_log_roots, max_item_bytes))
      |> Enum.map(&put_bundle_id(&1, bundle_id))

    reject_duplicate_ids!(items)

    visible = Enum.filter(items, & &1.visible?)

    %__MODULE__{
      bundle_id: bundle_id,
      description: Map.get(manifest, "description"),
      visible: visible,
      items: Map.new(items, &{&1.id, &1}),
      bundle_checksum: checksum(bundle_fingerprint(visible)),
      manifest_checksum: checksum(manifest_fingerprint(items))
    }
  end

  defp put_bundle_id(%{envelope: envelope} = item, bundle_id) do
    %{item | envelope: Map.put(envelope, "bundle_id", bundle_id)}
  end

  defp build_item!(spec, root, allowed_log_roots, bundle_max_bytes) when is_map(spec) do
    id = required_string!(spec, "id")
    kind = required_string!(spec, "kind")
    visible? = Map.get(spec, "model_visible", false) == true
    max_bytes = Map.get(spec, "max_item_bytes", bundle_max_bytes)

    unless kind in @file_kinds or kind in @structured_kinds or kind in @hidden_kinds do
      raise ArgumentError, "unsupported evidence item kind #{inspect(kind)}"
    end

    envelope =
      cond do
        kind in @file_kinds ->
          file_item_envelope(spec, id, kind, root, max_bytes)

        kind in @hidden_kinds ->
          hidden_item_envelope(spec, id, kind, root, max_bytes)

        kind == "log_counters" ->
          log_counters_envelope(spec, id, root, allowed_log_roots, max_bytes)

        kind == "log_turns" ->
          log_turns_envelope(spec, id, root, allowed_log_roots, max_bytes)

        kind == "prelude_export" ->
          prelude_export_envelope(spec, id, root, max_bytes)
      end

    %{
      id: id,
      kind: kind,
      visible?: visible? and kind not in @hidden_kinds,
      source_ref: envelope["source_ref"],
      checksum: envelope["checksum"],
      bytes: envelope["bytes"],
      truncated: envelope["truncated"],
      manifest_checksum: Map.get(envelope, "manifest_checksum", envelope["checksum"]),
      manifest_bytes: Map.get(envelope, "manifest_bytes", envelope["bytes"]),
      envelope: envelope
    }
  end

  defp build_item!(_spec, _root, _allowed_log_roots, _max),
    do: raise(ArgumentError, "evidence item must be a map")

  defp file_item_envelope(spec, id, kind, root, max_bytes) do
    source_ref = required_string!(spec, "path")
    path = resolve_file_path!(source_ref, root)
    {served, truncated?} = read_bounded_file!(path, max_bytes)

    %{
      "bundle_id" => nil,
      "item_id" => id,
      "kind" => kind,
      "source_ref" => source_ref,
      "checksum" => checksum_bytes(served),
      "bytes" => byte_size(served),
      "content" => served,
      "truncated" => truncated?
    }
  end

  defp hidden_item_envelope(spec, id, kind, root, max_bytes) do
    validate_max_item_bytes!(max_bytes)
    source_ref = required_string!(spec, "path")
    path = resolve_file_path!(source_ref, root)
    %{checksum: checksum, bytes: bytes} = file_digest!(path)

    %{
      "bundle_id" => nil,
      "item_id" => id,
      "kind" => kind,
      "source_ref" => source_ref,
      "checksum" => checksum,
      "bytes" => min(bytes, max_bytes),
      "truncated" => bytes > max_bytes,
      "manifest_checksum" => checksum,
      "manifest_bytes" => bytes
    }
  end

  defp prelude_export_envelope(spec, id, root, max_bytes) do
    source_ref = required_string!(spec, "path")
    path = resolve_file_path!(source_ref, root)
    ensure_input_file_bytes!(path, max_bytes, "prelude_export", id)
    content = File.read!(path)

    data =
      case Jason.decode(content) do
        {:ok, decoded} -> decoded
        {:error, _} -> %{"content" => content}
      end

    structured_envelope(id, "prelude_export", source_ref, data, max_bytes)
  end

  defp log_counters_envelope(spec, id, root, allowed_log_roots, max_bytes) do
    source_ref = required_string!(spec, "log_source")

    data =
      spec
      |> load_log_events!(root, allowed_log_roots, max_bytes)
      |> counters(map_field(spec, "filters", %{}))

    structured_envelope(id, "log_counters", source_ref, data, max_bytes)
  end

  defp log_turns_envelope(spec, id, root, allowed_log_roots, max_bytes) do
    source_ref = required_string!(spec, "log_source")
    filters = map_field(spec, "filters", %{})
    session_id = Map.get(spec, "session_id")
    fields = Map.get(spec, "fields", @safe_turn_fields)
    validate_turn_fields!(fields)

    data =
      spec
      |> load_log_events!(root, allowed_log_roots, max_bytes)
      |> filtered_turns(filters)
      |> maybe_filter_session(session_id)
      |> Enum.map(&project_evidence_turn(&1, fields))

    structured_envelope(id, "log_turns", source_ref, data, max_bytes)
  end

  defp structured_envelope(id, kind, source_ref, data, max_bytes) do
    canonical = canonical_json!(data)
    ensure_structured_bytes!(id, kind, canonical, max_bytes)

    %{
      "bundle_id" => nil,
      "item_id" => id,
      "kind" => kind,
      "source_ref" => source_ref,
      "checksum" => checksum_bytes(canonical),
      "bytes" => byte_size(canonical),
      "data" => data,
      "truncated" => false
    }
  end

  defp summary(item) do
    %{
      "bundle_id" => item.envelope["bundle_id"],
      "item_id" => item.id,
      "kind" => item.kind,
      "source_ref" => item.source_ref,
      "checksum" => item.checksum,
      "bytes" => item.bytes,
      "truncated" => item.truncated
    }
  end

  defp bundle_fingerprint(items) do
    Enum.map(items, fn item ->
      %{
        "item_id" => item.id,
        "kind" => item.kind,
        "checksum" => item.checksum,
        "bytes" => item.bytes
      }
    end)
  end

  defp manifest_fingerprint(items) do
    Enum.map(items, fn item ->
      %{
        "item_id" => item.id,
        "kind" => item.kind,
        "visible" => item.visible?,
        "source_ref" => item.source_ref,
        "checksum" => item.manifest_checksum,
        "bytes" => item.manifest_bytes
      }
    end)
  end

  defp counters(events, filters) do
    turns = filtered_turns(events, filters)
    tool_calls = Enum.flat_map(turns, &(get_in(&1, ["data", "tool_calls"]) || []))
    input_tokens = sum_observed_field(turns, "input_tokens")
    output_tokens = sum_observed_field(turns, "output_tokens")
    total_tokens = sum_observed_field(turns, "total_tokens")

    %{
      "sessions" => turns |> Enum.map(&turn_correlation_id/1) |> Enum.uniq() |> length(),
      "attempts" => length(turns),
      "committed" => Enum.count(turns, &(&1["committed"] == true)),
      "failed" => Enum.count(turns, &(&1["committed"] == false)),
      "catalog_ops" =>
        turns |> Enum.flat_map(&(get_in(&1, ["data", "catalog_ops"]) || [])) |> length(),
      "tool_calls" => length(tool_calls),
      "upstream_calls" => Enum.count(tool_calls, &upstream_call?/1),
      "duration_ms" => sum_field(turns, "duration_ms"),
      "input_tokens" => observed_sum(input_tokens),
      "input_tokens_known_count" => observed_count(input_tokens),
      "output_tokens" => observed_sum(output_tokens),
      "output_tokens_known_count" => observed_count(output_tokens),
      "total_tokens" => observed_sum(total_tokens),
      "total_tokens_known_count" => observed_count(total_tokens)
    }
  end

  defp filtered_turns(events, filters) do
    events
    |> Analyzer.turn_events()
    |> Enum.filter(&matches_filters?(&1, filters))
  end

  defp matches_filters?(event, filters) do
    matches_driver?(event, string_field(filters, "driver")) and
      matches_status?(event, string_field(filters, "status")) and
      matches_tags?(event, map_field(filters, "tags", %{})) and
      matches_time?(event, string_field(filters, "from"), string_field(filters, "to"))
  end

  defp matches_driver?(_event, nil), do: true
  defp matches_driver?(event, driver), do: event["driver"] == driver

  defp matches_status?(_event, nil), do: true
  defp matches_status?(event, status), do: event["status"] == status

  defp matches_tags?(_event, tags) when tags == %{}, do: true

  defp matches_tags?(event, tags) when is_map(tags) do
    case event["tags"] do
      event_tags when is_map(event_tags) ->
        Enum.all?(tags, fn {key, value} -> Map.get(event_tags, to_string(key)) == value end)

      _other ->
        false
    end
  end

  defp matches_time?(_event, nil, nil), do: true

  defp matches_time?(event, from, to) do
    case parse_event_time(event["timestamp"] || event["ts"]) do
      nil ->
        false

      timestamp ->
        after_from? = is_nil(from) or DateTime.compare(timestamp, parse_filter_time!(from)) != :lt
        before_to? = is_nil(to) or DateTime.compare(timestamp, parse_filter_time!(to)) != :gt
        after_from? and before_to?
    end
  end

  defp parse_event_time(nil), do: nil
  defp parse_event_time(value), do: parse_filter_time!(value)

  defp parse_filter_time!(value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    datetime
  end

  defp maybe_filter_session(turns, nil), do: turns

  defp maybe_filter_session(turns, session_id),
    do: Enum.filter(turns, &(turn_correlation_id(&1) == session_id))

  defp project_evidence_turn(event, fields) do
    Map.new(fields, fn
      "turn" ->
        {"turn", event["turn"]}

      "attempt" ->
        {"attempt", event["attempt"]}

      "committed" ->
        {"committed", event["committed"]}

      "status" ->
        {"status", event["status"]}

      "tags" ->
        {"tags", event["tags"] || %{}}

      "catalog_ops_count" ->
        {"catalog_ops_count", length(get_in(event, ["data", "catalog_ops"]) || [])}

      "tool_calls_count" ->
        {"tool_calls_count", length(get_in(event, ["data", "tool_calls"]) || [])}

      "fail.reason" ->
        {"fail", %{"reason" => bounded_fail_reason(get_in(event, ["data", "fail", "reason"]))}}
    end)
  end

  defp bounded_fail_reason(nil), do: nil

  defp bounded_fail_reason(reason),
    do: reason |> to_string() |> truncate_utf8(@max_fail_reason_bytes)

  defp validate_turn_fields!(fields) when is_list(fields) do
    allowed = MapSet.new(@safe_turn_fields ++ @safe_optional_fields)

    case Enum.find(fields, &(not (is_binary(&1) and MapSet.member?(allowed, &1)))) do
      nil -> :ok
      field -> raise ArgumentError, "unsafe log_turns field #{inspect(field)}"
    end
  end

  defp validate_turn_fields!(_fields), do: raise(ArgumentError, "log_turns fields must be a list")

  defp load_log_events!(spec, root, allowed_log_roots, max_bytes) do
    source_ref = required_string!(spec, "log_source")
    path = resolve_log_source!(source_ref, root, allowed_log_roots)
    validate_max_item_bytes!(max_bytes)

    paths =
      if File.dir?(path) do
        path
        |> Path.join("*.jsonl")
        |> Path.wildcard()
        |> Enum.sort()
      else
        [path]
      end

    paths
    |> enforce_aggregate_input_bytes!(max_bytes, "log_source", source_ref)
    |> Enum.flat_map(&load_log_file!/1)
  end

  defp load_log_file!(path) do
    path
    |> File.stream!()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!/1)
  end

  defp enforce_aggregate_input_bytes!(paths, max_bytes, kind, source_ref) do
    _total_bytes =
      Enum.reduce(paths, 0, fn path, acc ->
        size = input_file_size!(path, kind, source_ref)
        total = acc + size

        if total > max_bytes do
          raise ArgumentError,
                "evidence #{kind} #{inspect(source_ref)} is #{total} bytes, " <>
                  "exceeding max_item_bytes #{max_bytes}"
        end

        total
      end)

    paths
  end

  defp ensure_input_file_bytes!(path, max_bytes, kind, id) do
    validate_max_item_bytes!(max_bytes)
    size = input_file_size!(path, kind, id)

    if size > max_bytes do
      raise ArgumentError,
            "evidence #{kind} #{inspect(id)} is #{size} bytes, " <>
              "exceeding max_item_bytes #{max_bytes}"
    end

    :ok
  end

  defp input_file_size!(path, kind, source_ref) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        size

      {:ok, %File.Stat{type: :directory}} ->
        0

      {:ok, %File.Stat{type: type}} ->
        raise ArgumentError,
              "evidence #{kind} #{inspect(source_ref)} must be a regular file, got #{type}"

      {:error, reason} ->
        raise ArgumentError,
              "evidence #{kind} #{inspect(source_ref)} is not readable: #{inspect(reason)}"
    end
  end

  defp resolve_file_path!(source_ref, root) do
    reject_absolute_or_parent!(source_ref, "path")
    path = Path.expand(source_ref, root)
    real = realpath!(path, "evidence file")

    unless under_root?(real, root) do
      raise ArgumentError, "evidence file path escapes bundle root: #{inspect(source_ref)}"
    end

    real
  end

  defp resolve_log_source!(source_ref, root, allowed_log_roots) do
    reject_absolute_or_parent!(source_ref, "log_source")
    path = Path.expand(source_ref, root)
    real = realpath!(path, "evidence log_source")
    allowed? = under_root?(real, root) or Enum.any?(allowed_log_roots, &under_root?(real, &1))

    unless allowed? do
      raise ArgumentError,
            "evidence log_source escapes bundle root and allowed log roots: #{inspect(source_ref)}"
    end

    real
  end

  defp reject_absolute_or_parent!(source_ref, field) do
    cond do
      Path.type(source_ref) == :absolute ->
        raise ArgumentError, "evidence #{field} must be relative: #{inspect(source_ref)}"

      source_ref |> Path.split() |> Enum.member?("..") ->
        raise ArgumentError,
              "evidence #{field} may not contain .. segments: #{inspect(source_ref)}"

      true ->
        :ok
    end
  end

  defp realpath!(path, label) do
    path
    |> Path.expand()
    |> Path.split()
    |> resolve_realpath_parts(label, [])
  end

  defp resolve_realpath_parts(["/" | rest], label, seen),
    do: resolve_realpath_parts(rest, "/", label, seen)

  defp resolve_realpath_parts(parts, label, seen),
    do: resolve_realpath_parts(parts, "", label, seen)

  defp resolve_realpath_parts([], acc, _label, _seen), do: acc

  defp resolve_realpath_parts([part | rest], acc, label, seen) do
    current = Path.join(acc, part)

    case File.lstat(current) do
      {:ok, %File.Stat{type: :symlink}} ->
        if current in seen do
          raise ArgumentError, "#{label} has a symlink cycle: #{current}"
        end

        target = File.read_link!(current)

        target =
          case Path.type(target) do
            :absolute -> target
            _relative -> Path.expand(target, acc)
          end

        [target | rest]
        |> Path.join()
        |> Path.split()
        |> resolve_realpath_parts(label, [current | seen])

      {:ok, _stat} ->
        resolve_realpath_parts(rest, current, label, seen)

      {:error, reason} ->
        raise ArgumentError, "#{label} is not readable: #{current} (#{reason})"
    end
  end

  defp under_root?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  defp page_items(items, args) when is_map(args) do
    all? = Map.get(args, "all") == true or Map.get(args, :all) == true
    offset = cursor_arg(args)
    limit = if all?, do: min(length(items), @max_page_limit), else: limit_arg(args)
    paged = items |> Enum.drop(offset) |> Enum.take(limit)
    next_offset = offset + length(paged)
    has_more? = next_offset < length(items)

    %{
      "items" => paged,
      "next_cursor" => if(has_more?, do: Integer.to_string(next_offset), else: nil),
      "has_more" => has_more?,
      "limit" => limit
    }
  end

  defp page_items(items, _args), do: page_items(items, %{})

  defp limit_arg(args) do
    args
    |> int_field("limit", @default_limit)
    |> max(1)
    |> min(@max_page_limit)
  end

  defp cursor_arg(args) do
    case args |> string_field("cursor", "0") |> Integer.parse() do
      {offset, ""} -> max(offset, 0)
      _ -> 0
    end
  end

  defp sum_field(events, field) do
    Enum.reduce(events, 0, fn event, acc ->
      case event[field] do
        value when is_integer(value) -> acc + value
        _ -> acc
      end
    end)
  end

  defp sum_observed_field(events, field) do
    Enum.reduce(events, {0, 0}, fn event, {sum, count} ->
      case event[field] do
        value when is_integer(value) -> {sum + value, count + 1}
        _ -> {sum, count}
      end
    end)
  end

  defp observed_sum({_sum, 0}), do: nil
  defp observed_sum({sum, _count}), do: sum
  defp observed_count({_sum, count}), do: count

  defp upstream_call?(%{"server" => server}) when is_binary(server) and server != "", do: true
  defp upstream_call?(_), do: false

  defp turn_correlation_id(event), do: event["session_id"] || event["agent_id"] || "unknown"

  defp bound_bytes(bytes, max_bytes) when is_integer(max_bytes) and max_bytes >= 0 do
    if byte_size(bytes) > max_bytes do
      {truncate_utf8(bytes, max_bytes), true}
    else
      {bytes, false}
    end
  end

  defp bound_bytes(_bytes, max_bytes),
    do:
      raise(
        ArgumentError,
        "max_item_bytes must be a non-negative integer, got #{inspect(max_bytes)}"
      )

  defp ensure_structured_bytes!(id, kind, canonical, max_bytes)
       when is_integer(max_bytes) and max_bytes >= 0 do
    if byte_size(canonical) > max_bytes do
      raise ArgumentError,
            "structured evidence item #{inspect(id)} (#{kind}) is #{byte_size(canonical)} bytes, " <>
              "exceeding max_item_bytes #{max_bytes}"
    end
  end

  defp ensure_structured_bytes!(_id, _kind, _canonical, max_bytes),
    do:
      raise(
        ArgumentError,
        "max_item_bytes must be a non-negative integer, got #{inspect(max_bytes)}"
      )

  defp read_bounded_file!(path, max_bytes) when is_integer(max_bytes) and max_bytes >= 0 do
    {:ok, io} = File.open(path, [:read, :binary])

    try do
      bytes =
        case IO.binread(io, max_bytes + 1) do
          :eof -> ""
          data when is_binary(data) -> data
        end

      bound_bytes(bytes, max_bytes)
    after
      File.close(io)
    end
  end

  defp read_bounded_file!(_path, max_bytes),
    do:
      raise(
        ArgumentError,
        "max_item_bytes must be a non-negative integer, got #{inspect(max_bytes)}"
      )

  defp validate_max_item_bytes!(max_bytes) when is_integer(max_bytes) and max_bytes >= 0,
    do: :ok

  defp validate_max_item_bytes!(max_bytes),
    do:
      raise(
        ArgumentError,
        "max_item_bytes must be a non-negative integer, got #{inspect(max_bytes)}"
      )

  defp truncate_utf8(value, max_bytes) when byte_size(value) <= max_bytes, do: value
  defp truncate_utf8(_value, max_bytes) when max_bytes <= 0, do: ""

  defp truncate_utf8(value, max_bytes) do
    chunk = binary_part(value, 0, max_bytes)

    if String.valid?(chunk) do
      chunk
    else
      truncate_utf8(value, max_bytes - 1)
    end
  end

  defp file_digest!(path) do
    {:ok, io} = File.open(path, [:read, :binary])

    try do
      stream_digest(io, :crypto.hash_init(:sha256), 0)
    after
      File.close(io)
    end
  end

  defp stream_digest(io, ctx, bytes) do
    case IO.binread(io, 64 * 1024) do
      :eof ->
        %{
          checksum:
            ctx
            |> :crypto.hash_final()
            |> Base.encode16(case: :lower)
            |> then(&("sha256:" <> &1)),
          bytes: bytes
        }

      data when is_binary(data) ->
        stream_digest(io, :crypto.hash_update(ctx, data), bytes + byte_size(data))
    end
  end

  defp checksum(value), do: value |> canonical_json!() |> checksum_bytes()

  defp checksum_bytes(bytes) do
    bytes
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("sha256:" <> &1))
  end

  @doc false
  @spec canonical_json!(term()) :: String.t()
  def canonical_json!(value), do: value |> canonical_json_iodata() |> IO.iodata_to_binary()

  defp canonical_json_iodata(value) when is_map(value) do
    value
    |> Enum.map(fn {key, inner} -> {to_string(key), inner} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_intersperse(",", fn {key, inner} ->
      [Jason.encode!(key), ":", canonical_json_iodata(inner)]
    end)
    |> then(&["{", &1, "}"])
  end

  defp canonical_json_iodata(value) when is_list(value) do
    value
    |> Enum.map_intersperse(",", &canonical_json_iodata/1)
    |> then(&["[", &1, "]"])
  end

  defp canonical_json_iodata(value) when is_boolean(value), do: Jason.encode!(value)
  defp canonical_json_iodata(nil), do: Jason.encode!(nil)

  defp canonical_json_iodata(value) when is_atom(value),
    do: value |> to_string() |> Jason.encode!()

  defp canonical_json_iodata(value), do: Jason.encode!(value)

  defp reject_duplicate_ids!(items) do
    ids = Enum.map(items, & &1.id)

    case ids -- Enum.uniq(ids) do
      [] -> :ok
      [id | _] -> raise ArgumentError, "duplicate evidence item id #{inspect(id)}"
    end
  end

  defp required_string!(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> raise ArgumentError, "evidence manifest field #{key} must be a non-empty string"
    end
  end

  defp map_field(map, key, default) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_map(value) -> value
      _ -> default
    end
  end

  defp string_field(map, key, default \\ nil)

  defp string_field(map, key, default) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) -> value
      value when is_integer(value) -> Integer.to_string(value)
      _ -> default
    end
  end

  defp int_field(map, key, default) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end
end
