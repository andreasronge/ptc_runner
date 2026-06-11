defmodule PtcRunner.Lisp.HeapRebaselineTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  @moduledoc """
  Sandbox heap re-baseline (docs/plans/sandbox-heap-rebaseline.md, P1+P3):
  host-granted data (tools env, `memory:`) must not consume the program's
  `:max_heap` budget, while program-acquired memory stays fail-closed.

  The refc payloads below are >64-byte binaries — the kind
  `include_shared_binaries: true` bills against the heap limit. Measured
  amplification of the baseline over the raw payload (2026-06-11, OTP 28):
  `memory:` ≈ 1.7×; tool grants ≈ 3.5× **per closure capturing the data**
  (`grant_over/1` below has two, so ≈ 7×). Payload sizes are chosen so each
  grant exceeded the 10 MB default budget before the re-baseline but fits
  the default `4 × max_heap` setup ceiling after it. Note the ceiling is
  checked at GC time and counts GC workspace (~2× the live baseline), so the
  practical default-ceiling capacity is about half its nominal value.
  """

  @default_max_heap 1_250_000

  # `count` refc binaries of `size` bytes each (size > 64 => off-heap).
  defp refc_rows(count, size) do
    Enum.map(1..count, fn i ->
      %{"name" => "row-#{i}", "payload" => :binary.copy(<<120>>, size), "n" => i}
    end)
  end

  defp grant_over(rows) do
    %{
      "lookup" => fn _args -> length(rows) end,
      "rows" => fn _args -> Enum.take(rows, 3) end
    }
  end

  describe "host-granted data is excluded from the program budget (F3 regression)" do
    test "tools closing over 2MB of refc binaries: trivial program passes at default budget" do
      tools = grant_over(refc_rows(6_667, 300))

      assert {:ok, step} =
               Lisp.run("(+ 1 2)", tools: tools, max_heap: @default_max_heap, timeout: 5_000)

      assert step.return == 3
    end

    test "tools closing over 2MB of refc binaries: grouping analysis passes at default budget" do
      tools = grant_over(refc_rows(6_667, 300))

      program = """
      (let [rows (tool/rows {})
            groups (group-by (fn [r] (get r "name")) rows)]
        (mapv (fn [hits] (count hits)) (vec (vals groups))))
      """

      assert {:ok, step} =
               Lisp.run(program, tools: tools, max_heap: @default_max_heap, timeout: 5_000)

      assert step.return == [1, 1, 1]
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
