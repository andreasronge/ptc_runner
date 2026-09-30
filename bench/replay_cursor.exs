# mix run bench/replay_cursor.exs
alias PtcRunner.Kernel.LLMReplayOwner
IO.puts("length,scopes,elapsed_us,reductions,loaded_bytes,active_bytes,drained_bytes")

for n <- [1, 10, 1_000, 10_000, 40_000], count <- [1, 4] do
  entries = %{"request" => Enum.map(1..n, &%{"turn" => &1})}

  scopes =
    Enum.map(1..count, fn _ ->
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)
    end)

  {:ok, pid} = LLMReplayOwner.start(entries, self())

  memory = fn ->
    :erlang.garbage_collect(pid)
    {:memory, bytes} = Process.info(pid, :memory)
    bytes
  end

  loaded = memory.()
  Enum.each(scopes, &LLMReplayOwner.take(pid, "request", &1))
  active = memory.()
  {:reductions, before} = Process.info(pid, :reductions)

  {elapsed, _} =
    :timer.tc(fn ->
      scopes
      |> Task.async_stream(
        fn scope ->
          if n > 1,
            do: Enum.each(2..n, fn _ -> {:ok, _} = LLMReplayOwner.take(pid, "request", scope) end)

          {:error, :exhausted} = LLMReplayOwner.take(pid, "request", scope)
        end,
        timeout: :infinity
      )
      |> Stream.run()
    end)

  {:reductions, after_count} = Process.info(pid, :reductions)
  drained = memory.()
  IO.puts("#{n},#{count},#{elapsed},#{after_count - before},#{loaded},#{active},#{drained}")
  Enum.each(scopes, &send(&1, :stop))
  LLMReplayOwner.stop(pid)
end
