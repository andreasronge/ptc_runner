defmodule PtcRunner.Lisp.IntegrationTest do
  @moduledoc """
  E2E tests for PTC-Lisp covering all benchmark scenario types.

  These tests verify the interpreter correctly executes programs matching
  the scenarios defined in PtcLispBenchmark, plus invalid program handling.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  # ==========================================================================
  # Level 1: Simple Operations
  # ==========================================================================

  describe "Level 1 - simple_filter" do
    test "filters products where price > 100" do
      source = ~S"""
      (filter (where :price > 100) ctx/products)
      """

      ctx = %{
        products: [
          %{name: "Apple", price: 50},
          %{name: "Laptop", price: 999},
          %{name: "Book", price: 25},
          %{name: "Phone", price: 599}
        ]
      }

      {:ok, result, _, _} = Lisp.run(source, context: ctx)

      assert length(result) == 2
      assert Enum.all?(result, fn p -> p.price > 100 end)
      assert Enum.map(result, & &1.name) == ["Laptop", "Phone"]
    end
  end

  describe "Level 1 - simple_count" do
    test "counts active users" do
      source = ~S"""
      (count (filter (where :active) ctx/users))
      """

      ctx = %{
        users: [
          %{name: "Alice", active: true},
          %{name: "Bob", active: false},
          %{name: "Carol", active: true},
          %{name: "Dave", active: nil}
        ]
      }

      {:ok, result, _, _} = Lisp.run(source, context: ctx)
      assert result == 2
    end
  end

  # ==========================================================================
  # Level 2: Pipelines and Multiple Operations
  # ==========================================================================

  describe "Level 2 - pipeline_filter_sort" do
    test "gets top 5 highest-paid employees" do
      source = ~S"""
      (->> ctx/employees
           (filter (where :salary > 50000))
           (sort-by :salary >)
           (take 5))
      """

      ctx = %{
        employees: [
          %{name: "Alice", salary: 120_000},
          %{name: "Bob", salary: 45_000},
          %{name: "Carol", salary: 85_000},
          %{name: "Dave", salary: 95_000},
          %{name: "Eve", salary: 75_000},
          %{name: "Frank", salary: 110_000},
          %{name: "Grace", salary: 55_000}
        ]
      }

      {:ok, result, _, _} = Lisp.run(source, context: ctx)

      assert length(result) == 5
      assert Enum.all?(result, fn e -> e.salary > 50_000 end)
      salaries = Enum.map(result, & &1.salary)
      assert salaries == Enum.sort(salaries, :desc)
      assert hd(result).name == "Alice"
    end
  end

  describe "Level 2 - aggregate_sum" do
    test "calculates total of completed orders" do
      source = ~S"""
      (->> ctx/orders
           (filter (where :status = "completed"))
           (sum-by :amount))
      """

      ctx = %{
        orders: [
          %{id: 1, amount: 100, status: "completed"},
          %{id: 2, amount: 200, status: "pending"},
          %{id: 3, amount: 150, status: "completed"},
          %{id: 4, amount: 50, status: "cancelled"}
        ]
      }

      {:ok, result, _, _} = Lisp.run(source, context: ctx)
      assert result == 250
    end
  end

  # ==========================================================================
  # Level 3: Predicates and Conditionals
  # ==========================================================================

  describe "Level 3 - predicate_combinator" do
    test "finds electronics OR expensive, excluding out of stock" do
      source = ~S"""
      (->> ctx/products
           (filter (all-of
                     (any-of (where :category = "electronics")
                             (where :price > 500))
                     (where :in_stock))))
      """

      ctx = %{
        products: [
          %{name: "Laptop", category: "electronics", price: 999, in_stock: true},
          %{name: "TV", category: "electronics", price: 400, in_stock: false},
          %{name: "Sofa", category: "furniture", price: 800, in_stock: true},
          %{name: "Book", category: "books", price: 25, in_stock: true},
          %{name: "Phone", category: "electronics", price: 599, in_stock: true}
        ]
      }

      {:ok, result, _, _} = Lisp.run(source, context: ctx)

      names = Enum.map(result, & &1.name) |> Enum.sort()
      assert names == ["Laptop", "Phone", "Sofa"]
    end
  end

  describe "Level 3 - conditional_logic" do
    test "categorizes orders by size" do
      source = ~S"""
      (->> ctx/orders
           (map (fn [order]
                  {:id (:id order)
                   :size (cond
                           (> (:amount order) 500) "large"
                           (>= (:amount order) 100) "medium"
                           :else "small")})))
      """

      ctx = %{
        orders: [
          %{id: 1, amount: 50},
          %{id: 2, amount: 150},
          %{id: 3, amount: 750}
        ]
      }

      {:ok, result, _, _} = Lisp.run(source, context: ctx)

      assert Enum.find(result, &(&1.id == 1)).size == "small"
      assert Enum.find(result, &(&1.id == 2)).size == "medium"
      assert Enum.find(result, &(&1.id == 3)).size == "large"
    end
  end

  # ==========================================================================
  # Level 4: Tool Calls and Memory
  # ==========================================================================

  describe "Level 4 - tool_call_transform" do
    test "fetches premium users and returns emails" do
      source = ~S"""
      (->> (call "get-users" {})
           (filter (where :tier = "premium"))
           (pluck :email))
      """

      tools = %{
        "get-users" => fn _args ->
          [
            %{name: "Alice", email: "alice@example.com", tier: "premium"},
            %{name: "Bob", email: "bob@example.com", tier: "free"},
            %{name: "Carol", email: "carol@example.com", tier: "premium"}
          ]
        end
      }

      {:ok, result, _, _} = Lisp.run(source, tools: tools)

      assert result == ["alice@example.com", "carol@example.com"]
    end
  end

  describe "Level 4 - memory_contract" do
    test "stores high-value orders in memory and returns count" do
      source = ~S"""
      (let [high-value (->> (call "get-orders" {})
                            (filter (where :amount > 1000)))]
        {:result (count high-value)
         :high_value_orders high-value})
      """

      tools = %{
        "get-orders" => fn _args ->
          [
            %{id: 1, amount: 500, customer: "Alice"},
            %{id: 2, amount: 1500, customer: "Bob"},
            %{id: 3, amount: 2000, customer: "Carol"},
            %{id: 4, amount: 800, customer: "Dave"}
          ]
        end
      }

      {:ok, result, delta, new_memory} = Lisp.run(source, tools: tools)

      assert result == 2
      assert length(delta.high_value_orders) == 2
      assert Enum.all?(delta.high_value_orders, fn o -> o.amount > 1000 end)
      assert new_memory == delta
    end
  end

  # ==========================================================================
  # Level 5: Edge Cases
  # ==========================================================================

  describe "Level 5 - edge_truthy_check" do
    test "filters active users with explicit equality" do
      source = ~S"""
      (filter (where :active = true) ctx/users)
      """

      ctx = %{
        users: [
          %{name: "Alice", active: true},
          %{name: "Bob", active: false},
          %{name: "Carol", active: "yes"},
          %{name: "Dave", active: 1}
        ]
      }

      {:ok, result, _, _} = Lisp.run(source, context: ctx)

      # Only Alice matches (explicit true, not truthy values)
      assert length(result) == 1
      assert hd(result).name == "Alice"
    end

    test "filters active users with truthy check" do
      source = ~S"""
      (filter (where :active) ctx/users)
      """

      ctx = %{
        users: [
          %{name: "Alice", active: true},
          %{name: "Bob", active: false},
          %{name: "Carol", active: "yes"},
          %{name: "Dave", active: 1},
          %{name: "Eve", active: nil}
        ]
      }

      {:ok, result, _, _} = Lisp.run(source, context: ctx)

      # All truthy values match
      names = Enum.map(result, & &1.name) |> Enum.sort()
      assert names == ["Alice", "Carol", "Dave"]
    end
  end

  describe "Level 5 - edge_range_check" do
    test "finds products with price between 100 and 500 inclusive" do
      source = ~S"""
      (filter (all-of (where :price >= 100)
                      (where :price <= 500))
              ctx/products)
      """

      ctx = %{
        products: [
          %{name: "A", price: 50},
          %{name: "B", price: 100},
          %{name: "C", price: 300},
          %{name: "D", price: 500},
          %{name: "E", price: 501}
        ]
      }

      {:ok, result, _, _} = Lisp.run(source, context: ctx)

      names = Enum.map(result, & &1.name) |> Enum.sort()
      assert names == ["B", "C", "D"]
    end
  end

  describe "Level 5 - edge_multi_field_extract" do
    test "extracts id and name from orders using map" do
      source = ~S"""
      (->> ctx/orders
           (map (fn [o] {:id (:id o) :name (:name o)})))
      """

      ctx = %{
        orders: [
          %{id: 1, name: "Order A", amount: 100, status: "pending"},
          %{id: 2, name: "Order B", amount: 200, status: "completed"}
        ]
      }

      {:ok, result, _, _} = Lisp.run(source, context: ctx)

      assert result == [
               %{id: 1, name: "Order A"},
               %{id: 2, name: "Order B"}
             ]
    end

    test "extracts fields using let destructuring" do
      source = ~S"""
      (->> ctx/orders
           (map (fn [o]
                  (let [{:keys [id name]} o]
                    {:id id :name name}))))
      """

      ctx = %{
        orders: [
          %{id: 1, name: "Order A", amount: 100},
          %{id: 2, name: "Order B", amount: 200}
        ]
      }

      {:ok, result, _, _} = Lisp.run(source, context: ctx)

      assert result == [
               %{id: 1, name: "Order A"},
               %{id: 2, name: "Order B"}
             ]
    end
  end

  # ==========================================================================
  # Invalid Program Tests
  # ==========================================================================

  describe "invalid programs - parse errors" do
    test "missing closing paren" do
      source = "(filter (where :active ctx/users"

      assert {:error, {:parse_error, message}} = Lisp.run(source)
      assert message =~ "expected"
      assert message =~ ")"
    end

    test "unbalanced brackets" do
      source = "[1 2 3"

      assert {:error, {:parse_error, message}} = Lisp.run(source)
      assert message =~ "expected"
    end

    test "invalid token" do
      source = "(+ 1 @invalid)"

      assert {:error, {:parse_error, message}} = Lisp.run(source)
      assert message =~ "@invalid"
    end
  end

  describe "invalid programs - semantic errors" do
    test "unbound variable" do
      # Referencing undefined variable returns specific error with variable name
      source = "(+ x 1)"

      assert {:error, {:unbound_var, :x}} = Lisp.run(source)
    end

    test "calling non-function" do
      # Attempting to call a literal value returns error with the value
      source = "(42 1 2)"

      assert {:error, {:not_callable, 42}} = Lisp.run(source)
    end

    test "unknown tool raises error" do
      # Tool calls to unregistered tools raise RuntimeError
      source = ~S|(call "unknown-tool" {})|

      error = assert_raise RuntimeError, fn -> Lisp.run(source) end
      assert error.message =~ "Unknown tool"
      assert error.message =~ "unknown-tool"
    end
  end

  describe "invalid programs - type errors" do
    test "filter with non-collection returns type error" do
      # Passing non-list to filter returns error tuple
      source = "(filter (where :x) 42)"

      assert {:error, {:type_error, message, _}} = Lisp.run(source)
      assert message =~ "invalid argument types"
    end

    test "count with non-collection returns type error" do
      # Passing non-list to count returns error tuple
      source = "(count 42)"

      assert {:error, {:type_error, message, _}} = Lisp.run(source)
      assert message =~ "invalid argument types"
    end

    test "take on set returns type error" do
      # Sets are unordered, so take doesn't make sense
      source = "(take 2 \#{1 2 3})"

      assert {:error, {:type_error, message, _}} = Lisp.run(source)
      assert message =~ "take does not support sets"
    end

    test "first on set returns type error" do
      # Sets are unordered, so first doesn't make sense
      source = "(first \#{1 2 3})"

      assert {:error, {:type_error, message, _}} = Lisp.run(source)
      assert message =~ "first does not support sets"
    end
  end

  describe "invalid programs - common LLM mistakes" do
    test "where with field and value but missing operator" do
      # LLMs often write (where :field value) expecting equality
      # but where requires explicit operator: (where :field = value)
      source = ~S|(filter (where :status "active") ctx/items)|
      ctx = %{items: [%{status: "active"}]}

      assert {:error, {:invalid_where_form, message}} = Lisp.run(source, context: ctx)
      assert message =~ "expected (where field) or (where field op value)"
    end

    test "using quoted list syntax instead of vector" do
      # PTC-Lisp uses vectors [1 2 3], not quoted lists '(1 2 3)
      source = "'(1 2 3)"

      assert {:error, {:parse_error, message}} = Lisp.run(source)
      assert message =~ "expected"
    end

    test "if without else clause" do
      # PTC-Lisp requires else clause: (if cond then else)
      # Use (when cond then) for single-branch conditionals
      source = "(if true 1)"

      assert {:error, {:invalid_arity, :if, message}} = Lisp.run(source)
      assert message =~ "expected (if cond then else)"
    end

    test "3-arity comparison (range syntax)" do
      # Clojure allows (<= 1 x 10) but PTC-Lisp only supports 2-arity
      # Use (and (>= x 1) (<= x 10)) instead
      source = "(<= 1 5 10)"

      assert {:error, {:invalid_arity, :<=, message}} = Lisp.run(source)
      assert message =~ "comparison operators require exactly 2 arguments"
      assert message =~ "got 3"
    end

    test "destructuring in fn params - map pattern with wrong argument type" do
      # Analyzer now accepts destructuring patterns in fn parameters
      # Evaluator supports map destructuring patterns
      # But this test passes wrong argument type to catch runtime error
      source = "((fn [{:keys [a]}] a) :not-a-map)"

      # The error should be from destructuring error at runtime
      assert {:error, _reason} = Lisp.run(source)
    end

    test "destructuring in fn params - vector pattern success" do
      source = "((fn [[a b]] a) [1 2])"
      {:ok, result, _, _} = Lisp.run(source)
      assert result == 1
    end

    test "destructuring in fn params - map pattern success" do
      source = "((fn [{:keys [x]}] x) {:x 10})"
      {:ok, result, _, _} = Lisp.run(source)
      assert result == 10
    end

    test "destructuring in fn params - vector pattern ignores extra elements" do
      source = "((fn [[a]] a) [1 2 3])"
      {:ok, result, _, _} = Lisp.run(source)
      assert result == 1
    end

    test "destructuring in fn params - vector pattern insufficient elements error" do
      source = "((fn [[a b c]] a) [1 2])"
      assert {:error, {:destructure_error, message}} = Lisp.run(source)
      assert message =~ "expected at least 3 elements, got 2"
    end
  end

  describe "group-by with destructuring" do
    test "average by category using destructuring" do
      expenses = [
        %{category: "food", amount: 100},
        %{category: "food", amount: 50},
        %{category: "transport", amount: 30}
      ]

      program = """
      (->> ctx/expenses
           (group-by :category)
           (map (fn [[category items]]
                  {:category category
                   :average (avg-by :amount items)}))
           (sort-by :category))
      """

      {:ok, result, _, _} = Lisp.run(program, context: %{expenses: expenses})

      assert [
               %{category: "food", average: 75.0},
               %{category: "transport", average: 30.0}
             ] = result
    end
  end

  # ==========================================================================
  # update-vals - Map Value Transformation
  # ==========================================================================

  describe "update-vals" do
    test "counts items per group after group-by" do
      source = ~S"""
      (-> (group-by :status ctx/orders)
          (update-vals count))
      """

      ctx = %{
        orders: [
          %{id: 1, status: "pending"},
          %{id: 2, status: "delivered"},
          %{id: 3, status: "pending"},
          %{id: 4, status: "delivered"},
          %{id: 5, status: "cancelled"}
        ]
      }

      {:ok, result, _, _} = Lisp.run(source, context: ctx)

      assert result["pending"] == 2
      assert result["delivered"] == 2
      assert result["cancelled"] == 1
    end

    test "sums amounts per category after group-by" do
      source = ~S"""
      (-> (group-by :category ctx/expenses)
          (update-vals (fn [items] (sum-by :amount items))))
      """

      ctx = %{
        expenses: [
          %{category: "food", amount: 50},
          %{category: "food", amount: 30},
          %{category: "transport", amount: 20}
        ]
      }

      {:ok, result, _, _} = Lisp.run(source, context: ctx)

      assert result["food"] == 80
      assert result["transport"] == 20
    end

    test "applies inc to all values in a map" do
      source = ~S"""
      (update-vals {:a 1 :b 2 :c 3} inc)
      """

      {:ok, result, _, _} = Lisp.run(source)

      assert result == %{a: 2, b: 3, c: 4}
    end

    test "works with empty map" do
      source = ~S"""
      (update-vals {} count)
      """

      {:ok, result, _, _} = Lisp.run(source)

      assert result == %{}
    end
  end

  # ==========================================================================
  # Builtins as Higher-Order Function Arguments
  # ==========================================================================

  describe "builtins as HOF arguments" do
    test "sort-by with > comparator for descending order" do
      source = ~S"""
      (sort-by :price > ctx/products)
      """

      ctx = %{
        products: [
          %{name: "Book", price: 15},
          %{name: "Laptop", price: 999},
          %{name: "Phone", price: 599}
        ]
      }

      {:ok, result, _, _} = Lisp.run(source, context: ctx)

      assert Enum.map(result, & &1.name) == ["Laptop", "Phone", "Book"]
    end

    test "sort-by with < comparator for ascending order" do
      source = ~S"""
      (sort-by :name < ctx/users)
      """

      ctx = %{
        users: [
          %{name: "Charlie"},
          %{name: "Alice"},
          %{name: "Bob"}
        ]
      }

      {:ok, result, _, _} = Lisp.run(source, context: ctx)

      assert Enum.map(result, & &1.name) == ["Alice", "Bob", "Charlie"]
    end

    test "reduce with + accumulator" do
      source = ~S"""
      (reduce + 0 [1 2 3 4 5])
      """

      {:ok, result, _, _} = Lisp.run(source)

      assert result == 15
    end

    test "reduce with * accumulator" do
      source = ~S"""
      (reduce * 1 [1 2 3 4 5])
      """

      {:ok, result, _, _} = Lisp.run(source)

      assert result == 120
    end
  end
end
