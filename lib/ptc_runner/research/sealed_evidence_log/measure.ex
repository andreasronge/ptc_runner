defmodule PtcRunner.Research.SealedEvidenceLog.Measure do
  @moduledoc """
  Reproducible measurement harness for the sealed-log prototype.

  Large payload rungs are opt-in. The ordinary test suite uses the same
  functions with tiny fixtures and does not write committed binaries.
  """

  alias PtcRunner.Research.SealedEvidenceLog
  alias PtcRunner.Research.SealedEvidenceLog.Generator
  alias PtcRunner.Research.SealedEvidenceLog.Limits
  alias PtcRunner.Research.SealedEvidenceLog.Oracle

  @payload_rungs [
    {128 * 1024 * 1024, 2},
    {256 * 1024 * 1024, 4},
    {512 * 1024 * 1024, 8}
  ]

  @count_rungs [1_000, 10_000, 100_000, 1_000_000]

  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    tmp = Keyword.get_lazy(opts, :tmp_dir, fn -> tmp_root() end)
    File.mkdir_p!(tmp)

    try do
      {:ok, limits} = Limits.merge(Keyword.get(opts, :limits, []))
      full? = Keyword.get(opts, :full, false)
      max_records = Keyword.get(opts, :max_records, if(full?, do: 1_000_000, else: 10_000))
      payload_rungs = payload_rungs(opts, full?)
      count_rungs = Enum.filter(@count_rungs, &(&1 <= max_records))
      counts = Enum.map(count_rungs, &measure_count(tmp, limits, &1))
      completed_counts = Enum.filter(counts, &Map.has_key?(&1, :ets_bytes))

      %{
        environment: environment(),
        limits: envelope(limits),
        payload: Enum.map(payload_rungs, &measure_payload(tmp, limits, &1)),
        counts: counts,
        count_fit: linear_fit(completed_counts),
        refusals: measure_refusals(tmp),
        mixed: measure_mixed(tmp, limits),
        dense: measure_dense(tmp, limits),
        recommendation: recommendation(completed_counts)
      }
    after
      if Keyword.get(opts, :cleanup, true) do
        File.rm_rf(tmp)
      end
    end
  end

  defp measure_payload(tmp, limits, {artifact_bytes, frames}) do
    run_id = "payload-#{frames}"
    path = Path.join(tmp, "#{run_id}.ptcins")
    frame_bytes = div(artifact_bytes, frames)

    {produced_result, produce_ms} =
      timed(fn ->
        SealedEvidenceLog.produce(
          path,
          Generator.payload_stream(run_id, frames, frame_bytes),
          limits: Map.to_list(limits)
        )
      end)

    with {:ok, produced} <- produced_result,
         {admit_result, admit_ms} <-
           timed(fn ->
             SealedEvidenceLog.admit(
               %{path: path, trace_facts: Generator.empty_trace_facts()},
               limits: Map.to_list(limits)
             )
           end),
         {:ok, snapshot} <- admit_result do
      summarize_payload_success(
        path,
        produced,
        snapshot,
        artifact_bytes,
        produce_ms,
        admit_ms,
        run_id
      )
    else
      {:error, reason} ->
        File.rm(path)

        refused_rung(%{
          target_artifact_bytes: artifact_bytes,
          record_count: frames,
          reason: reason
        })
    end
  end

  defp summarize_payload_success(
         path,
         produced,
         snapshot,
         artifact_bytes,
         produce_ms,
         admit_ms,
         run_id
       ) do
    {:ok, info} = SealedEvidenceLog.info(snapshot)
    catalog_args = %{"limit" => 1}
    source_args = %{"run_id" => run_id, "limit" => 1}

    {catalog_result, cold_ms} =
      timed(fn -> SealedEvidenceLog.query(snapshot, :list_runs, catalog_args) end)

    {repeated_result, repeated_ms} =
      timed(fn -> SealedEvidenceLog.query(snapshot, :list_runs, catalog_args) end)

    {source_result, source_ms} =
      timed(fn -> SealedEvidenceLog.query(snapshot, :generated_sources, source_args) end)

    handle_count = info.handle_count
    artifact_stat = File.stat!(path)
    accounting = summarize_accounting(info.accounting)
    SealedEvidenceLog.close(snapshot)
    remaining = File.stat!(path).size
    File.rm(path)

    case {catalog_result, repeated_result} do
      {{:ok, page, metrics}, {:ok, _repeated, _repeated_metrics}} ->
        %{
          target_artifact_bytes: artifact_bytes,
          artifact_bytes: produced.total_bytes,
          record_count: produced.record_count,
          frame_size: produced.frame_size,
          producer_ms: produce_ms,
          admission_ms: admit_ms,
          cold_query_ms: cold_ms,
          repeated_query_ms: repeated_ms,
          generated_sources_query: query_outcome(source_result, source_ms),
          producer_checkpoints: summarize_checkpoints(produced.checkpoints),
          admission_checkpoints: admission_checkpoint_summary(info),
          admission_peaks: summarize_peaks(info.diagnostic_peaks),
          accounting: accounting,
          query_metrics: metrics,
          omitted_count: page["omitted_count"],
          handle_count_before_close: handle_count,
          scratch_bytes_before_close: 0,
          scratch_bytes_after_close: 0,
          artifact_bytes_remaining_after_close: remaining,
          artifact_bytes_before_close: artifact_stat.size
        }

      {error, _repeated} ->
        refused_rung(%{
          target_artifact_bytes: artifact_bytes,
          artifact_bytes: produced.total_bytes,
          record_count: produced.record_count,
          frame_size: produced.frame_size,
          producer_ms: produce_ms,
          admission_ms: admit_ms,
          accounting: accounting,
          reason: query_reason(error)
        })
    end
  end

  defp measure_count(tmp, limits, count) do
    run_id = "count-#{count}"
    path = Path.join(tmp, "#{run_id}.ptcins")
    rung_limits = %{limits | max_records: count}

    {produced_result, produce_ms} =
      timed(fn ->
        SealedEvidenceLog.produce(path, Generator.count_stream(run_id, count),
          limits: Map.to_list(rung_limits)
        )
      end)

    with {:ok, produced} <- produced_result,
         {admit_result, admit_ms} <-
           timed(fn ->
             SealedEvidenceLog.admit(%{path: path, trace_facts: Generator.empty_trace_facts()},
               limits: Map.to_list(rung_limits)
             )
           end),
         {:ok, snapshot} <- admit_result do
      summarize_count_success(path, produced, snapshot, count, produce_ms, admit_ms, run_id)
    else
      {:error, reason} ->
        File.rm(path)
        refused_rung(%{record_count: count, reason: reason, producer_ms: produce_ms})
    end
  end

  defp summarize_count_success(path, produced, snapshot, count, produce_ms, admit_ms, run_id) do
    {:ok, info} = SealedEvidenceLog.info(snapshot)
    arguments = %{"run_id" => run_id, "limit" => 10}

    {_page, cold_ms} =
      timed(fn ->
        {:ok, page, metrics} = SealedEvidenceLog.query(snapshot, :execution_prints, arguments)
        {page, metrics}
      end)

    {{page, metrics}, repeated_ms} =
      timed(fn ->
        {:ok, page, metrics} = SealedEvidenceLog.query(snapshot, :execution_prints, arguments)
        {page, metrics}
      end)

    accounting = info.accounting
    per_record = if count > 0, do: accounting.ets_bytes / count, else: 0.0
    SealedEvidenceLog.close(snapshot)

    one_over =
      if count > 1 do
        error_reason(
          SealedEvidenceLog.admit(%{path: path, trace_facts: Generator.empty_trace_facts()},
            limits: [max_records: count - 1]
          )
        )
      else
        :skipped
      end

    File.rm(path)

    %{
      record_count: count,
      artifact_bytes: produced.total_bytes,
      ets_bytes: accounting.ets_bytes,
      ets_words: accounting.ets_words,
      logical_bytes: accounting.logical_bytes,
      logical_entries: accounting.logical_entries,
      other_retained_bytes: accounting.other_retained_bytes,
      charged_retained_bytes: accounting.charged_retained_bytes,
      bytes_per_record: per_record,
      producer_ms: produce_ms,
      admission_ms: admit_ms,
      cold_query_ms: cold_ms,
      repeated_query_ms: repeated_ms,
      query_metrics: metrics,
      omitted_count: page["omitted_count"],
      producer_checkpoints: summarize_checkpoints(produced.checkpoints),
      admission_peaks: summarize_peaks(info.diagnostic_peaks),
      max_records_plus_one: one_over
    }
  end

  defp measure_refusals(tmp) do
    run_id = "refuse"
    path = Path.join(tmp, "#{run_id}.ptcins")
    {:ok, _} = SealedEvidenceLog.produce(path, Generator.count_stream(run_id, 3), limits: [])

    records_plus_one =
      SealedEvidenceLog.admit(%{path: path, trace_facts: Generator.empty_trace_facts()},
        limits: [max_records: 2]
      )

    exact =
      SealedEvidenceLog.admit(%{path: path, trace_facts: Generator.empty_trace_facts()},
        limits: [max_records: 3]
      )

    entries_plus_one =
      SealedEvidenceLog.admit(%{path: path, trace_facts: Generator.empty_trace_facts()},
        limits: [max_index_entries: 1]
      )

    bytes_plus_one =
      SealedEvidenceLog.admit(%{path: path, trace_facts: Generator.empty_trace_facts()},
        limits: [max_logical_index_bytes: 32]
      )

    File.rm(path)

    %{
      max_records: error_reason(records_plus_one),
      max_records_exact: ok?(exact),
      max_index_entries: error_reason(entries_plus_one),
      max_logical_index_bytes: error_reason(bytes_plus_one)
    }
  end

  defp measure_mixed(tmp, limits) do
    corpus = Generator.mixed_run("measure-mixed")
    path = Path.join(tmp, "measure-mixed.ptcins")
    {:ok, _} = SealedEvidenceLog.produce(path, corpus.records, limits: Map.to_list(limits))

    {:ok, snapshot} =
      SealedEvidenceLog.admit(%{path: path, trace_facts: corpus.trace_facts},
        limits: Map.to_list(limits)
      )

    {:ok, current} =
      Oracle.compile_current([corpus.records], "trace-source", corpus.trace_analysis)

    parity =
      Map.new(SealedEvidenceLog.Query.operations(), fn operation ->
        args = operation_args(operation, "measure-mixed")
        {operation, Oracle.walk_equal(current, snapshot, operation, args, 1_000_000)}
      end)

    SealedEvidenceLog.close(snapshot)
    File.rm(path)
    %{parity: parity}
  end

  defp measure_dense(tmp, limits) do
    corpus = Generator.dense_filter_run("dense", 32)
    path = Path.join(tmp, "dense.ptcins")
    {:ok, _} = SealedEvidenceLog.produce(path, corpus.records, limits: Map.to_list(limits))

    {:ok, snapshot} =
      SealedEvidenceLog.admit(%{path: path, trace_facts: corpus.trace_facts},
        limits: Map.to_list(limits)
      )

    {:ok, page, metrics} =
      SealedEvidenceLog.query(snapshot, :generated_sources, %{
        "run_id" => "dense",
        "limit" => 3,
        "mission_name" => "default"
      })

    SealedEvidenceLog.close(snapshot)
    File.rm(path)
    %{omitted_count: page["omitted_count"], metrics: metrics, truncated: page["truncated"]}
  end

  defp operation_args(:list_runs, _run_id), do: %{"limit" => 10}

  defp operation_args(operation, run_id) when operation in [:get_run, :result],
    do: %{"run_id" => run_id}

  defp operation_args(_operation, run_id), do: %{"run_id" => run_id, "limit" => 10}

  defp payload_rungs(opts, true), do: Keyword.get(opts, :payload_rungs, @payload_rungs)
  defp payload_rungs(opts, false), do: Keyword.get(opts, :payload_rungs, [])

  defp environment do
    %{
      otp: :erlang.system_info(:otp_release) |> List.to_string(),
      erts: :erlang.system_info(:version) |> List.to_string(),
      word_size: :erlang.system_info(:wordsize),
      schedulers: System.schedulers_online(),
      os: :os.type(),
      trials: 1,
      warm_up: 0
    }
  end

  defp envelope(limits) do
    Map.take(limits, [
      :max_record_bytes,
      :max_total_bytes,
      :producer_heap_bytes,
      :admission_heap_bytes,
      :query_heap_bytes,
      :io_buffer_bytes,
      :max_records
    ])
  end

  defp timed(function) do
    started = System.monotonic_time(:millisecond)
    result = function.()
    {result, System.monotonic_time(:millisecond) - started}
  end

  defp summarize_checkpoints(%{checkpoints: checkpoints, diagnostic_peaks: peaks} = finalized) do
    %{
      names: Enum.map(checkpoints, & &1.name) |> Enum.uniq(),
      counts: Map.get(finalized, :counts, %{}),
      peak_memory_bytes: peak_bytes(peaks, :aggregate_memory_bytes),
      peak_referenced_binary_bytes: peak_bytes(peaks, :aggregate_referenced_binary_bytes)
    }
  end

  defp summarize_checkpoints(_other), do: %{names: [], peak_memory_bytes: 0}

  defp summarize_peaks(peaks) when is_map(peaks) do
    %{
      names: Map.keys(peaks),
      peak_memory_bytes: peak_bytes(peaks, :aggregate_memory_bytes),
      peak_referenced_binary_bytes: peak_bytes(peaks, :aggregate_referenced_binary_bytes)
    }
  end

  defp summarize_peaks(_other), do: %{names: [], peak_memory_bytes: 0}

  defp peak_bytes(peaks, field) do
    peaks
    |> Map.values()
    |> Enum.map(&Map.get(&1, field, 0))
    |> Enum.max(fn -> 0 end)
  end

  defp summarize_accounting(accounting) do
    Map.take(accounting, [
      :ets_words,
      :ets_bytes,
      :ets_entries,
      :logical_entries,
      :logical_bytes,
      :other_retained_bytes,
      :charged_retained_bytes
    ])
  end

  defp query_outcome({:ok, page, metrics}, duration_ms) do
    %{
      status: :ok,
      duration_ms: duration_ms,
      omitted_count: page["omitted_count"],
      metrics: metrics
    }
  end

  defp query_outcome({:error, reason}, duration_ms) do
    %{status: :error, reason: reason, duration_ms: duration_ms}
  end

  defp query_reason({:error, reason}), do: reason
  defp query_reason(other), do: other

  defp refused_rung(fields), do: Map.put(fields, :refused, true)

  defp linear_fit([]), do: %{slope: 0.0, intercept: 0.0, rungs: 0}

  defp linear_fit(rows) do
    n = length(rows) * 1.0
    xs = Enum.map(rows, &(&1.record_count * 1.0))
    ys = Enum.map(rows, &(&1.ets_bytes * 1.0))
    sum_x = Enum.sum(xs)
    sum_y = Enum.sum(ys)
    sum_xx = Enum.reduce(xs, 0.0, fn x, acc -> acc + x * x end)
    sum_xy = Enum.zip_reduce(xs, ys, 0.0, fn x, y, acc -> acc + x * y end)
    denom = n * sum_xx - sum_x * sum_x

    if denom == 0.0 do
      %{slope: 0.0, intercept: 0.0, rungs: length(rows)}
    else
      slope = (n * sum_xy - sum_x * sum_y) / denom
      intercept = (sum_y - slope * sum_x) / n
      %{slope: slope, intercept: intercept, rungs: length(rows)}
    end
  end

  defp error_reason({:error, reason}), do: reason
  defp error_reason(other), do: other

  defp ok?({:ok, snapshot}) do
    SealedEvidenceLog.close(snapshot)
    true
  end

  defp ok?(_other), do: false

  defp tmp_root do
    Path.join(System.tmp_dir!(), "ptc-sealed-evidence-#{System.unique_integer([:positive])}")
  end

  defp recommendation(completed_counts) do
    last = completed_counts |> Enum.map(& &1.record_count) |> Enum.max(fn -> 0 end)

    %{
      format: :ets_only_v1,
      omitted_count: :exact_when_dependency_bytes_fit,
      next_comparison: :none,
      host_surface: :keep_existing_plus_internal_max_records,
      last_successful_count_rung: last,
      experiment_safety_ceiling: 1_000_000,
      proposed_production_max_records_default: 16_384,
      proposed_production_max_records_hard_max: 65_536
    }
  end

  defp checkpoint_counts(checkpoints) when is_list(checkpoints) do
    Enum.frequencies_by(checkpoints, & &1.name)
  end

  defp checkpoint_counts(_other), do: %{}

  defp admission_checkpoint_summary(info) do
    summarize_checkpoints(%{
      checkpoints: info.checkpoints,
      diagnostic_peaks: info.diagnostic_peaks,
      counts: checkpoint_counts(info.checkpoints)
    })
  end
end
