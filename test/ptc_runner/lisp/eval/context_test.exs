defmodule PtcRunner.Lisp.Eval.ContextTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Eval.Context
  alias PtcRunner.Lisp.Eval.Effects

  doctest PtcRunner.Lisp.Eval.Context

  test "does not carry the retired trace context plumbing" do
    ctx = Context.new(%{}, %{}, %{}, fn _, _, _ -> nil end, [])

    refute Map.has_key?(Map.from_struct(ctx), :trace_context)
  end

  test "child contexts reuse the run-owned atomic resources" do
    parent =
      Context.new(%{}, %{}, %{}, fn _, _, _ -> nil end, [],
        prelude: nil,
        strict_transitive_calls: true,
        private_tool_authority?: true,
        loop_limit: 250
      )

    child = Context.new_child(parent, %{"scope" => "child"}, %{"x" => 1})

    assert child.tool_call_budget === parent.tool_call_budget
    assert child.tool_activity === parent.tool_activity
    assert child.loop_limit === parent.loop_limit
    assert child.strict_transitive_calls === parent.strict_transitive_calls
    assert child.private_tool_authority? === parent.private_tool_authority?
    assert child.user_ns == %{"scope" => "child"}
    assert child.env == %{"x" => 1}
  end

  test "child contexts inherit run state while resetting invocation state" do
    tool_exec = fn _, _, _ -> nil end
    tool_failure_token = make_ref()
    parallel_budget = self()
    prelude_exports = %{"demo/value" => {:callable, %{}}}
    prelude = %{artifact: true}
    effects = %Effects{prints: ["parent"]}

    parent =
      Context.new(%{"input" => 1}, %{"scope" => "parent"}, %{"old" => 0}, tool_exec, [:turn],
        tool_failure_token: tool_failure_token,
        failure_origin: :capability,
        return_origin: :direct_tool_call,
        origin_stack: [%{type: :user_closure}],
        prelude_caller_user_ns_stack: [%{"caller" => true}],
        loop_limit: 25,
        max_tool_calls: 4,
        max_print_length: 99,
        max_tool_call_result_bytes: 88,
        pmap_timeout: 77,
        parallel_deadline_cap: 66,
        pmap_max_concurrency: 3,
        max_heap: 55,
        worker_max_heap: 44,
        parallel_budget: parallel_budget,
        tools_meta: %{"tool" => %{private: true}},
        strict_data: true,
        data_grants: ["one"],
        missing_data_params_message: "missing",
        component_catalog: %{entries: []},
        inspect_only: true,
        strict_transitive_calls: true,
        private_tool_authority?: true,
        direct_namespaces: ["demo"],
        transitive_namespace_requirers: %{"dep" => ["component"]},
        prelude_export_mask: %{"demo" => ["demo/value"]},
        shipped_export_owners: %{"demo/value" => "component"},
        attached_component_ids: ["component"]
      )
      |> Map.merge(%{
        effects: effects,
        locals: MapSet.new(["parent-local"]),
        pmap_deadline: 33,
        prelude_exports: prelude_exports,
        prelude: prelude
      })

    child = Context.new_child(parent, %{"scope" => "child"}, %{"x" => 1})

    inherited_fields =
      Map.keys(Map.from_struct(parent)) --
        [
          :user_ns,
          :env,
          :effects,
          :locals,
          :max_print_length,
          :max_tool_call_result_bytes,
          :pmap_timeout,
          :parallel_deadline_cap,
          :pmap_max_concurrency,
          :pmap_deadline,
          :max_heap,
          :worker_max_heap,
          :parallel_budget,
          :tools_meta
        ]

    assert Map.take(child, inherited_fields) === Map.take(parent, inherited_fields)
    assert child.user_ns == %{"scope" => "child"}
    assert child.env == %{"x" => 1}
    assert child.effects == Effects.empty()
    assert child.locals == MapSet.new()
    assert child.max_print_length == 2_000
    assert child.max_tool_call_result_bytes == 16_384
    assert child.pmap_timeout == 5_000
    assert child.parallel_deadline_cap == nil
    assert child.pmap_max_concurrency == Context.default_pmap_max_concurrency()
    assert child.pmap_deadline == nil
    assert child.max_heap == nil
    assert child.worker_max_heap == nil
    assert child.parallel_budget == nil
    assert child.tools_meta == %{}

    overridden =
      Context.new_child(parent, %{}, %{},
        max_print_length: 9,
        max_tool_call_result_bytes: 8,
        pmap_timeout: 7,
        parallel_deadline_cap: 6,
        pmap_max_concurrency: 5,
        max_heap: 4,
        worker_max_heap: 3,
        parallel_budget: parallel_budget,
        tools_meta: %{"override" => %{}}
      )

    assert overridden.max_print_length == 9
    assert overridden.max_tool_call_result_bytes == 8
    assert overridden.pmap_timeout == 7
    assert overridden.parallel_deadline_cap == 6
    assert overridden.pmap_max_concurrency == 5
    assert overridden.max_heap == 4
    assert overridden.worker_max_heap == 3
    assert overridden.parallel_budget === parallel_budget
    assert overridden.tools_meta == %{"override" => %{}}
  end

  test "loop_limit defaults to nil and consume_loop_iteration is activation-local" do
    ctx = Context.new(%{}, %{}, %{}, fn _, _, _ -> nil end, [])
    assert ctx.loop_limit == nil
    assert Context.consume_loop_iteration(0, nil) == {:ok, 0}
    assert Context.consume_loop_iteration(0, 2) == {:ok, 1}
    assert Context.consume_loop_iteration(1, 2) == {:ok, 2}
    assert Context.consume_loop_iteration(2, 2) == {:error, :loop_limit_exceeded}
  end

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
      assert [^tool_call_2, ^tool_call_1] = ctx.effects.tool_calls
    end

    test "starts with empty tool_calls list" do
      ctx = Context.new(%{}, %{}, %{}, fn _, _ -> nil end, [])
      assert ctx.effects.tool_calls == []
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
      assert [^tc] = ctx.effects.tool_calls
    end

    test "large result is truncated to a bounded preview and marked" do
      ctx = ctx_with_cap(100)
      tc = tool_call(%{result: Enum.to_list(1..10_000)})
      ctx = Context.append_tool_call(ctx, tc)
      [stored] = ctx.effects.tool_calls

      assert stored.result_truncated == true
      assert is_binary(stored.result)
      assert byte_size(stored.result) <= 100
      assert is_integer(stored.result_bytes) and stored.result_bytes > 100
    end

    test "preview is byte-bounded and valid UTF-8 for multibyte content" do
      ctx = ctx_with_cap(40)
      tc = tool_call(%{result: String.duplicate("é", 1_000)})
      ctx = Context.append_tool_call(ctx, tc)
      [stored] = ctx.effects.tool_calls

      assert stored.result_truncated == true
      assert byte_size(stored.result) <= 40
      assert String.valid?(stored.result)
    end

    test "preview honors a cap smaller than the inspect floor" do
      ctx = ctx_with_cap(8)
      tc = tool_call(%{result: Enum.to_list(1..10_000)})
      ctx = Context.append_tool_call(ctx, tc)
      [stored] = ctx.effects.tool_calls

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
      [stored] = ctx.effects.tool_calls

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
      [stored] = ctx.effects.tool_calls

      assert stored.name == "read"
      assert stored.error == nil
      assert stored.duration_ms == 7
      assert stored.child_trace_id == "trace-1"
      assert stored.child_step == %{some: :step}
    end

    test "args are left intact even when large for canonical summarization" do
      # Effect consumers retain :args for capability identity and canonical
      # argument hashing, so :args is preserved raw regardless of size.
      ctx = ctx_with_cap(100)
      big_args = %{"server" => "fs", "tool" => "call", "blob" => String.duplicate("x", 5_000)}
      tc = tool_call(%{args: big_args, result: 42})
      ctx = Context.append_tool_call(ctx, tc)
      [stored] = ctx.effects.tool_calls

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
      [stored] = ctx.effects.tool_calls

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
      [stored] = ctx.effects.tool_calls

      assert stored.result_truncated == true
      assert stored.result_bytes > 5_000
    end

    test "a logically small ledger result is detached from its large binary parent" do
      parent = :binary.copy(String.duplicate("x", 100_000))
      slice = binary_part(parent, 0, 1_000)
      result = %{"line" => slice}

      assert :erts_debug.flat_size(result) * :erlang.system_info(:wordsize) < 5_000

      ctx = ctx_with_cap(5_000)
      ctx = Context.append_tool_call(ctx, tool_call(%{result: result}))
      [stored] = ctx.effects.tool_calls

      assert stored.result == result
      refute Map.has_key?(stored, :result_truncated)
      assert :binary.referenced_byte_size(stored.result["line"]) == 1_000
    end

    test "nil result (failed call) is not truncated" do
      ctx = ctx_with_cap(100)
      tc = tool_call(%{result: nil, error: "boom"})
      ctx = Context.append_tool_call(ctx, tc)
      assert [^tc] = ctx.effects.tool_calls
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

      assert length(ctx.effects.tool_calls) == 50
      total = :erlang.external_size(ctx.effects.tool_calls)
      # 50 entries, each result capped to ~200-byte preview, plus small metadata.
      assert total < 50 * 2_000
      assert Enum.all?(ctx.effects.tool_calls, & &1.result_truncated)
    end
  end
end
