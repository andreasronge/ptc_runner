defmodule PtcRunner.Lisp.Integration.BenchmarkScenariosTest do
  @moduledoc """
  E2E tests for PTC-Lisp benchmark scenarios (Levels 1-5).

  These tests verify the interpreter correctly executes programs matching
  the scenarios defined in PtcLispBenchmark.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Step

  # ==========================================================================
  # Level 1: Simple Operations
  # ==========================================================================

  describe "Level 1 - simple_filter" do
    test "filters products where price > 100" do
      source = ~S"""
      (filter (where :price > 100) data/products)
      """

      ctx = %{
        products: [
          %{name: "Apple", price: 50},
          %{name: "Laptop", price: 999},
          %{name: "Book", price: 25},
          %{name: "Phone", price: 599}
        ]
      }

      {:ok, %Step{return: result}} = Lisp.run(source, context: ctx)

      assert length(result) == 2
      assert Enum.all?(result, fn p -> p.price > 100 end)
      assert Enum.map(result, & &1.name) == ["Laptop", "Phone"]
    end
  end

  describe "Level 1 - simple_count" do
    test "counts active users" do
      source = ~S"""
      (count (filter (where :active) data/users))
      """

      ctx = %{
        users: [
          %{name: "Alice", active: true},
          %{name: "Bob", active: false},
          %{name: "Carol", active: true},
          %{name: "Dave", active: nil}
        ]
      }

      {:ok, %Step{return: result}} = Lisp.run(source, context: ctx)
      assert result == 2
    end
  end

  # ==========================================================================
  # Level 2: Pipelines and Multiple Operations
  # ==========================================================================

  describe "Level 2 - pipeline_filter_sort" do
    test "gets top 5 highest-paid employees" do
      source = ~S"""
      (->> data/employees
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

      {:ok, %Step{return: result}} = Lisp.run(source, context: ctx)

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
      (->> data/orders
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

      {:ok, %Step{return: result}} = Lisp.run(source, context: ctx)
      assert result == 250
    end
  end

  # ==========================================================================
  # Level 3: Predicates and Conditionals
  # ==========================================================================

  describe "Level 3 - predicate_combinator" do
    test "finds electronics OR expensive, excluding out of stock" do
      source = ~S"""
      (->> data/products
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

      {:ok, %Step{return: result}} = Lisp.run(source, context: ctx)

      names = Enum.map(result, & &1.name) |> Enum.sort()
      assert names == ["Laptop", "Phone", "Sofa"]
    end
  end

  describe "Level 3 - conditional_logic" do
    test "categorizes orders by size" do
      source = ~S"""
      (->> data/orders
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

      {:ok, %Step{return: result}} = Lisp.run(source, context: ctx)

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
      (->> (tool/get-users {})
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

      {:ok, %Step{return: result}} = Lisp.run(source, tools: tools)

      assert result == ["alice@example.com", "carol@example.com"]
    end
  end

  describe "Level 4 - explicit_storage" do
    test "returns high-value orders with count using let bindings" do
      # V2: maps return as-is, no implicit memory merge
      # Use def for explicit storage if needed across turns
      source = ~S"""
      (let [high-value (->> (tool/get-orders {})
                            (filter (where :amount > 1000)))]
        {:count (count high-value)
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

      {:ok, %Step{return: result, memory: new_memory}} =
        Lisp.run(source, tools: tools)

      assert result.count == 2
      assert length(result.high_value_orders) == 2
      assert Enum.all?(result.high_value_orders, fn o -> o.amount > 1000 end)
      assert new_memory == %{}
    end
  end

  # ==========================================================================
  # Level 5: Edge Cases
  # ==========================================================================

  describe "Level 5 - edge_truthy_check" do
    test "filters active users with explicit equality" do
      source = ~S"""
      (filter (where :active = true) data/users)
      """

      ctx = %{
        users: [
          %{name: "Alice", active: true},
          %{name: "Bob", active: false},
          %{name: "Carol", active: "yes"},
          %{name: "Dave", active: 1}
        ]
      }

      {:ok, %Step{return: result}} = Lisp.run(source, context: ctx)

      # Only Alice matches (explicit true, not truthy values)
      assert length(result) == 1
      assert hd(result).name == "Alice"
    end

    test "filters active users with truthy check" do
      source = ~S"""
      (filter (where :active) data/users)
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

      {:ok, %Step{return: result}} = Lisp.run(source, context: ctx)

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
              data/products)
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

      {:ok, %Step{return: result}} = Lisp.run(source, context: ctx)

      names = Enum.map(result, & &1.name) |> Enum.sort()
      assert names == ["B", "C", "D"]
    end
  end

  describe "Level 5 - edge_multi_field_extract" do
    test "extracts id and name from orders using map" do
      source = ~S"""
      (->> data/orders
           (map (fn [o] {:id (:id o) :name (:name o)})))
      """

      ctx = %{
        orders: [
          %{id: 1, name: "Order A", amount: 100, status: "pending"},
          %{id: 2, name: "Order B", amount: 200, status: "completed"}
        ]
      }

      {:ok, %Step{return: result}} = Lisp.run(source, context: ctx)

      assert result == [
               %{id: 1, name: "Order A"},
               %{id: 2, name: "Order B"}
             ]
    end

    test "extracts fields using let destructuring" do
      source = ~S"""
      (->> data/orders
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

      {:ok, %Step{return: result}} = Lisp.run(source, context: ctx)

      assert result == [
               %{id: 1, name: "Order A"},
               %{id: 2, name: "Order B"}
             ]
    end
  end
end
