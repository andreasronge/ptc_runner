defmodule PtcDemo.TestRunner.TestCase do
  @moduledoc """
  Shared test case definitions for both JSON and Lisp runners.

  This module centralizes test case definitions to avoid duplication between runners
  and provide a single source of truth for test specifications.

  ## Test Levels

  Tests are organized by difficulty:
  - **Level 1 (Basic)**: Simple counts, filters, aggregations
  - **Level 2 (Intermediate)**: Boolean fields, numeric comparisons, AND logic, extremes
  - **Level 3 (Advanced)**: Top-N, OR logic, multi-step, cross-dataset
  """

  @doc """
  Return test cases that work with both DSLs.

  These 13 tests cover different aspects of the DSL with progressive difficulty.
  Both JSON and Lisp runners use these same tests for fair comparison.

  Returns a list of test case maps with keys:
    - `:query` - the question to ask the LLM
    - `:expect` - expected return type (:integer, :number, :string, :list, :map)
    - `:constraint` - validation constraint (e.g., {:eq, 500}, {:between, 1, 100})
    - `:description` - human-readable description of what the test validates
  """
  @spec common_test_cases() :: [map()]
  def common_test_cases do
    [
      # ═══════════════════════════════════════════════════════════════════════════
      # LEVEL 1: Basic Operations (4 tests)
      # ═══════════════════════════════════════════════════════════════════════════

      # 1. Simple count
      %{
        query: "How many products are there?",
        expect: :integer,
        constraint: {:eq, 500},
        description: "Simple count of products"
      },

      # 2. Filtered count (equality on string field)
      %{
        query: "How many orders have status 'delivered'?",
        expect: :integer,
        constraint: {:between, 1, 999},
        description: "Filter by string equality + count"
      },

      # 3. Simple aggregation (sum)
      %{
        query: "What is the total revenue from all orders? (sum the total field)",
        expect: :number,
        constraint: {:gt, 1000},
        description: "Sum aggregation on numeric field"
      },

      # 4. Average calculation
      %{
        query: "What is the average product rating?",
        expect: :number,
        constraint: {:between, 1.0, 5.0},
        description: "Average aggregation"
      },

      # ═══════════════════════════════════════════════════════════════════════════
      # LEVEL 2: Intermediate Operations (4 tests)
      # ═══════════════════════════════════════════════════════════════════════════

      # 5. Boolean field filtering
      %{
        query: "How many employees work remotely?",
        expect: :integer,
        constraint: {:between, 1, 199},
        description: "Filter on boolean field"
      },

      # 6. Numeric comparison (greater than)
      %{
        query: "How many products cost more than $500?",
        expect: :integer,
        constraint: {:between, 0, 500},
        description: "Filter with numeric comparison (gt)"
      },

      # 7. Multiple conditions (AND logic)
      %{
        query: "How many orders over $1000 were paid by credit card?",
        expect: :integer,
        constraint: {:between, 0, 1000},
        description: "Filter with AND conditions"
      },

      # 8. Find extreme value (minimum)
      %{
        query: "What is the name of the cheapest product?",
        expect: :string,
        constraint: {:starts_with, "Product"},
        description: "Find min + extract field"
      },

      # ═══════════════════════════════════════════════════════════════════════════
      # LEVEL 3: Advanced Operations (4 tests)
      # ═══════════════════════════════════════════════════════════════════════════

      # 9. Top-N with sorting and field extraction
      %{
        query: "Get the names of the 3 most expensive products",
        expect: :list,
        constraint: {:length, 3},
        description: "Sort descending + take N + extract field"
      },

      # 10. Multiple conditions (OR logic)
      %{
        query: "How many orders are either cancelled or refunded?",
        expect: :integer,
        constraint: {:between, 0, 1000},
        description: "Filter with OR conditions"
      },

      # 11. Two-step filter + aggregate
      %{
        query: "What is the average salary of senior-level employees?",
        expect: :number,
        constraint: {:between, 50_000, 200_000},
        description: "Filter then aggregate"
      },

      # 12. Cross-dataset query (distinct values)
      %{
        query:
          "How many unique products have been ordered? (count distinct product_id values in orders)",
        expect: :integer,
        constraint: {:between, 1, 500},
        description: "Distinct + count (cross-dataset reasoning)"
      },

      # 13. Cross-dataset join query (harder)
      %{
        query:
          "What is the total expense amount for employees in the engineering department? " <>
            "(Find engineering employee IDs, then sum expenses for those employees)",
        expect: :number,
        constraint: {:gt, 0},
        description: "Cross-dataset join: filter employees, lookup expenses by employee_id, sum"
      }
    ]
  end

  @doc """
  Return test cases specific to Lisp DSL.

  These tests are now empty since all tests have been unified into common_test_cases/0.
  Kept for backwards compatibility - may be used for Lisp-only features in the future.

  Returns an empty list.
  """
  @spec lisp_specific_cases() :: [map()]
  def lisp_specific_cases do
    []
  end

  @doc """
  Return multi-turn test cases that require memory persistence.

  Multi-turn tests execute multiple queries in sequence without resetting state,
  allowing the test to store results from one query and use them in subsequent queries.

  Each test case has:
    - `:queries` - list of query strings to execute in sequence
    - `:expect` - expected return type of the final result
    - `:constraint` - validation constraint on the final result
    - `:description` - what the multi-turn test validates

  Returns a list of test case maps.
  """
  @spec multi_turn_cases() :: [map()]
  def multi_turn_cases do
    [
      # Multi-turn query (tests memory persistence between questions)
      %{
        queries: [
          "Count delivered orders and store the result in memory as delivered-count",
          "What percentage of all orders are delivered? Use memory/delivered-count and total order count."
        ],
        expect: :number,
        constraint: {:between, 1, 99},
        description: "Multi-turn: percentage calculation using stored count"
      },
      %{
        queries: [
          "Store the list of employees in the engineering department in memory as engineering-employees",
          "What is the average salary of the engineering employees stored in memory?"
        ],
        expect: :number,
        constraint: {:between, 50_000, 200_000},
        description: "Multi-turn: average salary using stored employee list"
      }
    ]
  end
end
