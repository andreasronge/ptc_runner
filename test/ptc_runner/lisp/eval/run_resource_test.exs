defmodule PtcRunner.Lisp.Eval.RunResourceTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Eval.RunResources

  test "closure contexts do not allocate throwaway run resources" do
    :erlang.trace_pattern({RunResources, :new_counter, 0}, true, [:local])
    :erlang.trace(self(), true, [:call, :set_on_spawn])

    on_exit(fn ->
      :erlang.trace(self(), false, [:all])
      :erlang.trace_pattern({RunResources, :new_counter, 0}, false, [:local])
    end)

    assert {:ok, _step} =
             Lisp.run(
               "(let [mk (fn [x] (fn [y] (+ x y)))] " <>
                 "(reduce + 0 (map (mk 10) [1 2 3 4 5])))"
             )

    delivered = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^delivered}, 5_000

    # One budget counter and one activity counter belong to the sandbox owner.
    # Before child contexts received those references at construction time,
    # every closure call allocated two more and immediately overwrote them.
    assert count_allocations(0) == 2
  end

  defp count_allocations(count) do
    receive do
      {:trace, _pid, :call, {RunResources, :new_counter, []}} ->
        count_allocations(count + 1)
    after
      0 -> count
    end
  end
end
