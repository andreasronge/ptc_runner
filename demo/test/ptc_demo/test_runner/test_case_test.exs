defmodule PtcDemo.TestRunner.TestCaseTest do
  use ExUnit.Case, async: true

  alias PtcDemo.TestRunner.TestCase

  describe "common_test_cases/0" do
    test "returns a list of test cases" do
      cases = TestCase.common_test_cases()
      assert is_list(cases)
      assert length(cases) > 0
    end

    test "returns expected number of common test cases" do
      cases = TestCase.common_test_cases()
      # Unified test suite has 13 common cases covering 3 difficulty levels
      assert length(cases) == 13
    end

    test "each test case has required fields" do
      cases = TestCase.common_test_cases()

      Enum.each(cases, fn test_case ->
        assert Map.has_key?(test_case, :query)
        assert Map.has_key?(test_case, :expect)
        assert Map.has_key?(test_case, :constraint)
        assert Map.has_key?(test_case, :description)

        # Verify types
        assert is_binary(test_case.query)
        assert is_atom(test_case.expect)
        assert is_binary(test_case.description)
      end)
    end

    test "all queries are non-empty strings" do
      cases = TestCase.common_test_cases()

      Enum.each(cases, fn test_case ->
        assert String.length(test_case.query) > 0
        assert String.length(test_case.description) > 0
      end)
    end

    test "expect field contains valid types" do
      valid_types = [:integer, :number, :list, :string, :map]
      cases = TestCase.common_test_cases()

      Enum.each(cases, fn test_case ->
        assert test_case.expect in valid_types,
               "Invalid expect type: #{test_case.expect}"
      end)
    end

    test "constraint field is valid" do
      cases = TestCase.common_test_cases()

      Enum.each(cases, fn test_case ->
        constraint = test_case.constraint

        # Constraint should be a tuple or nil
        if constraint != nil do
          assert is_tuple(constraint),
                 "Constraint must be a tuple or nil, got: #{inspect(constraint)}"

          # First element should be constraint type
          constraint_type = elem(constraint, 0)
          valid_types = [:eq, :gt, :gte, :lt, :between, :length, :starts_with]

          assert constraint_type in valid_types,
                 "Invalid constraint type: #{constraint_type}"
        end
      end)
    end

    test "includes simple count test cases" do
      cases = TestCase.common_test_cases()

      # Check for product count test
      product_test = Enum.find(cases, fn tc -> String.contains?(tc.query, "products") end)
      assert product_test != nil
      assert product_test.expect == :integer
      assert product_test.constraint == {:eq, 500}
    end

    test "includes filtered count test cases" do
      cases = TestCase.common_test_cases()

      # Check for filtered status test (delivered orders)
      status_test =
        Enum.find(cases, fn tc -> String.contains?(tc.query, "delivered") end)

      assert status_test != nil
      assert status_test.expect == :integer
      # Constraint should be a range check
      assert elem(status_test.constraint, 0) == :between
    end

    test "includes aggregation test cases" do
      cases = TestCase.common_test_cases()

      # Check for total orders aggregation
      aggregation_test =
        Enum.find(cases, fn tc -> String.contains?(tc.query, "total revenue") end)

      assert aggregation_test != nil
    end

    test "includes boolean field filtering" do
      cases = TestCase.common_test_cases()

      # Check for remote employees test
      boolean_test =
        Enum.find(cases, fn tc -> String.contains?(tc.query, "remotely") end)

      assert boolean_test != nil
      assert boolean_test.expect == :integer
    end

    test "includes numeric comparison tests" do
      cases = TestCase.common_test_cases()

      # Check for price > $500 test
      numeric_test =
        Enum.find(cases, fn tc -> String.contains?(tc.query, "more than $500") end)

      assert numeric_test != nil
    end

    test "includes AND logic tests" do
      cases = TestCase.common_test_cases()

      # Check for combined conditions test
      and_test =
        Enum.find(cases, fn tc ->
          String.contains?(tc.query, "over $1000") and String.contains?(tc.query, "credit card")
        end)

      assert and_test != nil
    end

    test "includes OR logic tests" do
      cases = TestCase.common_test_cases()

      # Check for OR conditions test
      or_test =
        Enum.find(cases, fn tc ->
          String.contains?(tc.query, "cancelled or refunded")
        end)

      assert or_test != nil
    end

    test "includes find extreme value tests" do
      cases = TestCase.common_test_cases()

      # Check for cheapest product test
      min_test =
        Enum.find(cases, fn tc -> String.contains?(tc.query, "cheapest") end)

      assert min_test != nil
      assert min_test.expect == :string
    end

    test "includes top-N tests" do
      cases = TestCase.common_test_cases()

      # Check for top 3 most expensive products test
      topn_test =
        Enum.find(cases, fn tc -> String.contains?(tc.query, "3 most expensive") end)

      assert topn_test != nil
      assert topn_test.expect == :list
      assert topn_test.constraint == {:length, 3}
    end

    test "includes cross-dataset tests" do
      cases = TestCase.common_test_cases()

      # Check for distinct products ordered test
      cross_test =
        Enum.find(cases, fn tc -> String.contains?(tc.query, "unique products") end)

      assert cross_test != nil
    end

    test "does not have duplicate queries" do
      cases = TestCase.common_test_cases()
      queries = Enum.map(cases, & &1.query)
      unique_queries = Enum.uniq(queries)

      assert length(queries) == length(unique_queries),
             "Found duplicate test case queries"
    end
  end

  describe "lisp_specific_cases/0" do
    test "returns Lisp-only test cases" do
      cases = TestCase.lisp_specific_cases()
      assert is_list(cases)
      assert length(cases) == 1
    end
  end

  describe "multi_turn_cases/0" do
    test "returns a list of test cases" do
      cases = TestCase.multi_turn_cases()
      assert is_list(cases)
      assert length(cases) > 0
    end

    test "returns expected number of multi-turn test cases" do
      cases = TestCase.multi_turn_cases()
      # Based on the test case definitions, should have 2 multi-turn cases
      assert length(cases) == 2
    end

    test "each multi-turn test case has query field" do
      cases = TestCase.multi_turn_cases()

      Enum.each(cases, fn test_case ->
        assert Map.has_key?(test_case, :query),
               "Multi-turn test case must have :query field"

        assert is_binary(test_case.query),
               "query field must be a string"

        assert String.length(test_case.query) > 0
      end)
    end

    test "each multi-turn test case has expect and constraint" do
      cases = TestCase.multi_turn_cases()

      Enum.each(cases, fn test_case ->
        assert Map.has_key?(test_case, :expect)
        assert Map.has_key?(test_case, :constraint)
        assert Map.has_key?(test_case, :description)

        assert is_atom(test_case.expect)
        assert is_binary(test_case.description)
      end)
    end

    test "multi-turn tests have :max_turns > 1" do
      cases = TestCase.multi_turn_cases()

      Enum.each(cases, fn test_case ->
        assert Map.get(test_case, :max_turns, 1) > 1,
               "Multi-turn tests should have :max_turns > 1"
      end)
    end

    test "expect field contains valid types" do
      valid_types = [:integer, :number, :list, :string, :map]
      cases = TestCase.multi_turn_cases()

      Enum.each(cases, fn test_case ->
        assert test_case.expect in valid_types,
               "Invalid expect type: #{test_case.expect}"
      end)
    end

    test "includes complex reasoning test case" do
      cases = TestCase.multi_turn_cases()

      # Check for test that mentions searching or analyzing
      reasoning_tests =
        Enum.filter(cases, fn tc ->
          query = tc.query
          String.contains?(query, "Analyze") or String.contains?(query, "search")
        end)

      assert length(reasoning_tests) > 0,
             "Should have at least one test that demonstrates complex reasoning"
    end

    test "queries mention searching or analyzing" do
      cases = TestCase.multi_turn_cases()

      Enum.each(cases, fn test_case ->
        query = test_case.query

        # At least one query should mention storing or using stored values
        mentions_logic =
          String.contains?(query, "Analyze") or
            String.contains?(query, "search") or
            String.contains?(query, "suspicious")

        assert mentions_logic,
               "Multi-turn test should demonstrate complex reasoning"
      end)
    end

    test "constraint field is valid for multi-turn tests" do
      cases = TestCase.multi_turn_cases()

      Enum.each(cases, fn test_case ->
        constraint = test_case.constraint

        if constraint != nil do
          assert is_tuple(constraint),
                 "Constraint must be a tuple or nil"

          constraint_type = elem(constraint, 0)
          valid_types = [:eq, :gt, :gte, :lt, :between, :length, :starts_with]
          assert constraint_type in valid_types
        end
      end)
    end

    test "suspicious pattern test case structure" do
      cases = TestCase.multi_turn_cases()

      # Find the suspicious pattern test
      susp_test =
        Enum.find(cases, fn tc ->
          String.contains?(tc.query, "suspicious")
        end)

      assert susp_test != nil

      # Verify structure
      assert susp_test.expect == :integer
      assert susp_test.max_turns == 4
      assert elem(susp_test.constraint, 0) == :between
    end

    test "policy search test case structure" do
      cases = TestCase.multi_turn_cases()

      # Find the policy search test
      search_test =
        Enum.find(cases, fn tc ->
          String.contains?(tc.query, "search tool")
        end)

      assert search_test != nil

      # Verify structure
      assert search_test.expect == :string
      assert search_test.max_turns == 6
      assert search_test.constraint == {:eq, "Policy WFH-2024-REIMB"}
    end
  end

  describe "test case consistency across functions" do
    test "multi-turn cases are distinct from common cases" do
      common_queries = TestCase.common_test_cases() |> Enum.map(& &1.query)
      multi_queries = TestCase.multi_turn_cases() |> Enum.map(& &1.query)

      # Multi-turn queries should not appear in common cases
      Enum.each(multi_queries, fn multi_query ->
        # Check if exact query appears in common cases
        exact_match = Enum.any?(common_queries, &(&1 == multi_query))

        assert !exact_match,
               "Multi-turn query should not be identical to common case query"
      end)
    end

    test "all test cases have meaningful descriptions" do
      all_cases =
        TestCase.common_test_cases() ++
          TestCase.multi_turn_cases()

      Enum.each(all_cases, fn test_case ->
        description = test_case.description

        assert String.length(description) > 5,
               "Description too short: #{description}"

        # Should not be just the query repeated
        if Map.has_key?(test_case, :query) do
          refute description == test_case.query,
                 "Description should not be identical to query"
        end
      end)
    end
  end

  describe "test case validation" do
    test "all constraint values are reasonable" do
      all_cases =
        TestCase.common_test_cases() ++
          TestCase.multi_turn_cases()

      Enum.each(all_cases, fn test_case ->
        constraint = test_case.constraint

        case constraint do
          {:eq, val} ->
            # Equality values should be reasonable
            assert val != nil

          {:gt, min} ->
            # Greater than should have numeric value
            assert is_number(min) or is_integer(min)

          {:gte, min} ->
            assert is_number(min) or is_integer(min)

          {:lt, max} ->
            assert is_number(max) or is_integer(max)

          {:between, min, max} ->
            assert is_number(min) or is_integer(min)
            assert is_number(max) or is_integer(max)
            assert min <= max, "Min should be <= max in between constraint"

          {:length, len} ->
            assert is_integer(len)
            assert len >= 0

          {:starts_with, prefix} ->
            assert is_binary(prefix)

          nil ->
            # nil is acceptable (no constraint)
            :ok

          _ ->
            # Unknown constraint types
            :ok
        end
      end)
    end

    test "all expect types are valid" do
      valid_types = [:integer, :number, :list, :string, :map]

      all_cases =
        TestCase.common_test_cases() ++
          TestCase.multi_turn_cases()

      Enum.each(all_cases, fn test_case ->
        assert test_case.expect in valid_types,
               "Invalid expect type: #{test_case.expect} in query: #{test_case |> inspect()}"
      end)
    end
  end
end
