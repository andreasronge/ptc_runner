defmodule PtcRunner.Lisp.Eval.CaptureTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Eval.Apply
  alias PtcRunner.Lisp.Eval.Capture
  alias PtcRunner.Lisp.Eval.Context
  alias PtcRunner.Lisp.Eval.Effects

  test "run_value treats outcome-shaped tuples as plain values and cleans up" do
    context = context()

    assert {:ok, {:error, :plain_value}, ^context} =
             Capture.run_value(context, fn -> {:error, :plain_value} end)

    assert Capture.empty?()
  end

  test "materialization replaces effects idempotently and exposes live writes" do
    baseline = %{context() | effects: %Effects{prints: ["baseline"]}}

    assert {:ok, :done, final_context} =
             Capture.run_value(baseline, fn ->
               _context = Context.append_print(baseline, "captured")
               materialized = Capture.materialize_context(baseline)

               assert materialized.effects.prints == ["captured", "baseline"]
               assert Capture.materialize_context(materialized) == materialized
               :done
             end)

    assert final_context.effects.prints == ["captured", "baseline"]
    assert Capture.empty?()
  end

  test "nested frames merge their delta once into the parent" do
    context = context()

    assert {:ok, :outer, final_context} =
             Capture.run_value(context, fn ->
               _context = Context.append_print(context, "outer-before")
               nested_baseline = Capture.materialize_context(context)

               assert {:ok, :inner, inner_context} =
                        Capture.run_value(nested_baseline, fn ->
                          _context = Context.append_print(nested_baseline, "inner")
                          :inner
                        end)

               assert inner_context.effects.prints == ["inner", "outer-before"]

               materialized = Capture.materialize_context(context)
               assert materialized.effects.prints == ["inner", "outer-before"]
               :outer
             end)

    assert final_context.effects.prints == ["inner", "outer-before"]
    assert Capture.empty?()
  end

  test "ordinary exceptions return their captured context and clean up" do
    context = context()

    assert {:raise, :error, %RuntimeError{message: "boom"}, _stacktrace, final_context} =
             Capture.run_value(context, fn ->
               _context = Context.append_print(context, "before raise")
               raise "boom"
             end)

    assert final_context.effects.prints == ["before raise"]
    assert Capture.empty?()
  end

  test "context-bearing throws are normalized from the authoritative frame" do
    context = context()

    assert {:raise, :throw, {:return_signal, 7, thrown_context}, _stacktrace, final_context} =
             Capture.run_value(context, fn ->
               thrown_context = Context.append_print(context, "before return")
               throw({:return_signal, 7, thrown_context})
             end)

    assert thrown_context.effects.prints == ["before return"]
    assert final_context.effects.prints == ["before return"]
    assert Capture.empty?()
  end

  test "run_outcome normalizes the returned context effects" do
    context = context()

    assert {:ok, 42, final_context} =
             Capture.run_outcome(context, fn ->
               updated = Context.append_print(context, "outcome")
               {:ok, 42, updated}
             end)

    assert final_context.effects.prints == ["outcome"]
    assert Capture.empty?()
  end

  test "direct converted prelude closure preserves its caller baseline without capture" do
    context = Context.append_print(context(), "baseline")
    closure = {:closure, [], :body, %{}, [], %{prelude_ns: "api"}}

    fun =
      Apply.closure_to_fun(closure, context, fn :body, closure_context ->
        throw({:return_signal, 7, closure_context})
      end)

    assert {:return_signal, 7, thrown_context} = catch_throw(fun.())
    assert thrown_context.effects.prints == ["baseline"]
    assert Capture.empty?()
  end

  defp context, do: Context.new(%{}, %{}, %{}, fn _, _, _ -> nil end, [])
end
