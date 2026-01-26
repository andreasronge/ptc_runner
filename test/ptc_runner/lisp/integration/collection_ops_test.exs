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
end
