defmodule PtcRunner.Lisp.Integration.CollectionOpsTest do
  @moduledoc """
  Integration tests for collection operations in PTC-Lisp.

  This is the canonical location for all collection operation tests.
  Tests exercise operations through `Lisp.run/2` to verify end-to-end behavior.
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
      (->> data/expenses
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
      (-> (group-by :status data/orders)
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
      (-> (group-by :category data/expenses)
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
      (->> data/orders
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

  # ==========================================================================
  # Keywords as Functions in Higher-Order Functions
  # ==========================================================================

  describe "keywords as functions in HOFs" do
    test "map with keyword extracts field values" do
      items = [%{name: "Alice"}, %{name: "Bob"}]
      {:ok, %Step{return: result}} = Lisp.run("(map :name data/items)", context: %{items: items})
      assert result == ["Alice", "Bob"]
    end

    test "mapv with keyword extracts field values" do
      items = [%{name: "Alice"}, %{name: "Bob"}]
      {:ok, %Step{return: result}} = Lisp.run("(mapv :name data/items)", context: %{items: items})
      assert result == ["Alice", "Bob"]
    end

    test "filter with keyword as predicate" do
      items = [
        %{active: true, name: "A"},
        %{active: false, name: "B"},
        %{active: true, name: "C"}
      ]

      {:ok, %Step{return: result}} =
        Lisp.run("(filter :active data/items)", context: %{items: items})

      assert length(result) == 2
      assert Enum.all?(result, & &1.active)
    end

    test "filter with keyword checks truthiness not just presence" do
      items = [
        %{value: nil},
        %{value: false},
        %{value: true},
        %{value: 0},
        %{value: ""}
      ]

      {:ok, %Step{return: result}} =
        Lisp.run("(filter :value data/items)", context: %{items: items})

      # nil and false are falsy, 0 and "" are truthy
      assert length(result) == 3
    end

    test "remove with keyword as predicate" do
      items = [%{active: true}, %{active: false}]

      {:ok, %Step{return: result}} =
        Lisp.run("(remove :active data/items)", context: %{items: items})

      assert length(result) == 1
      assert hd(result).active == false
    end

    test "find with keyword as predicate" do
      items = [%{special: false}, %{special: true}]

      {:ok, %Step{return: result}} =
        Lisp.run("(find :special data/items)", context: %{items: items})

      assert result == %{special: true}
    end

    test "take-while with keyword as predicate" do
      items = [%{active: true}, %{active: true}, %{active: false}, %{active: true}]

      {:ok, %Step{return: result}} =
        Lisp.run("(take-while :active data/items)", context: %{items: items})

      assert length(result) == 2
    end

    test "drop-while with keyword as predicate" do
      items = [%{active: true}, %{active: true}, %{active: false}, %{active: true}]

      {:ok, %Step{return: result}} =
        Lisp.run("(drop-while :active data/items)", context: %{items: items})

      assert length(result) == 2
      assert hd(result).active == false
    end

    test "pluck still works with atoms as regular values" do
      items = [%{email: "a@b.com"}, %{email: "c@d.com"}]

      {:ok, %Step{return: result}} =
        Lisp.run("(pluck :email data/items)", context: %{items: items})

      assert result == ["a@b.com", "c@d.com"]
    end

    test "sort-by still works with keywords" do
      items = [%{score: 3}, %{score: 1}, %{score: 2}]

      {:ok, %Step{return: result}} =
        Lisp.run("(sort-by :score data/items)", context: %{items: items})

      assert Enum.map(result, & &1.score) == [1, 2, 3]
    end

    test "some with keyword finds first truthy" do
      items = [%{active: false}, %{active: true}]

      {:ok, %Step{return: result}} =
        Lisp.run("(some :active data/items)", context: %{items: items})

      assert result == true
    end

    test "some with keyword returns extracted value, not boolean" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(some :a [{:a 1} {:b 2}])|)
      assert result == 1
    end

    test "some with keyword skips false and returns next truthy value" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(some :a [{:a false} {:a 42}])|)
      assert result == 42
    end

    test "some with keyword returns nil when none match" do
      items = [%{active: false}, %{active: nil}]

      {:ok, %Step{return: result}} =
        Lisp.run("(some :active data/items)", context: %{items: items})

      assert result == nil
    end

    test "every? with keyword checks all truthy" do
      items = [%{valid: true}, %{valid: "yes"}]

      {:ok, %Step{return: result}} =
        Lisp.run("(every? :valid data/items)", context: %{items: items})

      assert result == true
    end

    test "every? with keyword returns false when any falsy" do
      items = [%{valid: true}, %{valid: nil}]

      {:ok, %Step{return: result}} =
        Lisp.run("(every? :valid data/items)", context: %{items: items})

      assert result == false
    end

    test "not-any? with keyword checks none truthy" do
      items = [%{error: nil}, %{error: false}]

      {:ok, %Step{return: result}} =
        Lisp.run("(not-any? :error data/items)", context: %{items: items})

      assert result == true
    end

    test "not-any? with keyword returns false when any truthy" do
      items = [%{error: nil}, %{error: "oops"}]

      {:ok, %Step{return: result}} =
        Lisp.run("(not-any? :error data/items)", context: %{items: items})

      assert result == false
    end

    test "some with keyword on empty collection returns nil" do
      {:ok, %Step{return: result}} =
        Lisp.run("(some :active [])")

      assert result == nil
    end

    test "every? with keyword on empty collection returns true" do
      {:ok, %Step{return: result}} =
        Lisp.run("(every? :active [])")

      assert result == true
    end

    test "not-any? with keyword on empty collection returns true" do
      {:ok, %Step{return: result}} =
        Lisp.run("(not-any? :error [])")

      assert result == true
    end

    test "some with predicate on set" do
      {:ok, %Step{return: result}} =
        Lisp.run(~S|(some #(> % 3) (set [1 2 3 4 5]))|)

      assert result == true
    end

    test "every? with predicate on set" do
      {:ok, %Step{return: result}} =
        Lisp.run(~S|(every? #(> % 0) (set [1 2 3]))|)

      assert result == true
    end

    test "not-any? with predicate on set" do
      {:ok, %Step{return: result}} =
        Lisp.run(~S|(not-any? #(> % 10) (set [1 2 3]))|)

      assert result == true
    end
  end

  # ==========================================================================
  # rest, next, and composed accessor functions
  # ==========================================================================

  describe "rest" do
    test "returns tail of list with multiple elements" do
      {:ok, %Step{return: result}} = Lisp.run("(rest [1 2 3])")
      assert result == [2, 3]
    end

    test "returns empty list for empty list" do
      {:ok, %Step{return: result}} = Lisp.run("(rest [])")
      assert result == []
    end

    test "returns empty list for single-element list" do
      {:ok, %Step{return: result}} = Lisp.run("(rest [1])")
      assert result == []
    end
  end

  describe "next" do
    test "returns tail of list with multiple elements" do
      {:ok, %Step{return: result}} = Lisp.run("(next [1 2 3])")
      assert result == [2, 3]
    end

    test "returns nil for empty list" do
      {:ok, %Step{return: result}} = Lisp.run("(next [])")
      assert result == nil
    end

    test "returns nil for single-element list" do
      {:ok, %Step{return: result}} = Lisp.run("(next [1])")
      assert result == nil
    end
  end

  describe "ffirst" do
    test "returns first of first with nested collections" do
      {:ok, %Step{return: result}} = Lisp.run("(ffirst [[1 2] [3 4]])")
      assert result == 1
    end

    test "returns nil when first element is empty" do
      {:ok, %Step{return: result}} = Lisp.run("(ffirst [[] [3 4]])")
      assert result == nil
    end

    test "returns nil when outer collection is empty" do
      {:ok, %Step{return: result}} = Lisp.run("(ffirst [])")
      assert result == nil
    end
  end

  describe "fnext" do
    test "returns first of next" do
      {:ok, %Step{return: result}} = Lisp.run("(fnext [1 2 3])")
      assert result == 2
    end

    test "returns nil when next returns nil (single-element list)" do
      {:ok, %Step{return: result}} = Lisp.run("(fnext [1])")
      assert result == nil
    end

    test "returns nil when next returns nil (empty list)" do
      {:ok, %Step{return: result}} = Lisp.run("(fnext [])")
      assert result == nil
    end
  end

  describe "nfirst" do
    test "returns next of first with nested collections" do
      {:ok, %Step{return: result}} = Lisp.run("(nfirst [[1 2] [3 4]])")
      assert result == [2]
    end

    test "returns nil when first element has single element" do
      {:ok, %Step{return: result}} = Lisp.run("(nfirst [[1] [3 4]])")
      assert result == nil
    end

    test "returns nil when first element is empty" do
      {:ok, %Step{return: result}} = Lisp.run("(nfirst [[] [3 4]])")
      assert result == nil
    end

    test "returns nil when outer collection is empty" do
      {:ok, %Step{return: result}} = Lisp.run("(nfirst [])")
      assert result == nil
    end
  end

  describe "nnext" do
    test "returns next of next" do
      {:ok, %Step{return: result}} = Lisp.run("(nnext [1 2 3 4])")
      assert result == [3, 4]
    end

    test "returns nil for two-element list" do
      {:ok, %Step{return: result}} = Lisp.run("(nnext [1 2])")
      assert result == nil
    end

    test "returns nil when next returns nil (single-element list)" do
      {:ok, %Step{return: result}} = Lisp.run("(nnext [1])")
      assert result == nil
    end

    test "returns nil when next returns nil (empty list)" do
      {:ok, %Step{return: result}} = Lisp.run("(nnext [])")
      assert result == nil
    end
  end

  describe "rest/next practical use case" do
    test "processing nested data with composed accessors" do
      program = """
      (let [matrix [[1 2 3] [4 5 6] [7 8 9]]]
        {:first-row-head (ffirst matrix)
         :first-row-tail (nfirst matrix)
         :remaining-rows (next matrix)})
      """

      {:ok, %Step{return: result}} = Lisp.run(program)

      assert result == %{
               "first-row-head": 1,
               "first-row-tail": [2, 3],
               "remaining-rows": [[4, 5, 6], [7, 8, 9]]
             }
    end
  end

  # ==========================================================================
  # Multi-arity map - Issue #667
  # ==========================================================================

  describe "multi-arity map" do
    test "map with two collections using +" do
      source = "(map + [1 2 3] [10 20 30])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [11, 22, 33]
    end

    test "map with three collections" do
      source = "(map (fn [a b c] (+ a b c)) [1 2] [10 20] [100 200])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [111, 222]
    end

    test "map creating pairs with anonymous function" do
      source = "(map (fn [a b] [a b]) [1 2] [:a :b])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [[1, :a], [2, :b]]
    end

    test "map stops at shortest collection" do
      source = "(map + [1 2 3 4 5] [10 20])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [11, 22]
    end

    test "map with nil collection returns empty" do
      source = "(map + nil [1 2 3])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == []
    end

    test "map with empty collection returns empty" do
      source = "(map + [] [1 2 3])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == []
    end

    test "mapv with two collections" do
      source = "(mapv * [2 3 4] [5 6 7])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [10, 18, 28]
    end

    test "map with closure capturing scope" do
      source = """
      (let [factor 10]
        (map (fn [a b] (* factor (+ a b))) [1 2] [3 4]))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [40, 60]
    end
  end

  # ==========================================================================
  # partition - Issue #667
  # ==========================================================================

  describe "partition" do
    test "basic partition by n" do
      source = "(partition 2 [1 2 3 4 5 6])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [[1, 2], [3, 4], [5, 6]]
    end

    test "partition discards incomplete chunk" do
      source = "(partition 3 [1 2 3 4 5 6 7 8])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [[1, 2, 3], [4, 5, 6]]
    end

    test "partition with step creates sliding window" do
      source = "(partition 2 1 [1 2 3 4])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [[1, 2], [2, 3], [3, 4]]
    end

    test "partition with step larger than n" do
      source = "(partition 2 3 [1 2 3 4 5 6 7])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [[1, 2], [4, 5]]
    end

    test "partition nil returns empty" do
      source = "(partition 2 nil)"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == []
    end

    test "partition empty returns empty" do
      source = "(partition 2 [])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == []
    end

    test "partition with n larger than collection returns empty" do
      source = "(partition 10 [1 2 3])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == []
    end

    test "consecutive month pairs pattern from issue #667" do
      source = """
      (let [months ["jan" "feb" "mar" "apr"]]
        (partition 2 1 months))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [["jan", "feb"], ["feb", "mar"], ["mar", "apr"]]
    end
  end

  # ==========================================================================
  # partition-all - like partition but keeps incomplete final chunk
  # ==========================================================================

  describe "partition-all" do
    test "keeps incomplete final chunk" do
      source = "(partition-all 3 [1 2 3 4 5 6 7 8])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [[1, 2, 3], [4, 5, 6], [7, 8]]
    end

    test "basic partition-all by n" do
      source = "(partition-all 2 [1 2 3 4 5])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [[1, 2], [3, 4], [5]]
    end

    test "with step" do
      source = "(partition-all 2 3 [1 2 3 4 5 6 7])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [[1, 2], [4, 5], [7]]
    end

    test "nil returns empty" do
      source = "(partition-all 2 nil)"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == []
    end

    test "exact fit behaves like partition" do
      source = "(partition-all 3 [1 2 3 4 5 6])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [[1, 2, 3], [4, 5, 6]]
    end
  end

  # ==========================================================================
  # interpose - Insert separator between elements
  # ==========================================================================

  describe "interpose" do
    test "inserts separator between elements" do
      source = ~S|(interpose ", " ["a" "b" "c"])|
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == ["a", ", ", "b", ", ", "c"]
    end

    test "works with numeric separator" do
      source = "(interpose 0 [1 2 3])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [1, 0, 2, 0, 3]
    end

    test "returns single element unchanged" do
      source = "(interpose :x [1])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [1]
    end

    test "returns empty list for empty input" do
      source = "(interpose :x [])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == []
    end

    test "works with keyword separator" do
      source = "(interpose :sep [:a :b :c])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [:a, :sep, :b, :sep, :c]
    end

    test "commonly used with join for string building" do
      source = ~S|(join (interpose ", " ["a" "b" "c"]))|
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == "a, b, c"
    end

    test "works in threading macro" do
      source = ~S|(->> ["a" "b" "c"] (interpose "-") (join))|
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == "a-b-c"
    end

    test "handles nil separator by inserting nil between elements" do
      source = "(interpose nil [1 2 3])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [1, nil, 2, nil, 3]
    end

    test "handles nil collection by returning empty list" do
      source = "(interpose :x nil)"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == []
    end
  end

  # ==========================================================================
  # distinct-by - Get unique items by key
  # ==========================================================================

  describe "distinct-by" do
    test "returns first item per unique key value" do
      items = [
        %{category: "food", name: "apple"},
        %{category: "food", name: "banana"},
        %{category: "drink", name: "water"}
      ]

      {:ok, %Step{return: result}} =
        Lisp.run("(distinct-by :category data/items)", context: %{items: items})

      assert length(result) == 2
      assert Enum.at(result, 0) == %{category: "food", name: "apple"}
      assert Enum.at(result, 1) == %{category: "drink", name: "water"}
    end

    test "works with function as key extractor" do
      source = "(distinct-by first [[\"a\" 1] [\"a\" 2] [\"b\" 3]])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [["a", 1], ["b", 3]]
    end

    test "returns empty list for empty collection" do
      {:ok, %Step{return: result}} = Lisp.run("(distinct-by :x [])")
      assert result == []
    end

    test "returns empty list for nil" do
      {:ok, %Step{return: result}} = Lisp.run("(distinct-by :x nil)")
      assert result == []
    end

    test "preserves order (first occurrence wins)" do
      items = [
        %{id: 1, status: "active"},
        %{id: 2, status: "pending"},
        %{id: 3, status: "active"},
        %{id: 4, status: "pending"}
      ]

      {:ok, %Step{return: result}} =
        Lisp.run("(distinct-by :status data/items)", context: %{items: items})

      assert length(result) == 2
      assert Enum.at(result, 0).id == 1
      assert Enum.at(result, 1).id == 2
    end

    test "works in threading macro" do
      source = """
      (->> [{:type "a" :val 1} {:type "b" :val 2} {:type "a" :val 3}]
           (distinct-by :type)
           (map :val))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [1, 2]
    end

    test "treats nil as a valid distinct key value" do
      items = [%{id: 1, status: nil}, %{id: 2, status: nil}, %{id: 3, status: "active"}]

      {:ok, %Step{return: result}} =
        Lisp.run("(distinct-by :status data/items)", context: %{items: items})

      assert length(result) == 2
      assert Enum.at(result, 0).id == 1
      assert Enum.at(result, 1).id == 3
    end

    test "supports nested path access" do
      items = [
        %{user: %{role: "admin"}},
        %{user: %{role: "user"}},
        %{user: %{role: "admin"}}
      ]

      {:ok, %Step{return: result}} =
        Lisp.run("(distinct-by [:user :role] data/items)", context: %{items: items})

      assert length(result) == 2
    end
  end

  # ==========================================================================
  # mapcat - Apply function and concatenate results
  # ==========================================================================

  describe "mapcat" do
    test "basic mapcat with vector-returning function" do
      source = "(mapcat (fn [x] [x (* x 2)]) [1 2 3])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [1, 2, 2, 4, 3, 6]
    end

    test "mapcat with range" do
      source = "(mapcat (fn [x] (range 0 x)) [2 3 1])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [0, 1, 0, 1, 2, 0]
    end

    test "mapcat with identity flattens one level" do
      source = "(mapcat identity [[1 2] [3 4] [5]])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [1, 2, 3, 4, 5]
    end

    test "mapcat with empty collection returns empty list" do
      source = "(mapcat (fn [x] [x (* x 2)]) [])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == []
    end

    test "mapcat with nil collection returns empty list" do
      source = "(mapcat (fn [x] [x (* x 2)]) nil)"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == []
    end

    test "mapcat with function returning empty vectors filters out" do
      source = "(mapcat (fn [x] (if (> x 0) [x] [])) [-1 2 -3 4])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [2, 4]
    end

    test "mapcat with keyword extracts nested values" do
      source = "(mapcat :tags data/items)"
      items = [%{tags: ["a", "b"]}, %{tags: ["c"]}, %{tags: []}]
      {:ok, %Step{return: result}} = Lisp.run(source, context: %{items: items})
      assert result == ["a", "b", "c"]
    end

    test "mapcat with anonymous function creating pairs" do
      source = "(mapcat (fn [x] [[x :start] [x :end]]) [:a :b])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [[:a, :start], [:a, :end], [:b, :start], [:b, :end]]
    end

    test "mapcat in threading macro" do
      source = """
      (->> [[1 2] [3 4 5] [6]]
           (mapcat identity)
           (filter (fn [x] (> x 2))))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [3, 4, 5, 6]
    end

    test "mapcat with closure capturing scope" do
      source = """
      (let [factor 10]
        (mapcat (fn [x] [x (* x factor)]) [1 2]))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [1, 10, 2, 20]
    end

    test "mapcat on string processes graphemes" do
      source = "(mapcat (fn [c] [c c]) \"abc\")"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == ["a", "a", "b", "b", "c", "c"]
    end

    test "mapcat on set" do
      source = ~S|(mapcat (fn [x] [x (* x 2)]) #{1 2 3})|
      {:ok, %Step{return: result}} = Lisp.run(source)
      # Sets have undefined order, so just check all elements are present
      assert length(result) == 6
      assert Enum.sort(result) == [1, 2, 2, 3, 4, 6]
    end

    test "mapcat on map with key-value pairs" do
      source = "(mapcat (fn [[k v]] [k v]) {:a 1 :b 2})"
      {:ok, %Step{return: result}} = Lisp.run(source)
      # Maps have undefined order, but check contents
      assert length(result) == 4
      assert :a in result
      assert :b in result
      assert 1 in result
      assert 2 in result
    end

    test "mapcat practical example: flatten nested tags" do
      source = """
      (let [posts [{:title "Post 1" :tags ["elixir" "beam"]}
                   {:title "Post 2" :tags ["clojure"]}
                   {:title "Post 3" :tags []}]]
        (->> posts
             (mapcat :tags)
             (distinct)))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == ["elixir", "beam", "clojure"]
    end
  end

  # ==========================================================================
  # concat - type error diagnostics
  # ==========================================================================

  describe "concat type errors" do
    test "concat with strings gives clear error instead of Enumerable protocol error" do
      {:error, %Step{fail: %{reason: :type_error, message: message}}} =
        Lisp.run(~s|(concat "hello" "world")|)

      assert message =~ "concat expected collections"
      assert message =~ "string"
    end

    test "apply concat on flat string list gives clear error" do
      # This is the exact pattern from the benchmark failure:
      # (apply concat (:topics doc)) where topics is already a flat list of strings
      {:error, %Step{fail: %{reason: :type_error, message: message}}} =
        Lisp.run(~s|(apply concat ["security" "compliance"])|)

      assert message =~ "concat expected collections"
      assert message =~ ~s("security")
    end
  end

  # ==========================================================================
  # Variadic Builtins in HOFs (GH-668)
  # ==========================================================================

  describe "variadic builtins in HOFs (GH-668)" do
    test "map with variadic + across multiple collections" do
      {:ok, %Step{return: result}} = Lisp.run("(map + [1 2] [10 20] [100 200])")
      assert result == [111, 222]
    end

    test "map with unary minus (negation)" do
      {:ok, %Step{return: result}} = Lisp.run("(map - [1 2 3])")
      assert result == [-1, -2, -3]
    end

    test "map with multi-arity range" do
      {:ok, %Step{return: result}} = Lisp.run("(map range [1 2 3])")
      assert result == [[0], [0, 1], [0, 1, 2]]
    end

    test "filter with variadic +" do
      {:ok, %Step{return: result}} = Lisp.run("(filter + [0 1 2 nil])")
      assert result == [0, 1, 2]
    end

    test "reduce with variadic + and initial value" do
      {:ok, %Step{return: result}} = Lisp.run("(reduce + 0 [1 2 3 4])")
      assert result == 10
    end

    test "reduce with variadic + without initial value" do
      {:ok, %Step{return: result}} = Lisp.run("(reduce + [1 2 3 4])")
      assert result == 10
    end

    test "map with variadic * across two collections" do
      {:ok, %Step{return: result}} = Lisp.run("(map * [1 2 3] [10 20 30])")
      assert result == [10, 40, 90]
    end

    test "some with variadic builtin" do
      {:ok, %Step{return: result}} = Lisp.run("(some + [nil nil 1 nil])")
      assert result == 1
    end

    test "every? with variadic builtin" do
      {:ok, %Step{return: result}} = Lisp.run("(every? + [1 2 3])")
      assert result == true
    end

    test "map-indexed with variadic +" do
      {:ok, %Step{return: result}} = Lisp.run("(map-indexed + [10 20 30])")
      assert result == [10, 21, 32]
    end
  end

  describe "_by functions with map arguments" do
    test "max-by second on map returns entry with largest value" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(max-by second {:a 1 :b 3 :c 2})|)
      assert result == [:b, 3]
    end

    test "min-by second on map returns entry with smallest value" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(min-by second {:a 1 :b 3 :c 2})|)
      assert result == [:a, 1]
    end

    test "sum-by second on map sums all values" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(sum-by second {:a 1 :b 3 :c 2})|)
      assert result == 6
    end

    test "avg-by second on map averages all values" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(avg-by second {:a 1 :b 3 :c 2})|)
      assert result == 2.0
    end

    test "group-by first on map groups entries by key" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(group-by first {:a 1 :b 2})|)
      assert result == %{a: [[:a, 1]], b: [[:b, 2]]}
    end

    test "distinct-by second on map removes entries with duplicate values" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(distinct-by second {:a 1 :b 1 :c 2})|)
      assert length(result) == 2
      seconds = Enum.map(result, &List.last/1)
      assert Enum.sort(seconds) == [1, 2]
    end

    test "sum-by with anonymous function on map" do
      source = ~S|(sum-by (fn [entry] (second entry)) {:a 1 :b 3 :c 2})|
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == 6
    end

    test "max-by with anonymous function on map" do
      source = ~S|(max-by (fn [entry] (second entry)) {:a 1 :b 3 :c 2})|
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [:b, 3]
    end
  end

  describe "_by functions with MapSet arguments" do
    test "max-by identity on set returns max element" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(max-by identity (set [1 3 2]))|)
      assert result == 3
    end

    test "min-by identity on set returns min element" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(min-by identity (set [1 3 2]))|)
      assert result == 1
    end

    test "sum-by identity on set sums all elements" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(sum-by identity (set [1 3 2]))|)
      assert result == 6
    end

    test "avg-by identity on set averages all elements" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(avg-by identity (set [1 3 2]))|)
      assert result == 2.0
    end

    test "group-by identity on set groups elements" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(group-by identity (set [1 2 3]))|)
      assert result == %{1 => [1], 2 => [2], 3 => [3]}
    end

    test "distinct-by identity on set returns all elements (already unique)" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(distinct-by identity (set [1 2 3]))|)
      assert Enum.sort(result) == [1, 2, 3]
    end

    test "sort-by identity on set returns sorted list" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(sort-by identity (set [3 1 2]))|)
      assert result == [1, 2, 3]
    end

    test "sum-by :age on set of maps" do
      source = ~S|(sum-by :age (set [{:name "alice" :age 30} {:name "bob" :age 25}]))|
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == 55
    end
  end

  describe "keep" do
    @describetag :keep

    test "even? returns true/false (never nil), so keep preserves all results" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(keep even? (range 1 10))|)
      assert result == [false, true, false, true, false, true, false, true, false]
    end

    test "conditional return filters and transforms" do
      {:ok, %Step{return: result}} =
        Lisp.run(~S|(keep (fn [x] (when (odd? x) x)) (range 10))|)

      assert result == [1, 3, 5, 7, 9]
    end

    test "identity keeps false but drops nil" do
      {:ok, %Step{return: result}} =
        Lisp.run(~S|(keep identity [false nil 1 2 nil 3])|)

      assert result == [false, 1, 2, 3]
    end

    test "transform and filter in one step" do
      {:ok, %Step{return: result}} =
        Lisp.run(~S|(keep (fn [x] (when (> x 2) (* x x))) [1 2 3 4 5])|)

      assert result == [9, 16, 25]
    end

    test "empty collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(keep identity [])|)
      assert result == []
    end

    test "nil collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(keep identity nil)|)
      assert result == []
    end

    test "all-nil results" do
      {:ok, %Step{return: result}} =
        Lisp.run(~S|(keep (fn [x] nil) [1 2 3])|)

      assert result == []
    end

    test "map entry handling" do
      {:ok, %Step{return: result}} =
        Lisp.run(~S|(keep (fn [[k v]] (when (> v 1) k)) {:a 1 :b 2 :c 3})|)

      assert Enum.sort(result) == [:b, :c]
    end
  end

  # ==========================================================================
  # Non-list collection predicate combinations (#815)
  # ==========================================================================

  describe "filter with non-list collections" do
    test "keyword predicate on set collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(filter :a #{{:a 1} {:b 2}})|)
      assert result == [%{a: 1}]
    end

    test "MapSet predicate on set collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(filter #{1 2} #{1 3 5})|)
      assert Enum.sort(result) == [1]
    end

    test "keyword predicate on map collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(filter :a {:a 1 :b 2})|)
      assert result == []
    end

    test "MapSet predicate on map collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(filter #{[:a 1]} {:a 1 :b 2})|)
      assert result == [[:a, 1]]
    end

    test "keyword predicate on string returns empty" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(filter :a "abc")|)
      assert result == []
    end
  end

  describe "remove with non-list collections" do
    test "keyword predicate on set collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(remove :a #{{:a 1} {:b 2}})|)
      assert result == [%{b: 2}]
    end

    test "MapSet predicate on set collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(remove #{1 2} #{1 3 5})|)
      assert Enum.sort(result) == [3, 5]
    end

    test "keyword predicate on map collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(remove :a {:a 1 :b 2})|)
      assert length(result) == 2
    end

    test "MapSet predicate on map collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(remove #{[:a 1]} {:a 1 :b 2})|)
      assert result == [[:b, 2]]
    end

    test "keyword predicate on string keeps all graphemes" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(remove :a "abc")|)
      assert result == ["a", "b", "c"]
    end
  end

  describe "keep with non-list collections" do
    test "keyword predicate on set collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(keep :a #{{:a 1} {:b 2}})|)
      assert result == [1]
    end

    test "MapSet predicate on set collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(keep #{1 2} #{1 3})|)
      assert result == [1]
    end

    test "MapSet predicate on string" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(keep #{"1" "2"} "123")|)
      assert Enum.sort(result) == ["1", "2"]
    end

    test "keyword predicate on map collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(keep :a {:a 1 :b 2})|)
      assert result == []
    end

    test "MapSet predicate on map collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(keep #{[:a 1]} {:a 1 :b 2})|)
      assert result == [[:a, 1]]
    end

    test "keyword predicate on string returns empty" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(keep :a "abc")|)
      assert result == []
    end
  end

  describe "find with non-list collections" do
    test "keyword predicate on set collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(find :a #{{:b 2} {:a 1}})|)
      assert result == %{a: 1}
    end

    test "function predicate on set collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(find even? #{1 2 3})|)
      assert result == 2
    end

    test "MapSet predicate on set collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(find #{2 4} #{1 2 3})|)
      assert result == 2
    end

    test "MapSet predicate on string" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(find #{"b" "c"} "abc")|)
      assert result == "b"
    end

    test "function predicate on map collection" do
      {:ok, %Step{return: result}} =
        Lisp.run(~S|(find (fn [[k v]] (> v 1)) {:a 1 :b 2})|)

      assert result == [:b, 2]
    end

    test "keyword predicate on map collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(find :a {:a 1 :b 2})|)
      # keyword on [k,v] pairs returns nil, so find returns nil
      assert result == nil
    end

    test "MapSet predicate on map collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(find #{[:a 1]} {:a 1 :b 2})|)
      assert result == [:a, 1]
    end

    test "keyword predicate on string returns nil" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(find :a "abc")|)
      assert result == nil
    end
  end

  describe "map with non-list collections" do
    test "keyword predicate on set collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(map :a #{{:a 1} {:a 2}})|)
      assert Enum.sort(result) == [1, 2]
    end

    test "MapSet predicate on set collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(map #{1 2} #{1 3})|)
      assert Enum.sort(result) == Enum.sort([nil, 1])
    end

    test "keyword predicate on map collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(map :a {:a 1 :b 2})|)
      assert length(result) == 2
    end

    test "MapSet predicate on map collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(map #{[:a 1]} {:a 1 :b 2})|)
      assert Enum.sort(result) == [nil, [:a, 1]]
    end

    test "keyword predicate on string returns nils" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(map :a "abc")|)
      assert result == [nil, nil, nil]
    end
  end

  describe "mapv with non-list collections" do
    test "keyword predicate on set collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(mapv :a #{{:a 1} {:a 2}})|)
      assert Enum.sort(result) == [1, 2]
    end

    test "MapSet predicate on set collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(mapv #{1 2} #{1 3})|)
      assert Enum.sort(result) == Enum.sort([nil, 1])
    end

    test "keyword predicate on map collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(mapv :a {:a 1 :b 2})|)
      assert length(result) == 2
    end

    test "MapSet predicate on map collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(mapv #{[:a 1]} {:a 1 :b 2})|)
      assert Enum.sort(result) == [nil, [:a, 1]]
    end

    test "keyword predicate on string returns nils" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(mapv :a "abc")|)
      assert result == [nil, nil, nil]
    end
  end

  describe "some with non-list collections" do
    test "keyword predicate on set" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(some :a #{{:a 1} {:b 2}})|)
      assert result == 1
    end

    test "MapSet predicate on set" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(some #{1 2} #{3 1})|)
      assert result == 1
    end

    test "keyword predicate on map" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(some :a {:a 1 :b 2})|)
      # keyword on [k,v] pairs always returns nil/false
      assert result == nil
    end

    test "MapSet predicate on map" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(some #{[:a 1]} {:a 1 :b 2})|)
      assert result == [:a, 1]
    end
  end

  describe "every? with non-list collections" do
    test "keyword predicate on set" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(every? :a #{{:a 1} {:a 2}})|)
      assert result == true
    end

    test "keyword predicate on set with missing key" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(every? :a #{{:a 1} {:b 2}})|)
      assert result == false
    end

    test "MapSet predicate on set" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(every? #{1 2 3} #{1 2})|)
      assert result == true
    end

    test "MapSet predicate on set fails" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(every? #{1 2} #{1 3})|)
      assert result == false
    end

    test "keyword predicate on map" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(every? :a {:a 1 :b 2})|)
      assert result == false
    end

    test "MapSet predicate on map" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(every? #{[:a 1] [:b 2]} {:a 1 :b 2})|)
      assert result == true
    end
  end

  describe "not-any? with non-list collections" do
    test "keyword predicate on set" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(not-any? :a #{{:b 1} {:c 2}})|)
      assert result == true
    end

    test "keyword predicate on set with match" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(not-any? :a #{{:a 1} {:b 2}})|)
      assert result == false
    end

    test "MapSet predicate on set" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(not-any? #{1 2} #{3 4})|)
      assert result == true
    end

    test "keyword predicate on map" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(not-any? :a {:a 1 :b 2})|)
      assert result == true
    end

    test "MapSet predicate on map" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(not-any? #{[:a 1]} {:a 1 :b 2})|)
      assert result == false
    end
  end

  # ============================================================
  # into
  # ============================================================

  describe "into" do
    test "into [] with map converts entries to vectors" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(into [] {:a 1 :b 2})|)
      assert length(result) == 2
      assert [:a, 1] in result
      assert [:b, 2] in result
    end

    test "into [] with empty map returns empty list" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(into [] {})|)
      assert result == []
    end

    test "into [] with list keeps elements as-is" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(into [] [1 2 3])|)
      assert result == [1, 2, 3]
    end

    test "into with existing vector appends list elements" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(into [99] [1 2])|)
      assert result == [99, 1, 2]
    end

    test "into #{} with list adds elements to set" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(into #{} [1 2 3])|)
      assert result == MapSet.new([1, 2, 3])
    end

    test "into #{1} with list adds new elements" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(into #{1} [2 3])|)
      assert result == MapSet.new([1, 2, 3])
    end

    test "into {} with list of pairs creates map" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(into {} [[:a 1] [:b 2]])|)
      assert result == %{a: 1, b: 2}
    end

    test "into {} with another map merges them" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(into {:a 1} {:b 2})|)
      assert result == %{a: 1, b: 2}
    end

    test "into {:a 1} with list of pairs overwrites existing key" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(into {:a 1} [[:a 2]])|)
      assert result == %{a: 2}
    end

    test "into with nil source returns original collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(into [1 2] nil)|)
      assert result == [1, 2]
    end
  end

  # ============================================================
  # entries, key, val
  # ============================================================

  describe "entries" do
    test "entries on map returns sorted list of pairs" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(entries {:z 26 :a 1 :m 13})|)
      assert result == [[:a, 1], [:m, 13], [:z, 26]]
    end

    test "entries on empty map returns empty list" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(entries {})|)
      assert result == []
    end
  end

  describe "key and val" do
    test "key extracts key from entry" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(key [:a 1])|)
      assert result == :a
    end

    test "val extracts value from entry" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(val [:a 1])|)
      assert result == 1
    end
  end

  # ============================================================
  # zip
  # ============================================================

  describe "zip" do
    test "zip returns list of vectors" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(zip [1 2 3] [:a :b :c])|)
      assert result == [[1, :a], [2, :b], [3, :c]]
    end

    test "zip with unequal lengths truncates to shorter" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(zip [1 2] [:a :b :c])|)
      assert result == [[1, :a], [2, :b]]
    end

    test "zip with empty lists returns empty list" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(zip [] [])|)
      assert result == []
    end

    test "zip elements are accessible with first/second" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(first (first (zip [1 2] [:a :b])))|)
      assert result == 1
    end
  end

  # ============================================================
  # parse-long, parse-double
  # ============================================================

  describe "parse-long" do
    test "parses valid integers" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(parse-long "42")|)
      assert result == 42
    end

    test "returns nil for invalid input" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(parse-long "abc")|)
      assert result == nil
    end

    test "returns nil for float string" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(parse-long "3.14")|)
      assert result == nil
    end

    test "handles nil" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(parse-long nil)|)
      assert result == nil
    end
  end

  describe "parse-double" do
    test "parses valid floats" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(parse-double "3.14")|)
      assert result == 3.14
    end

    test "parses integer string as float" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(parse-double "42")|)
      assert result == 42.0
    end

    test "returns nil for invalid input" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(parse-double "abc")|)
      assert result == nil
    end
  end

  # ============================================================
  # empty?, not-empty
  # ============================================================

  describe "empty? and not-empty" do
    test "empty? returns true for empty collections" do
      {:ok, %Step{return: r1}} = Lisp.run(~S|(empty? [])|)
      {:ok, %Step{return: r2}} = Lisp.run(~S|(empty? "")|)
      {:ok, %Step{return: r3}} = Lisp.run(~S|(empty? {})|)
      {:ok, %Step{return: r4}} = Lisp.run(~S|(empty? #{})|)
      assert r1 == true
      assert r2 == true
      assert r3 == true
      assert r4 == true
    end

    test "empty? returns true for nil" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(empty? nil)|)
      assert result == true
    end

    test "empty? returns false for non-empty collections" do
      {:ok, %Step{return: r1}} = Lisp.run(~S|(empty? [1])|)
      {:ok, %Step{return: r2}} = Lisp.run(~S|(empty? "a")|)
      {:ok, %Step{return: r3}} = Lisp.run(~S|(empty? {:a 1})|)
      assert r1 == false
      assert r2 == false
      assert r3 == false
    end

    test "not-empty returns collection for non-empty, nil for empty" do
      {:ok, %Step{return: r1}} = Lisp.run(~S|(not-empty [1 2])|)
      {:ok, %Step{return: r2}} = Lisp.run(~S|(not-empty [])|)
      {:ok, %Step{return: r3}} = Lisp.run(~S|(not-empty nil)|)
      assert r1 == [1, 2]
      assert r2 == nil
      assert r3 == nil
    end
  end

  # ============================================================
  # String operations
  # ============================================================

  describe "subs" do
    test "returns substring from start index" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(subs "hello" 1)|)
      assert result == "ello"
    end

    test "returns substring from start to end index" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(subs "hello" 1 3)|)
      assert result == "el"
    end

    test "handles out of bounds" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(subs "hello" 10)|)
      assert result == ""
    end
  end

  describe "join" do
    test "joins collection with separator" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(join ", " ["a" "b" "c"])|)
      assert result == "a, b, c"
    end

    test "joins without separator" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(join ["a" "b" "c"])|)
      assert result == "abc"
    end

    test "converts elements to strings" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(join ", " [1 "two" true])|)
      assert result == "1, two, true"
    end

    test "handles empty collection" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(join ", " [])|)
      assert result == ""
    end
  end

  describe "split" do
    test "splits string by separator" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(split "a,b,c" ",")|)
      assert result == ["a", "b", "c"]
    end

    test "splits into graphemes when separator is empty" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(split "hello" "")|)
      assert result == ["h", "e", "l", "l", "o"]
    end
  end

  describe "trim" do
    test "removes leading and trailing whitespace" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(trim "  hello  ")|)
      assert result == "hello"
    end
  end

  describe "replace (string)" do
    test "replaces all occurrences" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(replace "hello" "l" "L")|)
      assert result == "heLLo"
    end

    test "handles no match" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(replace "hello" "x" "y")|)
      assert result == "hello"
    end
  end

  describe "upcase and downcase" do
    test "upcase converts to uppercase" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(upcase "hello")|)
      assert result == "HELLO"
    end

    test "downcase converts to lowercase" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(downcase "HELLO")|)
      assert result == "hello"
    end
  end

  describe "starts-with?, ends-with?, includes?" do
    test "starts-with? checks prefix" do
      {:ok, %Step{return: r1}} = Lisp.run(~S|(starts-with? "hello" "he")|)
      {:ok, %Step{return: r2}} = Lisp.run(~S|(starts-with? "hello" "x")|)
      assert r1 == true
      assert r2 == false
    end

    test "ends-with? checks suffix" do
      {:ok, %Step{return: r1}} = Lisp.run(~S|(ends-with? "hello" "lo")|)
      {:ok, %Step{return: r2}} = Lisp.run(~S|(ends-with? "hello" "x")|)
      assert r1 == true
      assert r2 == false
    end

    test "includes? checks substring" do
      {:ok, %Step{return: r1}} = Lisp.run(~S|(includes? "hello" "ll")|)
      {:ok, %Step{return: r2}} = Lisp.run(~S|(includes? "hello" "x")|)
      assert r1 == true
      assert r2 == false
    end
  end

  # ============================================================
  # filter/remove with set predicate on string
  # ============================================================

  describe "filter/remove with set predicate on string" do
    test "filter string characters using set predicate" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(filter #{"r"} "raspberry")|)
      assert result == ["r", "r", "r"]
    end

    test "remove string characters using set predicate" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(remove #{"r"} "raspberry")|)
      assert result == ["a", "s", "p", "b", "e", "y"]
    end
  end

  # ============================================================
  # range
  # ============================================================

  describe "range" do
    test "range(end) returns sequence from 0 to end exclusive" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(range 5)|)
      assert result == [0, 1, 2, 3, 4]
    end

    test "range(start, end) returns sequence" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(range 5 10)|)
      assert result == [5, 6, 7, 8, 9]
    end

    test "range(start, end, step) returns sequence with step" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(range 0 10 2)|)
      assert result == [0, 2, 4, 6, 8]
    end

    test "range with negative step" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(range 10 0 -2)|)
      assert result == [10, 8, 6, 4, 2]
    end

    test "range with empty result" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(range 0)|)
      assert result == []
    end
  end

  # ============================================================
  # frequencies
  # ============================================================

  describe "frequencies" do
    test "counts occurrences of each element" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(frequencies [1 2 1 3 2 1])|)
      assert result == %{1 => 3, 2 => 2, 3 => 1}
    end

    test "handles empty list" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(frequencies [])|)
      assert result == %{}
    end

    test "handles strings as graphemes" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(frequencies "hello")|)
      assert result == %{"h" => 1, "e" => 1, "l" => 2, "o" => 1}
    end
  end

  # ============================================================
  # butlast, take-last, drop-last
  # ============================================================

  describe "butlast" do
    test "returns all but last element" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(butlast [1 2 3 4])|)
      assert result == [1, 2, 3]
    end

    test "returns empty list for single-element list" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(butlast [1])|)
      assert result == []
    end

    test "returns empty list for nil" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(butlast nil)|)
      assert result == []
    end

    test "works on strings (graphemes)" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(butlast "hello")|)
      assert result == ["h", "e", "l", "l"]
    end
  end

  describe "take-last" do
    test "returns last n elements" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(take-last 2 [1 2 3 4])|)
      assert result == [3, 4]
    end

    test "returns all elements when n > length" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(take-last 5 [1 2])|)
      assert result == [1, 2]
    end

    test "returns empty list when n is 0" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(take-last 0 [1 2 3])|)
      assert result == []
    end

    test "works on strings (graphemes)" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(take-last 2 "hello")|)
      assert result == ["l", "o"]
    end
  end

  describe "drop-last" do
    test "drops last element by default" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(drop-last [1 2 3 4])|)
      assert result == [1, 2, 3]
    end

    test "drops last n elements" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(drop-last 2 [1 2 3 4])|)
      assert result == [1, 2]
    end

    test "returns empty list when dropping all" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(drop-last 3 [1 2 3])|)
      assert result == []
    end

    test "works on strings" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(drop-last "hello")|)
      assert result == ["h", "e", "l", "l"]
    end
  end

  # ============================================================
  # reduce on various collection types
  # ============================================================

  describe "reduce" do
    test "reduce on lists" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(reduce + 0 [1 2 3])|)
      assert result == 6
    end

    test "reduce on maps" do
      {:ok, %Step{return: result}} =
        Lisp.run(~S|(reduce (fn [acc [_ v]] (+ acc v)) 0 {:a 1 :b 2})|)

      assert result == 3
    end

    test "reduce on strings (graphemes)" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(reduce (fn [acc x] (str acc "-" x)) "a" "bc")|)
      assert result == "a-b-c"
    end

    test "reduce on empty collection with init" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(reduce + 99 [])|)
      assert result == 99
    end

    test "reduce 2-arg on single element returns element without calling f" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(reduce + [42])|)
      assert result == 42
    end
  end

  # ============================================================
  # sort-by on maps
  # ============================================================

  describe "sort-by on maps" do
    test "sort-by on map returns sorted list of pairs" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(sort-by second {:a 3 :b 1 :c 2})|)
      assert result == [[:b, 1], [:c, 2], [:a, 3]]
    end

    test "sort-by on empty map returns empty list" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(sort-by second {})|)
      assert result == []
    end
  end

  # ============================================================
  # filter/remove on maps (seqable map support)
  # ============================================================

  describe "filter on maps" do
    test "filter on map returns matching entries as pairs" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(filter (fn [[_ v]] (> v 1)) {:a 1 :b 2 :c 3})|)
      assert Enum.sort(result) == [[:b, 2], [:c, 3]]
    end

    test "filter on empty map returns empty list" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(filter (fn [_] true) {})|)
      assert result == []
    end
  end

  describe "remove on maps" do
    test "remove on map removes matching entries" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(remove (fn [[_ v]] (= v 2)) {:a 1 :b 2 :c 3})|)
      assert Enum.sort(result) == [[:a, 1], [:c, 3]]
    end
  end

  # ============================================================
  # take/drop/take-while/drop-while/distinct on maps
  # ============================================================

  describe "take and drop on maps" do
    test "take on map returns n pairs" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(take 2 {:a 1 :b 2 :c 3})|)
      assert length(result) == 2
    end

    test "drop on map drops n pairs" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(drop 1 {:a 1 :b 2 :c 3})|)
      assert length(result) == 2
    end

    test "take on empty map returns empty list" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(take 2 {})|)
      assert result == []
    end

    test "distinct on map returns all pairs" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(distinct {:a 1 :b 2})|)
      assert length(result) == 2
    end
  end

  # ============================================================
  # map-indexed
  # ============================================================

  describe "map-indexed" do
    test "maps over a list with index" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(map-indexed (fn [i x] [i x]) ["a" "b" "c"])|)
      assert result == [[0, "a"], [1, "b"], [2, "c"]]
    end

    test "maps over a string with index" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(map-indexed (fn [i x] [i x]) "abc")|)
      assert result == [[0, "a"], [1, "b"], [2, "c"]]
    end

    test "works with empty list" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(map-indexed (fn [i x] [i x]) [])|)
      assert result == []
    end

    test "maps over a map with index" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(map-indexed (fn [i x] [i x]) {:a 1})|)
      assert result == [[0, [:a, 1]]]
    end
  end

  # ==========================================================================
  # cons - Prepend to sequence
  # ==========================================================================

  describe "cons" do
    test "prepends to vector" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(cons 1 [2 3])|)
      assert result == [1, 2, 3]
    end

    test "cons on nil returns single-element list" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(cons 1 nil)|)
      assert result == [1]
    end

    test "cons on empty vector" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(cons 1 [])|)
      assert result == [1]
    end

    test "cons on set" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(cons 0 #{1 2})|)
      assert 0 in result
      assert length(result) == 3
    end

    test "cons on map" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(cons :x {:a 1})|)
      assert hd(result) == :x
    end

    test "cons on string" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(cons "x" "ab")|)
      assert result == ["x", "a", "b"]
    end
  end

  # ==========================================================================
  # disj - Remove from set
  # ==========================================================================

  describe "disj" do
    test "removes element from set" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(disj #{1 2 3} 2)|)
      assert result == MapSet.new([1, 3])
    end

    test "removing non-existent element returns same set" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(disj #{1 2} 5)|)
      assert result == MapSet.new([1, 2])
    end

    test "disj on nil returns nil" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(disj nil :a)|)
      assert result == nil
    end

    test "variadic disj removes multiple elements" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(disj #{1 2 3 4} 2 4)|)
      assert result == MapSet.new([1, 3])
    end
  end

  # ==========================================================================
  # empty - Returns empty collection of same type
  # ==========================================================================

  describe "empty" do
    test "empty vector" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(empty [1 2 3])|)
      assert result == []
    end

    test "empty map" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(empty {:a 1})|)
      assert result == %{}
    end

    test "empty set" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(empty #{1 2})|)
      assert result == MapSet.new()
    end

    test "empty string" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(empty "hello")|)
      assert result == ""
    end

    test "empty nil returns nil" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(empty nil)|)
      assert result == nil
    end
  end

  # ==========================================================================
  # merge-with - Merge maps with combining function
  # ==========================================================================

  describe "merge-with" do
    test "merges with addition" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(merge-with + {:a 1 :b 2} {:a 3 :c 4})|)
      assert result == %{a: 4, b: 2, c: 4}
    end

    test "merges multiple maps" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(merge-with + {:a 1} {:a 2} {:a 3})|)
      assert result == %{a: 6}
    end

    test "merge-with no maps returns empty map" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(merge-with +)|)
      assert result == %{}
    end

    test "merge-with nil maps treated as empty" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(merge-with + nil {:a 1})|)
      assert result == %{a: 1}
    end

    test "merge-with conj for aggregation" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(merge-with conj {:a [1]} {:a [2]})|)
      assert result == %{a: [1, [2]]}
    end

    test "merge-with zero args raises error" do
      {:error, _} = Lisp.run(~S|(merge-with)|)
    end
  end

  # ==========================================================================
  # reduce-kv - Reduce over map key-value pairs
  # ==========================================================================

  describe "reduce-kv" do
    test "sums values in a map" do
      {:ok, %Step{return: result}} =
        Lisp.run(~S|(reduce-kv (fn [acc k v] (+ acc v)) 0 {:a 1 :b 2 :c 3})|)

      assert result == 6
    end

    test "builds new map from key-value pairs" do
      {:ok, %Step{return: result}} =
        Lisp.run(~S|(reduce-kv (fn [acc k v] (assoc acc k (* v 2))) {} {:a 1 :b 2})|)

      assert result == %{a: 2, b: 4}
    end

    test "reduce-kv on nil returns init" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(reduce-kv (fn [acc k v] (+ acc v)) 42 nil)|)
      assert result == 42
    end

    test "reduce-kv on empty map returns init" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(reduce-kv (fn [acc k v] (+ acc v)) 0 {})|)
      assert result == 0
    end

    test "collects keys" do
      {:ok, %Step{return: result}} =
        Lisp.run(~S|(reduce-kv (fn [acc k v] (conj acc k)) [] {:x 1 :y 2})|)

      assert Enum.sort(result) == [:x, :y]
    end
  end

  # ==========================================================================
  # zipmap - Create map from keys and values
  # ==========================================================================

  describe "zipmap" do
    test "creates map from keys and values" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(zipmap [:a :b :c] [1 2 3])|)
      assert result == %{a: 1, b: 2, c: 3}
    end

    test "truncates to shorter input" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(zipmap [:a :b] [1 2 3])|)
      assert result == %{a: 1, b: 2}
    end

    test "empty inputs" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(zipmap [] [])|)
      assert result == %{}
    end

    test "with string keys" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(zipmap ["x" "y"] [1 2])|)
      assert result == %{"x" => 1, "y" => 2}
    end

    test "with string as keys seq" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(zipmap "ab" [1 2])|)
      assert result == %{"a" => 1, "b" => 2}
    end

    test "with set as keys seq" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(zipmap #{:a :b} [1 2])|)
      assert map_size(result) == 2
    end
  end

  # ==========================================================================
  # hash-map - Create map from key-value pairs
  # ==========================================================================

  describe "hash-map" do
    test "creates empty map with no args" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(hash-map)|)
      assert result == %{}
    end

    test "creates map from key-value pairs" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(hash-map :a 1 :b 2)|)
      assert result == %{a: 1, b: 2}
    end

    test "creates map with string keys" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(hash-map "x" 1 "y" 2)|)
      assert result == %{"x" => 1, "y" => 2}
    end

    test "errors on odd number of arguments" do
      {:error, %Step{fail: fail}} = Lisp.run(~S|(hash-map :a 1 :b)|)
      assert fail.message =~ "even number"
    end
  end

  # ==========================================================================
  # filterv - Filter returning vector
  # ==========================================================================

  describe "filterv" do
    test "filters with predicate" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(filterv even? [1 2 3 4 5 6])|)
      assert result == [2, 4, 6]
    end

    test "equivalent to filter" do
      {:ok, %Step{return: r1}} = Lisp.run(~S|(filter odd? [1 2 3 4 5])|)
      {:ok, %Step{return: r2}} = Lisp.run(~S|(filterv odd? [1 2 3 4 5])|)
      assert r1 == r2
    end
  end

  # ==========================================================================
  # update-keys - Apply function to map keys
  # ==========================================================================

  describe "update-keys" do
    test "transforms keys with function" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(update-keys {:a 1 :b 2} str)|)
      assert result == %{":a" => 1, ":b" => 2}
    end

    test "update-keys on nil returns nil" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(update-keys nil str)|)
      assert result == nil
    end

    test "update-keys on empty map" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(update-keys {} str)|)
      assert result == %{}
    end

    test "collision - one value retained" do
      # Two keys that map to the same new key; retained value is unspecified
      {:ok, %Step{return: result}} = Lisp.run(~S|(update-keys {1 "a" 1.0 "b"} int)|)
      assert map_size(result) == 1
      assert Map.has_key?(result, 1)
    end
  end

  # ==========================================================================
  # keys / vals - nil tolerance
  # ==========================================================================

  describe "keys nil tolerance" do
    test "keys on nil returns nil" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(keys nil)|)
      assert result == nil
    end

    test "keys on nil nested access returns nil" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(keys (:missing {:a 1}))|)
      assert result == nil
    end
  end

  describe "vals nil tolerance" do
    test "vals on nil returns nil" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(vals nil)|)
      assert result == nil
    end

    test "vals on nil nested access returns nil" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(vals (:missing {:a 1}))|)
      assert result == nil
    end
  end

  # ==========================================================================
  # peek - Get last element without removing
  # ==========================================================================

  describe "peek" do
    test "returns last element of vector" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(peek [1 2 3])|)
      assert result == 3
    end

    test "peek on empty vector returns nil" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(peek [])|)
      assert result == nil
    end

    test "peek on nil returns nil" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(peek nil)|)
      assert result == nil
    end

    test "peek on single-element vector" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(peek [42])|)
      assert result == 42
    end
  end

  # ==========================================================================
  # pop - Remove last element
  # ==========================================================================

  describe "pop" do
    test "returns vector without last element" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(pop [1 2 3])|)
      assert result == [1, 2]
    end

    test "pop on single-element vector" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(pop [1])|)
      assert result == []
    end

    test "pop on nil returns nil" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(pop nil)|)
      assert result == nil
    end

    test "pop on empty vector returns nil" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(pop [])|)
      assert result == nil
    end
  end

  # ==========================================================================
  # subvec - Subvector
  # ==========================================================================

  describe "subvec" do
    test "basic subvector with start and end" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(subvec [0 1 2 3 4] 1 3)|)
      assert result == [1, 2]
    end

    test "subvec with only start" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(subvec [0 1 2 3 4] 2)|)
      assert result == [2, 3, 4]
    end

    test "subvec from beginning" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(subvec [0 1 2 3] 0 2)|)
      assert result == [0, 1]
    end

    test "subvec with start > end returns empty" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(subvec [0 1 2] 2 1)|)
      assert result == []
    end

    test "subvec with end past length clamps" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(subvec [0 1 2] 1 100)|)
      assert result == [1, 2]
    end

    test "subvec with negative start clamps to 0" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(subvec [0 1 2] -1 2)|)
      assert result == [0, 1]
    end

    test "subvec empty vector" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(subvec [] 0 0)|)
      assert result == []
    end
  end

  # ==========================================================================
  # split-at
  # ==========================================================================

  describe "split-at" do
    test "splits vector at index" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(split-at 2 [1 2 3 4 5])|)
      assert result == [[1, 2], [3, 4, 5]]
    end

    test "split-at 0 returns empty left" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(split-at 0 [1 2 3])|)
      assert result == [[], [1, 2, 3]]
    end

    test "split-at beyond length returns empty right" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(split-at 10 [1 2 3])|)
      assert result == [[1, 2, 3], []]
    end

    test "split-at negative n clamps to 0" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(split-at -1 [1 2 3])|)
      assert result == [[], [1, 2, 3]]
    end

    test "split-at nil returns two empty lists" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(split-at 2 nil)|)
      assert result == [[], []]
    end

    test "split-at string returns graphemes" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(split-at 2 "hello")|)
      assert result == [["h", "e"], ["l", "l", "o"]]
    end
  end

  # ==========================================================================
  # split-with
  # ==========================================================================

  describe "split-with" do
    test "splits by predicate" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(split-with pos? [1 2 -1 3])|)
      assert result == [[1, 2], [-1, 3]]
    end

    test "splits with even?" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(split-with even? [2 4 5 6])|)
      assert result == [[2, 4], [5, 6]]
    end

    test "nothing matches returns empty left" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(split-with pos? [-1 2 3])|)
      assert result == [[], [-1, 2, 3]]
    end

    test "everything matches returns empty right" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(split-with pos? [1 2 3])|)
      assert result == [[1, 2, 3], []]
    end

    test "splits map entries as [k v] pairs" do
      {:ok, %Step{return: result}} =
        Lisp.run(~S|(split-with (fn [[k v]] (> v 1)) {:a 2 :b 3 :c 0})|)

      # split-while on map: takes while pred true, then rest
      [left, right] = result
      assert is_list(left)
      assert is_list(right)
      assert length(left) + length(right) == 3
      assert Enum.all?(left ++ right, fn entry -> is_list(entry) and length(entry) == 2 end)
    end

    test "keyword pred on string returns empty left" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(split-with :x "abc")|)
      assert result == [[], ["a", "b", "c"]]
    end
  end

  # ==========================================================================
  # partition-by
  # ==========================================================================

  describe "partition-by" do
    test "partitions by predicate result" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(partition-by odd? [1 1 2 2 3])|)
      assert result == [[1, 1], [2, 2], [3]]
    end

    test "partitions by identity" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(partition-by identity [1 1 2 3 3])|)
      assert result == [[1, 1], [2], [3, 3]]
    end

    test "partitions by key function" do
      {:ok, %Step{return: result}} =
        Lisp.run(~S|(partition-by count ["a" "b" "ab" "cd"])|)

      assert result == [["a", "b"], ["ab", "cd"]]
    end

    test "partitions map entries as [k v] pairs" do
      {:ok, %Step{return: result}} =
        Lisp.run(~S|(partition-by second {:a 1 :b 1 :c 2})|)

      # Result is list of groups, each group is list of [k v] pairs
      assert is_list(result)
      assert Enum.all?(result, &is_list/1)
      flat = List.flatten(result)
      # Each entry is a [k v] pair — total entries equal map size
      assert length(flat) == 6
    end
  end

  # ==========================================================================
  # dedupe
  # ==========================================================================

  describe "dedupe" do
    test "removes consecutive duplicates" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(dedupe [1 1 2 3 3 2])|)
      assert result == [1, 2, 3, 2]
    end

    test "no consecutive duplicates returns same" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(dedupe [1 2 3])|)
      assert result == [1, 2, 3]
    end

    test "dedupe nil returns empty" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(dedupe nil)|)
      assert result == []
    end

    test "dedupe string removes consecutive duplicate graphemes" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(dedupe "aabcc")|)
      assert result == ["a", "b", "c"]
    end

    test "dedupe on map entries" do
      {:ok, %Step{return: result}} = Lisp.run(~S|(dedupe {:a 1 :b 2})|)
      assert is_list(result)
      assert Enum.all?(result, fn entry -> is_list(entry) and length(entry) == 2 end)
    end
  end

  # ==========================================================================
  # keep-indexed
  # ==========================================================================

  describe "keep-indexed" do
    test "keeps non-nil results with index" do
      {:ok, %Step{return: result}} =
        Lisp.run(~S|(keep-indexed (fn [idx v] (if (odd? idx) v)) [:a :b :c :d])|)

      assert result == [:b, :d]
    end

    test "returns index-value pairs" do
      {:ok, %Step{return: result}} =
        Lisp.run(~S|(keep-indexed (fn [i v] (if (pos? v) [i v])) [-1 0 2 3])|)

      assert result == [[2, 2], [3, 3]]
    end

    test "keeps by even index using when" do
      {:ok, %Step{return: result}} =
        Lisp.run(~S|(keep-indexed (fn [i v] (when (even? i) v)) [10 20 30 40])|)

      assert result == [10, 30]
    end

    test "preserves false, drops only nil" do
      {:ok, %Step{return: result}} =
        Lisp.run(~S|(keep-indexed (fn [i v] v) [false nil true nil])|)

      assert result == [false, true]
    end

    test "works on string input" do
      {:ok, %Step{return: result}} =
        Lisp.run(~S|(keep-indexed (fn [i v] (when (even? i) v)) "abcd")|)

      assert result == ["a", "c"]
    end

    test "works on map entries" do
      {:ok, %Step{return: result}} =
        Lisp.run(~S|(keep-indexed (fn [i entry] (when (zero? i) entry)) {:a 1 :b 2})|)

      assert length(result) == 1
      assert hd(result) |> is_list()
      assert hd(result) |> length() == 2
    end
  end
end
