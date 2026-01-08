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
        query:
          "What is the average salary of senior-level employees? Return only the numeric value.",
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

  These tests use PTC-Lisp features that cannot be expressed in PTC-JSON:
  - `group-by` returning a map
  - `map` over map entries with destructuring
  - Complex `let` bindings with multiple aggregations

  Returns a list of Lisp-only test case maps.
  """
  @spec lisp_specific_cases() :: [map()]
  def lisp_specific_cases do
    [
      # ═══════════════════════════════════════════════════════════════════════════
      # LISP-ONLY: Advanced Features (not expressible in PTC-JSON)
      # ═══════════════════════════════════════════════════════════════════════════

      # 1. Group-by with map over map entries + destructuring
      %{
        query:
          "Which expense category has the highest total spending? " <>
            "Return a map with :highest (the top category with its stats) and :breakdown " <>
            "(all categories sorted by total descending). Each category should have " <>
            ":category, :total, :count, and :avg fields.",
        expect: :map,
        constraint: {:has_keys, [:highest, :breakdown]},
        description:
          "group-by + map over map with fn [[cat items]] destructuring, multiple aggregations"
      },

      # 2. Group-by with max aggregation
      %{
        query:
          "Which employee has the most rejected expense claims? " <>
            "Return their employee_id.",
        expect: :integer,
        constraint: {:between, 1, 200},
        description: "Group by employee_id, filter rejected, find max count"
      }
    ]
  end

  @doc """
  Return multi-turn test cases requiring observation and judgment.

  These are "open-form" tasks where the LLM must:
  1. Execute a program to gather data
  2. Observe and analyze the result
  3. Make a judgment call based on subjective criteria
  4. Execute a follow-up program using that judgment

  Each test case has:
    - `:query` - single query requiring multi-turn execution
    - `:expect` - expected return type of the final result
    - `:constraint` - validation constraint on the final result
    - `:max_turns` - maximum turns allowed (typically 2-3)
    - `:description` - what the multi-turn test validates

  Returns a list of test case maps.
  """
  @spec multi_turn_cases() :: [map()]
  def multi_turn_cases do
    [
      # Parallel processing (pmap) with tool calls
      %{
        query:
          "Search for 'security' policies, then fetch the full content for ALL found documents in parallel. " <>
            "Return a list of the full content of these documents.",
        expect: :list,
        constraint: {:gt_length, 0},
        max_turns: 2,
        description: "pmap + tool calls: search for multiple items then fetch details in parallel"
      },

      # Search-based task requiring query refinement
      # Must use the search tool to find documents, then narrow down results
      %{
        query:
          "Use the search tool to find the policy document that covers BOTH " <>
            "'remote work' AND 'expense reimbursement'. Return the document title.",
        expect: :string,
        constraint: {:eq, "Policy WFH-2024-REIMB"},
        max_turns: 6,
        description: "Multi-turn: search, narrow results, find document covering both topics"
      },

      # ═══════════════════════════════════════════════════════════════════════════
      # REASONING + COMPUTATION: Tests requiring both data processing and judgment
      # ═══════════════════════════════════════════════════════════════════════════

      # Temporal trend analysis - requires date parsing, grouping, delta calculation
      %{
        query:
          "Find the month with the highest order growth rate compared to the previous month. " <>
            "Orders have created_at dates in 'YYYY-MM-DD' format. " <>
            "Return a map with :month (e.g. '2024-03'), :growth_rate (as decimal, e.g. 0.25 for 25%), " <>
            "and :order_counts showing {:previous, :current} counts.",
        expect: :map,
        constraint: {:has_keys, [:month, :growth_rate, :order_counts]},
        max_turns: 4,
        description: "Temporal trend: group by month, calculate sequential growth rates, find max"
      }

      # ═══════════════════════════════════════════════════════════════════════════
      # TODO: Additional reasoning + computation tests to implement
      # ═══════════════════════════════════════════════════════════════════════════

      # TODO: Budget-Constrained Optimization
      # Query: "Select products to restock with a $50,000 budget, maximizing total
      #         expected revenue (price × stock as proxy for demand). Don't exceed budget.
      #         Return list of product IDs and total cost."
      # Requires: sorting by value ratio, greedy selection, constraint checking
      # Reasoning: Trade-off analysis, knowing when to stop adding items

      # TODO: Anomaly Detection with Explanation
      # Query: "Find employees whose expense patterns are unusual compared to their
      #         department peers. Return employee_id and explanation of why unusual."
      # Requires: group-by department, calculate stats (mean, stddev), compare individuals
      # Reasoning: Define "unusual" (>2 std dev?), articulate findings

      # TODO: Data Quality Assessment
      # Query: "Identify orders that have data integrity issues (e.g., quantity is 0,
      #         total is negative, or status is invalid). Return list of order IDs
      #         with the issue type for each."
      # Requires: validation logic, cross-field checks
      # Reasoning: Understanding what "integrity" means, categorizing issues

      # TODO: Hypothesis Testing Loop
      # Query: "Determine if remote employees have different expense patterns than
      #         office employees. Compare average expense amounts and category
      #         distributions. Return your methodology and conclusion as a map."
      # Requires: join employees→expenses, group-by remote status, statistical comparison
      # Reasoning: Form hypothesis, design test, interpret results

      # TODO: Dependency Resolution (would need new dataset with task dependencies)
      # Query: "Given project tasks with dependencies, return the optimal execution
      #         order (topological sort) and identify any circular dependencies."
      # Requires: graph traversal, cycle detection
      # Reasoning: Understanding dependency semantics, handling edge cases

      # TODO: Multi-Step ETL Pipeline
      # Query: "Create a customer value report: calculate total spend per customer
      #         from orders, segment into tiers (Bronze <$1000, Silver <$5000,
      #         Gold ≥$5000), return count per tier."
      # Requires: aggregation, classification logic, final summary
      # Reasoning: Breaking complex task into sequential steps

      # TODO: Comparative Period Analysis
      # Query: "Compare first half vs second half of 2024 orders: which product
      #         categories improved and which declined? Return categories with
      #         change direction and percentage."
      # Requires: date filtering, join orders→products, grouping, calculating changes
      # Reasoning: Defining "improvement" and "decline" thresholds

      # TODO: Resource Allocation with Minimum Threshold
      # Query: "Distribute $100,000 training budget across departments proportionally
      #         to headcount, but ensure no department gets less than $5,000.
      #         Return allocation per department."
      # Requires: proportional calculation, constraint handling, redistribution
      # Reasoning: Handling minimum threshold edge cases, iterative adjustment

      # TODO: Error Recovery Scenario (would need flaky tool simulation)
      # Query: "Calculate correlation between employee tenure and expense approval rate.
      #         Handle any incomplete or missing data gracefully."
      # Requires: join, aggregation, handling missing values
      # Reasoning: Recognizing incomplete data, deciding how to proceed

      # TODO: Search with Disambiguation
      # Query: "Find the policy about 'leaves'. If ambiguous (vacation vs environmental),
      #         search for both interpretations and report what you found."
      # Requires: multiple searches, result analysis
      # Reasoning: Recognizing ambiguity, exploring interpretations

      # TODO: Incremental Refinement (would need simulator tool)
      # Query: "Find the optimal discount percentage (0-50%) that maximizes
      #         revenue using the price_simulator tool. Use binary search."
      # Requires: iterative testing, optimization strategy
      # Reasoning: Search strategy, convergence criteria
    ]
  end
end
