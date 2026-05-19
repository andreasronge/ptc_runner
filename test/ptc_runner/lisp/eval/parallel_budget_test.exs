defmodule PtcRunner.Lisp.Eval.ParallelBudgetTest do
  @moduledoc """
  Unit tests for `ParallelBudget` — the shared, lock-free slot semaphore
  that bounds the number of parallel pmap/pcalls workers alive at once.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Eval.ParallelBudget

  describe "acquire / release" do
    test "a fresh budget has all slots free" do
      budget = ParallelBudget.new(3)
      assert ParallelBudget.held(budget) == 0
      assert ParallelBudget.available(budget) == 3
    end

    test "try_acquire claims slots up to capacity, then reports :full" do
      budget = ParallelBudget.new(2)

      assert :ok = ParallelBudget.try_acquire(budget)
      assert :ok = ParallelBudget.try_acquire(budget)
      assert ParallelBudget.held(budget) == 2

      # Capacity exhausted — non-blocking, returns :full immediately.
      assert :full = ParallelBudget.try_acquire(budget)
      assert ParallelBudget.held(budget) == 2
    end

    test "release frees a slot back to the pool" do
      budget = ParallelBudget.new(1)

      assert :ok = ParallelBudget.try_acquire(budget)
      assert :full = ParallelBudget.try_acquire(budget)

      ParallelBudget.release(budget)
      assert ParallelBudget.available(budget) == 1

      # The freed slot can be re-acquired.
      assert :ok = ParallelBudget.try_acquire(budget)
    end

    test "held count returns to zero after every slot is released" do
      budget = ParallelBudget.new(3)

      for _ <- 1..3, do: assert(:ok = ParallelBudget.try_acquire(budget))
      assert ParallelBudget.held(budget) == 3

      for _ <- 1..3, do: ParallelBudget.release(budget)
      assert ParallelBudget.held(budget) == 0
      assert ParallelBudget.available(budget) == 3
    end

    test "release underflow raises and leaves the held count unchanged" do
      budget = ParallelBudget.new(2)

      assert_raise RuntimeError, "parallel budget release underflow", fn ->
        ParallelBudget.release(budget)
      end

      assert ParallelBudget.held(budget) == 0
      assert :ok = ParallelBudget.try_acquire(budget)
      assert ParallelBudget.held(budget) == 1
    end
  end

  describe "concurrent acquisition" do
    test "exactly `capacity` of N racing acquirers succeed" do
      capacity = 4
      racers = 40
      budget = ParallelBudget.new(capacity)
      test_pid = self()

      # Many processes race to acquire. The lock-free `add_get`
      # try-acquire must hand out no more than `capacity` slots total.
      for _ <- 1..racers do
        spawn(fn -> send(test_pid, {:result, ParallelBudget.try_acquire(budget)}) end)
      end

      results = for _ <- 1..racers, do: assert_receive({:result, r}) && r

      assert Enum.count(results, &(&1 == :ok)) == capacity
      assert Enum.count(results, &(&1 == :full)) == racers - capacity
      assert ParallelBudget.held(budget) == capacity
    end
  end
end
