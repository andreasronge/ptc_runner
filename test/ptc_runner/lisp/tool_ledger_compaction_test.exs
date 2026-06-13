defmodule PtcRunner.Lisp.ToolLedgerCompactionTest do
  @moduledoc """
  End-to-end proof of the in-eval tool-ledger bound (chunked-reads plan, the
  one core change): a program that calls a tool returning large results many
  times — as a paginated fold would — receives the FULL values for its
  computation, while `step.tool_calls` retains only bounded previews. This is
  what lets a long fold stay within the sandbox budget instead of accumulating
  every page in eval state.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  test "program gets full tool results while the ledger keeps only bounded previews" do
    # Each call returns a 5,000-element list; the program counts each (needs the
    # whole list) and sums the counts across 20 calls.
    tools = %{"page" => fn _args -> Enum.to_list(1..5_000) end}

    source = "(reduce + 0 (map (fn [i] (count (tool/page {:n i}))) (range 20)))"

    {:ok, step} = Lisp.run(source, tools: tools, max_tool_call_result_bytes: 200)

    # The program used the full 5,000-element results: 20 * 5000 = 100_000.
    assert step.return == 100_000

    # 20 calls recorded, every one truncated in the ledger.
    assert length(step.tool_calls) == 20
    assert Enum.all?(step.tool_calls, &(&1[:result_truncated] == true))

    # The ledger does NOT retain 20 * 5,000 elements: total stays O(calls * cap),
    # not O(total data). Unbounded, this would be ~100K integers (~800 KB+).
    # Measure RETAINED bytes (parents pinned by any sub-binary previews), not
    # just logical external_size, so a preview pinning a large parent is caught.
    retained =
      Enum.reduce(step.tool_calls, 0, fn call, acc ->
        acc + :erlang.external_size(call) + referenced_bytes(call[:result])
      end)

    assert retained < 100_000
  end

  defp referenced_bytes(bin) when is_binary(bin), do: :binary.referenced_byte_size(bin)
  defp referenced_bytes(_), do: 0

  test "the cap is honored for tool calls made inside a closure (HOF)" do
    # Each result is ~600 bytes (250 ints) — UNDER the 16 KB struct default but
    # OVER the custom 200-byte cap. The call runs inside (map (fn ...) ...), so
    # this only truncates if the cap propagates into the closure's eval context
    # (codex review P2). Without propagation it would silently retain full
    # results.
    tools = %{"page" => fn _args -> Enum.to_list(1..250) end}
    source = "(map (fn [i] (count (tool/page {:n i}))) (range 3))"

    {:ok, step} = Lisp.run(source, tools: tools, max_tool_call_result_bytes: 200)

    assert step.return == [250, 250, 250]
    assert length(step.tool_calls) == 3
    assert Enum.all?(step.tool_calls, &(&1[:result_truncated] == true))
  end
end
