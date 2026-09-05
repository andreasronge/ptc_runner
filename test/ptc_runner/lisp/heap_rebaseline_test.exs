defmodule PtcRunner.Lisp.HeapRebaselineTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Format.SymbolRef

  @moduledoc """
  Sandbox heap re-baseline contract:
  host-granted data (tools env, `memory:`) must not consume the program's
  `:max_heap` budget, while program-acquired memory stays fail-closed.

  The refc payloads below are >64-byte binaries — the kind
  `include_shared_binaries: true` bills against the heap limit. Measured
  amplification of the baseline over the raw payload (2026-08-12, OTP 29):
  `memory:` ≈ 1.7×; tool grants ≈ 3.5× per closure capturing the data.
  The tool-grant regressions use an explicit 8 MB program budget and assert
  that the measured baseline exceeds it, while retaining margin below the
  default `4 × max_heap` setup ceiling; other cases retain the 10 MB default.
  The ceiling is checked at GC time and counts GC workspace (~2× the live
  baseline), so its practical capacity is about half its nominal value.
  """

  @default_max_heap 1_250_000
  @rebaseline_max_heap 1_000_000

  # `count` refc binaries of `size` bytes each (size > 64 => off-heap).
  defp refc_rows(count, size) do
    Enum.map(1..count, fn i ->
      %{"name" => "row-#{i}", "payload" => :binary.copy(<<120>>, size), "n" => i}
    end)
  end

  defp grant_over(rows) do
    %{"rows" => fn _args -> Enum.take(rows, 3) end}
  end

  # One sample is noisy in one direction only: the first call pays code
  # loading, and a garbage collection of the caller's heap, which holds the
  # granted map, is charged to the caller as reductions. An enumeration of the
  # map would show in every sample, so the minimum is the cost of the work.
  @reduction_samples 5

  defp caller_reductions(fun) do
    1..@reduction_samples
    |> Enum.map(fn _sample ->
      :erlang.garbage_collect()
      {:reductions, before_run} = Process.info(self(), :reductions)
      fun.()
      {:reductions, after_run} = Process.info(self(), :reductions)
      after_run - before_run
    end)
    |> Enum.min()
  end

  describe "host-granted data is excluded from the program budget (F3 regression)" do
    test "tools closing over 4MB of refc binaries: trivial program passes after re-baseline" do
      tools = grant_over(refc_rows(4_000, 1_000))

      assert {:ok, step} =
               Lisp.run("(+ 1 2)", tools: tools, max_heap: @rebaseline_max_heap, timeout: 5_000)

      assert step.return == 3
      assert step.usage.baseline_bytes > @rebaseline_max_heap * 8
    end

    test "tools closing over 4MB of refc binaries: grouping passes after re-baseline" do
      tools = grant_over(refc_rows(4_000, 1_000))

      program = """
      (let [rows (tool/rows {})
            groups (group-by (fn [r] (get r "name")) rows)]
        (mapv (fn [hits] (count hits)) (vec (vals groups))))
      """

      assert {:ok, step} =
               Lisp.run(program, tools: tools, max_heap: @rebaseline_max_heap, timeout: 5_000)

      assert step.return == [1, 1, 1]
      assert step.usage.baseline_bytes > @rebaseline_max_heap * 8
    end

    test "memory: carrying 9MB of refc binaries: trivial program passes at default budget" do
      memory = %{"cached" => refc_rows(30_000, 300)}

      assert {:ok, step} =
               Lisp.run("(+ 1 2)", memory: memory, max_heap: @default_max_heap, timeout: 5_000)

      assert step.return == 3
    end
  end

  describe "program-acquired memory stays fail-closed" do
    test "a program allocating beyond max_heap is killed with phase :eval diagnostics" do
      assert {:error, step} =
               Lisp.run("(count (vec (range 2000000)))",
                 max_heap: @default_max_heap,
                 timeout: 5_000
               )

      assert step.fail.reason == :memory_exceeded
      assert step.fail.details.phase == :eval
      assert is_integer(step.fail.details.baseline_bytes)
      assert step.fail.details.budget_bytes == @default_max_heap * 8
      assert step.fail.details.limit_bytes >= step.fail.details.budget_bytes
    end

    test "eval heap messages stay stable across different environment baselines" do
      program = "(count (vec (range 2000000)))"

      assert {:error, small} =
               Lisp.run(program,
                 context: %{"padding" => [0]},
                 filter_context: false,
                 max_heap: @default_max_heap,
                 setup_max_heap: 6_000_000,
                 timeout: 5_000
               )

      assert {:error, large} =
               Lisp.run(program,
                 context: %{"padding" => Enum.to_list(1..100_000)},
                 filter_context: false,
                 max_heap: @default_max_heap,
                 setup_max_heap: 6_000_000,
                 timeout: 5_000
               )

      assert small.fail.details.baseline_bytes != large.fail.details.baseline_bytes
      assert small.fail.message == large.fail.message

      assert small.fail.message ==
               "heap limit exceeded: program exceeded its evaluation heap budget"

      for step <- [small, large] do
        assert step.fail.details.phase == :eval
        assert step.fail.details.budget_bytes == @default_max_heap * 8

        assert step.fail.details.limit_bytes ==
                 step.fail.details.baseline_bytes + step.fail.details.budget_bytes
      end
    end

    test "an evaluation timeout preserves prepared native continuation memory" do
      owner = self()

      task =
        Task.async(fn ->
          Lisp.run("(tool/wait {})",
            memory: %{"saved" => %SymbolRef{name: "x"}},
            tools: %{
              "wait" => fn _arguments ->
                send(owner, :evaluation_started)
                receive do: (:never -> nil)
              end
            },
            timeout: 2_000
          )
        end)

      assert_receive :evaluation_started, 5_000
      assert {:error, step} = Task.await(task, 5_000)
      assert step.fail.reason == :timeout
      assert step.fail.details.phase == :eval
      assert step.memory == %{"saved" => {:symbol_ref, "x"}}
    end

    test "a grant larger than the setup ceiling is killed with phase :setup diagnostics" do
      tools = grant_over(refc_rows(20_000, 300))

      assert {:error, step} =
               Lisp.run("(+ 1 2)",
                 tools: tools,
                 max_heap: @default_max_heap,
                 setup_max_heap: 150_000,
                 timeout: 5_000
               )

      assert step.fail.reason == :memory_exceeded
      assert step.fail.details.phase == :setup
      assert step.fail.details.limit_bytes == 150_000 * 8
    end

    test "a setup memory kill does not re-project the oversized input memory" do
      memory = %{"cached" => refc_rows(20_000, 300)}

      assert {:error, step} =
               Lisp.run("(+ 1 2)",
                 memory: memory,
                 max_heap: @default_max_heap,
                 setup_max_heap: 150_000,
                 timeout: 5_000
               )

      assert step.fail.reason == :memory_exceeded
      assert step.fail.details.phase == :setup
      assert step.memory == %{}
    end

    test "context filtering runs under the setup heap ceiling" do
      large_charlist_value = List.duplicate(?x, 100_000)

      assert {:error, step} =
               Lisp.run("data/used",
                 context: %{"used" => large_charlist_value},
                 filter_context: true,
                 setup_max_heap: 20_000,
                 timeout: 5_000
               )

      assert step.fail.reason == :memory_exceeded
      assert step.fail.details.phase == :setup
    end

    test "a setup timeout does not re-project continuation memory in the caller" do
      expensive_setup_value = List.duplicate(?x, 200_000)

      assert {:error, step} =
               Lisp.run("data/used",
                 context: %{"used" => expensive_setup_value},
                 memory: %{preserved: "memory"},
                 filter_context: true,
                 setup_max_heap: 5_000_000,
                 timeout: 1
               )

      assert step.fail.reason == :timeout
      assert step.fail.details.phase == :setup
      assert step.memory == %{}
    end

    test "early errors fail closed when continuation-memory preparation exceeds its limits" do
      assert {:error, timeout_step} =
               Lisp.run("(", memory: %{preserved: "memory"}, timeout: 0)

      assert timeout_step.fail.reason == :timeout
      assert timeout_step.fail.details.phase == :setup
      assert timeout_step.memory == %{}

      assert {:error, heap_step} =
               Lisp.run("(",
                 memory: %{"rows" => Enum.to_list(1..100_000)},
                 setup_max_heap: 10_000,
                 timeout: 5_000
               )

      assert heap_step.fail.reason == :memory_exceeded
      assert heap_step.fail.details.phase == :setup
      assert heap_step.memory == %{}
    end

    test "context filtering removes ordinary unused datasets before the sandbox copy" do
      context = %{"unused" => Enum.to_list(1..200_000)}

      assert {:ok, step} =
               Lisp.run("nil",
                 context: context,
                 filter_context: true,
                 max_heap: 300_000,
                 setup_max_heap: 100_000,
                 timeout: 5_000
               )

      assert step.return == nil
    end

    test "context filtering does not copy high-cardinality unused scalar grants" do
      context = Map.new(1..50_000, fn index -> {"unused-#{index}", index} end)

      assert {:ok, step} =
               Lisp.run("nil",
                 context: context,
                 filter_context: true,
                 max_heap: 300_000,
                 setup_max_heap: 20_000,
                 timeout: 5_000
               )

      assert step.return == nil
    end

    test "compile scope checks do not enumerate high-cardinality continuation memory" do
      memory = Map.new(1..250_000, fn index -> {"unused-#{index}", index} end)

      baseline_reductions =
        caller_reductions(fn ->
          assert {:error, %{fail: %{reason: :unbound_var}}} =
                   Lisp.run_native("missing-binding", memory: %{})
        end)

      granted_reductions =
        caller_reductions(fn ->
          assert {:error, %{fail: %{reason: :unbound_var}}} =
                   Lisp.run_native("missing-binding", memory: memory)
        end)

      # Compare with the same work on this runtime, rather than pinning an
      # absolute OTP reduction delta. Retain a negative control: eagerly
      # constructing the old scope must still exceed the allowed overhead.
      budget = baseline_reductions * 1.5
      assert granted_reductions <= budget

      enumerated_reductions =
        caller_reductions(fn ->
          scope = memory |> Map.keys() |> MapSet.new()
          assert MapSet.size(scope) == map_size(memory)

          assert {:error, %{fail: %{reason: :unbound_var}}} =
                   Lisp.run_native("missing-binding", memory: memory)
        end)

      assert enumerated_reductions > budget
    end
  end

  describe "accounting pins (move when OTP accounting or the parser changes)" do
    test "memory: amplification: a 1MB payload's measured baseline stays under 5x + slack" do
      # Pins the 5x factor used in the MCP setup-ceiling formula
      # (4 * max_heap + 5 * words(max_session_memory_bytes)); session memory
      # measured at ~1.7x, so 5x leaves real headroom.
      payload_bytes = 3334 * 300
      memory = %{"cached" => refc_rows(3_334, 300)}

      assert {:ok, step} =
               Lisp.run("(+ 1 2)", memory: memory, max_heap: @default_max_heap, timeout: 5_000)

      baseline = step.usage.baseline_bytes
      assert is_integer(baseline)
      # Lower bound: the payload itself is referenced and billed.
      assert baseline >= payload_bytes
      assert baseline <= 5 * payload_bytes + 2_000_000
    end

    test "tools amplification: a single-closure 1MB grant stays under 5x + slack" do
      # A tool closure bills ~3.5x its captured payload (and each ADDITIONAL
      # closure capturing the same data bills again) — the reason callers
      # granting large tools must raise :setup_max_heap.
      payload_bytes = 3334 * 300
      rows = refc_rows(3_334, 300)
      tools = %{"lookup" => fn _args -> length(rows) end}

      assert {:ok, step} =
               Lisp.run("(+ 1 2)", tools: tools, max_heap: @default_max_heap, timeout: 5_000)

      baseline = step.usage.baseline_bytes
      assert is_integer(baseline)
      assert baseline >= payload_bytes
      assert baseline <= 5 * payload_bytes + 2_000_000
    end

    test "AST expansion: program-authored literals land in the baseline at a bounded factor" do
      # The baseline deliberately includes the parsed user program (spec
      # caveat); this pins source-bytes -> baseline-bytes expansion so the
      # max_program_bytes bound stays meaningful.
      literals = Enum.map_join(1..2_000, " ", fn i -> ~s("literal-string-value-#{i}") end)
      source = "(count [#{literals}])"
      source_bytes = byte_size(source)
      assert source_bytes > 50_000

      assert {:ok, step} = Lisp.run(source, max_heap: @default_max_heap, timeout: 5_000)
      assert step.return == 2_000

      baseline = step.usage.baseline_bytes
      assert is_integer(baseline)
      # 30x source size + 2MB fixed slack: generous, but a pathological
      # parser/analyzer change (quadratic metadata, duplicated subtrees)
      # blows straight past it.
      assert baseline <= 30 * source_bytes + 2_000_000
    end
  end
end
