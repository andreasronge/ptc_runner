defmodule PtcRunner.Kernel.SelectedCanonicalSource do
  @moduledoc """
  Exact canonical-file selection for one or a bounded set of PTC command run
  references.

  Named capture resolves only these candidates, without listing a directory:

  - `<traces>/<run-ref>.jsonl`
  - `<traces>/<run-ref>.private.jsonl`
  - `<inspection>/<run-ref>.ptcins`

  Filenames are routing hints. Embedded run and trace identities remain
  authoritative, and snapshot identity commits to the selector, trace source
  class, exact evidence digests, and correlated trace ID. Whole-directory
  snapshots stay a distinct source variant.
  """

  alias PtcRunner.Kernel.CommandRunRef

  @max_selected_runs 16

  @type trace_source ::
          {:file, binary(), binary()} | {:private_authorized_file, binary(), binary()}

  @type selected_trace :: %{
          required(:path) => binary(),
          required(:run_ref) => binary(),
          required(:source_kind) => :sanitized | :private
        }

  @spec max_selected_runs() :: pos_integer()
  def max_selected_runs, do: @max_selected_runs

  @spec valid_run_ref?(term()) :: boolean()
  def valid_run_ref?(run_ref), do: CommandRunRef.valid?(run_ref)

  @spec validate_run_refs(term()) :: {:ok, [binary()]} | {:error, atom()}
  def validate_run_refs(run_refs) when is_list(run_refs) do
    cond do
      length(run_refs) > @max_selected_runs ->
        {:error, :selected_set_limit_exceeded}

      run_refs == [] or not Enum.all?(run_refs, &CommandRunRef.valid?/1) ->
        {:error, :invalid_run_reference}

      length(run_refs) != MapSet.size(MapSet.new(run_refs)) ->
        {:error, :duplicate_selected_run}

      true ->
        {:ok, Enum.sort(run_refs)}
    end
  end

  def validate_run_refs(_run_refs), do: {:error, :invalid_run_reference}

  @spec resolve_traces(term(), term()) :: {:ok, [selected_trace()]} | {:error, atom()}
  def resolve_traces(directory, run_refs) do
    with {:ok, run_refs} <- validate_run_refs(run_refs),
         {:ok, directory} <- existing_directory(directory) do
      Enum.reduce_while(run_refs, {:ok, []}, fn run_ref, {:ok, selected} ->
        case resolve_trace_in(directory, run_ref) do
          {:ok, source} -> {:cont, {:ok, [selected_trace(source) | selected]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, selected} -> {:ok, Enum.reverse(selected)}
        {:error, _reason} = error -> error
      end
    end
  end

  @spec resolve_inspections(term(), term()) ::
          {:ok, [%{required(:path) => binary(), required(:run_ref) => binary()}]}
          | {:error, atom()}
  def resolve_inspections(directory, run_refs) do
    with {:ok, run_refs} <- validate_run_refs(run_refs),
         {:ok, directory} <- existing_directory(directory) do
      Enum.reduce_while(run_refs, {:ok, []}, fn run_ref, {:ok, selected} ->
        case resolve_inspection_in(directory, run_ref) do
          {:ok, path} -> {:cont, {:ok, [%{path: path, run_ref: run_ref} | selected]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, selected} -> {:ok, Enum.reverse(selected)}
        {:error, _reason} = error -> error
      end
    end
  end

  @spec resolve_trace(term(), term()) :: {:ok, trace_source()} | {:error, atom()}
  def resolve_trace(directory, run_ref) do
    with :ok <- require_run_ref(run_ref),
         {:ok, directory} <- existing_directory(directory) do
      resolve_trace_in(directory, run_ref)
    end
  end

  @spec resolve_inspection(term(), term()) :: {:ok, binary()} | {:error, atom()}
  def resolve_inspection(directory, run_ref) do
    with :ok <- require_run_ref(run_ref),
         {:ok, directory} <- existing_directory(directory) do
      resolve_inspection_in(directory, run_ref)
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

  @spec trace_set_source_id([map()]) :: binary()
  def trace_set_source_id(commitments) when is_list(commitments) do
    digest({:selected_canonical_trace_set, commitments})
  end

  @spec inspection_set_source_id(binary(), [map()]) :: binary()
  def inspection_set_source_id(correlated_digest, commitments)
      when is_binary(correlated_digest) and is_list(commitments) do
    digest({:selected_canonical_inspection_set, correlated_digest, commitments})
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

  defp resolve_trace_in(directory, run_ref) do
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

  defp resolve_inspection_in(directory, run_ref) do
    path = join_candidate(directory, run_ref <> ".ptcins")

    case candidate_status(path) do
      :regular -> {:ok, path}
      :absent -> {:error, :selected_inspection_missing}
      :not_regular -> {:error, :selected_inspection_not_regular}
      :unavailable -> {:error, :source_unavailable}
    end
  end

  defp selected_trace({:file, path, run_ref}),
    do: %{path: path, run_ref: run_ref, source_kind: :sanitized}

  defp selected_trace({:private_authorized_file, path, run_ref}),
    do: %{path: path, run_ref: run_ref, source_kind: :private}

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
