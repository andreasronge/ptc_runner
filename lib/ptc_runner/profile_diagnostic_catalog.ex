defmodule PtcRunner.ProfileDiagnosticCatalog do
  @moduledoc """
  Closed public diagnostics for private profile selection and source capture.

  The catalog translates internal capture reasons into stable, bounded,
  path-free frontend codes and messages. Unknown reasons are never promoted to
  public vocabulary; `classify!/1` collapses them to `profile_setup_failed`.

  This catalog is intentionally separate from
  `PtcRunner.Kernel.DiagnosticCatalog`. Kernel diagnostic rows describe command
  envelope phases, while these rows are emitted by the one-shot REPL frontend.
  """

  @rows [
    %{
      code: :invalid_run_reference,
      message: "selected run reference is invalid",
      description: "A --run value is not a canonical PTC command run reference."
    },
    %{
      code: :selected_set_limit_exceeded,
      message: "selected run set exceeds the 16-run limit",
      description: "More than sixteen run references were selected for one session."
    },
    %{
      code: :duplicate_selected_run,
      message: "selected run set contains a duplicate reference",
      description: "The same run reference was supplied more than once."
    },
    %{
      code: :selected_trace_missing,
      message: "selected trace is missing",
      description: "No trace candidate exists for a selected run."
    },
    %{
      code: :selected_inspection_missing,
      message: "selected inspection artifact is missing",
      description: "No sealed inspection artifact exists for a selected run."
    },
    %{
      code: :ambiguous_selected_trace,
      message: "selected run has ambiguous trace candidates",
      description: "Both sanitized and private trace candidates exist."
    },
    %{
      code: :selected_trace_not_regular,
      message: "selected trace is not a regular file",
      description: "The exact selected trace candidate is not a regular file."
    },
    %{
      code: :selected_inspection_not_regular,
      message: "selected inspection artifact is not a regular file",
      description: "The exact selected inspection candidate is not a regular file."
    },
    %{
      code: :source_changed,
      message: "analysis source changed during immutable capture",
      description: "A selected source or cursor identity changed while it was being verified."
    },
    %{
      code: :unsupported_schema,
      message: "analysis source uses an unsupported schema version",
      description: "A selected trace or inspection artifact uses an unsupported version."
    },
    %{
      code: :malformed_source,
      message: "analysis source is malformed",
      description: "Selected metadata or sealed evidence failed structural validation."
    },
    %{
      code: :selected_run_mismatch,
      message: "selected source identity does not match its run reference",
      description: "Embedded run or trace identity disagrees with the selected candidate."
    },
    %{
      code: :inspection_correlation_missing,
      message: "selected trace and inspection artifacts do not correlate",
      description: "The selected trace and sealed evidence do not prove one correlation."
    },
    %{
      code: :duplicate_inspection_run,
      message: "selected inspection set contains a duplicate run identity",
      description: "More than one selected artifact claims the same inspection run identity."
    },
    %{
      code: :catalog_limit_exceeded,
      message: "private run catalog exceeded its capture limits",
      description: "Catalog entry, file, retained-memory, heap, or listing bounds were exceeded."
    },
    %{
      code: :source_limit_exceeded,
      message: "selected analysis source exceeded its admission limits",
      description: "Aggregate bytes, per-artifact records, index entries, or heap were exceeded."
    },
    %{
      code: :source_retained_limit_exceeded,
      message:
        "selected analysis source exceeded its retained-memory limit; for whole-directory private-run-analysis-v2 capture, select exact runs with --run RUN_ID",
      description: "The immutable trace projection or inspection index retained too much memory."
    },
    %{
      code: :result_limit_exceeded,
      message: "profile evaluation result exceeded its byte limit",
      description: "A catalog page or selected-analysis result could not fit its result bound."
    },
    %{
      code: :source_unavailable,
      message: "analysis source is unavailable or capture timed out",
      description: "A source root became unavailable or its bounded capture deadline elapsed."
    },
    %{
      code: :profile_setup_failed,
      message: "private analysis profile setup failed",
      description: "An unclassified internal setup failure was closed at the frontend boundary."
    },
    %{
      code: :profile_evaluation_failed,
      message: "profile evaluation failed",
      description: "A profile form failed for a reason outside the source-capture vocabulary."
    }
  ]

  @by_code Map.new(@rows, &{&1.code, &1})

  @spec rows() :: [map()]
  def rows, do: @rows

  @spec classify(term()) :: {:ok, map()} | {:error, :unknown_profile_diagnostic}
  def classify({:source_retained_limit_exceeded, _details}),
    do: fetch(:source_retained_limit_exceeded)

  def classify(reason) when reason in [:unsupported_version], do: fetch(:unsupported_schema)

  def classify(reason)
      when reason in [:incomplete_inspection_correlation],
      do: fetch(:inspection_correlation_missing)

  def classify(reason)
      when reason in [
             :snapshot_unavailable,
             :catalog_unavailable,
             :deadline_exceeded,
             :empty_traces_resource,
             :empty_inspection_resource
           ],
      do: fetch(:source_unavailable)

  def classify(reason)
      when reason in [:heap_exceeded, :max_records, :max_index_entries, :max_logical_index_bytes],
      do: fetch(:source_limit_exceeded)

  def classify(:max_retained_bytes), do: fetch(:source_retained_limit_exceeded)
  def classify(reason) when is_atom(reason), do: fetch(reason)
  def classify(_reason), do: {:error, :unknown_profile_diagnostic}

  @spec classify!(term()) :: map()
  def classify!(reason) do
    case classify(reason) do
      {:ok, diagnostic} -> diagnostic
      {:error, :unknown_profile_diagnostic} -> Map.fetch!(@by_code, :profile_setup_failed)
    end
  end

  defp fetch(code) do
    case Map.fetch(@by_code, code) do
      {:ok, diagnostic} -> {:ok, diagnostic}
      :error -> {:error, :unknown_profile_diagnostic}
    end
  end
end
