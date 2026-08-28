defmodule PtcRunner.Kernel.RunCatalogProbe do
  @moduledoc """
  Bounded non-payload probes behind one private run-catalog generation.

  A probe answers what a sealed artifact pair already states about itself
  without opening either payload:

  - a canonical trace contributes its first line (guaranteed `run-started`)
    and the last complete line inside a bounded tail window (`run-stopped`
    for a complete run);
  - a `.ptcins` artifact contributes its 16-byte header and 192-byte footer,
    read with two `pread/3` calls. No evidence frame is decoded.

  Every read is bounded before it is issued: the two directory listings are
  capped, the union of run stems is capped, and each file contributes at most
  a head window, a tail window, and the container's fixed edges. Nothing here
  classifies — `PtcRunner.Kernel.RunCatalog` owns the row vocabulary and the
  failure matrix, so this module reports only what it observed and stays a
  pure function of the filesystem.

  A probe reports only bytes it can prove belong to the entry it inventoried.
  Each file is `lstat`ed before the open, the opened descriptor is `fstat`ed
  and compared before a byte is read, and the path is `lstat`ed again after —
  so neither a file replaced under its path nor one rewritten mid-probe is
  described as the file that was listed. Either reports `:unstable`.

  What survives is validated rather than trusted: the two probed trace events
  go through the same canonical trace-event validation a directory capture
  applies, and a sealed container whose versions are this build's is validated
  against the same header and footer contract its reader enforces.
  """

  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.InspectionArtifact.Format
  alias PtcRunner.Kernel.TraceDirectoryAdmission
  alias PtcRunner.Kernel.TraceEventValidation

  @head_bytes 65_536
  @tail_bytes 65_536
  @default_directory_entries 4_096
  @default_files 1_024
  @listing_timeout_ms 5_000
  @listing_heap_words 1_000_000
  @inspection_suffix ".ptcins"
  @sealed_edge_bytes Format.header_size() + Format.footer_size()
  @max_identity_bytes 256
  @max_timestamp_bytes 64

  @type stat_identity ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(), term()}

  @typedoc """
  A half whose bytes were read but did not decode into a describable state.

  It still carries what it observed — the descriptor identity and a digest of
  the exact bytes probed — because a generation must distinguish one malformed
  file from another. Only a half that never reached any bytes carries neither.
  """
  @type malformed_probe :: %{
          :present => :malformed,
          optional(:identity) => stat_identity(),
          optional(:commitment) => binary()
        }

  @type trace_probe ::
          %{present: :absent | :ambiguous | :unstable}
          | malformed_probe()
          | %{
              present: :probed,
              source_kind: :sanitized | :private,
              bytes: non_neg_integer(),
              identity: stat_identity(),
              commitment: binary(),
              head: map(),
              tail: map() | nil
            }

  @type inspection_probe ::
          %{present: :absent | :unstable}
          | malformed_probe()
          | %{
              present: :versions,
              bytes: non_neg_integer(),
              identity: stat_identity(),
              commitment: binary(),
              format_version: pos_integer(),
              schema_version: pos_integer()
            }
          | %{
              present: :probed,
              format_version: pos_integer(),
              schema_version: pos_integer(),
              bytes: non_neg_integer(),
              identity: stat_identity(),
              commitment: binary(),
              record_count: non_neg_integer(),
              run_id_sha256: binary(),
              trace_id_sha256: binary(),
              artifact_digest: binary()
            }

  @type probe :: %{run_ref: binary(), trace: trace_probe(), inspection: inspection_probe()}

  @spec head_bytes() :: pos_integer()
  def head_bytes, do: @head_bytes

  @spec tail_bytes() :: pos_integer()
  def tail_bytes, do: @tail_bytes

  @spec default_directory_entries() :: pos_integer()
  def default_directory_entries, do: @default_directory_entries

  @spec default_files() :: pos_integer()
  def default_files, do: @default_files

  @doc """
  Probes every canonical run stem under one trace and inspection root pair.

  Returns the probes in stem order together with the number of listed files
  that carry no canonical stem, which the catalog reports as `excluded_files`
  rather than as rows. Fails whole-operation with `:source_unavailable` for an
  unusable root and `:catalog_limit_exceeded` for a listing or stem count
  beyond its bound.
  """
  @spec probe_all(binary(), binary(), keyword()) ::
          {:ok, %{probes: [probe()], excluded_files: non_neg_integer()}} | {:error, atom()}
  def probe_all(traces_directory, inspection_directory, opts \\ [])

  def probe_all(traces_directory, inspection_directory, opts)
      when is_binary(traces_directory) and is_binary(inspection_directory) and is_list(opts) do
    max_directory_entries = Keyword.get(opts, :max_directory_entries, @default_directory_entries)
    max_files = Keyword.get(opts, :max_files, @default_files)
    listing_hook = Keyword.get(opts, :listing_hook)

    with true <- max_directory_entries in 1..@default_directory_entries,
         true <- max_files in 1..@default_files,
         true <- is_nil(listing_hook) or is_function(listing_hook, 0),
         {:ok, trace_names} <- listing(traces_directory, max_directory_entries, listing_hook),
         {:ok, inspection_names} <-
           listing(inspection_directory, max_directory_entries, listing_hook) do
      collect(
        traces_directory,
        inspection_directory,
        trace_names,
        inspection_names,
        max_files
      )
    else
      false -> {:error, :invalid_catalog}
      {:error, _reason} = error -> error
    end
  end

  def probe_all(_traces_directory, _inspection_directory, _opts), do: {:error, :invalid_catalog}

  defp collect(traces_directory, inspection_directory, trace_names, inspection_names, max_files) do
    {trace_entries, excluded_traces} = trace_entries(trace_names)
    {inspection_entries, excluded_inspection} = inspection_entries(inspection_names)

    stems =
      (Map.keys(trace_entries) ++ Map.keys(inspection_entries))
      |> Enum.uniq()
      |> Enum.sort()

    if length(stems) <= max_files do
      probes =
        Enum.map(stems, fn stem ->
          %{
            run_ref: stem,
            trace: probe_trace(traces_directory, Map.get(trace_entries, stem, [])),
            inspection: probe_inspection(inspection_directory, Map.get(inspection_entries, stem))
          }
        end)

      {:ok, %{probes: probes, excluded_files: excluded_traces + excluded_inspection}}
    else
      {:error, :catalog_limit_exceeded}
    end
  end

  defp listing(directory, max_directory_entries, listing_hook) do
    case BoundedWorker.run(
           fn -> bounded_names(directory, max_directory_entries, listing_hook) end,
           timeout_ms: @listing_timeout_ms,
           max_heap_words: @listing_heap_words,
           cancel_with_caller: true
         ) do
      {:ok, result} -> result
      {:error, :heap_exceeded} -> {:error, :catalog_limit_exceeded}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp bounded_names(directory, max_directory_entries, listing_hook) do
    if listing_hook, do: listing_hook.()

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(directory, time: :posix),
         {:ok, names} <- File.ls(directory),
         true <- length(names) <= max_directory_entries do
      {:ok, names}
    else
      false -> {:error, :catalog_limit_exceeded}
      _unavailable -> {:error, :source_unavailable}
    end
  end

  defp trace_entries(names) do
    Enum.reduce(names, {%{}, 0}, fn name, {entries, excluded} ->
      case {TraceDirectoryAdmission.run_claim(name), TraceDirectoryAdmission.source_kind(name)} do
        {stem, source_kind} when is_binary(stem) and not is_nil(source_kind) ->
          {Map.update(entries, stem, [{source_kind, name}], &[{source_kind, name} | &1]),
           excluded}

        _uncatalogued ->
          {entries, excluded + 1}
      end
    end)
  end

  defp inspection_entries(names) do
    Enum.reduce(names, {%{}, 0}, fn name, {entries, excluded} ->
      case inspection_stem(name) do
        nil -> {entries, excluded + 1}
        stem -> {Map.put(entries, stem, name), excluded}
      end
    end)
  end

  defp inspection_stem(name) do
    suffix_size = byte_size(@inspection_suffix)

    with true <- byte_size(name) > suffix_size,
         true <-
           binary_part(name, byte_size(name) - suffix_size, suffix_size) == @inspection_suffix do
      TraceDirectoryAdmission.canonical_stem(binary_part(name, 0, byte_size(name) - suffix_size))
    else
      _other -> nil
    end
  end

  defp probe_trace(_directory, []), do: %{present: :absent}
  defp probe_trace(_directory, [_first, _second | _rest]), do: %{present: :ambiguous}

  defp probe_trace(directory, [{source_kind, name}]),
    do: probe_trace_file(Path.join(directory, name), source_kind)

  defp probe_trace_file(path, source_kind) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, size: size} = before} when size > 0 ->
        probe_stable(path, before, &decode_trace(&1, &2, source_kind, before))

      {:ok, %File.Stat{}} ->
        %{present: :malformed}

      {:error, _reason} ->
        %{present: :unstable}
    end
  end

  # Reads a file's bounded edges and reports them only if the entry's identity
  # is unchanged across the reads. One recheck, then isolation: the catalog
  # commits to what it observed, so a row is never assembled from a head and a
  # tail that may belong to different contents.
  defp probe_stable(path, before, decode) do
    case read_edges(path, before.size, stat_identity(before)) do
      {:ok, head, tail} ->
        case File.lstat(path, time: :posix) do
          {:ok, %File.Stat{type: :regular} = later} ->
            if stat_identity(before) == stat_identity(later),
              do: decode.(head, tail),
              else: %{present: :unstable}

          _moved ->
            %{present: :unstable}
        end

      :moved ->
        %{present: :unstable}

      :error ->
        %{present: :malformed}
    end
  end

  # The descriptor, not the path, is what the reads come from, so the descriptor
  # is what must be proven to be the inventoried file: a path can be replaced
  # between the `lstat` and the `open` and restored before the closing `lstat`,
  # which would commit replacement bytes under the original identity. Following
  # `InspectionArtifact.Handle.open/2`, the opened file is `fstat`ed and
  # compared before a single byte is read. The descriptor is deliberately not
  # `:raw`: a raw descriptor is process-local and cannot be `fstat`ed.
  defp read_edges(path, size, expected) do
    case :file.open(path, [:read, :binary]) do
      {:ok, io} ->
        result =
          case opened_identity(io) do
            {:ok, identity} when identity == expected -> read_windows(io, size)
            _replaced -> :moved
          end

        :file.close(io)
        result

      {:error, _reason} ->
        :error
    end
  end

  defp opened_identity(io) do
    case :file.read_file_info(io, time: :posix) do
      {:ok, file_info} -> {:ok, stat_identity(File.Stat.from_record(file_info))}
      {:error, _reason} -> :error
    end
  end

  defp read_windows(io, size) do
    head_length = min(size, @head_bytes)
    tail_offset = max(size - @tail_bytes, 0)
    tail_length = min(size, @tail_bytes)

    with {:ok, head} <- pread(io, 0, head_length),
         {:ok, tail} <- pread(io, tail_offset, tail_length) do
      {:ok, head, {tail, tail_offset}}
    end
  end

  defp pread(io, offset, length) do
    case :file.pread(io, offset, length) do
      {:ok, bytes} when byte_size(bytes) == length -> {:ok, bytes}
      _short -> :error
    end
  end

  # Both probed events are validated as canonical trace events before anything
  # is projected from them. Projecting from a handful of hand-picked fields let
  # a file the canonical reader rejects — a `run-stopped` missing its
  # `trace_id`, a result hash contradicting its outcome — be published as a
  # complete, admissible run. The rule lives in `TraceEventValidation`, which
  # already owns per-event shape, run/trace identity agreement, sequence
  # ordering, and run lifecycle; the probe hands it exactly the events the row
  # is built from, so the check stays bounded to two events.
  defp decode_trace(head, {tail_bytes, tail_offset}, source_kind, stat) do
    observed = %{
      identity: stat_identity(stat),
      commitment: :crypto.hash(:sha256, [head, tail_bytes])
    }

    with {:ok, head_line} <- first_line(head),
         {:ok, started} <- decode_event(head_line),
         %{"type" => "run-started"} <- started,
         {:ok, stopped} <- decode_stopped(tail_bytes, tail_offset, started),
         :ok <- canonical_events(started, stopped) do
      Map.merge(observed, projected_trace(started, stopped, source_kind, stat))
    else
      _invalid -> Map.put(observed, :present, :malformed)
    end
  end

  # A schema version this build does not support is a state the row reports
  # together with the version it declares, not a file the catalog calls corrupt.
  # Every other validation failure is a refusal, and the row is isolated with
  # nothing projected from it.
  defp canonical_events(started, stopped) do
    case TraceEventValidation.validate(Enum.reject([started, stopped], &is_nil/1)) do
      :ok -> :ok
      {:error, :unsupported_version} -> :ok
      {:error, _malformed} -> :error
    end
  end

  defp projected_trace(started, stopped, source_kind, stat) do
    head = project_started(started)

    if head do
      %{
        present: :probed,
        source_kind: source_kind,
        bytes: stat.size,
        head: head,
        tail: project_stopped(stopped)
      }
    else
      %{present: :malformed}
    end
  end

  defp first_line(bytes) do
    case :binary.split(bytes, "\n") do
      [line, _rest] -> {:ok, line}
      _unterminated -> :error
    end
  end

  # The last line the probe may trust is the last one terminated inside the
  # tail window. A window that starts mid-file discards its leading fragment,
  # because those bytes continue a line whose start was never read.
  defp last_complete_line(bytes, tail_offset) do
    candidate =
      if tail_offset > 0 do
        case :binary.split(bytes, "\n") do
          [_partial, rest] -> rest
          _unterminated -> ""
        end
      else
        bytes
      end

    case candidate |> :binary.split("\n", [:global]) |> Enum.reverse() do
      [_trailing | terminated] -> Enum.find(terminated, &(&1 != "")) |> wrap_line()
      [] -> :error
    end
  end

  defp wrap_line(nil), do: :error
  defp wrap_line(line), do: {:ok, line}

  defp project_started(%{"run_id" => run_id, "trace_id" => trace_id} = event) do
    if identifier?(run_id) and identifier?(trace_id) do
      %{
        run_id: run_id,
        trace_id: trace_id,
        schema_version: schema_version(event["schema_version"]),
        timestamp: timestamp(event["timestamp"]),
        labels: labels(event)
      }
    end
  end

  defp project_started(_event), do: nil

  defp project_stopped(nil), do: nil

  defp project_stopped(event) do
    data = event_data(event)

    %{
      timestamp: timestamp(event["timestamp"]),
      status: stringify(data["outcome"]),
      terminal_reason: stringify(data["reason"]),
      result_hash: safe_string(data["result_hash"])
    }
  end

  defp decode_stopped(tail_bytes, tail_offset, started) do
    with {:ok, line} <- last_complete_line(tail_bytes, tail_offset),
         {:ok, event} <- decode_event(line) do
      classify_tail(event, started)
    end
  end

  # A trailing line that is not `run-stopped` means the run never stopped, which
  # is a state the catalog reports rather than a malformed file. A `run-stopped`
  # for another run in this run's file is neither: the two lines disagree about
  # whose file this is, so the entry is refused.
  defp classify_tail(%{"type" => "run-stopped", "run_id" => run_id} = event, started) do
    if run_id == started["run_id"], do: {:ok, event}, else: :error
  end

  defp classify_tail(%{"type" => "run-stopped"}, _started), do: :error
  defp classify_tail(%{"type" => type}, _started) when is_binary(type), do: {:ok, nil}
  defp classify_tail(_event, _started), do: :error

  # A version a row reports is a number or nothing. Anything else is a value
  # the row cannot carry within its byte bound and cannot compare against the
  # supported version, so it reads as absent and the entry is isolated as
  # unsupported rather than published with a version field of unknown shape.
  defp schema_version(value) when is_integer(value) and value >= 0, do: value
  defp schema_version(_value), do: nil

  defp decode_event(line) do
    case Jason.decode(line) do
      {:ok, event} when is_map(event) -> {:ok, event}
      _invalid -> :error
    end
  end

  defp event_data(%{"data" => data}) when is_map(data), do: data
  defp event_data(_event), do: %{}

  defp labels(event) do
    case event_data(event)["labels"] do
      labels when is_map(labels) -> labels
      _absent -> %{}
    end
  end

  # The same claim bound canonical trace admission applies. A row must stay
  # inside the catalog's per-row byte bound, and an identity is one of the
  # fields that bound cannot drop, so an over-long one is refused at the probe
  # rather than carried into a row that would then have to be reduced.
  defp identifier?(value),
    do: is_binary(value) and byte_size(value) in 1..@max_identity_bytes and String.valid?(value)

  # ISO 8601 admits an unbounded fractional-second field, so a parse alone is
  # not a bound: a syntactically valid timestamp can be kilobytes long. A row
  # cannot drop its timestamps when it is reduced to fit, so the bound belongs
  # here, and an over-long one is reported as no timestamp rather than carried.
  defp timestamp(value) when is_binary(value) and byte_size(value) <= @max_timestamp_bytes do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, 0} -> value
      _invalid -> nil
    end
  end

  defp timestamp(_value), do: nil

  defp stringify(value) when is_binary(value), do: safe_string(value)
  defp stringify(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp stringify(_value), do: nil

  defp safe_string(value) when is_binary(value) do
    if String.valid?(value), do: value
  end

  defp safe_string(_value), do: nil

  defp probe_inspection(_directory, nil), do: %{present: :absent}

  defp probe_inspection(directory, name) do
    path = Path.join(directory, name)

    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, size: size} = before} when size >= @sealed_edge_bytes ->
        probe_stable(path, before, &decode_inspection(&1, &2, before))

      {:ok, %File.Stat{}} ->
        %{present: :malformed}

      {:error, _reason} ->
        %{present: :unstable}
    end
  end

  # The commitment is over the exact bytes the row is read from, not over the
  # values decoded out of them. A footer's `artifact_digest` is a stored claim
  # that a metadata-only probe never recomputes, so a rewritten `record_count`
  # leaves that claim — and any commitment built from it — unchanged while the
  # row it produces differs. Every outcome that got bytes commits to them,
  # malformed and foreign-version probes included.
  defp decode_inspection(head, {tail_bytes, _tail_offset}, stat) do
    header = binary_part(head, 0, Format.header_size())

    footer_bytes =
      binary_part(
        tail_bytes,
        byte_size(tail_bytes) - Format.footer_size(),
        Format.footer_size()
      )

    observed = %{
      identity: stat_identity(stat),
      commitment: :crypto.hash(:sha256, [header, footer_bytes])
    }

    with {:ok, header_versions} <- Format.decode_header_versions(header),
         {:ok, footer_versions} <- Format.decode_footer_versions(footer_bytes),
         true <- header_versions == footer_versions do
      Map.merge(observed, inspection_row(header_versions, header, footer_bytes, stat))
    else
      _malformed -> Map.put(observed, :present, :malformed)
    end
  end

  defp inspection_row(versions, header, footer_bytes, stat) do
    if current_versions?(versions) do
      current_inspection_row(versions, header, footer_bytes, stat)
    else
      versions |> Map.put(:present, :versions) |> Map.put(:bytes, stat.size)
    end
  end

  # `decode_header_versions/1` reads the two version fields without committing
  # to a layout, which is what makes a foreign version reportable — but it says
  # nothing about the rest of the current header. Once the versions are this
  # build's, the whole header is validated the way the artifact reader validates
  # it, so a container the reader would reject is never published as admissible.
  defp current_inspection_row(versions, header, footer_bytes, stat) do
    with {:ok, :header} <- Format.decode_header(header),
         {:ok, footer} <- Format.decode_footer(footer_bytes),
         true <- footer.total_bytes == stat.size,
         true <- footer.evidence_offset == Format.header_size(),
         true <-
           footer.evidence_offset + footer.evidence_bytes + Format.footer_size() == stat.size do
      %{
        present: :probed,
        format_version: versions.format_version,
        schema_version: versions.schema_version,
        bytes: stat.size,
        record_count: footer.record_count,
        run_id_sha256: footer.run_id_sha256,
        trace_id_sha256: footer.trace_id_sha256,
        artifact_digest: footer.artifact_digest
      }
    else
      _malformed -> %{present: :malformed}
    end
  end

  defp current_versions?(%{format_version: format_version, schema_version: schema_version}),
    do: format_version == Format.format_version() and schema_version == Format.schema_version()

  defp stat_identity(%File.Stat{
         size: size,
         inode: inode,
         major_device: major,
         minor_device: minor,
         mtime: mtime
       }),
       do: {size, inode, major, minor, mtime}
end
