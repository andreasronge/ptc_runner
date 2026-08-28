defmodule PtcRunner.Kernel.RunCatalog do
  @moduledoc """
  Immutable safe-metadata rows for one private run-cohort generation.

  A generation is a captured value, not a view of a directory. It turns the
  bounded probes of `PtcRunner.Kernel.RunCatalogProbe` into one frozen row per
  canonical run stem, commits to their identities with a domain-separated
  digest, and never re-lists anything afterwards. Filesystem change therefore
  cannot alter an open generation: a later capture is a different generation
  with a different digest.

  ## What a row may say

  A row carries only what a sealed artifact states about itself at O(1) cost:
  identities, artifact presence and source class, schema and format versions,
  byte and record counts, lifecycle timestamps and terminal status, the safe
  `result_hash` fingerprint, the same `run-started` labels the public
  `analysis/runs` surface already exposes, the sealed artifact digest, and the
  correlation and admissibility of the pair.

  A row never carries prompts, responses, generated source, capability
  payloads, diagnostics, prints, result values, evidence-record content, or a
  filesystem path — and never a counter that would require scanning a whole
  trace (`evaluations`, `llm_calls`, `error_count`, `truncated`). Those stay
  where they already are, behind admission, on `analysis/runs {"view" "full"}`
  and `analysis/counters`.

  "Non-copying" here means no payload copying: beyond a head line, a bounded
  tail line, and a sealed container's fixed edges, nothing is read, decoded,
  or retained. The bounded per-row metadata projection is the product.

  ## Isolation

  Classification is per row, and a row is the unit of failure. A malformed,
  ambiguous, duplicate, unstable, or version-incompatible entry becomes an
  isolated row carrying a path-free reason code — it never blocks the
  generation, because nothing beyond its own probe was ever opened. Whole-
  operation refusals belong to the probe and the owner, not here.
  """

  alias PtcRunner.Kernel.InspectionArtifact.Format
  alias PtcRunner.Kernel.RunCatalogProbe

  @catalog_version "ptc-run-catalog-v1"
  @trace_schema_version 2
  @max_row_bytes 2_048

  # Most fundamental first: a reason that describes the entry itself outranks
  # one that describes its relationship to another entry, so a row that is both
  # malformed and duplicated reports the malformation it actually has.
  @reason_order [
    :ambiguous_trace,
    :unstable_entry,
    :malformed_metadata,
    :unsupported_schema,
    :filename_run_mismatch,
    :duplicate_run_identity,
    :inspection_correlation_missing
  ]

  @reason_rank @reason_order |> Enum.with_index() |> Map.new()

  @type row :: %{binary() => term()}

  @type generation :: %{
          rows: [row()],
          catalog_digest: binary(),
          excluded_files: non_neg_integer()
        }

  @spec catalog_version() :: binary()
  def catalog_version, do: @catalog_version

  @spec max_row_bytes() :: pos_integer()
  def max_row_bytes, do: @max_row_bytes

  @spec reason_order() :: [atom()]
  def reason_order, do: @reason_order

  @doc """
  Freezes one generation from the probes of a single capture.

  Rows are ordered by run reference so a generation, its digest, and any
  cursor derived from it stay stable for the lifetime of the capture.
  """
  @spec generation([RunCatalogProbe.probe()], non_neg_integer()) ::
          {:ok, generation()} | {:error, :invalid_catalog}
  def generation(probes, excluded_files)
      when is_list(probes) and is_integer(excluded_files) and excluded_files >= 0 do
    if Enum.all?(probes, &valid_probe?/1) and unique_refs?(probes) do
      {:ok, build_generation(probes, excluded_files)}
    else
      {:error, :invalid_catalog}
    end
  end

  def generation(_probes, _excluded_files), do: {:error, :invalid_catalog}

  defp build_generation(probes, excluded_files) do
    probes = Enum.sort_by(probes, & &1.run_ref)
    duplicated = duplicated_identities(probes)
    rows = Enum.map(probes, &row(&1, duplicated))

    %{
      rows: rows,
      catalog_digest: digest(Enum.map(probes, &commitment/1)),
      excluded_files: excluded_files
    }
  end

  # Two entries may not both claim one run or trace identity. Stems are unique
  # within a root, so this catches the case the filesystem cannot prevent: a
  # trace whose embedded identity belongs to another entry's run.
  defp duplicated_identities(probes) do
    probes
    |> Enum.flat_map(&claimed_identities/1)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_identity, refs} -> refs |> Enum.uniq() |> length() > 1 end)
    |> Enum.flat_map(fn {_identity, refs} -> refs end)
    |> MapSet.new()
  end

  defp claimed_identities(%{run_ref: run_ref, trace: %{present: :probed, head: head}}),
    do: [{{:run, head.run_id}, run_ref}, {{:trace, head.trace_id}, run_ref}]

  defp claimed_identities(_probe), do: []

  defp row(probe, duplicated) do
    correlation = correlation(probe)
    reasons = reasons(probe, correlation, duplicated)

    probe
    |> base_row(correlation, reasons)
    |> bound_row()
  end

  defp base_row(probe, correlation, reasons) do
    trace = probe.trace
    inspection = probe.inspection
    head = trace_head(trace)
    tail = trace_tail(trace)

    %{
      "run_id" => probe.run_ref,
      "trace_id" => head[:trace_id],
      "trace_present" => trace_present(trace),
      "inspection_present" => inspection.present != :absent,
      "trace_schema_version" => head[:schema_version],
      "inspection_format_version" => Map.get(inspection, :format_version),
      "inspection_schema_version" => Map.get(inspection, :schema_version),
      "trace_bytes" => Map.get(trace, :bytes),
      "inspection_bytes" => Map.get(inspection, :bytes),
      "inspection_record_count" => Map.get(inspection, :record_count),
      "start_timestamp" => head[:timestamp],
      "stop_timestamp" => tail[:timestamp],
      "duration_ms" => duration_ms(head[:timestamp], tail[:timestamp]),
      "status" => tail[:status],
      "terminal_reason" => tail[:terminal_reason],
      "result_hash" => tail[:result_hash],
      "complete" => not is_nil(tail),
      "name" => string_label(head, "name"),
      "model" => string_label(head, "model"),
      "provider" => string_label(head, "provider"),
      "tags" => map_label(head, "tags"),
      "labels" => (head && head.labels) || %{},
      "artifact_digest" => artifact_digest(inspection),
      "correlation" => correlation,
      "state" => if(reasons == [], do: "admissible", else: "isolated"),
      "isolation_reason" => reasons |> List.first() |> stringify_reason()
    }
  end

  # An oversized row is a row the safe vocabulary cannot carry, so it is
  # reduced field-wise and isolated rather than published in full or dropped.
  # What is removed is exactly what a caller can grow without bound: the
  # `run-started` label data and the terminal strings. Every field that
  # survives is either an identity the probe already bounds, a validated
  # timestamp, a fixed-width digest, or a number, so the reduced row is always
  # inside the bound and the row schema keeps all of its keys.
  defp bound_row(row) do
    if row_bytes(row) <= @max_row_bytes do
      row
    else
      Map.merge(row, %{
        "labels" => %{},
        "tags" => %{},
        "name" => nil,
        "model" => nil,
        "provider" => nil,
        "status" => nil,
        "terminal_reason" => nil,
        "result_hash" => nil,
        "state" => "isolated",
        "isolation_reason" => "malformed_metadata"
      })
    end
  end

  defp row_bytes(row) do
    case Jason.encode(row) do
      {:ok, encoded} -> byte_size(encoded)
      {:error, _reason} -> @max_row_bytes + 1
    end
  end

  defp trace_head(%{present: :probed, head: head}), do: head
  defp trace_head(_trace), do: nil

  defp trace_tail(%{present: :probed, tail: tail}), do: tail
  defp trace_tail(_trace), do: nil

  defp trace_present(%{present: :probed, source_kind: :private}), do: "private"
  defp trace_present(%{present: :probed, source_kind: :sanitized}), do: "sanitized"
  defp trace_present(%{present: :absent}), do: "absent"
  defp trace_present(_trace), do: "unreadable"

  # Label data reaches a row from a file, so its shape is asserted rather than
  # assumed: a row field keeps one type whatever the envelope happened to
  # carry, and anything else reads as absent.
  defp string_label(head, key) do
    case label(head, key) do
      value when is_binary(value) -> value
      _absent -> nil
    end
  end

  defp map_label(head, key) do
    case label(head, key) do
      value when is_map(value) -> value
      _absent -> %{}
    end
  end

  defp label(nil, _key), do: nil
  defp label(head, key), do: Map.get(head.labels, key)

  defp artifact_digest(%{present: :probed, artifact_digest: digest}),
    do: Base.encode16(digest, case: :lower)

  defp artifact_digest(_inspection), do: nil

  defp correlation(%{trace: trace, inspection: inspection} = probe) do
    cond do
      not usable?(trace) or not usable?(inspection) -> "unavailable"
      trace.present == :absent and inspection.present == :absent -> "unavailable"
      inspection.present == :absent -> "trace_only"
      trace.present == :absent -> "inspection_only"
      paired?(probe) -> "paired"
      true -> "mismatch"
    end
  end

  defp usable?(%{present: present}), do: present in [:probed, :absent]

  # The footer commits to identity only as digests, so correlation is proven by
  # hashing what the trace states and comparing — never by trusting a filename.
  defp paired?(%{trace: %{head: head}, inspection: inspection}) do
    inspection.trace_id_sha256 == Format.identity_sha256(head.trace_id)
  end

  defp reasons(probe, correlation, duplicated) do
    []
    |> add(probe.trace.present == :ambiguous, :ambiguous_trace)
    |> add(unstable?(probe), :unstable_entry)
    |> add(malformed?(probe), :malformed_metadata)
    |> add(unsupported_schema?(probe), :unsupported_schema)
    |> add(filename_mismatch?(probe), :filename_run_mismatch)
    |> add(MapSet.member?(duplicated, probe.run_ref), :duplicate_run_identity)
    |> add(correlation == "mismatch", :inspection_correlation_missing)
    |> Enum.uniq()
    |> Enum.sort_by(&Map.fetch!(@reason_rank, &1))
  end

  defp unstable?(%{trace: trace, inspection: inspection}),
    do: trace.present == :unstable or inspection.present == :unstable

  defp malformed?(%{trace: trace, inspection: inspection}),
    do: trace.present == :malformed or inspection.present == :malformed

  defp unsupported_schema?(%{trace: trace, inspection: inspection}) do
    unsupported_trace_schema?(trace) or inspection.present == :versions
  end

  defp unsupported_trace_schema?(%{present: :probed, head: head}),
    do: head.schema_version != @trace_schema_version

  defp unsupported_trace_schema?(_trace), do: false

  # Filenames are routing hints; embedded identity is authoritative. Both halves
  # are checked against the stem the entry was found under, so a file that
  # describes another run is isolated instead of published under this one.
  defp filename_mismatch?(%{run_ref: run_ref, trace: trace, inspection: inspection}) do
    trace_mismatch?(trace, run_ref) or inspection_mismatch?(inspection, run_ref)
  end

  defp trace_mismatch?(%{present: :probed, head: head}, run_ref), do: head.run_id != run_ref
  defp trace_mismatch?(_trace, _run_ref), do: false

  defp inspection_mismatch?(%{present: :probed, run_id_sha256: digest}, run_ref),
    do: digest != Format.identity_sha256(run_ref)

  defp inspection_mismatch?(_inspection, _run_ref), do: false

  defp duration_ms(nil, _stop), do: nil
  defp duration_ms(_start, nil), do: nil

  defp duration_ms(start_timestamp, stop_timestamp) do
    with {:ok, started_at, 0} <- DateTime.from_iso8601(start_timestamp),
         {:ok, stopped_at, 0} <- DateTime.from_iso8601(stop_timestamp) do
      max(DateTime.diff(stopped_at, started_at, :millisecond), 0)
    else
      _invalid -> nil
    end
  end

  # A row commitment covers the entry's reference, the trace's filesystem
  # identity, the digest of the bytes actually probed, and the sealed artifact
  # digest. Absent halves commit to their absence, so a generation captured
  # before a run was published cannot collide with one captured after.
  defp commitment(%{run_ref: run_ref, trace: trace, inspection: inspection}) do
    {run_ref, trace_commitment(trace), inspection_commitment(inspection)}
  end

  defp trace_commitment(%{present: :probed, identity: identity, commitment: commitment}),
    do: {:probed, identity, commitment}

  defp trace_commitment(%{present: present}), do: {present}

  defp inspection_commitment(%{present: :probed} = inspection),
    do: {:probed, inspection.bytes, inspection.artifact_digest}

  defp inspection_commitment(%{present: :versions} = inspection),
    do: {:versions, inspection.bytes, inspection.format_version, inspection.schema_version}

  defp inspection_commitment(%{present: present}), do: {present}

  defp digest(commitments) do
    [@catalog_version, 0, :erlang.term_to_binary(Enum.sort(commitments), [:deterministic])]
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  # A probe is validated before any row is built, and a probed half must carry
  # the fields a row reads from it. Refusing the whole generation is the only
  # honest answer to a probe the classifier cannot read: half a row would
  # publish a state nothing observed.
  defp valid_probe?(%{run_ref: run_ref, trace: trace, inspection: inspection}) do
    is_binary(run_ref) and run_ref != "" and valid_trace_probe?(trace) and
      valid_inspection_probe?(inspection)
  end

  defp valid_probe?(_probe), do: false

  defp valid_trace_probe?(%{present: :probed, head: head, tail: tail} = trace) do
    Map.has_key?(trace, :bytes) and Map.has_key?(trace, :identity) and
      Map.has_key?(trace, :commitment) and trace.source_kind in [:sanitized, :private] and
      is_map(head) and is_map(head.labels) and is_binary(head.run_id) and
      is_binary(head.trace_id) and (is_nil(tail) or is_map(tail))
  end

  defp valid_trace_probe?(%{present: present}),
    do: present in [:absent, :ambiguous, :malformed, :unstable]

  defp valid_trace_probe?(_trace), do: false

  defp valid_inspection_probe?(%{present: :probed} = inspection) do
    Map.has_key?(inspection, :bytes) and Map.has_key?(inspection, :record_count) and
      is_binary(inspection.run_id_sha256) and is_binary(inspection.trace_id_sha256) and
      is_binary(inspection.artifact_digest)
  end

  defp valid_inspection_probe?(%{present: :versions} = inspection) do
    Map.has_key?(inspection, :bytes) and is_integer(inspection.format_version) and
      is_integer(inspection.schema_version)
  end

  defp valid_inspection_probe?(%{present: present}),
    do: present in [:absent, :malformed, :unstable]

  defp valid_inspection_probe?(_inspection), do: false

  defp unique_refs?(probes) do
    refs = Enum.map(probes, & &1.run_ref)
    refs == Enum.uniq(refs)
  end

  defp add(reasons, true, reason), do: [reason | reasons]
  defp add(reasons, false, _reason), do: reasons

  defp stringify_reason(nil), do: nil
  defp stringify_reason(reason), do: Atom.to_string(reason)
end
