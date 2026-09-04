defmodule PtcRunner.ProfileDiagnosticCatalogTest do
  use ExUnit.Case, async: true

  alias PtcRunner.ProfileDiagnosticCatalog

  @selection_and_capture_reasons [
    :invalid_run_reference,
    :selected_set_limit_exceeded,
    :duplicate_selected_run,
    :selected_trace_missing,
    :selected_inspection_missing,
    :ambiguous_selected_trace,
    :selected_trace_not_regular,
    :selected_inspection_not_regular,
    :source_changed,
    :unsupported_schema,
    :malformed_source,
    :selected_run_mismatch,
    :inspection_correlation_missing,
    :duplicate_inspection_run,
    :catalog_limit_exceeded,
    :source_limit_exceeded,
    :source_retained_limit_exceeded,
    :result_limit_exceeded,
    :source_unavailable,
    :profile_evaluation_failed
  ]

  test "the closed catalog covers every profile selection and capture refusal" do
    rows = ProfileDiagnosticCatalog.rows()

    assert Enum.map(rows, & &1.code) |> Enum.uniq() == Enum.map(rows, & &1.code)

    for reason <- @selection_and_capture_reasons do
      assert {:ok, %{code: ^reason, message: message, description: description}} =
               ProfileDiagnosticCatalog.classify(reason)

      assert byte_size(message) in 1..512
      assert description != ""
    end
  end

  test "aliases normalize without expanding the public vocabulary" do
    assert {:ok, %{code: :unsupported_schema}} =
             ProfileDiagnosticCatalog.classify(:unsupported_version)

    assert {:ok, %{code: :inspection_correlation_missing}} =
             ProfileDiagnosticCatalog.classify(:incomplete_inspection_correlation)

    assert {:ok, %{code: :source_retained_limit_exceeded}} =
             ProfileDiagnosticCatalog.classify({
               :source_retained_limit_exceeded,
               %{source: :ptc_inspection_snapshot, measured_bytes: 2, limit_bytes: 1}
             })

    for reason <- [:heap_exceeded, :max_records, :max_index_entries, :max_logical_index_bytes] do
      assert {:ok, %{code: :source_limit_exceeded}} =
               ProfileDiagnosticCatalog.classify(reason)
    end

    assert {:ok, %{code: :source_retained_limit_exceeded}} =
             ProfileDiagnosticCatalog.classify(:max_retained_bytes)

    assert %{message: message} =
             ProfileDiagnosticCatalog.classify!(:source_retained_limit_exceeded)

    assert message =~ "--run RUN_ID"
    assert message =~ "whole-directory private-run-analysis-v2"
  end

  test "unknown internal reasons collapse to the closed fallback" do
    assert %{code: :profile_setup_failed, message: "private analysis profile setup failed"} =
             ProfileDiagnosticCatalog.classify!(:private_payload_must_not_be_rendered)
  end
end
