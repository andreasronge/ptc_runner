defmodule PtcRunner.Lisp.Eval.ContextTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Eval.Context

  doctest PtcRunner.Lisp.Eval.Context

  describe "append_tool_call/2" do
    test "accumulates tool calls in reverse order" do
      ctx = Context.new(%{}, %{}, %{}, fn _, _ -> nil end, [])

      tool_call_1 = %{
        name: "add",
        args: %{a: 1, b: 2},
        result: 3,
        error: nil,
        timestamp: DateTime.utc_now(),
        duration_ms: 5
      }

      tool_call_2 = %{
        name: "multiply",
        args: %{a: 3, b: 4},
        result: 12,
        error: nil,
        timestamp: DateTime.utc_now(),
        duration_ms: 3
      }

      ctx = Context.append_tool_call(ctx, tool_call_1)
      ctx = Context.append_tool_call(ctx, tool_call_2)

      # Tool calls are prepended (most recent first)
      assert [^tool_call_2, ^tool_call_1] = ctx.tool_calls
    end

    test "starts with empty tool_calls list" do
      ctx = Context.new(%{}, %{}, %{}, fn _, _ -> nil end, [])
      assert ctx.tool_calls == []
    end
  end

  describe "append_tool_call/2 ledger compaction" do
    defp ctx_with_cap(cap),
      do: Context.new(%{}, %{}, %{}, fn _, _ -> nil end, [], max_tool_call_result_bytes: cap)

    defp tool_call(overrides) do
      Map.merge(
        %{
          name: "t",
          args: %{a: 1},
          result: 1,
          error: nil,
          timestamp: DateTime.utc_now(),
          duration_ms: 1
        },
        overrides
      )
    end

    test "small result/args pass through byte-for-byte unchanged" do
      ctx = ctx_with_cap(100)
      tc = tool_call(%{result: [1, 2, 3], args: %{path: "x"}})
      ctx = Context.append_tool_call(ctx, tc)
      assert [^tc] = ctx.tool_calls
    end

    test "large result is truncated to a bounded preview and marked" do
      ctx = ctx_with_cap(100)
      tc = tool_call(%{result: Enum.to_list(1..10_000)})
      ctx = Context.append_tool_call(ctx, tc)
      [stored] = ctx.tool_calls

      assert stored.result_truncated == true
      assert is_binary(stored.result)
      assert byte_size(stored.result) <= 100
      assert is_integer(stored.result_bytes) and stored.result_bytes > 100
    end

    test "preview is byte-bounded and valid UTF-8 for multibyte content" do
      ctx = ctx_with_cap(40)
      tc = tool_call(%{result: String.duplicate("é", 1_000)})
      ctx = Context.append_tool_call(ctx, tc)
      [stored] = ctx.tool_calls

      assert stored.result_truncated == true
      assert byte_size(stored.result) <= 40
      assert String.valid?(stored.result)
    end

    test "preview honors a cap smaller than the inspect floor" do
      ctx = ctx_with_cap(8)
      tc = tool_call(%{result: Enum.to_list(1..10_000)})
      ctx = Context.append_tool_call(ctx, tc)
      [stored] = ctx.tool_calls

      assert stored.result_truncated == true
      assert byte_size(stored.result) <= 8
    end

    test "int-heavy collection is sized by heap, not encoding, under the default cap" do
      # A 16k-int list ENCODES to ~16 KB but occupies ~256 KB of heap. The cap
      # must use the heap size (what the sandbox bills), or 50 such results in a
      # fold blow max_heap while each looks "small". Uses the default cap.
      ctx = Context.new(%{}, %{}, %{}, fn _, _ -> nil end, [])
      tc = tool_call(%{result: List.duplicate(0, 16_000)})
      ctx = Context.append_tool_call(ctx, tc)
      [stored] = ctx.tool_calls

      assert stored.result_truncated == true
      assert stored.result_bytes > 100_000
    end

    test "truncation preserves metadata, error, and child-trace fields" do
      ctx = ctx_with_cap(100)

      tc =
        tool_call(%{
          name: "read",
          result: Enum.to_list(1..10_000),
          duration_ms: 7,
          child_trace_id: "trace-1",
          child_step: %{some: :step}
        })

      ctx = Context.append_tool_call(ctx, tc)
      [stored] = ctx.tool_calls

      assert stored.name == "read"
      assert stored.error == nil
      assert stored.duration_ms == 7
      assert stored.child_trace_id == "trace-1"
      assert stored.child_step == %{some: :step}
    end

    test "args are left intact even when large (telemetry needs raw args)" do
      # TurnEvent.tool_call_summary/1 reads :args for upstream server/tool and
      # the canonical args hash; truncating it would break duplicate-fetch
      # detection. So :args is preserved raw regardless of size.
      ctx = ctx_with_cap(100)
      big_args = %{"server" => "fs", "tool" => "call", "blob" => String.duplicate("x", 5_000)}
      tc = tool_call(%{args: big_args, result: 42})
      ctx = Context.append_tool_call(ctx, tc)
      [stored] = ctx.tool_calls

      assert stored.args == big_args
      refute Map.has_key?(stored, :args_truncated)
      assert stored.result == 42
      refute Map.has_key?(stored, :result_truncated)
    end

    test "the stored preview does not pin the large inspect output" do
      # A list of many large strings inspects to a ~MB string. The stored
      # preview must be a standalone copy, not a sub-binary pinning that whole
      # inspect output — else a fold of such calls retains far more than the cap.
      big = for _ <- 1..50, do: String.duplicate("abcdefgh", 5_000)
      ctx = ctx_with_cap(200)
      ctx = Context.append_tool_call(ctx, tool_call(%{result: big}))
      [stored] = ctx.tool_calls

      assert stored.result_truncated == true
      assert byte_size(stored.result) <= 200
      # retained (not just logical) size of the preview is bounded
      assert :binary.referenced_byte_size(stored.result) <= 200
    end

    test "a mixed heap+binary result is sized by the sum of both parts" do
      # Each part is individually under the cap, but together they exceed it.
      # max() would keep it; the retained sum (heap + binary) must truncate.
      list = List.duplicate(0, 250)
      bin = :binary.copy(String.duplicate("x", 4_000))
      result = {list, bin}

      ctx = ctx_with_cap(5_000)
      ctx = Context.append_tool_call(ctx, tool_call(%{result: result}))
      [stored] = ctx.tool_calls

      assert stored.result_truncated == true
      assert stored.result_bytes > 5_000
    end

    test "a sub-binary that pins a large parent is truncated even when logically small" do
      # A 1 KB slice of a 100 KB refc binary stays a sub-binary that keeps the
      # whole parent alive (the sandbox bills shared binaries). Its logical size
      # is UNDER the cap, so only the pinned-parent check forces truncation —
      # otherwise a fold of such slices would accumulate the parents.
      parent = :binary.copy(String.duplicate("x", 100_000))
      slice = binary_part(parent, 0, 1_000)
      result = %{"line" => slice}

      # the term's flat heap is under the cap; only the pinned parent forces it
      assert :erts_debug.flat_size(result) * :erlang.system_info(:wordsize) < 5_000

      ctx = ctx_with_cap(5_000)
      ctx = Context.append_tool_call(ctx, tool_call(%{result: result}))
      [stored] = ctx.tool_calls

      assert stored.result_truncated == true
      assert stored.result_bytes >= 100_000
    end

    test "nil result (failed call) is not truncated" do
      ctx = ctx_with_cap(100)
      tc = tool_call(%{result: nil, error: "boom"})
      ctx = Context.append_tool_call(ctx, tc)
      assert [^tc] = ctx.tool_calls
    end

    test "a long fold of large results keeps the ledger bounded" do
      # Simulates a paginated read fold: many large page results. Each entry is
      # capped, so total ledger bytes stay O(pages * cap), not O(total data).
      ctx = ctx_with_cap(200)
      page = Enum.to_list(1..5_000)

      ctx =
        Enum.reduce(1..50, ctx, fn _, acc ->
          Context.append_tool_call(acc, tool_call(%{name: "read_lines", result: page}))
        end)

      assert length(ctx.tool_calls) == 50
      total = :erlang.external_size(ctx.tool_calls)
      # 50 entries, each result capped to ~200-byte preview, plus small metadata.
      assert total < 50 * 2_000
      assert Enum.all?(ctx.tool_calls, & &1.result_truncated)
    end
  end
end
