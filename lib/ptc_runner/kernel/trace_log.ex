defmodule PtcRunner.Kernel.TraceLog do
  @moduledoc """
  Bounded canonical trace loading, validation, filtering, and pagination.

  A source is an in-memory `PtcRunner.Kernel.EventSink`, one JSONL file, or a
  directory of JSONL files. Explicit files validate one complete aggregate.
  Immutable directory capture instead treats each
  `<run-id>[.private].jsonl` member as one filename-bound run, proves the
  selected namespace and bytes stable, and isolates a damaged connected
  identity component without hiding disjoint healthy runs. Each admitted run
  validates the complete event envelope, schema version, JSON-like data,
  run/trace identity, timestamps, monotonic sequence, and lifecycle.

  Supported query operations are:

  - `:list_runs` — bounded filtered run summaries, including the run-started
    sequence and component-override provenance, ordered by newest start instant
    and then descending run ID;
  - `:get_run` — one run summary by run ID;
  - `:list_turns` — ordered evaluation/capability facts for one run;
  - `:counters` — aggregate counters for filtered runs, including LLM usage by
    alias/revision and by safely published resolved model.

  Pagination cursors are bound to the source and operation. Every source and
  result has an aggregate encoded-and-retained byte ceiling. A requested page
  limit is an upper bound; pagination returns the largest prefix that fits both
  measurements. Normal directory sources exclude the reserved private filename
  suffix; private files require an explicit source.
  Internal immutable capture may use a private authority that admits both
  normal and private trace files while retaining accurate per-run provenance.
  Its `directory_admission_v1` identity commits to every selected raw name,
  content digest, classification, admitted event, provenance claim, and full
  isolation component, but excludes absolute paths, opposite-class names, and
  advisory exclusion counts.

  A direct directory query creates that admission transiently on every call
  under the same entry, file, source, retained, and result ceilings as an
  immutable snapshot. Consequently a direct cursor observes later selected
  evidence as `:source_changed`, while a snapshot cursor stays bound to its
  retained admission. Run-scoped queries distinguish a grant-visible isolated
  claim as `:run_isolated` from an absent or out-of-grant run as `:not_found`.

  The internal trace-snapshot owner uses this module's canonical validation and
  query execution against one immutable directory capture or one exact selected
  canonical file. A snapshot is
  deliberately not another public `t:source/0` variant.
  """

  alias Jason.OrderedObject
  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.LLMBudget
  alias PtcRunner.Kernel.LLMUsageSummary
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.PublicationHandle
  alias PtcRunner.Kernel.QueryCursor
  alias PtcRunner.Kernel.QueryValidation
  alias PtcRunner.Kernel.ResultLimit
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.TraceDirectoryAdmission
  alias PtcRunner.Kernel.TraceEventValidation
  alias PtcRunner.Kernel.TraceIsolationPresentation
  alias PtcRunner.Kernel.TracePublication
  alias PtcRunner.Lisp.RetainedSize

  @default_source_bytes 8_000_000
  @default_retained_bytes 32_000_000
  @default_result_bytes 1_000_000
  @default_capture_directory_entries 4_096
  @default_capture_trace_files 1_024
  @capture_listing_timeout_ms 5_000
  @capture_listing_heap_words 1_000_000
  @direct_capture_timeout_ms 15_000
  @direct_capture_heap_words 10_000_000
  @default_limit 20
  @max_limit 100
  @max_cursor_bytes 1_024
  @max_string_bytes 256
  @append_lock_timeout_ms 30_000
  @append_lock_helper ~S"""
  set -eu
  lock_kind=$1
  lock_executable=$2
  shell=$3
  lock_file=$4
  lock_body='printf "READY\n"; IFS= read -r command; [ "$command" = X ]; printf "DONE\n"'
  case "$lock_kind" in
    lockf) exec "$lock_executable" -k -t 30 "$lock_file" "$shell" -c "$lock_body" ;;
    flock) exec "$lock_executable" -w 30 "$lock_file" "$shell" -c "$lock_body" ;;
    *) exit 1 ;;
  esac
  """
  @bound_publication_helper ~S"""
  set -eu
  final_name=$1
  temporary_name=$2
  byte_count=$3
  marker_name=$4
  umask 077
  trap 'rm -f "$temporary_name" "$marker_name"' EXIT HUP INT TERM
  : > "$marker_name"
  printf 'READY\n'
  command=$(dd bs=1 count=1 2>/dev/null)
  [ "$command" = W ]
  head -c "$byte_count" > "$temporary_name"
  printf 'DATA\n'
  sentinel=$(dd bs=1 count=1 2>/dev/null)
  [ "$sentinel" = X ]
  sync
  if ln "$temporary_name" "$final_name" 2>/dev/null; then
    :
  elif cmp -s "$temporary_name" "$final_name"; then
    :
  else
    exit 1
  fi
  sync
  rm -f "$temporary_name" "$marker_name"
  trap - EXIT HUP INT TERM
  sync
  """

  @enforce_keys [
    :source,
    :source_kind,
    :max_source_bytes,
    :max_retained_bytes,
    :max_result_bytes,
    :max_directory_entries,
    :max_trace_files
  ]
  defstruct @enforce_keys

  @type source :: EventSink.t() | {:file, binary()} | {:directory, binary()}
  @type t :: %__MODULE__{
          source: source(),
          source_kind: :sanitized | :private,
          max_source_bytes: pos_integer(),
          max_retained_bytes: pos_integer(),
          max_result_bytes: pos_integer(),
          max_directory_entries: pos_integer(),
          max_trace_files: pos_integer()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_trace_log}
  @doc """
  Constructs a query boundary from required `:source` and optional positive
  `:max_source_bytes` and `:max_result_bytes` limits. Directory sources also
  accept `:max_retained_bytes`, `:max_directory_entries`, and
  `:max_trace_files`; all five directory limits may be lowered but never raised
  above the canonical directory-query ceilings.
  """
  def new(opts) when is_list(opts) do
    with {:ok, source, source_kind} <- validate_source(Keyword.get(opts, :source)),
         {:ok, limits} <- trace_log_limits(source, opts) do
      {:ok,
       %__MODULE__{
         source: source,
         source_kind: source_kind,
         max_source_bytes: limits.max_source_bytes,
         max_retained_bytes: limits.max_retained_bytes,
         max_result_bytes: limits.max_result_bytes,
         max_directory_entries: limits.max_directory_entries,
         max_trace_files: limits.max_trace_files
       }}
    else
      _ -> {:error, :invalid_trace_log}
    end
  end

  def new(_opts), do: {:error, :invalid_trace_log}

  defp trace_log_limits({:directory, _path}, opts) do
    allowed = [
      :source,
      :max_source_bytes,
      :max_retained_bytes,
      :max_result_bytes,
      :max_directory_entries,
      :max_trace_files
    ]

    with true <- Keyword.keys(opts) -- allowed == [],
         {:ok, max_source_bytes} <-
           bounded_limit(opts, :max_source_bytes, @default_source_bytes),
         {:ok, max_retained_bytes} <-
           bounded_limit(opts, :max_retained_bytes, @default_retained_bytes),
         {:ok, max_result_bytes} <-
           bounded_limit(opts, :max_result_bytes, @default_result_bytes),
         {:ok, max_directory_entries} <-
           bounded_limit(opts, :max_directory_entries, @default_capture_directory_entries),
         {:ok, max_trace_files} <-
           bounded_limit(opts, :max_trace_files, @default_capture_trace_files) do
      {:ok,
       %{
         max_source_bytes: max_source_bytes,
         max_retained_bytes: max_retained_bytes,
         max_result_bytes: max_result_bytes,
         max_directory_entries: max_directory_entries,
         max_trace_files: max_trace_files
       }}
    else
      _invalid -> {:error, :invalid_trace_log}
    end
  end

  defp trace_log_limits(_source, opts) do
    with true <- Keyword.keys(opts) -- [:source, :max_source_bytes, :max_result_bytes] == [],
         {:ok, max_source_bytes} <- positive_limit(opts, :max_source_bytes, @default_source_bytes),
         {:ok, max_result_bytes} <- positive_limit(opts, :max_result_bytes, @default_result_bytes) do
      {:ok,
       %{
         max_source_bytes: max_source_bytes,
         max_retained_bytes: @default_retained_bytes,
         max_result_bytes: max_result_bytes,
         max_directory_entries: @default_capture_directory_entries,
         max_trace_files: @default_capture_trace_files
       }}
    else
      _invalid -> {:error, :invalid_trace_log}
    end
  end

  defp bounded_limit(opts, key, maximum) do
    case Keyword.get(opts, key, maximum) do
      value when is_integer(value) and value in 1..maximum//1 -> {:ok, value}
      _invalid -> {:error, :invalid_trace_log}
    end
  end

  defp positive_limit(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _invalid -> {:error, :invalid_trace_log}
    end
  end

  @spec query(t(), :list_runs | :get_run | :list_turns | :counters, map()) ::
          {:ok, map()} | {:error, atom()}
  @doc "Executes one validated, source-scoped bounded trace query."
  def query(%__MODULE__{} = trace_log, operation, arguments)
      when operation in [:list_runs, :get_run, :list_turns, :counters] and is_map(arguments) do
    with {:ok, events, source_id, source_kind, source_metadata, known_isolated_run_ids} <-
           load(trace_log) do
      result_metadata =
        operation
        |> source_presence_metadata(source_metadata)
        |> reserve_snapshot_hash(trace_log.source, source_id)

      operation
      |> execute(
        events,
        source_id,
        arguments,
        trace_log.max_result_bytes,
        source_kind,
        result_metadata
      )
      |> maybe_run_isolated(operation, arguments, known_isolated_run_ids)
      |> strip_reserved_snapshot_hash(trace_log.source)
    end
  end

  def query(_trace_log, _operation, _arguments), do: {:error, :invalid_query}

  defp reserve_snapshot_hash(metadata, {:directory, _path}, source_id),
    do: Map.put(metadata, "snapshot_hash", SafeMetadata.fingerprint(source_id))

  defp reserve_snapshot_hash(metadata, _source, _source_id), do: metadata

  defp strip_reserved_snapshot_hash({:ok, result}, {:directory, _path}),
    do: {:ok, Map.delete(result, "snapshot_hash")}

  defp strip_reserved_snapshot_hash(result, _source), do: result

  defp maybe_run_isolated(
         {:error, :not_found},
         operation,
         %{"run_id" => run_id},
         known_isolated_run_ids
       )
       when operation in [:get_run, :list_turns] and is_binary(run_id) do
    if MapSet.member?(known_isolated_run_ids, run_id),
      do: {:error, :run_isolated},
      else: {:error, :not_found}
  end

  defp maybe_run_isolated(result, _operation, _arguments, _known_isolated_run_ids), do: result

  @doc false
  @spec query_loaded(
          [map()],
          binary(),
          :list_runs | :get_run | :list_turns | :counters,
          map(),
          pos_integer(),
          :sanitized | :private | %{binary() => :sanitized | :private},
          map(),
          MapSet.t(binary())
        ) :: {:ok, map()} | {:error, atom()}
  def query_loaded(
        events,
        source_id,
        operation,
        arguments,
        max_result_bytes,
        source_kind,
        metadata \\ %{},
        known_isolated_run_ids \\ MapSet.new()
      )

  def query_loaded(
        events,
        source_id,
        operation,
        arguments,
        max_result_bytes,
        source_kind,
        metadata,
        known_isolated_run_ids
      )
      when is_list(events) and is_binary(source_id) and
             operation in [:list_runs, :get_run, :list_turns, :counters] and is_map(arguments) and
             is_integer(max_result_bytes) and max_result_bytes > 0 and
             (source_kind in [:sanitized, :private] or is_map(source_kind)) and is_map(metadata) and
             is_struct(known_isolated_run_ids, MapSet) do
    if valid_query_source_kind?(events, source_kind) do
      operation
      |> execute(events, source_id, arguments, max_result_bytes, source_kind, metadata)
      |> maybe_run_isolated(operation, arguments, known_isolated_run_ids)
    else
      {:error, :invalid_query}
    end
  end

  def query_loaded(
        _events,
        _source_id,
        _operation,
        _arguments,
        _max_result_bytes,
        _source_kind,
        _metadata,
        _known_isolated_run_ids
      ),
      do: {:error, :invalid_query}

  @doc false
  @spec source_presence_metadata(atom(), map()) :: map()
  # Only the two operations that answer "what does this source hold" carry the
  # exclusion count. A run-scoped answer would attach it to a single run,
  # where it would state nothing true about that run.
  def source_presence_metadata(operation, metadata)
      when operation in [:list_runs, :counters] and is_map(metadata),
      do: metadata

  def source_presence_metadata(_operation, _metadata), do: %{}

  @doc false
  @spec directory_source_metadata(map()) :: map()
  def directory_source_metadata(%{
        excluded_trace_files: excluded,
        isolated_components: components,
        known_isolated_run_ids: known_run_ids
      }) do
    Map.merge(excluded, TraceIsolationPresentation.metadata(components, known_run_ids))
  end

  def directory_source_metadata(%{excluded_trace_files: excluded}), do: excluded

  @doc false
  @spec compile_analysis([map()], :sanitized | :private | map()) :: map()
  def compile_analysis(events, source_kind) when is_list(events) do
    summaries = runs(events, source_kind)
    summaries_by_id = Map.new(summaries, &{&1["run_id"], &1})

    facts =
      events
      |> Enum.group_by(& &1["run_id"])
      |> Map.new(fn {run_id, run_events} ->
        summary = Map.fetch!(summaries_by_id, run_id)

        expected_model_exchanges =
          run_events
          |> Enum.filter(fn event ->
            event["type"] == "capability-started" and
              stringify(event_data(event, "environment")) == "workflow" and
              event_data(event, "name") == "llm-request"
          end)
          |> Enum.map(&event_data(&1, "capability_id"))
          |> Enum.filter(&is_binary/1)
          |> Enum.uniq()
          |> Enum.sort()

        parent_evaluation_ids =
          run_events
          |> Enum.filter(&(&1["type"] == "evaluation-started"))
          |> Map.new(fn event ->
            {event_data(event, "evaluation_id"), event_data(event, "parent_evaluation_id")}
          end)
          |> Map.reject(fn {evaluation_id, parent_evaluation_id} ->
            not is_binary(evaluation_id) or not is_binary(parent_evaluation_id)
          end)

        evaluation_statuses =
          run_events
          |> Enum.filter(&(&1["type"] == "evaluation-stopped"))
          |> Map.new(fn event ->
            {event_data(event, "evaluation_id"), stringify(event_data(event, "status"))}
          end)
          |> Map.reject(fn {evaluation_id, status} ->
            not is_binary(evaluation_id) or not is_binary(status)
          end)

        capabilities =
          run_events
          |> Enum.filter(&(&1["type"] == "capability-started"))
          |> Map.new(fn event ->
            {event_data(event, "capability_id"),
             %{
               "environment" => stringify(event_data(event, "environment")),
               "mission_name" => event_data(event, "mission_name"),
               "name" => event_data(event, "name")
             }}
          end)
          |> Map.reject(fn {id, _value} -> not is_binary(id) end)

        evaluations =
          run_events
          |> Enum.filter(&(&1["type"] == "evaluation-started"))
          |> Map.new(fn event ->
            {event_data(event, "evaluation_id"),
             %{
               "environment" => stringify(event_data(event, "environment")),
               "mission_name" => event_data(event, "mission_name"),
               "source_hash" => event_data(event, "source_hash"),
               "source_bytes" => event_data(event, "source_bytes")
             }}
          end)
          |> Map.reject(fn {id, _value} -> not is_binary(id) end)

        {run_id,
         %{
           "trace_id" => summary["trace_id"],
           "capabilities" => capabilities,
           "evaluations" => evaluations,
           "dropped_event_counts" => inspection_dropped_counts(run_events),
           "terminal_result" => inspection_terminal_result(run_events),
           "expected_model_exchange_ids" => expected_model_exchanges,
           "evaluation_statuses" => evaluation_statuses,
           "parent_evaluation_ids" => parent_evaluation_ids,
           "workflow_prelude" => summary["workflow_prelude"],
           "missions" => summary["missions"],
           "terminal?" => Enum.any?(run_events, &(&1["type"] == "run-stopped")),
           "events_dropped?" => Enum.any?(run_events, &(&1["type"] == "events-dropped"))
         }}
      end)

    %{
      runs: summaries,
      runs_by_id: summaries_by_id,
      facts_by_run_id: facts
    }
  end

  defp inspection_dropped_counts(events) do
    marker = Enum.find(events, &(&1["type"] == "events-dropped"))
    terminal = Enum.find(events, &(&1["type"] == "run-stopped"))
    marker_counts = event_data(marker, "counts")
    terminal_counts = get_in(terminal || %{}, ["data", "usage", "events_dropped"])

    if is_map(marker_counts) and marker_counts == terminal_counts,
      do: marker_counts,
      else: %{}
  end

  defp inspection_terminal_result(events) do
    case Enum.filter(events, &(&1["type"] == "run-stopped")) do
      [terminal] ->
        %{
          "outcome" => stringify(event_data(terminal, "outcome")),
          "result_hash" => event_data(terminal, "result_hash")
        }

      _other ->
        nil
    end
  end

  defp valid_query_source_kind?(_events, source_kind)
       when source_kind in [:sanitized, :private],
       do: true

  defp valid_query_source_kind?(events, run_sources) when is_map(run_sources) do
    run_ids = events |> MapSet.new(& &1["run_id"]) |> MapSet.to_list() |> Enum.sort()

    Enum.sort(Map.keys(run_sources)) == run_ids and
      Enum.all?(run_sources, fn {run_id, source_kind} ->
        is_binary(run_id) and source_kind in [:sanitized, :private]
      end)
  end

  @doc false
  @spec capture_directory(binary(), keyword()) ::
          {:ok,
           %{
             events: [map()],
             run_sources: %{binary() => :sanitized | :private},
             source_id: binary(),
             source_bytes: non_neg_integer(),
             file_count: non_neg_integer(),
             excluded_trace_files: %{optional(binary()) => pos_integer()}
           }}
          | {:error, atom()}
  def capture_directory(directory, opts \\ [])

  def capture_directory(directory, opts) when is_binary(directory) and is_list(opts) do
    with true <-
           Keyword.keys(opts) --
             [
               :max_source_bytes,
               :max_directory_entries,
               :max_trace_files,
               :source_kind,
               :include_sanitized,
               :capture_hook,
               :listing_hook
             ] == [],
         true <- String.valid?(directory),
         max_source_bytes when max_source_bytes in 1..@default_source_bytes <-
           Keyword.get(opts, :max_source_bytes, @default_source_bytes),
         max_directory_entries
         when max_directory_entries in 1..@default_capture_directory_entries <-
           Keyword.get(
             opts,
             :max_directory_entries,
             @default_capture_directory_entries
           ),
         max_trace_files when max_trace_files in 1..@default_capture_trace_files <-
           Keyword.get(opts, :max_trace_files, @default_capture_trace_files),
         source_kind when source_kind in [:sanitized, :private] <-
           Keyword.get(opts, :source_kind, :sanitized),
         include_sanitized when is_boolean(include_sanitized) <-
           Keyword.get(opts, :include_sanitized, source_kind == :private),
         capture_hook when is_nil(capture_hook) or is_function(capture_hook, 0) <-
           Keyword.get(opts, :capture_hook),
         listing_hook when is_nil(listing_hook) or is_function(listing_hook, 0) <-
           Keyword.get(opts, :listing_hook),
         {:ok, capture} <-
           capture_directory_files(
             Path.expand(directory),
             source_kind,
             max_source_bytes,
             max_directory_entries,
             max_trace_files,
             include_sanitized,
             capture_hook,
             listing_hook
           ) do
      {:ok, capture}
    else
      false -> {:error, :invalid_trace_log}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_trace_log}
    end
  rescue
    _exception -> {:error, :source_unavailable}
  end

  def capture_directory(_directory, _opts), do: {:error, :invalid_trace_log}

  @doc false
  @spec capture_file(binary(), keyword()) ::
          {:ok,
           %{
             events: [map()],
             run_sources: %{binary() => :sanitized | :private},
             source_id: binary(),
             source_bytes: non_neg_integer(),
             file_count: 1,
             excluded_trace_files: %{optional(binary()) => pos_integer()}
           }}
          | {:error, atom()}
  def capture_file(path, opts \\ [])

  def capture_file(path, opts) when is_binary(path) and is_list(opts) do
    with true <-
           Keyword.keys(opts) -- [:max_source_bytes, :source_kind, :capture_hook] == [],
         true <- String.valid?(path),
         max_source_bytes when max_source_bytes in 1..@default_source_bytes <-
           Keyword.get(opts, :max_source_bytes, @default_source_bytes),
         source_kind when source_kind in [:sanitized, :private] <-
           Keyword.get(opts, :source_kind, :sanitized),
         capture_hook when is_nil(capture_hook) or is_function(capture_hook, 0) <-
           Keyword.get(opts, :capture_hook),
         path = Path.expand(path),
         {:ok, before_inventory} <- file_inventory(path, source_kind) do
      capture_inventory(
        Path.dirname(path),
        before_inventory,
        max_source_bytes,
        capture_hook,
        fn -> changed_file_inventory(path, source_kind) end
      )
    else
      false -> {:error, :invalid_trace_log}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_trace_log}
    end
  rescue
    _exception -> {:error, :source_unavailable}
  end

  def capture_file(_path, _opts), do: {:error, :invalid_trace_log}

  @doc false
  @spec capture_selected([map()], keyword()) :: {:ok, map()} | {:error, atom()}
  def capture_selected(selected, opts \\ [])

  def capture_selected(selected, opts) when is_list(selected) and is_list(opts) do
    with true <- Keyword.keys(opts) -- [:max_source_bytes, :capture_hook] == [],
         max_source_bytes when max_source_bytes in 1..@default_source_bytes <-
           Keyword.get(opts, :max_source_bytes, @default_source_bytes),
         capture_hook when is_nil(capture_hook) or is_function(capture_hook, 0) <-
           Keyword.get(opts, :capture_hook),
         {:ok, directory, before_inventory} <- selected_inventory(selected) do
      capture_directory_inventory(
        directory,
        before_inventory,
        max_source_bytes,
        capture_hook,
        fn -> changed_selected_inventory(selected) end,
        :selected_private_authorized
      )
    else
      false -> {:error, :invalid_trace_log}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_trace_log}
    end
  rescue
    _exception -> {:error, :source_unavailable}
  end

  def capture_selected(_selected, _opts), do: {:error, :invalid_trace_log}

  @doc """
  Appends canonical events to one admin-selected JSONL file under a total byte
  cap. `private: true` requires safe parent ancestry and a mode-`0600` file,
  owned by the current process authority or root, creating a missing file
  privately before publication. The permission-checked descriptor is retained
  through validation and append so pathname replacement cannot redirect private
  bytes. One OS-released advisory lease keyed by the parent-directory/name
  identity remains held across first-file creation. A nested device/inode lease
  serializes hard-link aliases. The fixed path-then-inode acquisition order
  applies across BEAM processes and separate local runtimes.
  """
  @spec append_jsonl(binary(), [map()], keyword()) :: :ok | {:error, atom()}
  def append_jsonl(path, events, opts \\ [])

  def append_jsonl(path, events, opts)
      when is_binary(path) and is_list(events) and is_list(opts) do
    with true <- Keyword.keys(opts) -- [:max_source_bytes, :private, :append_hook] == [],
         max_bytes when is_integer(max_bytes) and max_bytes > 0 <-
           Keyword.get(opts, :max_source_bytes, @default_source_bytes),
         private? when is_boolean(private?) <- Keyword.get(opts, :private, false),
         append_hook when is_nil(append_hook) or is_function(append_hook, 1) <-
           Keyword.get(opts, :append_hook),
         :ok <- validate_append_path(path, private?),
         {:ok, path} <- PrivateDirectory.anchor(path) do
      :global.trans({{__MODULE__, {:append, path}}, self()}, fn ->
        with_append_lock(path, fn ->
          append_locked(path, normalize(events), max_bytes, private?, append_hook)
        end)
      end)
    else
      _ -> {:error, :invalid_trace_log}
    end
  end

  def append_jsonl(_path, _events, _opts), do: {:error, :invalid_trace_log}

  @doc false
  @spec validate_append_path(term(), term()) :: :ok | {:error, atom()}
  def validate_append_path(path, private?)
      when is_binary(path) and is_boolean(private?) do
    cond do
      not String.valid?(path) ->
        {:error, :invalid_trace_path}

      not String.ends_with?(path, ".jsonl") or inspection_path?(path) ->
        {:error, :invalid_trace_path}

      private? and not private_path?(path) ->
        {:error, :private_trace_requires_private_suffix}

      not private? and private_path?(path) ->
        {:error, :normal_trace_requires_normal_suffix}

      true ->
        :ok
    end
  end

  def validate_append_path(_path, _private?), do: {:error, :invalid_trace_path}

  @doc false
  @spec preflight_destination(term(), term()) :: :ok | {:error, atom()}
  def preflight_destination(path, private?)
      when is_binary(path) and is_boolean(private?) do
    with :ok <- validate_append_path(path, private?),
         {:ok, path} <- PrivateDirectory.anchor(path),
         :ok <- preflight_trace_destination(path, private?) do
      :ok
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
    end
  end

  def preflight_destination(_path, _private?), do: {:error, :invalid_trace_path}

  @doc false
  @spec append_lock_identity(binary()) :: {:ok, term()} | {:error, :source_unavailable}
  def append_lock_identity(path) when is_binary(path) do
    with {:ok, path} <- PrivateDirectory.anchor(path),
         do: append_path_lock_scope(path)
  end

  def append_lock_identity(_path), do: {:error, :source_unavailable}

  @doc false
  @spec append_reservation_path(binary()) :: {:ok, binary()} | {:error, :source_unavailable}
  def append_reservation_path(path) when is_binary(path) do
    with {:ok, path} <- PrivateDirectory.anchor(path),
         {:ok, scope} <- append_path_lock_scope(path),
         {:ok, lock_root} <- append_lock_root() do
      {:ok, Path.join(lock_root, "reservation-" <> append_lock_name(scope))}
    else
      _ -> {:error, :source_unavailable}
    end
  end

  def append_reservation_path(_path), do: {:error, :source_unavailable}

  @doc false
  @spec with_append_authority_lock(binary(), (-> result)) :: result when result: term()
  def with_append_authority_lock(path, callback)
      when is_binary(path) and is_function(callback, 0) do
    case PrivateDirectory.anchor(path) do
      {:ok, path} ->
        :global.trans({{__MODULE__, {:append, path}}, self()}, fn ->
          with_append_authority_lock_at(path, callback)
        end)

      _other ->
        {:error, :source_unavailable}
    end
  end

  def with_append_authority_lock(_path, _callback), do: {:error, :source_unavailable}

  defp with_append_authority_lock_at(path, callback) do
    with_append_lock(path, fn ->
      case File.lstat(path, time: :posix) do
        {:ok, %File.Stat{type: :regular}} ->
          with_inode_append_lock(path, fn _locked_stat -> callback.() end)

        {:error, :enoent} ->
          callback.()

        _other ->
          {:error, :source_unavailable}
      end
    end)
  end

  defp with_append_lock(path, callback, attempts \\ 3)

  defp with_append_lock(_path, _callback, 0), do: {:error, :source_unavailable}

  defp with_append_lock(path, callback, attempts) do
    with {:ok, scope} <- append_path_lock_scope(path),
         {:ok, port} <- start_append_lock(scope) do
      result =
        try do
          case append_path_lock_scope(path) do
            {:ok, ^scope} -> callback.()
            _changed -> :retry_append_lock
          end
        after
          release_append_lock(port)
        end

      if result == :retry_append_lock,
        do: with_append_lock(path, callback, attempts - 1),
        else: result
    else
      _ -> {:error, :source_unavailable}
    end
  end

  defp start_append_lock(scope) do
    with {:ok, lock_root} <- append_lock_root(),
         {:ok, shell, lock_kind, lock_executable} <- append_lock_executables(),
         lock_file = Path.join(lock_root, append_lock_name(scope)),
         port <-
           Port.open(
             {:spawn_executable, shell},
             [
               :binary,
               :exit_status,
               :use_stdio,
               :stderr_to_stdout,
               {:line, 64},
               args: [
                 "-c",
                 @append_lock_helper,
                 "ptc-trace-append-lock",
                 Atom.to_string(lock_kind),
                 lock_executable,
                 shell,
                 lock_file
               ]
             ]
           ),
         :ok <- await_append_lock(port) do
      {:ok, port}
    else
      _ -> {:error, :source_unavailable}
    end
  rescue
    _exception -> {:error, :source_unavailable}
  end

  defp append_lock_executables do
    case System.find_executable("sh") do
      shell when is_binary(shell) ->
        cond do
          lockf = System.find_executable("lockf") -> {:ok, shell, :lockf, lockf}
          flock = System.find_executable("flock") -> {:ok, shell, :flock, flock}
          true -> {:error, :source_unavailable}
        end

      nil ->
        {:error, :source_unavailable}
    end
  end

  defp await_append_lock(port) do
    receive do
      {^port, {:data, {:eol, "READY"}}} -> :ok
      {^port, {:data, _diagnostic}} -> await_append_lock(port)
      {^port, {:exit_status, _status}} -> {:error, :source_unavailable}
    after
      @append_lock_timeout_ms ->
        if Port.info(port), do: Port.close(port)
        {:error, :source_unavailable}
    end
  end

  defp release_append_lock(port) do
    if Port.info(port) do
      _ = Port.command(port, "X\n")
      drain_append_lock(port)
    end

    :ok
  rescue
    _exception -> :ok
  end

  defp drain_append_lock(port) do
    receive do
      {^port, {:data, _diagnostic}} -> drain_append_lock(port)
      {^port, {:exit_status, _status}} -> :ok
    after
      2_000 ->
        if Port.info(port), do: Port.close(port)
        drain_closed_append_lock(port)
    end
  end

  defp drain_closed_append_lock(port) do
    receive do
      {^port, {:data, _diagnostic}} -> drain_closed_append_lock(port)
      {^port, {:exit_status, _status}} -> :ok
    after
      100 -> :ok
    end
  end

  defp append_path_lock_scope(path) do
    case File.stat(Path.dirname(path), time: :posix) do
      {:ok,
       %File.Stat{
         type: :directory,
         major_device: major,
         minor_device: minor,
         inode: inode
       }} ->
        name = path |> Path.basename() |> PrivateDirectory.casefold_name()
        {:ok, {:path, major, minor, inode, name}}

      _ ->
        {:error, :source_unavailable}
    end
  end

  defp with_inode_append_lock(path, callback, attempts \\ 3)

  defp with_inode_append_lock(_path, _callback, 0),
    do: {:error, :source_unavailable}

  defp with_inode_append_lock(path, callback, attempts) do
    with {:ok, scope, _stat} <- append_inode_lock_scope(path),
         {:ok, port} <- start_append_lock(scope) do
      result =
        try do
          case append_inode_lock_scope(path) do
            {:ok, ^scope, locked_stat} -> callback.(locked_stat)
            _changed -> :retry_inode_append_lock
          end
        after
          release_append_lock(port)
        end

      if result == :retry_inode_append_lock,
        do: with_inode_append_lock(path, callback, attempts - 1),
        else: result
    else
      _ -> {:error, :source_unavailable}
    end
  end

  defp append_inode_lock_scope(path) do
    case File.lstat(path) do
      {:ok,
       %File.Stat{
         type: :regular,
         major_device: major,
         minor_device: minor,
         inode: inode
       } = stat} ->
        {:ok, {:inode, major, minor, inode}, stat}

      _ ->
        {:error, :source_unavailable}
    end
  end

  defp append_lock_root do
    base = Path.join(System.tmp_dir!(), "ptc-runner-trace-append-locks")

    with {:ok, uid} <- PrivateDirectory.preflight_owner(base),
         root = base <> "-" <> Integer.to_string(uid),
         :ok <- ensure_append_lock_root(root, uid) do
      {:ok, root}
    else
      _error -> {:error, :source_unavailable}
    end
  end

  defp ensure_append_lock_root(root, uid) do
    case validate_append_lock_root(root, uid) do
      :ok ->
        :ok

      {:error, :enoent} ->
        case PrivateDirectory.create(root) do
          :ok -> validate_append_lock_root(root, uid)
          {:error, _reason} -> validate_append_lock_root(root, uid)
        end

      {:error, _reason} ->
        {:error, :source_unavailable}
    end
  end

  defp validate_append_lock_root(root, uid) do
    case File.lstat(root, time: :posix) do
      {:ok, %File.Stat{type: :directory, uid: ^uid, mode: mode}}
      when Bitwise.band(mode, 0o777) == 0o700 ->
        :ok

      {:error, :enoent} ->
        {:error, :enoent}

      _unsafe_or_unavailable ->
        {:error, :source_unavailable}
    end
  end

  defp append_lock_name(scope) do
    digest =
      scope
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "#{digest}.lock"
  end

  @doc false
  @spec publish_jsonl(binary(), [map()], keyword()) :: :ok | {:error, atom()}
  def publish_jsonl(path, events, opts \\ [])

  def publish_jsonl(path, events, opts)
      when is_binary(path) and is_list(events) and is_list(opts) do
    with true <-
           Keyword.keys(opts) -- [:max_source_bytes, :fault_hook, :expected_parent_identity] == [],
         true <- String.valid?(path),
         true <- String.ends_with?(path, ".jsonl") and not reserved_path?(path),
         {:ok, path} <- PrivateDirectory.anchor(path),
         max_bytes when max_bytes in 1..@default_source_bytes <-
           Keyword.get(opts, :max_source_bytes, @default_source_bytes),
         fault_hook when is_nil(fault_hook) or is_function(fault_hook, 1) <-
           Keyword.get(opts, :fault_hook),
         expected_parent_identity = Keyword.get(opts, :expected_parent_identity),
         true <- valid_expected_parent_identity?(expected_parent_identity),
         normalized = normalize(events),
         {:ok, _validated, _source_id} <- validate_loaded(normalized, max_bytes),
         :ok <- publication_fault(fault_hook, :after_validation),
         {:ok, encoded} <- encode_jsonl(normalized, max_bytes),
         :ok <- publication_fault(fault_hook, :after_encoding) do
      publish_encoded(path, encoded, fault_hook, expected_parent_identity)
    else
      false ->
        {:error, :invalid_trace_log}

      {:error, reason} when reason in [:malformed_source, :unsupported_version] ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :trace_persistence_failed}

      _ ->
        {:error, :invalid_trace_log}
    end
  rescue
    _exception -> {:error, :trace_persistence_failed}
  end

  def publish_jsonl(_path, _events, _opts), do: {:error, :invalid_trace_log}

  defp execute(
         :list_runs,
         events,
         source_id,
         arguments,
         max_result_bytes,
         source_kind,
         metadata
       ) do
    with :ok <-
           validate_keys(
             arguments,
             ~w(limit cursor status run_id trace_id tags name bundle model provider from to)
           ),
         :ok <- validate_run_filters(arguments),
         {:ok, page} <- page_options(arguments, source_id, :list_runs) do
      events
      |> runs(source_kind)
      |> filter_runs(arguments)
      |> paginate(page, source_id, max_result_bytes, metadata)
    end
  end

  defp execute(
         :get_run,
         events,
         _source_id,
         %{"run_id" => run_id} = arguments,
         max_result_bytes,
         source_kind,
         result_metadata
       ) do
    with :ok <- validate_keys(arguments, ["run_id"]),
         :ok <- valid_string(run_id),
         metadata when not is_nil(metadata) <-
           Enum.find(runs(events, source_kind), &(&1["run_id"] == run_id)),
         result = Map.merge(metadata, result_metadata),
         :ok <- ResultLimit.validate(result, max_result_bytes) do
      {:ok, result}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp execute(
         :get_run,
         _events,
         _source_id,
         _arguments,
         _max_result_bytes,
         _source_kind,
         _metadata
       ),
       do: {:error, :invalid_query}

  defp execute(
         :list_turns,
         events,
         source_id,
         %{"run_id" => run_id} = arguments,
         max_result_bytes,
         _source_kind,
         metadata
       ) do
    with :ok <-
           validate_keys(
             arguments,
             ~w(run_id limit cursor status evaluation_id parent_evaluation_id capability mission_name)
           ),
         :ok <- valid_string(run_id),
         :ok <- validate_turn_filters(arguments),
         true <- Enum.any?(events, &(&1["run_id"] == run_id)),
         {:ok, page} <- page_options(arguments, source_id, :list_turns) do
      events
      |> Enum.filter(&(&1["run_id"] == run_id and turn_matches?(&1, arguments)))
      |> Enum.sort_by(& &1["sequence"])
      |> paginate(page, source_id, max_result_bytes, metadata)
    else
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp execute(
         :list_turns,
         _events,
         _source_id,
         _arguments,
         _max_result_bytes,
         _source_kind,
         _metadata
       ),
       do: {:error, :invalid_query}

  defp execute(
         :counters,
         events,
         _source_id,
         arguments,
         max_result_bytes,
         source_kind,
         metadata
       ) do
    with :ok <-
           validate_keys(
             arguments,
             ~w(status run_id trace_id tags name bundle model provider from to mission_name)
           ),
         :ok <- validate_run_filters(arguments),
         :ok <- optional_strings(arguments, ["mission_name"]) do
      selected_ids =
        events |> runs(source_kind) |> filter_runs(arguments) |> MapSet.new(& &1["run_id"])

      selected_run_events =
        Enum.filter(events, &MapSet.member?(selected_ids, &1["run_id"]))

      selected =
        Enum.filter(
          selected_run_events,
          &mission_matches?(&1, arguments["mission_name"])
        )

      aggregate = counters(selected, selected_run_events)

      fit_metadata(metadata, max_result_bytes, &Map.merge(aggregate, &1))
    end
  end

  defp append_locked(path, events, max_bytes, true, append_hook),
    do: append_private_locked(path, events, max_bytes, append_hook)

  defp append_locked(path, events, max_bytes, false, append_hook) do
    with :ok <- ensure_trace_file(path),
         :ok <- append_fault(append_hook, :after_file_ready) do
      with_inode_append_lock(path, fn locked_stat ->
        append_regular_locked(path, events, max_bytes, locked_stat)
      end)
    end
  end

  defp append_regular_locked(path, events, max_bytes, locked_stat) do
    with {:ok, current_stat} <- File.lstat(path),
         :ok <- same_file(locked_stat, current_stat),
         {:ok, existing_source} <- read_regular_file(path, max_bytes),
         {:ok, existing_events} <- decode_jsonl(existing_source),
         {:ok, _events, _source_id} <- validate_loaded(existing_events ++ events, max_bytes),
         encoded = Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")),
         true <- byte_size(existing_source) + byte_size(encoded) <= max_bytes,
         :ok <- append_regular_file(path, existing_source, encoded, max_bytes, locked_stat) do
      :ok
    else
      false -> {:error, :source_limit_exceeded}
      {:error, _reason} = error -> error
    end
  rescue
    Jason.EncodeError -> {:error, :malformed_source}
  end

  defp append_private_locked(path, events, max_bytes, append_hook) do
    with {:ok, uid} <- private_parent_identity(path),
         :ok <- ensure_private_trace_file(path, uid, append_hook),
         :ok <- append_fault(append_hook, :after_file_ready) do
      with_inode_append_lock(path, fn locked_stat ->
        append_private_inode_locked(path, events, max_bytes, uid, locked_stat)
      end)
    end
  end

  defp append_private_inode_locked(path, events, max_bytes, uid, locked_stat) do
    with {:ok, device} <- open_private_trace(path, uid, locked_stat) do
      try do
        with {:ok, existing_source} <- read_private_device(device, max_bytes),
             {:ok, existing_events} <- decode_jsonl(existing_source),
             {:ok, _events, _source_id} <- validate_loaded(existing_events ++ events, max_bytes),
             encoded = Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")),
             true <- byte_size(existing_source) + byte_size(encoded) <= max_bytes,
             {:ok, _position} <- :file.position(device, :eof),
             :ok <- :file.write(device, encoded) do
          :ok
        else
          false -> {:error, :source_limit_exceeded}
          {:error, _reason} = error -> error
        end
      after
        :file.close(device)
      end
    end
  rescue
    Jason.EncodeError -> {:error, :malformed_source}
  end

  defp append_fault(nil, _stage), do: :ok
  defp append_fault(hook, stage), do: hook.(stage)

  defp read_private_device(device, max_bytes) do
    case :file.position(device, :bof) do
      {:ok, 0} -> read_device(device, max_bytes)
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp encode_jsonl(events, max_bytes) do
    Enum.reduce_while(events, {:ok, [], 0}, fn event, {:ok, encoded, bytes} ->
      case DeterministicJSON.encode(event) do
        {:ok, line} when bytes + byte_size(line) + 1 <= max_bytes ->
          {:cont, {:ok, ["\n", line | encoded], bytes + byte_size(line) + 1}}

        _ ->
          {:halt, {:error, :source_limit_exceeded}}
      end
    end)
    |> case do
      {:ok, encoded, _bytes} -> {:ok, encoded |> Enum.reverse() |> IO.iodata_to_binary()}
      {:error, _reason} = error -> error
    end
  end

  defp publish_encoded(path, encoded, fault_hook, nil) do
    :global.trans({{__MODULE__, {:publish, path}}, self()}, fn ->
      publish_at_path(path, encoded, fault_hook)
    end)
  end

  defp publish_encoded(path, encoded, fault_hook, expected_parent_identity) do
    :global.trans({{__MODULE__, {:publish, path}}, self()}, fn ->
      publish_bound(path, encoded, fault_hook, expected_parent_identity)
    end)
  end

  defp publish_bound(path, encoded, fault_hook, expected_parent_identity) do
    case start_bound_publisher(path, encoded, expected_parent_identity) do
      {:ok, lease} ->
        try do
          with :ok <- publication_fault(fault_hook, :before_write),
               :ok <- publication_fault(fault_hook, :during_write),
               :ok <- publication_fault(fault_hook, :after_sync),
               true <- Port.command(lease.port, ["W", encoded]),
               :ok <- await_bound_data(lease.port, ""),
               true <- Port.command(lease.port, "X"),
               :ok <- await_bound_publication(lease.port),
               :ok <- publication_fault(fault_hook, :after_publish),
               :ok <- publication_fault(fault_hook, :cleanup) do
            verify_parent_identity(path, expected_parent_identity)
          else
            {:error, _reason} = error -> error
          end
        after
          close_bound_lease(lease)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp start_bound_publisher(path, encoded, expected_parent_identity) do
    with executable when is_binary(executable) <- System.find_executable("sh"),
         parent = Path.dirname(path),
         final_name = Path.basename(path),
         temporary_name =
           ".ptc-tmp-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
         marker_name =
           ".ptc-marker-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
         port <-
           Port.open(
             {:spawn_executable, executable},
             [
               :binary,
               :exit_status,
               :use_stdio,
               :stderr_to_stdout,
               {:cd, parent},
               {:args,
                [
                  "-c",
                  @bound_publication_helper,
                  "--",
                  final_name,
                  temporary_name,
                  Integer.to_string(byte_size(encoded)),
                  marker_name
                ]}
             ]
           ),
         result <-
           await_bound_ready(port, parent, marker_name, expected_parent_identity, "") do
      case result do
        :ok ->
          {:ok,
           %{port: port, parent: parent, temporary_name: temporary_name, marker_name: marker_name}}

        {:error, _reason} = error ->
          close_bound_lease(%{
            port: port,
            parent: parent,
            temporary_name: temporary_name,
            marker_name: marker_name
          })

          error
      end
    else
      nil -> {:error, :trace_persistence_failed}
    end
  rescue
    _exception -> {:error, :trace_persistence_failed}
  catch
    _kind, _reason -> {:error, :trace_persistence_failed}
  end

  defp await_bound_ready(port, parent, marker_name, expected, buffered) do
    receive do
      {^port, {:data, data}} ->
        parse_bound_ready(port, parent, marker_name, expected, buffered <> data)

      {^port, {:exit_status, _status}} ->
        {:error, :trace_persistence_failed}
    after
      5_000 -> {:error, :trace_persistence_failed}
    end
  end

  defp parse_bound_ready(port, parent, marker_name, expected, buffered) do
    case String.split(buffered, "\n", parts: 2) do
      ["READY", _rest] ->
        verify_bound_marker(parent, marker_name, expected)

      [_line, _rest] ->
        {:error, :trace_persistence_failed}

      [_partial] ->
        await_bound_ready(port, parent, marker_name, expected, buffered)
    end
  end

  defp verify_bound_marker(parent, marker_name, expected) do
    marker = Path.join(parent, marker_name)

    with :ok <- verify_parent_identity(marker, expected),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(marker) do
      :ok
    else
      _ -> {:error, :trace_persistence_failed}
    end
  end

  defp await_bound_data(port, buffered) do
    receive do
      {^port, {:data, data}} ->
        case String.split(buffered <> data, "\n", parts: 2) do
          ["DATA", _rest] -> :ok
          [_line, _rest] -> {:error, :trace_persistence_failed}
          [_partial] -> await_bound_data(port, buffered <> data)
        end

      {^port, {:exit_status, _status}} ->
        {:error, :trace_persistence_failed}
    after
      5_000 -> {:error, :trace_persistence_failed}
    end
  end

  defp await_bound_publication(port) do
    receive do
      {^port, {:data, _diagnostic}} -> await_bound_publication(port)
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, _status}} -> {:error, :trace_persistence_failed}
    after
      30_000 -> {:error, :trace_persistence_failed}
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  catch
    :error, :badarg -> :ok
  end

  defp close_bound_lease(lease) do
    abort_bound_publisher(lease.port)
    _ = File.rm(Path.join(lease.parent, lease.temporary_name))
    _ = File.rm(Path.join(lease.parent, lease.marker_name))
    :ok
  end

  defp abort_bound_publisher(port) do
    if Port.info(port) do
      _ = safe_port_command(port, "A")
      await_bound_shutdown(port)
    end

    close_port(port)
  end

  defp safe_port_command(port, data) do
    Port.command(port, data)
  catch
    :error, :badarg -> false
  end

  defp await_bound_shutdown(port) do
    receive do
      {^port, {:data, _diagnostic}} -> await_bound_shutdown(port)
      {^port, {:exit_status, _status}} -> :ok
    after
      5_000 -> :ok
    end
  end

  defp publish_at_path(path, encoded, fault_hook) do
    case read_publication(path, byte_size(encoded), fault_hook) do
      {:ok, ^encoded} -> sync_directory(Path.dirname(path))
      {:ok, _different} -> {:error, :trace_collision}
      {:error, :enoent} -> publish_new(path, encoded, fault_hook)
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_expected_parent_identity?(nil), do: true

  defp valid_expected_parent_identity?({major, minor, inode}),
    do: is_integer(major) and is_integer(minor) and is_integer(inode)

  defp valid_expected_parent_identity?(_identity), do: false

  defp verify_parent_identity(_path, nil), do: :ok

  defp verify_parent_identity(path, expected) do
    case File.stat(Path.dirname(path)) do
      {:ok,
       %File.Stat{
         type: :directory,
         major_device: major,
         minor_device: minor,
         inode: inode
       }}
      when {major, minor, inode} == expected ->
        :ok

      _ ->
        {:error, :trace_persistence_failed}
    end
  end

  defp publish_new(path, encoded, fault_hook) do
    temporary =
      path <> ".ptc-tmp-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    result =
      with :ok <- publication_fault(fault_hook, :before_write),
           {:ok, device} <-
             :file.open(String.to_charlist(temporary), [:write, :binary, :raw, :exclusive]) do
        try do
          with {:ok, file_info} <- :file.read_file_info(device),
               opened = File.Stat.from_record(file_info),
               :ok <- write_publication(device, encoded, fault_hook),
               :ok <- :file.sync(device),
               :ok <- publication_fault(fault_hook, :after_sync),
               :ok <- link_publication(temporary, path, opened, encoded),
               :ok <- sync_directory(Path.dirname(path)),
               :ok <- publication_fault(fault_hook, :after_publish) do
            :ok
          else
            {:error, _reason} = error -> error
          end
        after
          :file.close(device)
        end
      else
        {:error, _reason} = error -> error
      end

    cleanup_result = cleanup_temporary(temporary, fault_hook)

    cleanup_result =
      case cleanup_result do
        :ok -> sync_directory(Path.dirname(path))
        {:error, _reason} = error -> error
      end

    case {result, cleanup_result} do
      {:ok, :ok} -> :ok
      {{:error, reason}, _cleanup} -> {:error, reason}
      {:ok, {:error, reason}} -> {:error, reason}
    end
  end

  defp write_publication(device, encoded, fault_hook) do
    case publication_fault(fault_hook, :during_write) do
      :ok ->
        :file.write(device, encoded)

      {:error, :partial_write} ->
        partial_bytes = div(byte_size(encoded), 2)
        _ = :file.write(device, binary_part(encoded, 0, partial_bytes))
        {:error, :trace_persistence_failed}

      {:error, _reason} = error ->
        error
    end
  end

  defp link_publication(temporary, path, opened, encoded) do
    with {:ok, current} <- File.lstat(temporary),
         :ok <- publication_same_file(opened, current),
         true <- current.type == :regular and current.size == byte_size(encoded) do
      case File.ln(temporary, path) do
        :ok -> verify_linked_publication(path, opened, encoded)
        {:error, :eexist} -> verify_publication(path, encoded)
        {:error, _reason} -> {:error, :trace_persistence_failed}
      end
    else
      _ -> {:error, :trace_collision}
    end
  end

  defp verify_linked_publication(path, opened, encoded) do
    with {:ok, linked} <- File.lstat(path),
         :ok <- publication_same_file(opened, linked),
         {:ok, ^encoded} <- read_publication(path, byte_size(encoded), nil),
         {:ok, current} <- File.lstat(path),
         :ok <- publication_same_file(opened, current) do
      :ok
    else
      _ -> {:error, :trace_collision}
    end
  end

  defp publication_same_file(expected, current) do
    case same_file(expected, current) do
      :ok -> :ok
      {:error, _reason} -> {:error, :trace_collision}
    end
  end

  defp verify_publication(path, encoded) do
    case read_publication(path, byte_size(encoded), nil) do
      {:ok, ^encoded} -> :ok
      {:ok, _different} -> {:error, :trace_collision}
      {:error, _reason} -> {:error, :trace_collision}
    end
  end

  defp sync_directory(directory) do
    case :file.open(String.to_charlist(directory), [:directory, :read, :raw]) do
      {:ok, device} ->
        try do
          case :file.sync(device) do
            :ok -> :ok
            {:error, _reason} -> {:error, :trace_persistence_failed}
          end
        after
          :file.close(device)
        end

      {:error, _reason} ->
        {:error, :trace_persistence_failed}
    end
  end

  defp read_publication(path, max_bytes, fault_hook) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size} = expected} when size <= max_bytes ->
        with :ok <- publication_fault(fault_hook, :before_publication_read),
             {:ok, device} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
          try do
            with {:ok, file_info} <- :file.read_file_info(device),
                 opened = File.Stat.from_record(file_info),
                 :ok <- same_file(expected, opened),
                 true <- opened.type == :regular and opened.size <= max_bytes,
                 {:ok, source} <- bounded_publication_read(device, max_bytes),
                 {:ok, current} <- File.lstat(path),
                 :ok <- same_file(expected, current),
                 true <- current.type == :regular and current.size == opened.size do
              {:ok, source}
            else
              _ -> {:error, :trace_collision}
            end
          after
            :file.close(device)
          end
        else
          {:error, :trace_persistence_failed} = error -> error
          _ -> {:error, :trace_collision}
        end

      {:ok, %File.Stat{}} ->
        {:error, :trace_collision}

      {:error, :enoent} ->
        {:error, :enoent}

      {:error, _reason} ->
        {:error, :trace_persistence_failed}
    end
  end

  defp bounded_publication_read(device, max_bytes) do
    case :file.read(device, max_bytes + 1) do
      {:ok, source} when byte_size(source) <= max_bytes -> {:ok, source}
      :eof -> {:ok, ""}
      _ -> {:error, :trace_collision}
    end
  end

  defp cleanup_temporary(temporary, fault_hook) do
    injected = publication_fault(fault_hook, :cleanup)

    removed =
      case File.rm(temporary) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, _reason} -> {:error, :trace_persistence_failed}
      end

    case {injected, removed} do
      {:ok, :ok} -> :ok
      {{:error, _reason} = error, _removed} -> error
      {:ok, {:error, _reason} = error} -> error
    end
  end

  defp publication_fault(nil, _stage), do: :ok

  defp publication_fault(hook, stage) do
    case hook.(stage) do
      :ok -> :ok
      {:error, :partial_write} = error -> error
      {:error, _reason} -> {:error, :trace_persistence_failed}
      _ -> {:error, :trace_persistence_failed}
    end
  rescue
    _exception -> {:error, :trace_persistence_failed}
  catch
    _kind, _reason -> {:error, :trace_persistence_failed}
  end

  defp ensure_trace_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{}} -> {:error, :malformed_source}
      {:error, :enoent} -> create_trace_file(path)
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp create_trace_file(path) do
    case File.write(path, "", [:exclusive]) do
      :ok ->
        :ok

      {:error, :eexist} ->
        ensure_trace_file(path)

      {:error, _reason} ->
        {:error, :source_unavailable}
    end
  end

  defp preflight_trace_destination(path, private?) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        if private?,
          do: preflight_private_trace(path, stat),
          else: preflight_normal_trace(path)

      {:ok, %File.Stat{}} ->
        {:error, :invalid_trace_path}

      {:error, :enoent} ->
        preflight_missing_trace(path, private?)

      {:error, _reason} ->
        {:error, :trace_destination_unavailable}
    end
  end

  defp preflight_missing_trace(path, private?) do
    case File.lstat(Path.dirname(path)) do
      {:ok, %File.Stat{type: :directory}} ->
        if private?, do: private_creation_parent(path), else: normal_creation_parent(path)

      _missing_or_invalid ->
        {:error, :trace_destination_unavailable}
    end
  end

  defp preflight_normal_trace(path) do
    case PrivateDirectory.preflight_writable_file(path) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, preflight_reason(reason, :source_unavailable)}
    end
  end

  defp normal_creation_parent(path) do
    case PrivateDirectory.preflight_writable_parent(path) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, preflight_reason(reason, :source_unavailable)}
    end
  end

  defp preflight_private_trace(path, %File.Stat{mode: mode, uid: owner}) do
    with {:ok, uid} <- PrivateDirectory.preflight_owner(path),
         true <- owner in [0, uid] and Bitwise.band(mode, 0o777) == 0o600,
         :ok <- PrivateDirectory.preflight_writable_file(path) do
      :ok
    else
      false -> {:error, :trace_destination_unavailable}
      {:error, reason} -> {:error, preflight_reason(reason, :trace_destination_unavailable)}
    end
  end

  # Unlike the normal-trace paths, this one has always collapsed an unavailable
  # parent into :source_unavailable. Only the unsafe split is new here.
  defp private_creation_parent(path) do
    case PrivateDirectory.preflight(path) do
      :ok -> :ok
      {:error, :private_directory_parent_unsafe} -> {:error, :trace_destination_unsafe}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  # An untrusted ancestor — one owned outside this authority, or a
  # group/other-writable directory somewhere on the path -- is operator-fixable
  # and names a specific directory to go look at. A missing `id`/`mkdir` or an
  # unreadable parent is a different problem with a different remedy, so
  # preflight names the untrusted ancestor apart from both. What the remaining
  # faults collapse to still differs by call site, which is why each passes its
  # own fallback. The append path keeps its single closed reason.
  defp preflight_reason(:private_directory_parent_unsafe, _fallback),
    do: :trace_destination_unsafe

  defp preflight_reason(:private_directory_parent_unavailable, _fallback),
    do: :trace_destination_unavailable

  defp preflight_reason(_reason, fallback), do: fallback

  defp private_parent_identity(path) do
    case PrivateDirectory.preflight_owner(path) do
      {:ok, uid} -> {:ok, uid}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp ensure_private_trace_file(path, uid, append_hook) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode, uid: owner}}
      when owner in [0, uid] and Bitwise.band(mode, 0o777) == 0o600 ->
        :ok

      {:ok, %File.Stat{}} ->
        {:error, :source_unavailable}

      {:error, :enoent} ->
        publish_empty_private_trace(path, uid, append_hook)

      {:error, _reason} ->
        {:error, :source_unavailable}
    end
  end

  defp publish_empty_private_trace(path, uid, append_hook) do
    {temporary_directory, temporary} = PrivateDirectory.temporary_sibling(path, "trace")

    case PrivateDirectory.create(temporary_directory) do
      :ok ->
        publish_empty_private_trace_created(
          path,
          uid,
          temporary_directory,
          temporary,
          append_hook
        )

      {:error, _reason} ->
        {:error, :source_unavailable}
    end
  end

  defp publish_empty_private_trace_created(
         path,
         uid,
         temporary_directory,
         temporary,
         append_hook
       ) do
    with {:ok, :ok} <-
           File.open(temporary, [:write, :binary, :exclusive], fn _device ->
             with :ok <- append_fault(append_hook, :before_private_chmod),
                  do: File.chmod(temporary, 0o600)
           end),
         :ok <- File.ln(temporary, path) do
      :ok
    else
      {:error, :eexist} -> ensure_private_trace_file(path, uid, append_hook)
      {:ok, {:error, _reason}} -> {:error, :source_unavailable}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  after
    _ = File.rm(temporary)
    _ = File.rmdir(temporary_directory)
  end

  defp open_private_trace(path, uid, locked_stat) do
    case :file.open(String.to_charlist(path), [:read, :append, :binary, :raw]) do
      {:ok, device} ->
        case validate_open_private_trace(path, device, uid, locked_stat) do
          :ok ->
            {:ok, device}

          {:error, _reason} = error ->
            :file.close(device)
            error
        end

      {:error, _reason} ->
        {:error, :source_unavailable}
    end
  end

  defp validate_open_private_trace(path, device, uid, locked_stat) do
    with {:ok, file_info} <- :file.read_file_info(device, time: :posix),
         opened = File.Stat.from_record(file_info),
         :ok <- same_file(locked_stat, opened),
         true <-
           opened.type == :regular and opened.uid in [0, uid] and
             Bitwise.band(opened.mode, 0o777) == 0o600,
         {:ok, current} <- File.lstat(path, time: :posix),
         true <-
           current.type == :regular and current.uid in [0, uid] and
             Bitwise.band(current.mode, 0o777) == 0o600,
         :ok <- same_file(opened, current) do
      :ok
    else
      _changed_or_invalid -> {:error, :source_unavailable}
    end
  end

  defp append_regular_file(path, existing_source, encoded, max_bytes, locked_stat) do
    with {:ok, %File.Stat{type: :regular} = expected} <- File.lstat(path),
         :ok <- same_file(locked_stat, expected),
         true <- expected.size == byte_size(existing_source),
         {:ok, device} <-
           :file.open(String.to_charlist(path), [:read, :append, :binary, :raw]) do
      try do
        with {:ok, file_info} <- :file.read_file_info(device),
             opened = File.Stat.from_record(file_info),
             :ok <- same_file(expected, opened),
             true <- opened.type == :regular and opened.size == byte_size(existing_source),
             {:ok, 0} <- :file.position(device, :bof),
             {:ok, current_source} <- read_device(device, max_bytes),
             true <- current_source == existing_source,
             true <- byte_size(current_source) + byte_size(encoded) <= max_bytes,
             :ok <- :file.write(device, encoded) do
          :ok
        else
          false -> {:error, :source_changed}
          {:error, _reason} = error -> error
        end
      after
        :file.close(device)
      end
    else
      false -> {:error, :source_changed}
      {:ok, %File.Stat{}} -> {:error, :malformed_source}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp read_device(device, max_bytes) do
    case :file.read(device, max_bytes + 1) do
      {:ok, source} when byte_size(source) <= max_bytes -> {:ok, source}
      :eof -> {:ok, ""}
      {:ok, _source} -> {:error, :source_limit_exceeded}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp validate_source(%EventSink{} = sink) do
    case EventSink.policy(sink) do
      :normal -> {:ok, sink, :sanitized}
      _ -> {:error, :invalid_trace_log}
    end
  catch
    :exit, _reason -> {:error, :invalid_trace_log}
  end

  defp validate_source({:private, %EventSink{} = sink}) do
    case EventSink.policy(sink) do
      :private -> {:ok, sink, :private}
      _ -> {:error, :invalid_trace_log}
    end
  catch
    :exit, _reason -> {:error, :invalid_trace_log}
  end

  defp validate_source({:file, path}) when is_binary(path) do
    case {reserved_path?(path), File.lstat(path)} do
      {true, _stat} ->
        {:error, :invalid_trace_log}

      {false, {:ok, %File.Stat{type: :regular}}} ->
        {:ok, {:file, Path.expand(path)}, :sanitized}

      _ ->
        {:error, :invalid_trace_log}
    end
  end

  defp validate_source({:directory, path}) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, {:directory, Path.expand(path)}, :sanitized}

      _ ->
        {:error, :invalid_trace_log}
    end
  end

  defp validate_source({:private_file, path}) when is_binary(path) do
    case {private_path?(path), File.lstat(path)} do
      {true, {:ok, %File.Stat{type: :regular}}} ->
        {:ok, {:file, Path.expand(path)}, :private}

      _ ->
        {:error, :invalid_trace_log}
    end
  end

  defp validate_source({:private_directory, path}) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, {:directory, Path.expand(path)}, :private}

      _ ->
        {:error, :invalid_trace_log}
    end
  end

  defp validate_source(_source), do: {:error, :invalid_trace_log}

  defp load(%__MODULE__{source: %EventSink{} = sink} = trace_log) do
    sink
    |> EventSink.events()
    |> normalize()
    |> validate_loaded(trace_log.max_source_bytes)
    |> with_source_metadata(trace_log.source_kind, %{})
  catch
    :exit, _reason -> {:error, :source_unavailable}
  end

  defp load(%__MODULE__{source: {:file, path}, max_source_bytes: max_bytes} = trace_log) do
    with {:ok, source} <- read_regular_file(path, max_bytes),
         {:ok, events} <- decode_jsonl(source),
         do:
           events
           |> validate_loaded(max_bytes)
           |> with_source_metadata(trace_log.source_kind, %{})
  end

  defp load(%__MODULE__{source: {:directory, directory}} = trace_log) do
    case BoundedWorker.run(
           fn -> load_directory_admission(directory, trace_log) end,
           timeout_ms: @direct_capture_timeout_ms,
           max_heap_words: @direct_capture_heap_words,
           cancel_with_caller: true
         ) do
      {:ok, result} -> result
      {:error, :heap_exceeded} -> {:error, :source_retained_limit_exceeded}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp load_directory_admission(directory, trace_log) do
    with {:ok, capture} <-
           capture_directory(directory,
             max_source_bytes: trace_log.max_source_bytes,
             max_directory_entries: trace_log.max_directory_entries,
             max_trace_files: trace_log.max_trace_files,
             source_kind: trace_log.source_kind,
             include_sanitized: false
           ),
         {:ok, capture} <- retain_transient_directory(capture, trace_log.max_retained_bytes) do
      {:ok, capture.events, capture.source_id, capture.run_sources,
       directory_source_metadata(capture), capture.known_isolated_run_ids}
    end
  end

  defp with_source_metadata({:ok, events, source_id}, source_kind, metadata),
    do: {:ok, events, source_id, source_kind, metadata, MapSet.new()}

  defp with_source_metadata({:error, _reason} = error, _source_kind, _metadata), do: error

  defp retain_transient_directory(capture, max_retained_bytes) do
    retained_capture = RetainedSize.detach_binaries(capture)

    case RetainedSize.bytes(retained_capture) do
      retained_bytes when is_integer(retained_bytes) and retained_bytes <= max_retained_bytes ->
        {:ok, retained_capture}

      retained_bytes when is_integer(retained_bytes) ->
        {:error, :source_retained_limit_exceeded}

      :oversized ->
        {:error, :source_retained_limit_exceeded}
    end
  end

  # One trace directory holds both sanitized and private artifacts, and one
  # query boundary reads exactly one kind. Staying silent about the other kind
  # made an all-private project answer an empty run listing, so name the files
  # this source kind refused to read. The count is advisory and deliberately
  # outside `source_id`: a concurrent write to the kind this boundary does not
  # read must not invalidate the evidence it does read.
  defp excluded_trace_files(listed, accepted, source_kind) do
    accepted = MapSet.new(accepted)

    case Enum.count(listed, &(trace_file_name?(&1) and not MapSet.member?(accepted, &1))) do
      0 -> %{}
      excluded -> %{exclusion_key(source_kind) => excluded}
    end
  end

  defp exclusion_key(:sanitized), do: "excluded_private_trace_files"
  defp exclusion_key(:private), do: "excluded_sanitized_trace_files"

  defp trace_file_name?(name) do
    TraceDirectoryAdmission.source_kind(name) in [:sanitized, :private]
  end

  defp capture_directory_files(
         directory,
         source_kind,
         max_source_bytes,
         max_directory_entries,
         max_trace_files,
         include_sanitized,
         capture_hook,
         listing_hook
       ) do
    with {:ok, before_inventory, _initial_excluded} <-
           directory_inventory(
             directory,
             source_kind,
             max_directory_entries,
             max_trace_files,
             include_sanitized,
             listing_hook
           ) do
      capture_directory_inventory(
        directory,
        before_inventory,
        max_source_bytes,
        capture_hook,
        fn ->
          changed_inventory(
            directory,
            source_kind,
            max_directory_entries,
            max_trace_files,
            include_sanitized,
            listing_hook
          )
        end,
        directory_grant_class(source_kind, include_sanitized)
      )
    end
  end

  defp directory_grant_class(:sanitized, _include_sanitized), do: :sanitized
  defp directory_grant_class(:private, false), do: :private
  defp directory_grant_class(:private, true), do: :mixed_private_authorized

  defp capture_directory_inventory(
         directory,
         before_inventory,
         max_source_bytes,
         capture_hook,
         refresh_inventory,
         grant_class
       ) do
    with {:ok, captured_sources, source_bytes} <-
           read_directory_inventory(directory, before_inventory.files, max_source_bytes),
         :ok <- run_capture_hook(capture_hook),
         {:ok, after_read_inventory, _after_read_excluded} <- refresh_inventory.(),
         :ok <- same_inventory(before_inventory, after_read_inventory),
         :ok <- verify_directory_sources(directory, after_read_inventory.files, captured_sources),
         {:ok, after_verify_inventory, final_excluded} <- refresh_inventory.(),
         :ok <- same_inventory(after_read_inventory, after_verify_inventory),
         :ok <-
           verify_directory_sources(directory, after_verify_inventory.files, captured_sources),
         {:ok, evidence, source_proofs} <- directory_evidence(captured_sources),
         {:ok, classification} <- TraceDirectoryAdmission.classify(evidence) do
      build_directory_admission(
        grant_class,
        classification,
        source_proofs,
        source_bytes,
        final_excluded
      )
    end
  end

  defp build_directory_admission(
         grant_class,
         classification,
         source_proofs,
         source_bytes,
         excluded_trace_files
       ) do
    events = Enum.flat_map(classification.admitted, & &1.events)

    run_sources =
      Map.new(classification.admitted, fn evidence ->
        [run_id] = evidence.embedded_run_claims
        {run_id, evidence.source_kind}
      end)

    analysis = compile_analysis(events, run_sources)

    identity = %{
      version: :directory_admission_v1,
      grant_class: grant_class,
      sources: directory_identity_sources(source_proofs, classification.components),
      events: events,
      run_sources: run_sources,
      isolated_components: classification.isolated
    }

    admission = %{
      version: :directory_admission_v1,
      grant_class: grant_class,
      events: events,
      run_sources: run_sources,
      analysis: analysis,
      source_id: digest(identity),
      source_bytes: source_bytes,
      file_count: length(source_proofs),
      excluded_trace_files: excluded_trace_files,
      source_proofs: source_proofs,
      components: classification.components,
      isolated_components: classification.isolated,
      known_isolated_run_ids: classification.known_isolated_run_ids
    }

    {:ok, admission}
  end

  defp directory_identity_sources(source_proofs, components) do
    classifications =
      components
      |> Enum.flat_map(& &1.sources)
      |> Map.new(&{&1.raw_name, &1})

    Enum.map(source_proofs, fn proof ->
      evidence = Map.fetch!(classifications, proof.raw_name)

      %{
        raw_name: proof.raw_name,
        source_kind: proof.source_kind,
        byte_length: proof.byte_length,
        content_digest: proof.content_digest,
        status: evidence.status,
        filename_run_claim: evidence.filename_run_claim,
        embedded_run_claims: evidence.embedded_run_claims,
        embedded_trace_claims: evidence.embedded_trace_claims,
        reasons: evidence.reasons
      }
    end)
  end

  defp capture_inventory(
         directory,
         before_inventory,
         max_source_bytes,
         capture_hook,
         refresh_inventory
       ) do
    with true <- is_function(refresh_inventory, 0),
         {:ok, sources, source_bytes} <-
           read_inventory(directory, before_inventory.files, max_source_bytes),
         :ok <- run_capture_hook(capture_hook),
         {:ok, after_read_inventory} <- refresh_inventory.(),
         :ok <- same_inventory(before_inventory, after_read_inventory),
         :ok <- verify_sources(directory, after_read_inventory.files, sources),
         {:ok, after_verify_inventory} <- refresh_inventory.(),
         :ok <- same_inventory(after_read_inventory, after_verify_inventory),
         :ok <- verify_sources(directory, after_verify_inventory.files, sources),
         {:ok, events, run_sources} <- decode_capture_sources(sources),
         {:ok, events, _event_source_id} <- validate_loaded(events, max_source_bytes) do
      source_id = digest({events, run_sources})

      {:ok,
       %{
         events: events,
         run_sources: run_sources,
         source_id: source_id,
         source_bytes: source_bytes,
         file_count: length(after_verify_inventory.files),
         excluded_trace_files: %{}
       }}
    end
  end

  defp file_inventory(path, source_kind) do
    name = Path.basename(path)

    with true <- capture_file_name?(name, source_kind),
         {:ok, %File.Stat{type: :regular} = stat} <- File.lstat(path, time: :posix) do
      {:ok, %{files: [{name, stat_identity(stat)}]}}
    else
      false -> {:error, :invalid_trace_log}
      {:ok, %File.Stat{}} -> {:error, :malformed_source}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp selected_inventory([%{path: first_path} | _rest] = selected) do
    directory = first_path |> Path.expand() |> Path.dirname()

    with true <-
           Enum.all?(selected, fn
             %{path: path, run_ref: run_ref, source_kind: source_kind}
             when is_binary(path) and is_binary(run_ref) and
                    source_kind in [:sanitized, :private] ->
               expanded = Path.expand(path)

               Path.dirname(expanded) == directory and
                 capture_file_name?(Path.basename(expanded), source_kind)

             _invalid ->
               false
           end),
         names <- Enum.map(selected, &Path.basename(&1.path)),
         true <- names == Enum.sort(names) and names == Enum.uniq(names),
         {:ok, files} <- inventory_selected_files(directory, names) do
      {:ok, directory, %{files: files}}
    else
      false -> {:error, :invalid_trace_log}
      {:error, _reason} = error -> error
    end
  end

  defp selected_inventory(_selected), do: {:error, :invalid_trace_log}

  defp changed_selected_inventory(selected) do
    case selected_inventory(selected) do
      {:ok, _directory, inventory} -> {:ok, inventory, %{}}
      {:error, _reason} -> {:error, :source_changed}
    end
  end

  defp inventory_selected_files(directory, names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, files} ->
      case File.lstat(Path.join(directory, name), time: :posix) do
        {:ok, %File.Stat{type: :regular} = stat} ->
          {:cont, {:ok, [{name, stat_identity(stat)} | files]}}

        {:ok, %File.Stat{}} ->
          {:halt, {:error, :selected_trace_not_regular}}

        {:error, _reason} ->
          {:halt, {:error, :source_unavailable}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      {:error, _reason} = error -> error
    end
  end

  defp changed_file_inventory(path, source_kind) do
    case file_inventory(path, source_kind) do
      {:ok, inventory} -> {:ok, inventory}
      {:error, _reason} -> {:error, :source_changed}
    end
  end

  defp directory_inventory(
         directory,
         source_kind,
         max_directory_entries,
         max_trace_files,
         include_sanitized,
         listing_hook
       ) do
    with {:ok, %File.Stat{type: :directory} = directory_stat} <-
           File.lstat(directory, time: :posix),
         {:ok, listed} <- bounded_directory_names(directory, max_directory_entries, listing_hook),
         {:ok, names} <-
           bounded_capture_names(listed, source_kind, include_sanitized, max_trace_files),
         {:ok, files} <- inventory_files(directory, names) do
      {:ok, %{directory: directory_root_identity(directory_stat), files: files},
       excluded_trace_files(listed, names, source_kind)}
    else
      {:ok, %File.Stat{}} -> {:error, :malformed_source}
      {:error, :source_limit_exceeded} = error -> error
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp changed_inventory(
         directory,
         source_kind,
         max_directory_entries,
         max_trace_files,
         include_sanitized,
         listing_hook
       ) do
    case directory_inventory(
           directory,
           source_kind,
           max_directory_entries,
           max_trace_files,
           include_sanitized,
           listing_hook
         ) do
      {:ok, inventory, excluded} -> {:ok, inventory, excluded}
      {:error, :source_limit_exceeded} = error -> error
      {:error, _reason} -> {:error, :source_changed}
    end
  end

  defp bounded_directory_names(directory, max_directory_entries, listing_hook) do
    case BoundedWorker.run(
           fn ->
             if listing_hook, do: listing_hook.()

             with {:ok, names} <- File.ls(directory),
                  true <- length(names) <= max_directory_entries do
               {:ok, names}
             else
               false -> {:error, :source_limit_exceeded}
               {:error, _reason} -> {:error, :source_unavailable}
             end
           end,
           timeout_ms: @capture_listing_timeout_ms,
           max_heap_words: @capture_listing_heap_words,
           cancel_with_caller: true
         ) do
      {:ok, result} -> result
      {:error, :heap_exceeded} -> {:error, :source_limit_exceeded}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp bounded_capture_names(names, source_kind, include_sanitized, max_trace_files) do
    supported = Enum.filter(names, &capture_name?(&1, source_kind, include_sanitized))

    if length(supported) <= max_trace_files,
      do: {:ok, Enum.sort(supported)},
      else: {:error, :source_limit_exceeded}
  end

  defp capture_name?(name, :sanitized, _include_sanitized),
    do: TraceDirectoryAdmission.source_kind(name) == :sanitized

  defp capture_name?(name, :private, true),
    do: TraceDirectoryAdmission.source_kind(name) in [:sanitized, :private]

  defp capture_name?(name, :private, false),
    do: TraceDirectoryAdmission.source_kind(name) == :private

  defp capture_file_name?(name, :sanitized),
    do: Path.basename(name) == name and not reserved_path?(name)

  defp capture_file_name?(name, :private),
    do: Path.basename(name) == name and private_path?(name)

  defp inventory_files(directory, names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, files} ->
      case File.lstat(directory_member_path(directory, name), time: :posix) do
        {:ok, %File.Stat{} = stat} ->
          {:cont, {:ok, [{name, stat_identity(stat)} | files]}}

        {:error, _reason} ->
          {:halt, {:error, :source_unavailable}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      {:error, _reason} = error -> error
    end
  end

  defp read_directory_inventory(directory, files, max_source_bytes) do
    source_bytes =
      Enum.reduce(files, 0, fn
        {_name, %{type: :regular, size: size}}, bytes -> bytes + size
        {_name, _identity}, bytes -> bytes
      end)

    if source_bytes <= max_source_bytes do
      Enum.reduce_while(files, {:ok, []}, fn {name, expected}, {:ok, sources} ->
        case read_directory_member(directory, name, expected) do
          {:ok, status} ->
            source = %{raw_name: name, stat_identity: expected, read_status: status}
            {:cont, {:ok, [source | sources]}}

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, sources} -> {:ok, Enum.reverse(sources), source_bytes}
        {:error, _reason} = error -> error
      end
    else
      {:error, :source_limit_exceeded}
    end
  end

  defp read_directory_member(directory, name, %{type: type} = expected) when type != :regular do
    path = directory_member_path(directory, name)

    with {:ok, %File.Stat{} = current} <- File.lstat(path, time: :posix),
         :ok <- same_stat_identity(expected, stat_identity(current)) do
      {:ok, :not_regular}
    else
      _changed -> {:error, :source_changed}
    end
  end

  defp read_directory_member(directory, name, expected) do
    path = directory_member_path(directory, name)

    with {:ok, %File.Stat{type: :regular} = current} <- File.lstat(path, time: :posix),
         :ok <- same_stat_identity(expected, stat_identity(current)) do
      case :file.open(path, [:read, :binary, :raw]) do
        {:ok, device} ->
          try do
            case read_inventory_device(device, expected) do
              {:ok, source} -> {:ok, {:read, source}}
              {:error, _reason} = error -> error
            end
          after
            :file.close(device)
          end

        {:error, reason} when reason in [:eacces, :eperm] ->
          confirm_unreadable_member(path, expected)

        {:error, _reason} ->
          confirm_open_failure(path, expected)
      end
    else
      {:ok, %File.Stat{}} -> {:error, :source_changed}
      {:error, :source_changed} = error -> error
      {:error, _reason} -> {:error, :source_changed}
    end
  end

  defp confirm_unreadable_member(path, expected) do
    with {:ok, %File.Stat{type: :regular} = current} <- File.lstat(path, time: :posix),
         :ok <- same_stat_identity(expected, stat_identity(current)) do
      {:ok, :unreadable}
    else
      _changed -> {:error, :source_changed}
    end
  end

  defp confirm_open_failure(path, expected) do
    with {:ok, %File.Stat{type: :regular} = current} <- File.lstat(path, time: :posix),
         :ok <- same_stat_identity(expected, stat_identity(current)) do
      {:error, :source_unavailable}
    else
      _changed -> {:error, :source_changed}
    end
  end

  defp verify_directory_sources(directory, files, captured_sources) do
    expected_sources = Map.new(captured_sources, &{&1.raw_name, &1})

    Enum.reduce_while(files, :ok, fn {name, expected}, :ok ->
      captured = Map.fetch!(expected_sources, name)

      case verify_directory_source(directory, name, expected, captured.read_status) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp verify_directory_source(directory, name, expected, expected_status) do
    case read_directory_member(directory, name, expected) do
      {:ok, ^expected_status} -> :ok
      {:ok, _changed_status} -> {:error, :source_changed}
      {:error, :source_unavailable} = error -> error
      {:error, _reason} -> {:error, :source_changed}
    end
  end

  defp directory_evidence(captured_sources) do
    Enum.reduce_while(captured_sources, {:ok, [], []}, fn source, {:ok, evidence, proofs} ->
      with {:ok, status, digest} <- directory_evidence_status(source.read_status),
           source_kind when source_kind in [:sanitized, :private] <-
             TraceDirectoryAdmission.source_kind(source.raw_name),
           {:ok, file_evidence} <-
             TraceDirectoryAdmission.evidence(source.raw_name, source_kind, status) do
        proof = %{
          raw_name: source.raw_name,
          source_kind: source_kind,
          byte_length: source.stat_identity.size,
          content_digest: digest,
          stat_identity: source.stat_identity
        }

        {:cont, {:ok, [file_evidence | evidence], [proof | proofs]}}
      else
        _invalid -> {:halt, {:error, :source_unavailable}}
      end
    end)
    |> case do
      {:ok, evidence, proofs} -> {:ok, Enum.reverse(evidence), Enum.reverse(proofs)}
      {:error, _reason} = error -> error
    end
  end

  defp directory_evidence_status(:not_regular), do: {:ok, :not_regular, nil}
  defp directory_evidence_status(:unreadable), do: {:ok, :unreadable, nil}

  defp directory_evidence_status({:read, source}) do
    digest = :crypto.hash(:sha256, source)

    case decode_jsonl(source) do
      {:ok, events} -> {:ok, {:decoded, events}, digest}
      {:error, :malformed_source} -> {:ok, :malformed_jsonl, digest}
    end
  end

  defp read_inventory(directory, files, max_source_bytes) do
    source_bytes = Enum.reduce(files, 0, fn {_name, stat}, bytes -> bytes + stat.size end)

    if source_bytes <= max_source_bytes do
      Enum.reduce_while(files, {:ok, []}, fn {name, expected}, {:ok, sources} ->
        case read_inventory_file(Path.join(directory, name), expected) do
          {:ok, source} -> {:cont, {:ok, [{name, source} | sources]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, sources} -> {:ok, Enum.reverse(sources), source_bytes}
        {:error, _reason} = error -> error
      end
    else
      {:error, :source_limit_exceeded}
    end
  end

  defp read_inventory_file(path, expected) do
    with {:ok, %File.Stat{type: :regular} = current} <- File.lstat(path, time: :posix),
         :ok <- same_stat_identity(expected, stat_identity(current)),
         {:ok, device} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      try do
        read_inventory_device(device, expected)
      after
        :file.close(device)
      end
    else
      {:ok, %File.Stat{}} -> {:error, :source_changed}
      {:error, :source_changed} = error -> error
      {:error, _reason} -> {:error, :source_changed}
    end
  end

  defp read_inventory_device(device, expected) do
    with {:ok, before_info} <- :file.read_file_info(device, time: :posix),
         :ok <-
           same_stat_identity(expected, before_info |> File.Stat.from_record() |> stat_identity()),
         {:ok, source} <- read_exact_source(device, expected.size),
         {:ok, after_info} <- :file.read_file_info(device, time: :posix),
         :ok <-
           same_stat_identity(expected, after_info |> File.Stat.from_record() |> stat_identity()) do
      {:ok, source}
    else
      {:error, :source_changed} = error -> error
      {:error, _reason} -> {:error, :source_changed}
    end
  end

  defp read_exact_source(device, 0) do
    case :file.read(device, 1) do
      :eof -> {:ok, ""}
      _ -> {:error, :source_changed}
    end
  end

  defp read_exact_source(device, expected_size) do
    case :file.read(device, expected_size + 1) do
      {:ok, source} when byte_size(source) == expected_size -> {:ok, source}
      _ -> {:error, :source_changed}
    end
  end

  defp verify_sources(directory, files, sources) do
    expected_sources = Map.new(sources)

    Enum.reduce_while(files, :ok, fn {name, expected}, :ok ->
      with {:ok, source} <- read_inventory_file(Path.join(directory, name), expected),
           true <- source == Map.fetch!(expected_sources, name) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :source_changed}}
      end
    end)
  end

  defp decode_capture_sources(sources) do
    Enum.reduce_while(sources, {:ok, [], %{}}, fn {name, source},
                                                  {:ok, event_groups, run_sources} ->
      case decode_jsonl(source) do
        {:ok, events} ->
          case put_run_sources(run_sources, events, filename_source_kind(name), name) do
            {:ok, run_sources} -> {:cont, {:ok, [events | event_groups], run_sources}}
            {:error, _reason} = error -> {:halt, error}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, event_groups, run_sources} ->
        source_kinds = Map.new(run_sources, fn {run_id, {kind, _name}} -> {run_id, kind} end)
        {:ok, event_groups |> Enum.reverse() |> List.flatten(), source_kinds}

      {:error, _reason} = error ->
        error
    end
  end

  defp put_run_sources(run_sources, events, source_kind, source_name) do
    Enum.reduce_while(events, {:ok, run_sources}, fn
      %{"run_id" => run_id}, {:ok, sources} ->
        case Map.get(sources, run_id) do
          nil -> {:cont, {:ok, Map.put(sources, run_id, {source_kind, source_name})}}
          {^source_kind, ^source_name} -> {:cont, {:ok, sources}}
          _conflicting -> {:halt, {:error, :malformed_source}}
        end

      _invalid_event, _acc ->
        {:halt, {:error, :malformed_source}}
    end)
  end

  defp filename_source_kind(name), do: if(private_path?(name), do: :private, else: :sanitized)

  defp same_inventory(inventory, inventory), do: :ok
  defp same_inventory(_before, _after), do: {:error, :source_changed}

  defp same_stat_identity(identity, identity), do: :ok
  defp same_stat_identity(_expected, _current), do: {:error, :source_changed}

  defp directory_root_identity(%File.Stat{} = stat) do
    %{
      major_device: stat.major_device,
      minor_device: stat.minor_device,
      inode: stat.inode,
      type: stat.type
    }
  end

  defp directory_member_path(directory, raw_name), do: directory <> "/" <> raw_name

  # ex_dna:disable-for-next-line — TraceLog keeps its source identity contract independent from inspection snapshots.
  defp stat_identity(%File.Stat{} = stat) do
    %{
      major_device: stat.major_device,
      minor_device: stat.minor_device,
      inode: stat.inode,
      type: stat.type,
      size: stat.size,
      mode: stat.mode,
      mtime: stat.mtime,
      ctime: stat.ctime
    }
  end

  # ex_dna:disable-for-next-line — TraceLog keeps its capture-hook contract independent from inspection snapshots.
  defp run_capture_hook(nil), do: :ok

  defp run_capture_hook(capture_hook) do
    case capture_hook.() do
      :ok -> :ok
      _other -> {:error, :source_unavailable}
    end
  rescue
    _exception -> {:error, :source_unavailable}
  catch
    _kind, _reason -> {:error, :source_unavailable}
  end

  defp read_regular_file(_path, remaining) when remaining < 0,
    do: {:error, :source_limit_exceeded}

  defp read_regular_file(path, remaining) do
    with {:ok, %File.Stat{type: :regular} = expected} <- File.lstat(path),
         true <- expected.size <= remaining,
         {:ok, device} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      try do
        with {:ok, file_info} <- :file.read_file_info(device),
             opened = File.Stat.from_record(file_info),
             :ok <- same_file(expected, opened),
             true <- opened.type == :regular and opened.size <= remaining do
          case :file.read(device, remaining + 1) do
            {:ok, source} when byte_size(source) <= remaining -> {:ok, source}
            :eof -> {:ok, ""}
            {:ok, _source} -> {:error, :source_limit_exceeded}
            {:error, _reason} -> {:error, :source_unavailable}
          end
        else
          false -> {:error, :source_limit_exceeded}
          {:error, _reason} = error -> error
        end
      after
        :file.close(device)
      end
    else
      false -> {:error, :source_limit_exceeded}
      {:ok, %File.Stat{}} -> {:error, :malformed_source}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp same_file(
         %File.Stat{major_device: device, minor_device: minor, inode: inode},
         %File.Stat{major_device: device, minor_device: minor, inode: inode}
       ),
       do: :ok

  defp same_file(_expected, _opened), do: {:error, :source_changed}

  defp decode_jsonl(source) do
    source
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, events} ->
      with {:ok, decoded} <- Jason.decode(line, objects: :ordered_objects),
           {:ok, event} <- ordered_map(decoded),
           true <- is_map(event) do
        {:cont, {:ok, [event | events]}}
      else
        _ -> {:halt, {:error, :malformed_source}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      {:error, _reason} = error -> error
    end
  end

  defp ordered_map(%OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if keys == Enum.uniq(keys) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, map} ->
        case ordered_map(value) do
          {:ok, normalized} -> {:cont, {:ok, Map.put(map, key, normalized)}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:error, :duplicate_json_key}
    end
  end

  defp ordered_map(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, normalized} ->
      case ordered_map(value) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp ordered_map(value), do: {:ok, value}

  defp validate_loaded(events, max_bytes) when is_list(events) do
    encoded_bytes = Enum.reduce(events, 0, &(&2 + byte_size(Jason.encode!(&1))))

    with true <- encoded_bytes <= max_bytes,
         :ok <- TraceEventValidation.validate(events) do
      source_id = digest(events)

      {:ok, events, source_id}
    else
      false -> {:error, :source_limit_exceeded}
      {:error, _reason} = error -> error
    end
  rescue
    Jason.EncodeError -> {:error, :malformed_source}
  end

  defp runs(events, source_kind) do
    events
    |> Enum.group_by(& &1["run_id"])
    |> Enum.map(fn {run_id, run_events} ->
      run_metadata(run_id, run_events, run_source_kind(source_kind, run_id))
    end)
    # Parse each timestamp once; comparisons otherwise repeat ISO-8601 parsing
    # across every comparison on every page of a broad cohort query.
    |> Enum.sort_by(&{timestamp_sort_value(&1["start_timestamp"]), &1["run_id"]}, :desc)
  end

  defp run_source_kind(source_kind, _run_id) when source_kind in [:sanitized, :private],
    do: source_kind

  defp run_source_kind(run_sources, run_id), do: Map.fetch!(run_sources, run_id)

  defp run_metadata(run_id, events, source_kind) do
    started = Enum.find(events, &(&1["type"] == "run-started"))
    stopped = events |> Enum.filter(&(&1["type"] == "run-stopped")) |> List.last()
    labels = event_data(started, "labels", %{})
    missions = run_missions(started)
    workflow_calls = capability_call_count(events, "workflow")
    mission_calls = capability_call_count(events, "mission")

    %{
      "run_id" => run_id,
      "trace_id" => event_value(started || List.first(events), "trace_id"),
      "start_timestamp" => event_value(started, "timestamp"),
      "stop_timestamp" => event_value(stopped, "timestamp"),
      "status" => stringify(event_data(stopped, "outcome")),
      "result_hash" => event_data(stopped, "result_hash"),
      "terminal_reason" => event_data(stopped, "reason"),
      "labels" => labels,
      "tags" => Map.get(labels, "tags", %{}),
      "name" => Map.get(labels, "name"),
      "model" => Map.get(labels, "model"),
      "provider" => Map.get(labels, "provider"),
      "evaluations" => evaluation_count(events),
      "subordinate_evaluations" => evaluation_count(events, "mission"),
      "subordinate_source_checks" => subordinate_source_checks(stopped),
      "workflow_capability_calls" => workflow_calls,
      "mission_capability_calls" => mission_calls,
      "llm_calls" => capability_name_count(events, "llm-request"),
      "llm_budget" => terminal_llm_budget(stopped),
      "llm_spend" => terminal_llm_spend(stopped),
      "error_count" => Enum.count(events, &error_event?/1),
      "duration_ms" => duration_ms(started, stopped),
      "workflow_prelude" => event_data(started, "workflow_prelude", empty_prelude()),
      "missions" => missions,
      "component_overrides" => event_data(started, "component_overrides", []),
      "connector_snapshots" => event_data(started, "connector_snapshots", []),
      "installation_config_digests" => event_data(started, "installation_config_digests", %{}),
      "session_profile" => event_data(started, "session_profile"),
      "positions" => event_positions(started),
      "complete" => not is_nil(stopped),
      "truncated" => Enum.any?(events, &(&1["type"] == "events-dropped")),
      "schema_version" => 2,
      "source" => Atom.to_string(source_kind)
    }
  end

  defp terminal_llm_budget(stopped) do
    case LLMBudget.validate_terminal_projection(event_data(stopped, "usage", %{})["llm_budget"]) do
      {:ok, budget} -> budget
      {:error, :invalid_llm_budget} -> nil
    end
  end

  defp terminal_llm_spend(stopped) do
    case LLMUsageSummary.validate_spend(event_data(stopped, "usage", %{})["llm_spend"]) do
      {:ok, spend} -> spend
      {:error, :invalid_llm_spend} -> nil
    end
  end

  # Absent prelude data projects to an empty graph.
  defp empty_prelude,
    do: %{"component_ids" => [], "dependency_indices" => [], "hash" => nil}

  defp run_missions(started), do: event_data(started, "missions", %{})

  defp subordinate_source_checks(%{
         "data" => %{"usage" => %{"subordinate_source_checks" => count}}
       })
       when is_integer(count) and count >= 0,
       do: count

  defp subordinate_source_checks(_stopped), do: 0

  defp event_positions(%{"sequence" => sequence}) when is_integer(sequence) and sequence > 0,
    do: [sequence]

  defp event_positions(_event), do: []

  defp filter_runs(items, arguments) do
    Enum.filter(items, fn item ->
      equal_filter?(item, arguments, "status") and equal_filter?(item, arguments, "run_id") and
        equal_filter?(item, arguments, "trace_id") and equal_filter?(item, arguments, "name") and
        bundle_filter?(item, arguments["bundle"]) and
        equal_filter?(item, arguments, "model") and equal_filter?(item, arguments, "provider") and
        tags_match?(item["tags"], arguments["tags"]) and
        after_or_equal?(item["start_timestamp"], arguments["from"]) and
        before_or_equal?(item["start_timestamp"], arguments["to"])
    end)
  end

  defp equal_filter?(item, arguments, key),
    do: is_nil(arguments[key]) or item[key] == arguments[key]

  defp bundle_filter?(_item, nil), do: true

  defp bundle_filter?(item, bundle),
    do: get_in(item, ["workflow_prelude", "hash"]) == bundle

  defp tags_match?(_tags, nil), do: true

  defp tags_match?(tags, expected),
    do: Enum.all?(expected, fn {key, value} -> tags[key] == value end)

  defp after_or_equal?(_timestamp, nil), do: true
  defp after_or_equal?(nil, _from), do: false
  defp after_or_equal?(timestamp, from), do: compare_timestamp(timestamp, from) != :lt
  defp before_or_equal?(_timestamp, nil), do: true
  defp before_or_equal?(nil, _to), do: false
  defp before_or_equal?(timestamp, to), do: compare_timestamp(timestamp, to) != :gt

  defp compare_timestamp(left, right) do
    {:ok, left_at, 0} = DateTime.from_iso8601(left)
    {:ok, right_at, 0} = DateTime.from_iso8601(right)
    DateTime.compare(left_at, right_at)
  end

  defp timestamp_sort_value(nil), do: -1

  defp timestamp_sort_value(timestamp) do
    {:ok, datetime, 0} = DateTime.from_iso8601(timestamp)
    DateTime.to_unix(datetime, :microsecond)
  end

  defp turn_matches?(event, arguments) do
    status = stringify(event_data(event, "status") || event_data(event, "outcome"))

    (is_nil(arguments["status"]) or status == arguments["status"]) and
      (is_nil(arguments["evaluation_id"]) or
         event_data(event, "evaluation_id") == arguments["evaluation_id"]) and
      (is_nil(arguments["parent_evaluation_id"]) or
         event_data(event, "parent_evaluation_id") == arguments["parent_evaluation_id"]) and
      (is_nil(arguments["capability"]) or event_data(event, "name") == arguments["capability"]) and
      mission_matches?(event, arguments["mission_name"])
  end

  defp mission_matches?(_event, nil), do: true

  defp mission_matches?(event, expected) when is_binary(expected),
    do: event_mission_name(event) == expected

  defp event_mission_name(%{"schema_version" => 2} = event) do
    if stringify(event_data(event, "environment")) == "mission",
      do: event_data(event, "mission_name"),
      else: nil
  end

  defp event_mission_name(_event), do: nil

  defp counters(events, attribution_events) do
    %{
      "events" => length(events),
      "runs" => events |> Enum.map(& &1["run_id"]) |> Enum.uniq() |> length(),
      "errors" => Enum.count(events, &error_event?/1),
      "evaluations" => Enum.count(events, &(&1["type"] == "evaluation-started")),
      "evaluations_by_mission" => evaluations_by_mission(events),
      "workflow_capability_calls" => capability_call_count(events, "workflow"),
      "mission_capability_calls" => capability_call_count(events, "mission")
    }
    |> Map.merge(LLMUsageSummary.summarize(events, attribution_events))
  end

  defp capability_call_count(events, environment) do
    Enum.count(events, fn event ->
      event["type"] == "capability-started" and
        stringify(event_data(event, "environment")) == environment
    end)
  end

  defp capability_name_count(events, name) do
    Enum.count(events, &(&1["type"] == "capability-started" and event_data(&1, "name") == name))
  end

  defp evaluation_count(events), do: Enum.count(events, &(&1["type"] == "evaluation-started"))

  defp evaluation_count(events, environment) do
    Enum.count(events, fn event ->
      event["type"] == "evaluation-started" and
        stringify(event_data(event, "environment")) == environment
    end)
  end

  # The summary has to agree with the transcript a reader opens next, which
  # renders one row per evaluation, capability call and exceeded limit. Counting
  # every event carrying an error status also counted `run-stopped`, so a single
  # failed capability call reported three errors against the rows that show it.
  # The run's own outcome is its status, not a fourth error.
  defp error_event?(event) do
    event["type"] == "limit-exceeded" or
      (event["type"] in ["capability-stopped", "evaluation-stopped"] and
         stringify(event_data(event, "status")) == "error")
  end

  defp duration_ms(nil, _stopped), do: nil
  defp duration_ms(_started, nil), do: nil

  defp duration_ms(started, stopped) do
    with {:ok, started_at, 0} <- DateTime.from_iso8601(started["timestamp"]),
         {:ok, stopped_at, 0} <- DateTime.from_iso8601(stopped["timestamp"]) do
      max(DateTime.diff(stopped_at, started_at, :millisecond), 0)
    else
      _ -> nil
    end
  end

  defp page_options(arguments, source_id, operation) do
    QueryCursor.page_options(
      arguments,
      source_id,
      {operation, Map.drop(arguments, ["cursor", "limit"])},
      @default_limit,
      @max_limit,
      @max_cursor_bytes
    )
  end

  defp paginate(
         items,
         %{limit: limit, offset: offset, query_id: query_id},
         source_id,
         max_result_bytes,
         metadata
       ) do
    selected = items |> Enum.drop(offset) |> Enum.take(limit)
    fit_page(selected, items, offset, source_id, query_id, max_result_bytes, metadata)
  end

  # ex_dna:disable-for-next-line — TraceLog and InspectionQuery intentionally own separate source query implementations.
  defp fit_page(
         selected,
         all_items,
         offset,
         source_id,
         query_id,
         max_result_bytes,
         metadata
       ) do
    full_result = fn fitted_metadata ->
      page_result(selected, all_items, offset, source_id, query_id, fitted_metadata)
    end

    case fit_metadata_result(metadata, max_result_bytes, full_result) do
      {:ok, result, _fitted_metadata} ->
        {:ok, result}

      {:exhausted, fitted_metadata} ->
        fit_page_items(
          selected,
          all_items,
          offset,
          source_id,
          query_id,
          max_result_bytes,
          fitted_metadata
        )
    end
  end

  defp fit_page_items(
         selected,
         all_items,
         offset,
         source_id,
         query_id,
         max_result_bytes,
         metadata
       ) do
    base = page_result([], all_items, offset, source_id, query_id, metadata)

    cond do
      not ResultLimit.within?(base, max_result_bytes) ->
        {:error, :result_limit_exceeded}

      selected == [] ->
        {:ok, base}

      true ->
        context = {all_items, offset, source_id, query_id, max_result_bytes, metadata}
        fit_page_prefix(selected, context, 1, length(selected) - 1, nil)
    end
  end

  defp fit_metadata(metadata, max_result_bytes, build_result) do
    case fit_metadata_result(metadata, max_result_bytes, build_result) do
      {:ok, result, _metadata} -> {:ok, result}
      {:exhausted, _metadata} -> {:error, :result_limit_exceeded}
    end
  end

  defp fit_metadata_result(metadata, max_result_bytes, build_result) do
    result = build_result.(metadata)

    if ResultLimit.within?(result, max_result_bytes) do
      {:ok, result, metadata}
    else
      case TraceIsolationPresentation.shrink(metadata) do
        {:ok, smaller} -> fit_metadata_result(smaller, max_result_bytes, build_result)
        :exhausted -> {:exhausted, metadata}
      end
    end
  end

  # ex_dna:disable-for-next-line — TraceLog and InspectionQuery intentionally own separate source query implementations.
  defp fit_page_prefix(_selected, _context, lower, upper, best)
       when lower > upper do
    if best, do: {:ok, best}, else: {:error, :result_limit_exceeded}
  end

  defp fit_page_prefix(
         selected,
         {all_items, offset, source_id, query_id, max_result_bytes, metadata} = context,
         lower,
         upper,
         best
       ) do
    count = div(lower + upper, 2)

    result =
      page_result(Enum.take(selected, count), all_items, offset, source_id, query_id, metadata)

    if ResultLimit.within?(result, max_result_bytes) do
      fit_page_prefix(
        selected,
        context,
        count + 1,
        upper,
        result
      )
    else
      fit_page_prefix(
        selected,
        context,
        lower,
        count - 1,
        best
      )
    end
  end

  # ex_dna:disable-for-next-line — TraceLog and InspectionQuery intentionally own separate source query implementations.
  defp page_result(selected, all_items, offset, source_id, query_id, metadata) do
    next_offset = offset + length(selected)
    more? = next_offset < length(all_items)

    Map.merge(metadata, %{
      "items" => selected,
      "next_cursor" =>
        if(more?, do: QueryCursor.encode(next_offset, source_id, query_id), else: nil),
      "truncated" => more?,
      "omitted_count" => max(length(all_items) - next_offset, 0)
    })
  end

  defp validate_run_filters(arguments) do
    with :ok <-
           optional_strings(
             arguments,
             ~w(status run_id trace_id name bundle model provider from to)
           ),
         :ok <- valid_tags(arguments["tags"]),
         :ok <- valid_timestamp(arguments["from"]) do
      valid_timestamp(arguments["to"])
    end
  end

  defp validate_turn_filters(arguments),
    do:
      optional_strings(
        arguments,
        ~w(status evaluation_id parent_evaluation_id capability mission_name)
      )

  defp evaluations_by_mission(events) do
    events
    |> Enum.filter(&(&1["type"] == "evaluation-started"))
    |> Enum.map(&event_mission_name/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.frequencies()
  end

  defp optional_strings(arguments, keys) do
    if Enum.all?(keys, &(is_nil(arguments[&1]) or valid_string(arguments[&1]) == :ok)),
      do: :ok,
      else: {:error, :invalid_query}
  end

  defp valid_string(value), do: QueryValidation.string(value, @max_string_bytes)
  defp valid_tags(nil), do: :ok
  defp valid_tags(tags), do: QueryValidation.tags(tags, @max_string_bytes)
  defp valid_timestamp(nil), do: :ok
  defp valid_timestamp(timestamp), do: QueryValidation.timestamp(timestamp)

  defp validate_keys(arguments, allowed) do
    if JSONValue.map?(arguments) and Map.keys(arguments) -- allowed == [],
      do: :ok,
      else: {:error, :invalid_query}
  end

  defp digest(value), do: QueryCursor.query_digest(value)

  defp event_data(nil, _key), do: nil
  defp event_data(event, key), do: get_in(event, ["data", key])
  defp event_data(nil, _key, default), do: default
  defp event_data(event, key, default), do: get_in(event, ["data", key]) || default
  defp event_value(nil, _key), do: nil
  defp event_value(event, key), do: event[key]
  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value

  defp normalize(value) when is_struct(value, DateTime), do: DateTime.to_iso8601(value)
  defp normalize(nil), do: nil
  defp normalize(value) when is_boolean(value), do: value
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)

  defp normalize(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), normalize(item)} end)

  defp normalize(value), do: value

  defp private_path?(path), do: String.ends_with?(path, ".private.jsonl")
  defp inspection_path?(path), do: String.ends_with?(path, ".ptcins")
  defp reserved_path?(path), do: private_path?(path) or inspection_path?(path)

  @doc false
  @spec publish_handle(
          PtcRunner.Kernel.PublicationHandle.t(),
          [map()],
          boolean(),
          nil | (atom() -> term())
        ) :: :ok | {:error, atom()}
  def publish_handle(handle, events, private?, fault_hook \\ nil) do
    TracePublication.publish(
      handle,
      events,
      private?,
      fault_hook,
      %{
        normalize: &normalize/1,
        validate: &validate_loaded(&1, @default_source_bytes),
        encode: &encode_jsonl(&1, @default_source_bytes),
        read: &PublicationHandle.read/2,
        decode: &decode_jsonl/1,
        within_limit: &within_append_limit/2,
        lock: &with_append_authority_lock/2,
        validate_path: &validate_append_path/2,
        fault: &publication_fault/2
      }
    )
  end

  defp within_append_limit(existing_source, encoded)
       when is_binary(existing_source) and is_binary(encoded) do
    if byte_size(existing_source) + byte_size(encoded) <= @default_source_bytes,
      do: :ok,
      else: {:error, :source_limit_exceeded}
  end
end
