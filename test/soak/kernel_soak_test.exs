defmodule PtcRunner.KernelSoakTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel
  alias PtcRunner.TestSupport.MemorySoak
  alias PtcRunner.TraceContext
  alias PtcRunner.TraceLog
  alias PtcRunner.TraceLog.Analyzer

  @moduletag :soak
  @moduletag :tmp_dir
  @moduletag timeout: :infinity

  test "untraced kernel owner churn stays bounded across complete one-turn runs" do
    iterations = MemorySoak.iteration_count()
    finch_before = finch_health!()

    {before, mid, after_snapshot} =
      MemorySoak.measure3(iterations, [warmup: 25], fn phase ->
        assert_one_turn_kernel(phase)
        assert_trace_state_empty()
      end)

    IO.puts("BEFORE (kernel untraced, n=#{iterations}):\n#{MemorySoak.format(before)}")
    IO.puts("AFTER  (kernel untraced, n=#{iterations}):\n#{MemorySoak.format(after_snapshot)}")

    MemorySoak.assert_flat!(before, after_snapshot, :total, tolerance_pct: 20)
    MemorySoak.assert_flat!(before, after_snapshot, :binary, tolerance_pct: 50)
    MemorySoak.assert_procs_stable!(before, after_snapshot, tolerance: 5)

    MemorySoak.assert_atoms_per_iter_strict!(before, mid, after_snapshot, iterations,
      max_per_iter: 0.1
    )

    assert_trace_state_empty()
    assert_finch_stable!(finch_before)
  end

  test "100 traced kernel turns persist without drops and collectors stop", %{tmp_dir: dir} do
    iterations = 100
    finch_before = finch_health!()

    {before, mid, after_snapshot} =
      MemorySoak.measure3(iterations, [warmup: 10], fn phase ->
        index = phase_index(phase)
        path = Path.join(dir, "kernel-#{phase_name(phase)}-#{index}.jsonl")
        parent = self()

        assert {:ok, {:ok, %{"value" => 42}}, %{path: ^path, write_errors: 0}} =
                 TraceLog.with_trace(
                   fn ->
                     send(parent, {:collector, TraceLog.current_collector()})
                     one_turn_kernel()
                   end,
                   path: path,
                   return_metadata: true
                 )

        assert_receive {:collector, collector}
        monitor = Process.monitor(collector)
        assert_receive {:DOWN, ^monitor, :process, ^collector, _reason}

        turns = path |> Analyzer.load() |> Analyzer.turn_events()
        assert Enum.count(turns, &(&1["driver"] == "kernel")) == 1
        assert_trace_state_empty()
      end)

    IO.puts("BEFORE (kernel traced, n=#{iterations}):\n#{MemorySoak.format(before)}")
    IO.puts("AFTER  (kernel traced, n=#{iterations}):\n#{MemorySoak.format(after_snapshot)}")

    measured_paths = Path.wildcard(Path.join(dir, "kernel-measured-*.jsonl"))
    actual_turns = Enum.sum(Enum.map(measured_paths, &count_kernel_turns/1))

    assert length(measured_paths) == iterations
    assert actual_turns == iterations
    assert iterations - actual_turns == 0
    assert max(actual_turns - iterations, 0) == 0

    MemorySoak.assert_flat!(before, after_snapshot, :total, tolerance_pct: 20)
    MemorySoak.assert_flat!(before, after_snapshot, :binary, tolerance_pct: 50)
    MemorySoak.assert_procs_stable!(before, after_snapshot, tolerance: 5)

    MemorySoak.assert_atoms_per_iter_strict!(before, mid, after_snapshot, iterations,
      max_per_iter: 0.1
    )

    assert_trace_state_empty()
    assert_finch_stable!(finch_before)
  end

  defp assert_one_turn_kernel(_phase) do
    assert {:ok, %{"value" => 42}} = one_turn_kernel()
  end

  defp one_turn_kernel do
    Kernel.run(%{"task" => "Return the integer result."},
      llm: fn _request ->
        {:ok, %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => "(return 42)"}}]}}
      end,
      max_turns: 1,
      max_llm_calls: 1
    )
  end

  defp assert_trace_state_empty do
    assert TraceLog.active_collectors() == []
    assert TraceLog.active_memory_sinks() == []
    assert TraceContext.capture().collectors == []
    assert TraceContext.capture().memory_sinks == []
  end

  defp count_kernel_turns(path) do
    path
    |> Analyzer.load()
    |> Analyzer.turn_events()
    |> Enum.count(&(&1["driver"] == "kernel"))
  end

  defp finch_health! do
    pid = Process.whereis(Req.Finch)
    assert is_pid(pid) and Process.alive?(pid)
    {:message_queue_len, mailbox_messages} = Process.info(pid, :message_queue_len)
    %{pid: pid, mailbox_messages: mailbox_messages}
  end

  defp assert_finch_stable!(before) do
    after_health = finch_health!()
    assert after_health.pid == before.pid
    assert after_health.mailbox_messages <= before.mailbox_messages + 1
  end

  defp phase_name({name, _index}), do: Atom.to_string(name)
  defp phase_index({_name, index}), do: index
end
