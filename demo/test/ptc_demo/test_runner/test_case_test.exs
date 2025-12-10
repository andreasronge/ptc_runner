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
      # Based on the test case definitions, should have 9 common cases
      assert length(cases) == 9
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

      # Check for filtered category test
      category_test =
        Enum.find(cases, fn tc -> String.contains?(tc.query, "electronics") end)

      assert category_test != nil
      assert category_test.expect == :integer
      # Constraint should be a range check
      assert elem(category_test.constraint, 0) == :between
    end

    test "includes aggregation test cases" do
      cases = TestCase.common_test_cases()

      # Check for total orders aggregation
      aggregation_test =
        Enum.find(cases, fn tc -> String.contains?(tc.query, "total") end)

      assert aggregation_test != nil
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
    test "returns a list of test cases" do
      cases = TestCase.lisp_specific_cases()
      assert is_list(cases)
      assert length(cases) > 0
    end

    test "returns expected number of lisp-specific test cases" do
      cases = TestCase.lisp_specific_cases()
      # Based on the test case definitions, should have 10 lisp-specific cases
      assert length(cases) == 10
    end

    test "each test case has required fields" do
      cases = TestCase.lisp_specific_cases()

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

    test "expect field contains valid types" do
      valid_types = [:integer, :number, :list, :string, :map]
      cases = TestCase.lisp_specific_cases()

      Enum.each(cases, fn test_case ->
        assert test_case.expect in valid_types,
               "Invalid expect type: #{test_case.expect}"
      end)
    end

    test "includes expense count test" do
      cases = TestCase.lisp_specific_cases()

      expense_test = Enum.find(cases, fn tc -> String.contains?(tc.query, "expenses") end)
      assert expense_test != nil
      assert expense_test.expect == :integer
      assert expense_test.constraint == {:eq, 800}
    end

    test "includes sort operation test cases" do
      cases = TestCase.lisp_specific_cases()

      # Check for sort-related tests (expensive product, highest paid employees)
      sort_tests =
        Enum.filter(cases, fn tc ->
          String.contains?(tc.query, "most expensive") or
            String.contains?(tc.query, "highest paid")
        end)

      assert length(sort_tests) >= 2, "Should have at least 2 sort-related tests"
    end

    test "includes list result test cases" do
      cases = TestCase.lisp_specific_cases()

      # Check for test with list expectation
      list_tests = Enum.filter(cases, fn tc -> tc.expect == :list end)
      assert length(list_tests) > 0

      # Check for length constraint
      length_tests =
        Enum.filter(list_tests, fn tc ->
          tc.constraint && elem(tc.constraint, 0) == :length
        end)

      assert length(length_tests) > 0
    end

    test "includes cross-dataset query tests" do
      cases = TestCase.lisp_specific_cases()

      # Check for tests that mention distinct, unique, or joining
      cross_dataset_tests =
        Enum.filter(cases, fn tc ->
          String.contains?(tc.query, "unique") or
            String.contains?(tc.query, "distinct") or
            String.contains?(tc.query, "department")
        end)

      assert length(cross_dataset_tests) > 0
    end

    test "does not have duplicate queries" do
      cases = TestCase.lisp_specific_cases()
      queries = Enum.map(cases, & &1.query)
      unique_queries = Enum.uniq(queries)

      assert length(queries) == length(unique_queries),
             "Found duplicate test case queries"
    end

    test "queries are different from common test cases" do
      common_queries = TestCase.common_test_cases() |> Enum.map(& &1.query)
      lisp_queries = TestCase.lisp_specific_cases() |> Enum.map(& &1.query)

      # There should be minimal overlap (some queries might be similar but not identical)
      common_set = MapSet.new(common_queries)
      lisp_set = MapSet.new(lisp_queries)
      overlap = MapSet.intersection(common_set, lisp_set)

      # Allow some overlap but most should be distinct
      assert MapSet.size(overlap) < length(lisp_queries) / 2
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

    test "each multi-turn test case has queries field" do
      cases = TestCase.multi_turn_cases()

      Enum.each(cases, fn test_case ->
        assert Map.has_key?(test_case, :queries),
               "Multi-turn test case must have :queries field"

        assert is_list(test_case.queries),
               "queries field must be a list"

        assert length(test_case.queries) >= 2,
               "Multi-turn tests must have at least 2 queries"

        # Each query should be a non-empty string
        Enum.each(test_case.queries, fn query ->
          assert is_binary(query)
          assert String.length(query) > 0
        end)
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

    test "multi-turn tests do not have :query field" do
      cases = TestCase.multi_turn_cases()

      Enum.each(cases, fn test_case ->
        assert !Map.has_key?(test_case, :query),
               "Multi-turn tests should use :queries, not :query"
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

    test "includes memory persistence test case" do
      cases = TestCase.multi_turn_cases()

      # Check for test that mentions storing and retrieving
      memory_tests =
        Enum.filter(cases, fn tc ->
          first_query = List.first(tc.queries)

          String.contains?(first_query, "store") or
            String.contains?(first_query, "memory")
        end)

      assert length(memory_tests) > 0,
             "Should have at least one test that demonstrates memory usage"
    end

    test "queries mention storing results for later use" do
      cases = TestCase.multi_turn_cases()

      Enum.each(cases, fn test_case ->
        # First query should often mention storing
        first_query = List.first(test_case.queries)
        second_query = Enum.at(test_case.queries, 1)

        # At least one query should mention storing or using stored values
        mentions_storage =
          String.contains?(first_query, "store") or
            String.contains?(first_query, "memory") or
            String.contains?(second_query, "memory") or
            String.contains?(second_query, "stored")

        assert mentions_storage,
               "Multi-turn test should demonstrate memory persistence"
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

    test "delivered orders percentage test case structure" do
      cases = TestCase.multi_turn_cases()

      # Find the delivered orders percentage test
      pct_test =
        Enum.find(cases, fn tc ->
          String.contains?(Enum.join(tc.queries), "percentage")
        end)

      assert pct_test != nil

      # Verify structure
      assert length(pct_test.queries) == 2
      assert pct_test.expect == :number
      assert pct_test.constraint == {:between, 1, 99}

      # First query should count and store
      first_query = List.first(pct_test.queries)

      assert String.contains?(first_query, "delivered") or
               String.contains?(first_query, "store")
    end

    test "engineering employees salary test case structure" do
      cases = TestCase.multi_turn_cases()

      # Find the engineering employees salary test
      eng_test =
        Enum.find(cases, fn tc ->
          String.contains?(Enum.join(tc.queries), "engineering")
        end)

      assert eng_test != nil

      # Verify structure
      assert length(eng_test.queries) == 2
      assert eng_test.expect == :number
      assert eng_test.constraint == {:between, 50_000, 200_000}

      # Both queries should reference engineering or stored employees
      full_text = Enum.join(eng_test.queries)

      assert String.contains?(full_text, "engineering") or
               String.contains?(full_text, "memory")
    end
  end

  describe "test case consistency across functions" do
    test "common and lisp cases do not have exact duplicate queries" do
      common_queries = TestCase.common_test_cases() |> Enum.map(& &1.query)
      lisp_queries = TestCase.lisp_specific_cases() |> Enum.map(& &1.query)

      common_set = MapSet.new(common_queries)
      lisp_set = MapSet.new(lisp_queries)

      # Some overlap is acceptable, but should be minority
      overlap = MapSet.intersection(common_set, lisp_set)
      assert MapSet.size(overlap) <= 1
    end

    test "multi-turn cases are distinct from common cases" do
      common_queries = TestCase.common_test_cases() |> Enum.map(& &1.query)
      multi_queries = TestCase.multi_turn_cases() |> Enum.map(&Enum.join(&1.queries))

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
          TestCase.lisp_specific_cases() ++
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
          TestCase.lisp_specific_cases() ++
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
          TestCase.lisp_specific_cases() ++
          TestCase.multi_turn_cases()

      Enum.each(all_cases, fn test_case ->
        assert test_case.expect in valid_types,
               "Invalid expect type: #{test_case.expect} in query: #{test_case |> inspect()}"
      end)
    end
  end
end
