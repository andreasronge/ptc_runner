defmodule PtcRunner.Lisp.BudgetRemainingTest do
  @moduledoc """
  Tests for the (budget/remaining) primitive.

  This primitive allows PTC-Lisp programs to query their remaining budget,
  enabling intelligent resource allocation decisions in RLM patterns.
  """

  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  describe "(budget/remaining)" do
    test "returns budget map when budget is provided" do
      budget = %{
        turns: 15,
        "work-turns": 10,
        "retry-turns": 5,
        depth: %{current: 1, max: 3},
        tokens: %{
          input: 5000,
          output: 2000,
          total: 7000,
          "cache-creation": 1000,
          "cache-read": 2000
        },
        "llm-requests": 3
      }

      {:ok, step} = Lisp.run("(budget/remaining)", budget: budget)

      assert step.return == budget
    end

    test "returns empty map when running standalone (no SubAgent)" do
      {:ok, step} = Lisp.run("(budget/remaining)")

      assert step.return == %{}
    end

    test "budget map can be accessed with keywords" do
      budget = %{
        turns: 15,
        "work-turns": 10
      }

      {:ok, step} = Lisp.run("(:turns (budget/remaining))", budget: budget)

      assert step.return == 15
    end

    test "hyphenated keys can be accessed with keyword syntax" do
      budget = %{
        turns: 15,
        "work-turns": 10,
        "retry-turns": 5,
        tokens: %{
          "cache-creation": 1000,
          "cache-read": 2000
        }
      }

      # Access hyphenated top-level key
      {:ok, step} = Lisp.run("(:work-turns (budget/remaining))", budget: budget)
      assert step.return == 10

      # Access another hyphenated top-level key
      {:ok, step} = Lisp.run("(:retry-turns (budget/remaining))", budget: budget)
      assert step.return == 5

      # Access nested hyphenated key
      {:ok, step} =
        Lisp.run("(:cache-creation (:tokens (budget/remaining)))", budget: budget)

      assert step.return == 1000
    end

    test "budget map can be used in conditional logic" do
      budget = %{turns: 5}

      {:ok, step} =
        Lisp.run(
          """
          (if (< (:turns (budget/remaining)) 10)
            :low-budget
            :high-budget)
          """,
          budget: budget
        )

      # Note: PTC-Lisp uses hyphenated keywords (Clojure-style)
      assert step.return == :"low-budget"
    end

    test "budget map with nil values returns empty map" do
      {:ok, step} = Lisp.run("(budget/remaining)", budget: nil)

      assert step.return == %{}
    end

    test "nested field access works on budget map" do
      budget = %{
        depth: %{current: 2, max: 5}
      }

      {:ok, step} =
        Lisp.run(
          """
          (let [b (budget/remaining)]
            (:current (:depth b)))
          """,
          budget: budget
        )

      assert step.return == 2
    end

    test "budget can be used to decide processing strategy" do
      # Simulating an RLM pattern where agent chooses between batch and individual processing
      low_budget = %{turns: 3}
      high_budget = %{turns: 20}

      code = """
      (let [b (budget/remaining)
            items [1 2 3 4 5]]
        (if (< (:turns b) (count items))
          :batch-mode
          :individual-mode))
      """

      {:ok, low_step} = Lisp.run(code, budget: low_budget)
      {:ok, high_step} = Lisp.run(code, budget: high_budget)

      # Note: PTC-Lisp uses hyphenated keywords (Clojure-style)
      assert low_step.return == :"batch-mode"
      assert high_step.return == :"individual-mode"
    end
  end

  describe "analyzer: budget namespace" do
    test "parses budget/remaining correctly" do
      {:ok, step} = Lisp.run("budget/remaining", budget: %{turns: 10})

      assert step.return == %{turns: 10}
    end

    test "rejects unknown budget functions with helpful error" do
      {:error, step} = Lisp.run("budget/other")

      assert step.fail.reason == :invalid_form
      assert step.fail.message =~ "Unknown budget function: budget/other"
      assert step.fail.message =~ "Available: budget/remaining"
    end

    test "rejects budget/foo with helpful error" do
      {:error, step} = Lisp.run("budget/foo")

      assert step.fail.reason == :invalid_form
      assert step.fail.message =~ "Unknown budget function: budget/foo"
    end
  end
end
