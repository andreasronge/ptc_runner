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
            "Return the top category with its stats as :highest, and all categories " <>
            "sorted by total descending as :breakdown. Each category should have " <>
            ":category, :total, :count, and :avg fields.",
        expect: :map,
        signature: "(question :string) -> {highest :map, breakdown [:map]}",
        constraint: {:has_keys, [:highest, :breakdown]},
        max_turns: 3,
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
        max_turns: 3,
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
            "Return :month (e.g. '2024-03'), :growth_rate (as decimal, e.g. 0.25 for 25%), " <>
            "and :order_counts with :previous and :current counts.",
        expect: :map,
        signature:
          "(question :string) -> {month :string, growth_rate :float, order_counts {previous :int, current :int}}",
        constraint: {:has_keys, [:month, :growth_rate, :order_counts]},
        max_turns: 4,
        description: "Temporal trend: group by month, calculate sequential growth rates, find max"
      },

      # Budget-constrained optimization - greedy selection with constraint checking
      %{
        query:
          "Select products to restock with a $50,000 budget, maximizing total expected revenue " <>
            "(price × stock as proxy for demand). Each product's cost is its price. Don't exceed budget. " <>
            "Use a greedy approach: sort by value ratio (expected_revenue / price = stock), " <>
            "then select products until budget is exhausted. " <>
            "Return :product_ids (selected IDs), :total_cost (sum of prices), " <>
            "and :expected_revenue (sum of price × stock for selected products).",
        expect: :map,
        signature:
          "(question :string) -> {product_ids [:int], total_cost :float, expected_revenue :float}",
        constraint: {:has_keys, [:product_ids, :total_cost, :expected_revenue]},
        max_turns: 5,
        description:
          "Budget optimization: greedy selection by value ratio with constraint checking"
      },

      # ═══════════════════════════════════════════════════════════════════════════
      # EXPLORATION-HEAVY: Tests requiring tool output inspection before answering
      # These are specifically designed to test premature-answer resistance.
      # ═══════════════════════════════════════════════════════════════════════════

      # Decoy first result: the first search result for "training" is NOT the right answer.
      # The correct document is about certification reimbursement, not training budget.
      # The model must fetch content to distinguish them.
      %{
        query:
          "Find the policy document about reimbursement for professional certifications. " <>
            "Search for relevant documents, then fetch the content of candidates to find " <>
            "the one specifically about certification reimbursement (not training budget). " <>
            "Return the document ID.",
        expect: :string,
        constraint: {:eq, "DOC-020"},
        max_turns: 6,
        description: "Decoy: first search result is plausible but wrong, must fetch to verify"
      },

      # Multi-document intersection: find the department that appears in BOTH
      # security AND compliance documents. Must search twice and intersect.
      %{
        query:
          "Search for documents about 'security', then search for documents about 'compliance'. " <>
            "Find which department has documents in BOTH categories. " <>
            "Return the department name.",
        expect: :string,
        constraint: {:eq, "IT"},
        max_turns: 6,
        description: "Multi-search intersection: two searches, find overlapping department"
      },

      # Required query refinement: search for "leave" returns multiple types
      # (PTO, parental, sabbatical). Must narrow to find the one about sabbatical eligibility.
      %{
        query:
          "Search for policies about 'leave'. Multiple types will come back. " <>
            "Find the one specifically about sabbatical leave and return its title.",
        expect: :string,
        constraint: {:eq, "Sabbatical Leave Program"},
        max_turns: 6,
        description: "Query refinement: broad search returns multiple hits, must narrow"
      },

      # Must inspect tool output: fetch two documents and compare their content
      # to answer a question that can't be answered from titles/topics alone.
      %{
        query:
          "Fetch documents DOC-001 and DOC-002. Compare their content. " <>
            "Which one mentions 'ergonomics'? Return its document ID.",
        expect: :string,
        constraint: {:eq, "DOC-002"},
        max_turns: 4,
        description: "Must-inspect: answer requires reading fetched document content"
      },

      # Cross-dataset verification: the model must check employee data AND
      # expense data to verify a claim. Can't answer from one dataset alone.
      %{
        query:
          "Find the department with the most rejected expense claims. " <>
            "You need to: 1) get all rejected expenses, 2) join with employees to get departments, " <>
            "3) count per department. Return a map with :department and :count.",
        expect: :map,
        signature: "(question :string) -> {department :string, count :int}",
        constraint: {:has_keys, [:department, :count]},
        max_turns: 4,
        description: "Cross-dataset: must join expenses→employees and aggregate, can't guess"
      }

      # ═══════════════════════════════════════════════════════════════════════════
      # TODO: Additional reasoning + computation tests to implement
      # ═══════════════════════════════════════════════════════════════════════════

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

  @doc """
  Return plan-mode test cases for benchmarking sequential vs flexible execution.

  These are multi-step analysis tasks where the LLM receives an explicit plan
  (list of step descriptions) and executes them using plan mode.

  Each test case has:
    - `:query` - the question to answer
    - `:plan` - list of step descriptions for the plan
    - `:expect` - expected return type
    - `:constraint` - validation constraint
    - `:max_turns` - maximum turns allowed
    - `:description` - what the test validates

  Returns a list of plan-mode test case maps.
  """
  @spec plan_cases() :: [map()]
  def plan_cases do
    [
      # ETL Pipeline: customer spend aggregation → tier segmentation → count per tier
      %{
        query:
          "Create a customer value report: calculate total spend per customer " <>
            "from orders, segment into tiers (Bronze <$1000, Silver <$5000, " <>
            "Gold >= $5000), return count per tier as a map with keys :bronze, :silver, :gold.",
        plan: [
          "Aggregate total spend per customer_id from orders (sum the :total field)",
          "Segment customers into tiers: Bronze (<1000), Silver (<5000), Gold (>=5000)",
          "Count customers in each tier and return as a map with keys :bronze, :silver, :gold"
        ],
        expect: :map,
        constraint: {:has_keys, [:bronze, :silver, :gold]},
        max_turns: 6,
        description: "Plan: ETL pipeline - aggregate, segment, summarize"
      },

      # Comparative Period Analysis: Q1 vs Q2 order totals and percentage change
      %{
        query:
          "Compare Q1 (Jan-Mar) vs Q2 (Apr-Jun) 2024 order totals. " <>
            "Orders have created_at dates in 'YYYY-MM-DD' format. " <>
            "Return a map with :q1_total, :q2_total, and :change_pct (percentage change as decimal).",
        plan: [
          "Filter orders to Q1 2024 (created_at between 2024-01-01 and 2024-03-31) and sum totals",
          "Filter orders to Q2 2024 (created_at between 2024-04-01 and 2024-06-30) and sum totals",
          "Calculate percentage change ((q2 - q1) / q1) and return map with :q1_total, :q2_total, :change_pct"
        ],
        expect: :map,
        constraint: {:has_keys, [:q1_total, :q2_total, :change_pct]},
        max_turns: 6,
        description: "Plan: Comparative period analysis - Q1 vs Q2"
      },

      # Remote vs Office Expenses: cross-dataset join, group averages, boolean comparison
      %{
        query:
          "Compare average expense amounts between remote and office employees. " <>
            "Join employees with expenses by employee_id, group by remote status, " <>
            "calculate average expense amount for each group. " <>
            "Return a map with :remote_avg, :office_avg, and :remote_higher (boolean).",
        plan: [
          "Get employee IDs grouped by remote status (true/false) from employees dataset",
          "For each group, find matching expenses by employee_id and calculate average amount",
          "Return map with :remote_avg, :office_avg, and :remote_higher (boolean comparing the two)"
        ],
        expect: :map,
        constraint: {:has_keys, [:remote_avg, :office_avg, :remote_higher]},
        max_turns: 6,
        description: "Plan: Remote vs office expenses - cross-dataset join"
      },

      # ═══════════════════════════════════════════════════════════════════════════
      # HARDER PLAN CASES: designed to differentiate sequential vs flexible
      # ═══════════════════════════════════════════════════════════════════════════

      # Independent sub-tasks: 6 department stats computed independently, then combined.
      # Flexible mode can pick any department first; sequential is locked to plan order.
      # Tests whether the LLM tracks 6 independent sub-results and combines them correctly.
      %{
        query:
          "For each of the 6 departments (engineering, sales, marketing, support, hr, finance), " <>
            "calculate: headcount, average salary, and total approved expense amount " <>
            "(join employees→expenses by employee_id, filter status='approved'). " <>
            "Return a map keyed by department name, where each value is a map with " <>
            ":headcount, :avg_salary, and :total_approved_expenses.",
        plan: [
          "Calculate headcount and average salary for the engineering department",
          "Calculate total approved expense amount for engineering (join employees→expenses by employee_id, filter status='approved')",
          "Calculate headcount and average salary for the sales department",
          "Calculate total approved expense amount for sales",
          "Calculate headcount and average salary for the marketing department",
          "Calculate total approved expense amount for marketing",
          "Calculate headcount and average salary for the support department",
          "Calculate total approved expense amount for support",
          "Calculate headcount and average salary for the hr department",
          "Calculate total approved expense amount for hr",
          "Calculate headcount and average salary for the finance department",
          "Calculate total approved expense amount for finance",
          "Combine all department results into a single map keyed by department name"
        ],
        expect: :map,
        constraint: {:has_keys, [:engineering, :sales, :marketing, :support, :hr, :finance]},
        max_turns: 16,
        description: "Plan: 6-department stats - independent sub-tasks"
      },

      # Multi-hop pipeline: 5-step cross-dataset join chain.
      # Each step genuinely depends on the previous — sequential should match well,
      # flexible might try to skip ahead and fail.
      %{
        query:
          "Find the top 3 product categories by total revenue from delivered orders, " <>
            "then for each category find how many distinct employees (from any department) " <>
            "have submitted approved expenses in the same month as those delivered orders. " <>
            "Steps: (1) filter delivered orders, (2) join with products to get categories, " <>
            "(3) aggregate revenue per category and pick top 3, " <>
            "(4) collect the months of delivered orders for those top 3 categories, " <>
            "(5) count distinct employees with approved expenses in those months. " <>
            "Return a list of maps with :category, :revenue, and :employee_count.",
        plan: [
          "Filter orders to status='delivered' and collect their totals, product_ids, and created_at months",
          "Join delivered orders with products by product_id to get the category for each order",
          "Aggregate total revenue per category and select the top 3 categories by revenue",
          "For the top 3 categories, collect all unique months (YYYY-MM) of their delivered orders",
          "Count distinct employee_ids with approved expenses (status='approved') in those months",
          "Return a list of maps with :category, :revenue, and :employee_count for each top category"
        ],
        expect: :list,
        constraint: {:length, 3},
        max_turns: 10,
        description: "Plan: 5-hop cross-dataset pipeline - products→orders→expenses"
      },

      # Threshold search with early exit potential.
      # Check departments one-by-one for a condition. Flexible mode can pick the most
      # promising department first; sequential must follow the plan order.
      # The condition is: department where average salary of remote senior+ employees > $150k.
      %{
        query:
          "Find ALL departments where remote senior-level employees (level is 'senior', 'lead', " <>
            "'manager', or 'director') have an average salary above $120,000. " <>
            "Check each department independently. " <>
            "Return a map with :qualifying_departments (list of department names) " <>
            "and :department_details (map of department name → average salary for qualifying ones).",
        plan: [
          "Check engineering: filter remote senior+ employees, calculate avg salary, record if > $120k",
          "Check sales: filter remote senior+ employees, calculate avg salary, record if > $120k",
          "Check marketing: filter remote senior+ employees, calculate avg salary, record if > $120k",
          "Check support: filter remote senior+ employees, calculate avg salary, record if > $120k",
          "Check hr: filter remote senior+ employees, calculate avg salary, record if > $120k",
          "Check finance: filter remote senior+ employees, calculate avg salary, record if > $120k",
          "Collect qualifying departments and return map with :qualifying_departments and :department_details"
        ],
        expect: :map,
        constraint: {:has_keys, [:qualifying_departments, :department_details]},
        max_turns: 10,
        description: "Plan: Department threshold search - independent checks"
      }
    ]
  end

  @doc """
  Return M0 validation cases for meta-learner failure clustering.

  These 25 tests are organized into 5 capability clusters. Within each cluster,
  tests require the same underlying capability at varying difficulty. When agents
  fail, failures should cluster by capability gap, enabling M0 to identify which
  abstraction is missing.

  ## Clusters

  - **String extraction**: substring, parsing, pattern matching on field values
  - **Date arithmetic**: temporal filtering, duration calculation, period comparison
  - **Nested aggregation**: group-then-aggregate, multi-level summaries, ranked groups
  - **Set operations**: intersection, difference, symmetric difference across datasets
  - **Conditional logic**: branching based on computed values, tiered classification
  """
  @spec m0_validation_cases() :: [map()]
  def m0_validation_cases do
    [
      # ═══════════════════════════════════════════════════════════════════════════
      # CLUSTER A: String Extraction and Manipulation (5 tests)
      # Capability gap: operating on string field values
      # ═══════════════════════════════════════════════════════════════════════════

      # A1. Extract numeric part from product name ("Product 42" → 42)
      %{
        query:
          "Extract the numeric ID from the name of the most expensive product. " <>
            "Product names are like 'Product 42'. Return just the number as an integer.",
        expect: :integer,
        constraint: {:between, 1, 500},
        description: "String extraction: parse number from product name field"
      },

      # A2. Filter by string prefix pattern
      %{
        query:
          "How many products have an ID (from their name 'Product N') that is " <>
            "a multiple of 10? E.g. Product 10, Product 20, etc.",
        expect: :integer,
        constraint: {:eq, 50},
        description: "String parsing + numeric filter: extract ID, check divisibility"
      },

      # A3. Categorize by first letter of department
      %{
        query:
          "Group employees by the first letter of their department name. " <>
            "Return a map where keys are single letters and values are employee counts. " <>
            "E.g. {:e 50, :s 40, :m 30, :h 20, :f 15}",
        expect: :map,
        constraint: {:has_keys, [:e, :s, :m, :h, :f]},
        description: "String extraction: first character grouping"
      },

      # A4. Build composite key from multiple fields
      %{
        query:
          "For each department, find the employee with the highest salary. " <>
            "Return a list of strings in the format 'department:employee_name' " <>
            "sorted alphabetically by department.",
        expect: :list,
        constraint: {:length, 6},
        description: "String concatenation: build composite key from fields"
      },

      # A5. Parse date string to extract month
      %{
        query:
          "How many distinct months appear in the orders dataset? " <>
            "Orders have created_at in 'YYYY-MM-DD' format. Count unique YYYY-MM values.",
        expect: :integer,
        constraint: {:between, 1, 12},
        description: "String parsing: extract month from date string"
      },

      # ═══════════════════════════════════════════════════════════════════════════
      # CLUSTER B: Date Arithmetic and Temporal Reasoning (5 tests)
      # Capability gap: comparing, filtering, and computing with date strings
      # ═══════════════════════════════════════════════════════════════════════════

      # B1. Simple date range filter
      %{
        query:
          "How many orders were created in the first quarter of 2024 " <>
            "(January through March)? Filter where created_at starts with '2024-01', '2024-02', or '2024-03'.",
        expect: :integer,
        constraint: {:between, 1, 1000},
        description: "Date filter: Q1 range using string prefix matching"
      },

      # B2. Find most recent record
      %{
        query:
          "What is the ID of the most recently created order? " <>
            "Compare created_at date strings (YYYY-MM-DD format sorts lexicographically).",
        expect: :integer,
        constraint: {:between, 1, 1000},
        description: "Date comparison: find max date via string sorting"
      },

      # B3. Count per month
      %{
        query:
          "Which month of 2024 had the most orders? Return the month as a string " <>
            "like '2024-06'. Extract month from created_at (first 7 characters).",
        expect: :string,
        constraint: {:starts_with, "2024-"},
        description: "Date grouping: group by month substring, find max count"
      },

      # B4. Compare two periods
      %{
        query:
          "Compare total expense amounts between the first half (months 01-06) " <>
            "and second half (months 07-12) of 2024. Expense dates are in 'YYYY-MM-DD' format. " <>
            "Return a map with :first_half_total, :second_half_total, and :difference.",
        expect: :map,
        constraint: {:has_keys, [:first_half_total, :second_half_total, :difference]},
        description: "Date arithmetic: period comparison with aggregation"
      },

      # B5. Temporal join — orders and expenses in same month
      %{
        query:
          "Find months where both orders and expenses exist. For each such month, " <>
            "return the order count and expense count. Return as a list of maps with " <>
            ":month, :order_count, :expense_count. Sort by month.",
        expect: :list,
        constraint: {:gt_length, 0},
        max_turns: 3,
        description: "Date join: match records across datasets by month substring"
      },

      # ═══════════════════════════════════════════════════════════════════════════
      # CLUSTER C: Nested Aggregation / Multi-level Grouping (5 tests)
      # Capability gap: composing group-by with aggregation functions
      # ═══════════════════════════════════════════════════════════════════════════

      # C1. Group and count
      %{
        query:
          "How many products are in each category? Return a map where keys are " <>
            "category names and values are counts.",
        expect: :map,
        constraint: {:has_keys, [:electronics, :clothing, :food, :books, :sports, :home, :toys]},
        description: "Group-by + count: single-level grouping"
      },

      # C2. Group and aggregate
      %{
        query:
          "For each product category, calculate the average price. " <>
            "Return a map of category name to average price.",
        expect: :map,
        constraint: {:has_keys, [:electronics, :clothing, :food, :books, :sports, :home, :toys]},
        description: "Group-by + average: single-level with numeric aggregation"
      },

      # C3. Two-level grouping
      %{
        query:
          "Group employees by department, then within each department count " <>
            "how many are at each level (junior, mid, senior, lead, manager, director). " <>
            "Return a map of department → map of level → count. " <>
            "Only include the engineering department.",
        expect: :map,
        constraint: {:has_keys, [:engineering]},
        max_turns: 3,
        description: "Nested group-by: two-level grouping with counts"
      },

      # C4. Group + filter + aggregate
      %{
        query:
          "For each expense category, find the approval rate (approved count / total count). " <>
            "Return a map of category name to approval rate as a decimal between 0 and 1.",
        expect: :map,
        constraint: {:has_keys, [:travel, :equipment, :software, :meals, :office, :training]},
        max_turns: 2,
        description: "Group-by + conditional count + division: approval rate per group"
      },

      # C5. Ranked groups with limit
      %{
        query:
          "Find the top 3 departments by total salary expenditure (sum of all employee salaries). " <>
            "Return a list of maps with :department and :total_salary, sorted descending by total.",
        expect: :list,
        constraint: {:length, 3},
        description: "Group-by + sum + sort + take: ranked aggregation"
      },

      # ═══════════════════════════════════════════════════════════════════════════
      # CLUSTER D: Set Operations Across Datasets (5 tests)
      # Capability gap: intersection, difference, membership testing
      # ═══════════════════════════════════════════════════════════════════════════

      # D1. Simple membership test
      %{
        query:
          "How many employees have at least one expense record? " <>
            "Count distinct employee IDs that appear in the expenses dataset.",
        expect: :integer,
        constraint: {:between, 1, 200},
        description: "Set membership: count IDs present in another dataset"
      },

      # D2. Set difference
      %{
        query:
          "How many employees have NO expense records at all? " <>
            "Find employee IDs not present in the expenses dataset.",
        expect: :integer,
        constraint: {:between, 0, 200},
        description: "Set difference: find IDs missing from another dataset"
      },

      # D3. Cross-dataset intersection with condition
      %{
        query:
          "How many products that cost over $500 have been ordered with status 'delivered'? " <>
            "Find product IDs matching both conditions across the products and orders datasets.",
        expect: :integer,
        constraint: {:between, 0, 500},
        description: "Set intersection: filter both datasets, intersect on ID"
      },

      # D4. Multi-dataset join count
      %{
        query:
          "Which product categories appear in delivered orders? " <>
            "Join orders (status='delivered') with products by product_id, " <>
            "then collect distinct categories. Return the sorted list of category names.",
        expect: :list,
        constraint: {:gt_length, 0},
        description: "Set collection: join + distinct across datasets"
      },

      # D5. Symmetric difference
      %{
        query:
          "Find departments that have EITHER only remote employees OR only office employees " <>
            "(not a mix of both). Return the list of such department names, or an empty list if " <>
            "all departments have both. Sort alphabetically.",
        expect: :list,
        constraint: {:gte_length, 0},
        max_turns: 2,
        description: "Set analysis: find groups with uniform membership"
      },

      # ═══════════════════════════════════════════════════════════════════════════
      # CLUSTER E: Conditional Logic and Tiered Classification (5 tests)
      # Capability gap: if/cond branching based on computed values
      # ═══════════════════════════════════════════════════════════════════════════

      # E1. Simple conditional classification
      %{
        query:
          "Classify each product as 'cheap' (price < 200), 'mid' (200-700), or 'expensive' (> 700). " <>
            "Return a map with keys :cheap, :mid, :expensive and values being the count in each tier.",
        expect: :map,
        constraint: {:has_keys, [:cheap, :mid, :expensive]},
        description: "Conditional: three-tier classification with counting"
      },

      # E2. Conditional with aggregation
      %{
        query:
          "For each employee, calculate total compensation (salary + bonus). " <>
            "How many employees have total compensation above $150,000?",
        expect: :integer,
        constraint: {:between, 0, 200},
        description: "Conditional: compute derived value, then filter"
      },

      # E3. Nested conditional
      %{
        query:
          "Classify employees into risk categories based on tenure and level: " <>
            "'flight_risk' if years_employed < 2 and level is 'senior' or higher " <>
            "(senior, lead, manager, director), 'stable' otherwise. " <>
            "Return a map with :flight_risk and :stable counts.",
        expect: :map,
        constraint: {:has_keys, [:flight_risk, :stable]},
        description: "Nested conditional: compound predicate with AND/OR"
      },

      # E4. Conditional aggregation (weighted)
      %{
        query:
          "Calculate a weighted score for each department: " <>
            "(average_salary * 0.4) + (average_years_employed * 1000 * 0.3) + " <>
            "(remote_percentage * 100000 * 0.3). " <>
            "Which department has the highest weighted score? Return the department name.",
        expect: :string,
        constraint: {:one_of, ["engineering", "sales", "marketing", "support", "hr", "finance"]},
        max_turns: 3,
        description: "Conditional: weighted multi-factor scoring"
      },

      # E5. Conditional with fallback
      %{
        query:
          "For each order payment method, calculate the average order total. " <>
            "Then classify each payment method as 'high_value' if average > $2500, " <>
            "'standard' otherwise. Return a map of payment_method to classification string.",
        expect: :map,
        constraint: {:has_keys, [:credit_card, :paypal, :bank_transfer, :crypto]},
        description: "Conditional: aggregate then classify result"
      }
    ]
  end

  @doc """
  Returns 1-based indices of plan cases within the full test suite.
  """
  @spec plan_case_indices() :: [pos_integer()]
  def plan_case_indices do
    offset =
      length(common_test_cases()) + length(lisp_specific_cases()) + length(multi_turn_cases())

    Enum.to_list((offset + 1)..(offset + length(plan_cases())))
  end

  @doc """
  Returns 1-based indices of M0 validation cases within the full test suite.
  """
  @spec m0_validation_indices() :: [pos_integer()]
  def m0_validation_indices do
    offset =
      length(common_test_cases()) + length(lisp_specific_cases()) +
        length(multi_turn_cases()) + length(plan_cases())

    Enum.to_list((offset + 1)..(offset + length(m0_validation_cases())))
  end
end
