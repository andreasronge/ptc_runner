defmodule PtcRunner.Lisp.Integration.CollectionOpsTest do
  @moduledoc """
  Tests for collection operations in PTC-Lisp.

  Covers group-by, update-vals, update, and update-in operations.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Step

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

      {:ok, %Step{return: result}} = Lisp.run(program, context: %{expenses: expenses})

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

      {:ok, %Step{return: result}} = Lisp.run(source, context: ctx)

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

      {:ok, %Step{return: result}} = Lisp.run(source, context: ctx)

      assert result["food"] == 80
      assert result["transport"] == 20
    end

    test "applies inc to all values in a map" do
      source = ~S"""
      (update-vals {:a 1 :b 2 :c 3} inc)
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == %{a: 2, b: 3, c: 4}
    end

    test "works with empty map" do
      source = ~S"""
      (update-vals {} count)
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == %{}
    end

    test "provides helpful error when using ->> instead of ->" do
      # Common mistake: using ->> (thread-last) with update-vals
      # which puts the map as the last argument instead of first
      source = ~S"""
      (->> ctx/orders
           (group-by :status)
           (update-vals count))
      """

      ctx = %{orders: [%{id: 1, status: "pending"}]}

      assert {:error, %Step{fail: %{reason: :type_error, message: message}}} =
               Lisp.run(source, context: ctx)

      assert message =~ "update-vals expects (map, function)"
      assert message =~ "Use -> (thread-first)"
    end
  end

  # ==========================================================================
  # update and update-in - Map Key/Path Value Updates
  # ==========================================================================

  describe "update" do
    test "basic update with function" do
      source = ~S"""
      (update {:n 1} :n inc)
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == %{n: 2}
    end

    test "missing key passes nil to function" do
      source = ~S"""
      (update {} :missing (fn [v] (if v (inc v) 0)))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == %{missing: 0}
    end

    test "multiple keys in map" do
      source = ~S"""
      (update {:a 1 :b 2 :c 3} :b inc)
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == %{a: 1, b: 3, c: 3}
    end
  end

  describe "update-in" do
    test "nested update-in with single level" do
      source = ~S"""
      (update-in {:a {:b 1}} [:a :b] inc)
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == %{a: %{b: 2}}
    end

    test "multiple levels deep" do
      source = ~S"""
      (update-in {:x {:y {:z 5}}} [:x :y :z] (fn [v] (* v 2)))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == %{x: %{y: %{z: 10}}}
    end

    test "works with empty nested map" do
      source = ~S"""
      (update-in {:a {}} [:a :b] (fn [v] (if v (inc v) 0)))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == %{a: %{b: 0}}
    end

    test "single key path is equivalent to update" do
      source = ~S"""
      (update-in {:n 1} [:n] inc)
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == %{n: 2}
    end
  end
end
