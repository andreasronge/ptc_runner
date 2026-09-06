defmodule PtcRunner.Bench.Heap do
  @moduledoc false
  def measure(fun) do
    sampler = spawn_link(fn -> sample_heaps(%{}, 0, 0) end)
    handler = {__MODULE__, :heap, self()}

    :ok =
      :telemetry.attach(handler, [:ptc_runner, :sandbox, :armed], &__MODULE__.armed/4, sampler)

    try do
      fun.()
      send(sampler, {:finish, self()})

      receive do
        {:heap_sample, peak, samples} ->
          %{sampled_peak_total_heap_words: peak, observations: samples}
      end
    after
      :telemetry.detach(handler)
      send(sampler, :stop)
    end
  end

  def armed(_event, _measurements, %{pid: pid, max_heap: 5_000_000}, sampler),
    do: send(sampler, {:armed, pid})

  def armed(_event, _measurements, _metadata, _sampler), do: :ok

  defp sample_heaps(pids, peak, samples) do
    receive do
      {:armed, pid} ->
        ref = Process.monitor(pid)
        sample_heaps(Map.put(pids, ref, pid), peak, samples)

      {:DOWN, ref, :process, _pid, _reason} ->
        sample_heaps(Map.delete(pids, ref), peak, samples)

      {:finish, parent} ->
        send(parent, {:heap_sample, peak, samples})

      :stop ->
        :ok
    after
      2 ->
        sizes =
          Enum.flat_map(pids, fn {_ref, pid} ->
            case Process.info(pid, :total_heap_size) do
              {:total_heap_size, words} -> [words]
              nil -> []
            end
          end)

        sample_heaps(pids, Enum.max([peak | sizes]), samples + length(sizes))
    end
  end
end
