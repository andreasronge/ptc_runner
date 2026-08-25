defmodule PtcRunner.Kernel.SelectedCanonicalSource do
  @moduledoc """
  Exact canonical-file selection for one PTC command run reference.

  Named capture resolves only these candidates, without listing a directory:

  - `<traces>/<run-ref>.jsonl`
  - `<traces>/<run-ref>.private.jsonl`
  - `<inspection>/<run-ref>.inspection.jsonl`

  Filenames are routing hints. Embedded run and trace identities remain
  authoritative, and snapshot identity commits to the selector, trace source
  class, exact evidence digests, and correlated trace ID. Whole-directory
  snapshots stay a distinct source variant.
  """

  alias PtcRunner.Kernel.CommandRunRef

  @type trace_source ::
          {:file, binary(), binary()} | {:private_authorized_file, binary(), binary()}

  @spec valid_run_ref?(term()) :: boolean()
  def valid_run_ref?(run_ref), do: CommandRunRef.valid?(run_ref)

  @spec resolve_trace(term(), term()) :: {:ok, trace_source()} | {:error, atom()}
  def resolve_trace(directory, run_ref) do
    with :ok <- require_run_ref(run_ref),
         {:ok, directory} <- existing_directory(directory) do
      normal = join_candidate(directory, run_ref <> ".jsonl")
      private = join_candidate(directory, run_ref <> ".private.jsonl")

      case {candidate_status(normal), candidate_status(private)} do
        {:regular, :absent} ->
          {:ok, {:file, normal, run_ref}}

        {:absent, :regular} ->
          {:ok, {:private_authorized_file, private, run_ref}}

        {:absent, :absent} ->
          {:error, :selected_trace_missing}

        {left, right} when left != :absent and right != :absent ->
          {:error, :ambiguous_selected_trace}

        {:not_regular, :absent} ->
          {:error, :selected_trace_not_regular}

        {:absent, :not_regular} ->
          {:error, :selected_trace_not_regular}

        _other ->
          {:error, :source_unavailable}
      end
    end
  end

  @spec resolve_inspection(term(), term()) :: {:ok, binary()} | {:error, atom()}
  def resolve_inspection(directory, run_ref) do
    with :ok <- require_run_ref(run_ref),
         {:ok, directory} <- existing_directory(directory) do
      path = join_candidate(directory, run_ref <> ".inspection.jsonl")

      case candidate_status(path) do
        :regular -> {:ok, path}
        :absent -> {:error, :selected_inspection_missing}
        :not_regular -> {:error, :selected_inspection_not_regular}
        :unavailable -> {:error, :source_unavailable}
      end
    end
  end

  @spec prove_trace_events(term(), term()) :: {:ok, binary()} | {:error, atom()}
  def prove_trace_events(events, run_ref) when is_list(events) do
    with :ok <- require_run_ref(run_ref),
         {:ok, declared_run} <- unique_binary(events, "run_id"),
         {:ok, trace_id} <- unique_binary(events, "trace_id"),
         true <- declared_run == run_ref do
      {:ok, trace_id}
    else
      _mismatch -> {:error, :selected_run_mismatch}
    end
  end

  def prove_trace_events(_events, _run_ref), do: {:error, :selected_run_mismatch}

  @spec prove_inspection_records(term(), term()) :: {:ok, binary()} | {:error, atom()}
  def prove_inspection_records([%{"run_id" => run_id, "trace_id" => trace_id} | _rest], run_ref)
      when is_binary(run_id) and is_binary(trace_id) do
    if run_id == run_ref and CommandRunRef.valid?(run_ref),
      do: {:ok, trace_id},
      else: {:error, :selected_run_mismatch}
  end

  def prove_inspection_records(_records, _run_ref), do: {:error, :selected_run_mismatch}

  @spec trace_source_id(binary(), atom(), atom(), binary(), binary()) :: binary()
  def trace_source_id(run_ref, source, source_kind, evidence_digest, trace_id)
      when is_binary(run_ref) and
             source in [:ptc_trace_snapshot, :ptc_private_trace_snapshot] and
             source_kind in [:sanitized, :private] and
             is_binary(evidence_digest) and is_binary(trace_id) do
    digest({:selected_canonical_trace, run_ref, source, source_kind, evidence_digest, trace_id})
  end

  @spec inspection_source_id(binary(), binary(), binary()) :: binary()
  def inspection_source_id(run_ref, evidence_digest, trace_id)
      when is_binary(run_ref) and is_binary(evidence_digest) and is_binary(trace_id) do
    digest({:selected_canonical_inspection, run_ref, evidence_digest, trace_id})
  end

  defp require_run_ref(run_ref) do
    if CommandRunRef.valid?(run_ref), do: :ok, else: {:error, :invalid_run_reference}
  end

  defp existing_directory(directory) when is_binary(directory) and directory != "" do
    expanded = Path.expand(directory)

    case File.lstat(expanded, time: :posix) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, expanded}
      _other -> {:error, :source_unavailable}
    end
  end

  defp existing_directory(_directory), do: {:error, :source_unavailable}

  defp join_candidate(directory, name), do: Path.join(directory, name)

  defp candidate_status(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular}} -> :regular
      {:ok, %File.Stat{}} -> :not_regular
      {:error, :enoent} -> :absent
      {:error, _reason} -> :unavailable
    end
  end

  defp unique_binary(events, key) do
    case events |> Enum.map(& &1[key]) |> Enum.uniq() do
      [value] when is_binary(value) and value != "" -> {:ok, value}
      _other -> :error
    end
  end

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end
end
