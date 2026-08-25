defmodule PtcRunner.Research.SealedEvidenceLog.Checkpoints do
  @moduledoc """
  Deterministic memory checkpoints for producer and admission processes.

  Sampled process peaks are diagnostic only. Each named event updates running
  peaks and keeps only the first and last sample for that name, so checkpoint
  memory does not grow with record count. Rows record `Process.info(pid, :memory)`
  and referenced binary bytes for every prototype-created process plus a
  conservative sum aggregate. Process identifiers are not retained.
  """

  @type sample :: %{
          memory_bytes: non_neg_integer(),
          referenced_binary_bytes: non_neg_integer()
        }

  @type checkpoint :: %{
          name: atom(),
          at_ms: integer(),
          processes: [sample()],
          aggregate_memory_bytes: non_neg_integer(),
          aggregate_referenced_binary_bytes: non_neg_integer()
        }

  @spec new() :: map()
  def new, do: %{samples: %{}, counts: %{}, peaks: %{}}

  @spec record(map(), atom(), [pid()]) :: map()
  def record(state, name, pids) when is_map(state) and is_atom(name) and is_list(pids) do
    processes = Enum.map(pids, &sample/1)

    checkpoint = %{
      name: name,
      at_ms: System.monotonic_time(:millisecond),
      processes: processes,
      aggregate_memory_bytes: Enum.reduce(processes, 0, &(&1.memory_bytes + &2)),
      aggregate_referenced_binary_bytes:
        Enum.reduce(processes, 0, &(&1.referenced_binary_bytes + &2))
    }

    count = Map.get(state.counts, name, 0) + 1

    samples =
      Map.update(state.samples, name, %{first: checkpoint, last: checkpoint}, fn existing ->
        %{existing | last: checkpoint}
      end)

    %{
      state
      | samples: samples,
        counts: Map.put(state.counts, name, count),
        peaks: update_peaks(state.peaks, checkpoint)
    }
  end

  @spec finalize(map()) :: map()
  def finalize(%{samples: samples, counts: counts, peaks: peaks}) do
    checkpoints =
      samples
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {_name, pair} ->
        if Map.fetch!(counts, pair.first.name) == 1,
          do: [pair.first],
          else: [pair.first, pair.last]
      end)

    %{
      checkpoints: checkpoints,
      counts: counts,
      diagnostic_peaks: peaks
    }
  end

  defp sample(pid) do
    %{
      memory_bytes: info_bytes(pid, :memory),
      referenced_binary_bytes: referenced_binary_bytes(pid)
    }
  end

  defp info_bytes(pid, key) do
    case Process.info(pid, key) do
      {^key, value} when is_integer(value) -> value
      _other -> 0
    end
  end

  defp referenced_binary_bytes(pid) do
    case Process.info(pid, :binary) do
      {:binary, binaries} ->
        Enum.reduce(binaries, 0, fn {_ptr, size, _refc}, acc -> acc + size end)

      _other ->
        0
    end
  end

  defp update_peaks(peaks, checkpoint) do
    Map.update(peaks, checkpoint.name, checkpoint, fn current ->
      if checkpoint.aggregate_memory_bytes > current.aggregate_memory_bytes,
        do: checkpoint,
        else: current
    end)
  end
end
