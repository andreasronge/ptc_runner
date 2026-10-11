defmodule PtcRunner.Kernel.TraceLog do
  @moduledoc """
  Thin façade for bounded canonical trace capture and loaded-event queries.

  `TraceLog.Capture` owns inventory and admission, `TraceLog.Query` owns
  analysis and pagination, `TraceLog.Append` owns append authority, and
  `TraceLog.Publish` owns canonical publication.

  A source is one JSONL file or a directory of JSONL files. Explicit files
  validate one complete aggregate.
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

  Run-scoped snapshot queries distinguish a grant-visible isolated claim as
  `:run_isolated` from an absent or out-of-grant run as `:not_found`.

  The internal trace-snapshot owner uses this module's canonical validation and
  query execution against one immutable directory capture or one exact selected
  canonical file.
  """

  alias PtcRunner.Kernel.TraceLog.Capture
  alias PtcRunner.Kernel.TraceLog.Query

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
  defdelegate capture_directory(directory, opts \\ []), to: Capture
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
  defdelegate capture_file(path, opts \\ []), to: Capture
  @doc false
  @spec capture_selected([map()], keyword()) :: {:ok, map()} | {:error, atom()}
  defdelegate capture_selected(selected, opts \\ []), to: Capture

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
  defdelegate query_loaded(
                events,
                source_id,
                operation,
                arguments,
                max_result_bytes,
                source_kind,
                metadata \\ %{},
                known_isolated_run_ids \\ MapSet.new()
              ),
              to: Query
end
