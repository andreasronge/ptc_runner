defmodule PtcDemo.TestRunner.TestCase do
  @moduledoc """
  Shared test case definitions for both JSON and Lisp runners.

  This module centralizes test case definitions to avoid duplication between runners
  and provide a single source of truth for test specifications.
  """

  @doc """
  Return test cases that work with both DSLs.

  These tests focus on basic operations like counting, filtering, and aggregations
  that are supported by both PTC-JSON and PTC-Lisp.

  Returns a list of test case maps with keys:
    - `:query` - the question to ask the LLM
    - `:expect` - expected return type (:integer, :number, :string, :list, :map)
    - `:constraint` - validation constraint (e.g., {:eq, 500}, {:between, 1, 100})
    - `:description` - human-readable description of what the test validates
  """
  @spec common_test_cases() :: [map()]
  def common_test_cases do
    [
      # Simple counts
      %{
        query: "How many products are there?",
        expect: :integer,
        constraint: {:eq, 500},
        description: "Total products should be 500"
      },
      %{
        query: "How many orders are there?",
        expect: :integer,
        constraint: {:eq, 1000},
        description: "Total orders should be 1000"
      },
      %{
        query: "How many employees are there?",
        expect: :integer,
        constraint: {:eq, 200},
        description: "Total employees should be 200"
      },

      # Filtered counts (should be > 0 given random distribution)
      %{
        query: "How many products are in the electronics category?",
        expect: :integer,
        constraint: {:between, 1, 499},
        description: "Electronics products should be between 1-499"
      },
      %{
        query: "How many employees work remotely?",
        expect: :integer,
        constraint: {:between, 1, 199},
        description: "Remote employees should be between 1-199"
      },

      # Aggregations
      %{
        query: "What is the total of all order amounts?",
        expect: :number,
        constraint: {:gt, 1000},
        description: "Total order revenue should be > 1000"
      },
      %{
        query: "What is the average employee salary?",
        expect: :number,
        constraint: {:between, 50_000, 200_000},
        description: "Average salary should be between 50k-200k"
      },

      # Combined filters
      %{
        query: "Count employees in engineering department",
        expect: :integer,
        constraint: {:between, 1, 199},
        description: "Engineering employees should be between 1-199"
      },

      # Expenses
      %{
        query: "Sum all travel expenses",
        expect: :number,
        constraint: {:gt, 0},
        description: "Travel expenses sum should be > 0"
      }
    ]
  end

  @doc """
  Return test cases specific to Lisp DSL.

  These tests exercise Lisp-specific features like:
    - Sort operations with comparators (sort-by with > or <)
    - Expense count and filtering
    - Cross-dataset queries (joining/correlating multiple datasets)

  Returns a list of test case maps with same structure as common_test_cases/0.
  """
  @spec lisp_specific_cases() :: [map()]
  def lisp_specific_cases do
    [
      # Expense count (Lisp-specific, not in JSON tests)
      %{
        query: "How many expenses are there?",
        expect: :integer,
        constraint: {:eq, 800},
        description: "Total expenses should be 800"
      },

      # Filtered counts (Lisp-specific variants)
      %{
        query: "How many orders have status delivered?",
        expect: :integer,
        constraint: {:between, 1, 999},
        description: "Delivered orders should be between 1-999"
      },
      %{
        query: "How many expenses are pending approval?",
        expect: :integer,
        constraint: {:between, 1, 799},
        description: "Pending expenses should be between 1-799"
      },

      # Aggregations (Lisp-specific variants)
      %{
        query: "What is the average product price?",
        expect: :number,
        constraint: {:between, 1, 10_000},
        description: "Average product price should be between 1-10000"
      },

      # Sort with comparator (tests the fix for sort-by with >)
      %{
        query: "Find the most expensive product and return its name",
        expect: :string,
        constraint: {:starts_with, "Product"},
        description: "Most expensive product name should start with 'Product'"
      },
      %{
        query: "Get the names of the top 3 highest paid employees",
        expect: :list,
        constraint: {:length, 3},
        description: "Should return exactly 3 employee names"
      },

      # Combined filters (Lisp-specific variant)
      %{
        query: "How many orders over 500 have status delivered?",
        expect: :integer,
        constraint: {:between, 0, 999},
        description: "High-value delivered orders should be 0-999"
      },

      # Cross-dataset queries (joining/correlating multiple datasets)
      %{
        query:
          "How many unique products have been ordered? (count distinct product_id values in orders)",
        expect: :integer,
        constraint: {:between, 1, 500},
        description: "Unique ordered products should be between 1-500"
      },
      %{
        query: "What is the total expense amount for employees in the engineering department?",
        expect: :number,
        constraint: {:gte, 0},
        description: "Engineering department expenses should be >= 0"
      },
      %{
        query:
          "How many employees have submitted expenses? (count unique employee_ids in expenses that exist in employees)",
        expect: :integer,
        constraint: {:between, 1, 200},
        description: "Employees with expenses should be between 1-200"
      }
    ]
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
