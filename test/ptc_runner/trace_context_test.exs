defmodule PtcRunner.TraceContextTest do
  use ExUnit.Case, async: true

  alias PtcRunner.TraceContext

  setup do
    # Clean process dictionary before each test
    Process.delete(:ptc_trace_collectors)
    Process.delete(:ptc_trace_handler_ids)
    Process.delete(:ptc_telemetry_span_stack)
    Process.delete(:last_child_trace_id)
    Process.delete(:last_child_step)
    :ok
  end

  describe "collector stack" do
    test "push and pop a single collector" do
      collector = spawn(fn -> Process.sleep(:infinity) end)
      TraceContext.push_collector(collector, "handler-1")

      assert TraceContext.current_collector() == collector
      assert TraceContext.collectors() == [collector]

      assert {^collector, "handler-1"} = TraceContext.pop_collector()
      assert TraceContext.current_collector() == nil
      assert TraceContext.collectors() == []
    end

    test "nested push/pop maintains LIFO order" do
      c1 = spawn(fn -> Process.sleep(:infinity) end)
      c2 = spawn(fn -> Process.sleep(:infinity) end)

      TraceContext.push_collector(c1, "h1")
      TraceContext.push_collector(c2, "h2")

      assert TraceContext.current_collector() == c2
      assert TraceContext.collectors() == [c2, c1]

      assert {^c2, "h2"} = TraceContext.pop_collector()
      assert TraceContext.current_collector() == c1

      assert {^c1, "h1"} = TraceContext.pop_collector()
      assert TraceContext.current_collector() == nil
    end

    test "pop on empty stack returns nil" do
      assert TraceContext.pop_collector() == nil
    end

    test "remove_collector removes from middle of stack" do
      c1 = spawn(fn -> Process.sleep(:infinity) end)
      c2 = spawn(fn -> Process.sleep(:infinity) end)
      c3 = spawn(fn -> Process.sleep(:infinity) end)

      TraceContext.push_collector(c1, "h1")
      TraceContext.push_collector(c2, "h2")
      TraceContext.push_collector(c3, "h3")

      assert {^c2, "h2"} = TraceContext.remove_collector(c2)
      assert TraceContext.collectors() == [c3, c1]
    end

    test "remove_collector returns nil for unknown collector" do
      unknown = spawn(fn -> Process.sleep(:infinity) end)
      assert TraceContext.remove_collector(unknown) == nil
    end

    test "merge_collectors adds new collectors and deduplicates" do
      c1 = spawn(fn -> Process.sleep(:infinity) end)
      c2 = spawn(fn -> Process.sleep(:infinity) end)

      TraceContext.push_collector(c1, "h1")
      TraceContext.merge_collectors([c1, c2])

      collectors = TraceContext.collectors()
      assert c1 in collectors
      assert c2 in collectors
      assert length(collectors) == 2
    end

    test "merge_collectors filters dead processes" do
      c1 = spawn(fn -> Process.sleep(:infinity) end)
      dead = spawn(fn -> :ok end)
      # Wait for dead process to finish
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}

      TraceContext.merge_collectors([c1, dead])
      assert TraceContext.collectors() == [c1]
    end
  end

  describe "span stack" do
    test "push and pop spans" do
      assert TraceContext.push_span("span-1") == nil
      assert TraceContext.current_span_id() == "span-1"

      assert TraceContext.push_span("span-2") == "span-1"
      assert TraceContext.current_span_id() == "span-2"
      assert TraceContext.parent_span_id() == "span-1"

      assert TraceContext.pop_span() == "span-2"
      assert TraceContext.current_span_id() == "span-1"
    end

    test "pop on empty stack returns nil" do
      assert TraceContext.pop_span() == nil
    end

    test "current_span_id returns nil when empty" do
      assert TraceContext.current_span_id() == nil
    end

    test "parent_span_id returns nil with fewer than 2 spans" do
      assert TraceContext.parent_span_id() == nil
      TraceContext.push_span("span-1")
      assert TraceContext.parent_span_id() == nil
    end

    test "span_context returns full context" do
      assert TraceContext.span_context() == %{span_id: nil, parent_span_id: nil}

      TraceContext.push_span("s1")
      assert TraceContext.span_context() == %{span_id: "s1", parent_span_id: nil}

      TraceContext.push_span("s2")
      assert TraceContext.span_context() == %{span_id: "s2", parent_span_id: "s1"}
    end

    test "set_parent_span only sets on empty stack" do
      TraceContext.set_parent_span("parent-1")
      assert TraceContext.current_span_id() == "parent-1"

      # Second call should not override
      TraceContext.set_parent_span("parent-2")
      assert TraceContext.current_span_id() == "parent-1"
    end

    test "set_parent_span with nil is a no-op" do
      TraceContext.set_parent_span(nil)
      assert TraceContext.current_span_id() == nil
    end
  end

  describe "capture/attach cross-process propagation" do
    test "propagates context across Task.async" do
      c1 = spawn(fn -> Process.sleep(:infinity) end)
      TraceContext.push_collector(c1, "h1")
      TraceContext.push_span("span-parent")

      context = TraceContext.capture()

      task =
        Task.async(fn ->
          TraceContext.attach(context)
          {TraceContext.collectors(), TraceContext.current_span_id()}
        end)

      {child_collectors, child_span} = Task.await(task)
      assert c1 in child_collectors
      assert child_span == "span-parent"
    end

    test "attach with empty map is a no-op" do
      assert TraceContext.attach(%{}) == :ok
    end

    test "attach filters dead collectors" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}

      context = %{collectors: [dead], span_stack: []}
      TraceContext.attach(context)
      assert TraceContext.collectors() == []
    end
  end

  describe "child step pass-through" do
    test "put and take child result" do
      TraceContext.put_child_result("trace-123", %{return: 42})

      assert {"trace-123", %{return: 42}} = TraceContext.take_child_result()
    end

    test "take_child_result is one-shot (second call returns nil)" do
      TraceContext.put_child_result("trace-123", %{return: 42})

      assert {"trace-123", %{return: 42}} = TraceContext.take_child_result()
      assert TraceContext.take_child_result() == nil
    end

    test "take_child_result returns nil when nothing stored" do
      assert TraceContext.take_child_result() == nil
    end

    test "put_child_result with nil trace_id stores only step" do
      TraceContext.put_child_result(nil, %{return: 42})

      assert {nil, %{return: 42}} = TraceContext.take_child_result()
    end

    test "put_child_result with nil step stores only trace_id" do
      TraceContext.put_child_result("trace-123", nil)

      assert {"trace-123", nil} = TraceContext.take_child_result()
    end
  end
end
