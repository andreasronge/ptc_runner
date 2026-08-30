defmodule PtcRunner.Kernel.TraceDirectoryAdmission do
  @moduledoc false

  alias PtcRunner.Kernel.TraceEventValidation

  @reason_order [
    :invalid_filename,
    :not_regular,
    :unreadable,
    :malformed_jsonl,
    :unsupported_version,
    :filename_run_mismatch,
    :run_identity_conflict,
    :trace_identity_conflict,
    :sequence_conflict,
    :lifecycle_conflict,
    :malformed_event
  ]

  @reason_rank @reason_order |> Enum.with_index() |> Map.new()
  @normal_suffix ".jsonl"
  @private_suffix ".private.jsonl"
  @max_claim_bytes 256

  @type source_kind :: :sanitized | :private
  @type reason ::
          :invalid_filename
          | :not_regular
          | :unreadable
          | :malformed_jsonl
          | :unsupported_version
          | :filename_run_mismatch
          | :run_identity_conflict
          | :trace_identity_conflict
          | :sequence_conflict
          | :lifecycle_conflict
          | :malformed_event

  @type evidence_status ::
          :not_regular | :unreadable | :malformed_jsonl | {:decoded, [map()]}

  @type file_evidence :: %{
          required(:raw_name) => binary(),
          required(:source_name) => binary() | nil,
          required(:source_kind) => source_kind(),
          required(:filename_run_claim) => binary() | nil,
          required(:embedded_run_claims) => [binary()],
          required(:embedded_trace_claims) => [binary()],
          required(:events) => [map()],
          required(:status) => evidence_status(),
          required(:semantic_reasons) => [reason()],
          required(:reasons) => [reason()]
        }

  @type component :: %{
          required(:sources) => [file_evidence()],
          required(:source_count) => pos_integer(),
          required(:source_names) => [binary()],
          required(:sources_omitted_count) => non_neg_integer(),
          required(:run_claims) => [binary()],
          required(:trace_claims) => [binary()],
          required(:reasons) => [reason()],
          required(:admitted?) => boolean()
        }

  @type classification :: %{
          required(:components) => [component()],
          required(:admitted) => [file_evidence()],
          required(:isolated) => [component()],
          required(:known_isolated_run_ids) => MapSet.t(binary())
        }

  @spec reason_order() :: [reason()]
  def reason_order, do: @reason_order

  @spec evidence(binary(), source_kind(), evidence_status()) ::
          {:ok, file_evidence()} | {:error, :invalid_evidence}
  def evidence(raw_name, source_kind, status)
      when is_binary(raw_name) and source_kind in [:sanitized, :private] do
    with ^source_kind <- filename_source_kind(raw_name),
         {:ok, events, _status_reasons} <- status_evidence(status),
         semantic_reasons = validate_semantics(status, events),
         true <- valid_semantic_reasons?(semantic_reasons) do
      {:ok, build_evidence(raw_name, source_kind, status, semantic_reasons)}
    else
      _invalid -> {:error, :invalid_evidence}
    end
  end

  def evidence(_raw_name, _source_kind, _status), do: {:error, :invalid_evidence}

  @spec source_kind(binary()) :: source_kind() | nil
  def source_kind(raw_name) when is_binary(raw_name), do: filename_source_kind(raw_name)
  def source_kind(_raw_name), do: nil

  @doc """
  Returns the canonical run stem a trace filename claims, or `nil`.

  This module owns the canonical stem grammar, so every reader that needs to
  route a filename to a run — directory admission here, and the bounded
  catalog probe that never decodes a file's events — asks it rather than
  restating the suffix and stem rules.
  """
  @spec run_claim(binary()) :: binary() | nil
  def run_claim(raw_name) when is_binary(raw_name) do
    case filename_source_kind(raw_name) do
      nil -> nil
      source_kind -> filename_run_claim(raw_name, source_kind)
    end
  end

  def run_claim(_raw_name), do: nil

  @doc "Returns `stem` when it is a canonical run stem, or `nil`."
  @spec canonical_stem(binary()) :: binary() | nil
  def canonical_stem(stem) when is_binary(stem) do
    if canonical_stem?(stem), do: stem
  end

  def canonical_stem(_stem), do: nil

  @spec classify([file_evidence()]) :: {:ok, classification()} | {:error, :invalid_evidence}
  def classify(evidence) when is_list(evidence) do
    if Enum.all?(evidence, &valid_evidence?/1) do
      classify_valid_evidence(evidence)
    else
      {:error, :invalid_evidence}
    end
  end

  def classify(_evidence), do: {:error, :invalid_evidence}

  defp classify_valid_evidence(evidence) do
    indexed = evidence |> Enum.sort_by(& &1.raw_name) |> Enum.with_index()

    components =
      indexed
      |> connected_indexes()
      |> Enum.map(&build_component(&1, indexed))
      |> Enum.sort_by(&component_sort_key/1)

    isolated = Enum.reject(components, & &1.admitted?)

    {:ok,
     %{
       components: components,
       admitted: components |> Enum.filter(& &1.admitted?) |> Enum.flat_map(& &1.sources),
       isolated: isolated,
       known_isolated_run_ids: isolated |> Enum.flat_map(& &1.run_claims) |> MapSet.new()
     }}
  end

  defp status_evidence({:decoded, events}) when is_list(events) do
    if Enum.all?(events, &is_map/1),
      do: {:ok, events, []},
      else: {:error, :invalid_evidence}
  end

  defp status_evidence(:not_regular), do: {:ok, [], [:not_regular]}
  defp status_evidence(:unreadable), do: {:ok, [], [:unreadable]}
  defp status_evidence(:malformed_jsonl), do: {:ok, [], [:malformed_jsonl]}
  defp status_evidence(_status), do: {:error, :invalid_evidence}

  defp decoded_reasons({:decoded, []}, _events, _filename_claim, _run_claims),
    do: [:malformed_jsonl]

  defp decoded_reasons({:decoded, _decoded}, _events, filename_claim, run_claims) do
    []
    |> maybe_add(filename_mismatch?(filename_claim, run_claims), :filename_run_mismatch)
  end

  defp decoded_reasons(_status, _events, _filename_claim, _run_claims), do: []

  defp validate_semantics({:decoded, [_ | _]}, events),
    do: TraceEventValidation.directory_reasons(events)

  defp validate_semantics(_status, _events), do: []

  defp valid_semantic_reasons?(reasons) when is_list(reasons) do
    allowed = [:unsupported_version, :sequence_conflict, :lifecycle_conflict, :malformed_event]
    Enum.all?(reasons, &(&1 in allowed)) and reasons == order_reasons(reasons)
  end

  defp valid_semantic_reasons?(_reasons), do: false

  defp build_evidence(raw_name, source_kind, status, semantic_reasons) do
    {:ok, events, status_reasons} = status_evidence(status)
    filename_run_claim = filename_run_claim(raw_name, source_kind)
    source_name = if filename_run_claim, do: raw_name
    embedded_run_claims = claims(events, "run_id")
    embedded_trace_claims = claims(events, "trace_id")

    reasons =
      []
      |> maybe_add(is_nil(filename_run_claim), :invalid_filename)
      |> Kernel.++(status_reasons)
      |> Kernel.++(decoded_reasons(status, events, filename_run_claim, embedded_run_claims))
      |> Kernel.++(semantic_reasons)
      |> order_reasons()

    %{
      raw_name: raw_name,
      source_name: source_name,
      source_kind: source_kind,
      filename_run_claim: filename_run_claim,
      embedded_run_claims: embedded_run_claims,
      embedded_trace_claims: embedded_trace_claims,
      events: events,
      status: status,
      semantic_reasons: semantic_reasons,
      reasons: reasons
    }
  end

  defp filename_mismatch?(_filename_claim, run_claims) when length(run_claims) != 1, do: true
  defp filename_mismatch?(nil, [_run_claim]), do: false
  defp filename_mismatch?(filename_claim, [run_claim]), do: filename_claim != run_claim

  defp claims(events, key) do
    events
    |> Enum.reduce(MapSet.new(), fn event, claims ->
      case Map.get(event, key) do
        claim when is_binary(claim) ->
          if bounded_claim?(claim), do: MapSet.put(claims, claim), else: claims

        _other ->
          claims
      end
    end)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp bounded_claim?(claim),
    do: byte_size(claim) in 1..@max_claim_bytes and String.valid?(claim)

  defp filename_run_claim(raw_name, source_kind) do
    suffix = if source_kind == :private, do: @private_suffix, else: @normal_suffix

    with true <- byte_size(raw_name) > byte_size(suffix),
         true <-
           binary_part(raw_name, byte_size(raw_name) - byte_size(suffix), byte_size(suffix)) ==
             suffix,
         stem_size = byte_size(raw_name) - byte_size(suffix),
         stem = binary_part(raw_name, 0, stem_size),
         true <- canonical_stem?(stem) do
      stem
    else
      _invalid -> nil
    end
  end

  defp canonical_stem?(stem) when byte_size(stem) in 1..@max_claim_bytes do
    <<first, rest::binary>> = stem
    ascii_alphanumeric?(first) and rest_bytes_valid?(rest)
  end

  defp canonical_stem?(_stem), do: false

  defp rest_bytes_valid?(<<>>), do: true

  defp rest_bytes_valid?(<<byte, rest::binary>>)
       when (byte >= ?A and byte <= ?Z) or (byte >= ?a and byte <= ?z) or
              (byte >= ?0 and byte <= ?9) or byte in [?., ?_, ?-],
       do: rest_bytes_valid?(rest)

  defp rest_bytes_valid?(_rest), do: false

  defp ascii_alphanumeric?(byte),
    do:
      (byte >= ?A and byte <= ?Z) or (byte >= ?a and byte <= ?z) or
        (byte >= ?0 and byte <= ?9)

  defp filename_source_kind(raw_name) do
    cond do
      has_suffix?(raw_name, @private_suffix) -> :private
      has_suffix?(raw_name, @normal_suffix) -> :sanitized
      true -> nil
    end
  end

  defp has_suffix?(value, suffix) when byte_size(value) >= byte_size(suffix),
    do: binary_part(value, byte_size(value) - byte_size(suffix), byte_size(suffix)) == suffix

  defp has_suffix?(_value, _suffix), do: false

  defp valid_evidence?(
         %{
           raw_name: raw_name,
           source_kind: source_kind,
           status: status,
           events: events,
           semantic_reasons: semantic_reasons
         } = candidate
       ) do
    filename_source_kind(raw_name) == source_kind and valid_semantic_reasons?(semantic_reasons) and
      candidate ==
        build_evidence(raw_name, source_kind, status, validate_semantics(status, events))
  rescue
    _exception -> false
  end

  defp valid_evidence?(_evidence), do: false

  defp connected_indexes(indexed) do
    parents = Map.new(indexed, fn {_evidence, index} -> {index, index} end)

    parents =
      indexed
      |> claim_groups()
      |> Enum.reduce(parents, &union_group/2)

    indexed
    |> Enum.group_by(fn {_evidence, index} -> find_root(parents, index) end, &elem(&1, 1))
    |> Map.values()
  end

  defp claim_groups(indexed) do
    Enum.reduce(indexed, %{}, fn {evidence, index}, groups ->
      claims =
        Enum.map(all_run_claims(evidence), &{:run, &1}) ++
          Enum.map(evidence.embedded_trace_claims, &{:trace, &1})

      Enum.reduce(claims, groups, fn claim, acc ->
        Map.update(acc, claim, [index], &[index | &1])
      end)
    end)
    |> Map.values()
  end

  defp union_group([first | rest], parents),
    do: Enum.reduce(rest, parents, &union_indexes(first, &1, &2))

  defp union_group([], parents), do: parents

  defp union_indexes(left, right, parents) do
    left_root = find_root(parents, left)
    right_root = find_root(parents, right)

    if left_root == right_root,
      do: parents,
      else: Map.put(parents, max(left_root, right_root), min(left_root, right_root))
  end

  defp find_root(parents, index) do
    case Map.fetch!(parents, index) do
      ^index -> index
      parent -> find_root(parents, parent)
    end
  end

  defp build_component(indexes, indexed) do
    by_index = Map.new(indexed, fn {evidence, index} -> {index, evidence} end)
    sources = indexes |> Enum.map(&Map.fetch!(by_index, &1)) |> Enum.sort_by(& &1.raw_name)
    run_claims = sources |> Enum.flat_map(&all_run_claims/1) |> Enum.uniq() |> Enum.sort()

    trace_claims =
      sources |> Enum.flat_map(& &1.embedded_trace_claims) |> Enum.uniq() |> Enum.sort()

    reasons =
      sources
      |> Enum.flat_map(& &1.reasons)
      |> maybe_add(run_claim_conflict?(sources), :run_identity_conflict)
      |> maybe_add(trace_claim_conflict?(sources), :trace_identity_conflict)
      |> order_reasons()

    source_names = sources |> Enum.map(& &1.source_name) |> Enum.reject(&is_nil/1)

    %{
      sources: sources,
      source_count: length(sources),
      source_names: source_names,
      sources_omitted_count: length(sources) - length(source_names),
      run_claims: run_claims,
      trace_claims: trace_claims,
      reasons: reasons,
      admitted?: admitted?(sources, reasons)
    }
  end

  defp all_run_claims(evidence) do
    [evidence.filename_run_claim | evidence.embedded_run_claims]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp run_claim_conflict?(sources) do
    repeated_claim?(sources, &all_run_claims/1)
  end

  defp trace_claim_conflict?(sources) do
    repeated_claim?(sources, & &1.embedded_trace_claims) or
      Enum.any?(sources, &(length(&1.embedded_trace_claims) > 1)) or
      trace_maps_to_multiple_runs?(sources)
  end

  defp repeated_claim?(sources, claims) do
    sources
    |> Enum.flat_map(fn source -> Enum.map(claims.(source), &{&1, source.raw_name}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.any?(fn {_claim, names} -> names |> Enum.uniq() |> length() > 1 end)
  end

  defp trace_maps_to_multiple_runs?(sources) do
    sources
    |> Enum.flat_map(fn source ->
      for trace_id <- source.embedded_trace_claims,
          run_id <- source.embedded_run_claims,
          do: {trace_id, run_id}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.any?(fn {_trace_id, run_ids} -> run_ids |> Enum.uniq() |> length() > 1 end)
  end

  defp admitted?([source], []) do
    source.status != :malformed_jsonl and match?({:decoded, [_ | _]}, source.status) and
      source.embedded_run_claims == [source.filename_run_claim] and
      length(source.embedded_trace_claims) == 1
  end

  defp admitted?(_sources, _reasons), do: false

  defp component_sort_key(component), do: Enum.map(component.sources, & &1.raw_name)

  defp maybe_add(values, true, value), do: [value | values]
  defp maybe_add(values, false, _value), do: values

  defp order_reasons(reasons) do
    reasons
    |> Enum.uniq()
    |> Enum.sort_by(&Map.fetch!(@reason_rank, &1))
  end
end
