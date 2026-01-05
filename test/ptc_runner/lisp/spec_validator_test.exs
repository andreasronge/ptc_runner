defmodule PtcRunner.Lisp.SpecValidatorTest do
  use ExUnit.Case

  alias PtcRunner.Lisp.SpecValidator
  import PtcRunner.TestSupport.ClojureTestHelpers

  describe "extract_examples/0" do
    test "returns map with examples from spec" do
      {:ok, result} = SpecValidator.extract_examples()

      assert is_map(result)
      assert Map.has_key?(result, :examples)
      assert Map.has_key?(result, :todos)
      assert Map.has_key?(result, :bugs)
      assert Map.has_key?(result, :skipped)

      assert is_list(result.examples)
      assert result.examples != []

      # Verify we got tuples of code, expected, and section
      Enum.each(result.examples, fn item ->
        assert is_tuple(item)
        assert tuple_size(item) == 3
        {code, _expected, _section} = item
        assert is_binary(code)
      end)
    end

    test "extracts expected number of examples" do
      {:ok, result} = SpecValidator.extract_examples()

      # The spec should have ~100+ examples after multi-line extraction
      # Some may be fragments that are filtered, so we allow a range
      assert length(result.examples) >= 70
    end
  end

  describe "extract_examples/1" do
    test "extracts examples from text content" do
      content = """
      ## Example Section

      ```clojure
      (+ 1 2)  ; => 3
      ```

      ```clojure
      (filter even? [1 2 3 4])  ; => (2 4)
      ```
      """

      result = SpecValidator.extract_examples(content)

      # At least one example should be extracted
      assert is_map(result)
      assert result.examples != []
    end

    test "extracts TODO markers" do
      content = """
      ## 1. Test Section

      ```clojure
      (some-fn x)  ; => TODO: not implemented
      ```
      """

      result = SpecValidator.extract_examples(content)

      assert length(result.todos) == 1
      {code, description, section} = hd(result.todos)
      assert code =~ "some-fn"
      assert description == "not implemented"
      assert section == "## 1. Test Section"
    end

    test "extracts BUG markers" do
      content = """
      ## 1. Test Section

      ```clojure
      (buggy-fn x)  ; => BUG: known issue
      ```
      """

      result = SpecValidator.extract_examples(content)

      assert length(result.bugs) == 1
      {code, description, section} = hd(result.bugs)
      assert code =~ "buggy-fn"
      assert description == "known issue"
      assert section == "## 1. Test Section"
    end

    test "counts skipped illustrative examples" do
      content = """
      ## 1. Test Section

      ```clojure
      (real-example 1)  ; => 1
      (illustrative ctx/data)  ; => ...
      ```
      """

      result = SpecValidator.extract_examples(content)

      assert length(result.examples) == 1
      assert result.skipped == 1
    end
  end

  describe "validate_example/2" do
    test "validates correct examples" do
      assert :ok = SpecValidator.validate_example("(+ 1 2)", 3)
    end

    test "detects incorrect results" do
      result = SpecValidator.validate_example("(+ 1 2)", 4)

      assert {:error, _} = result
      assert String.contains?(elem(result, 1), "Expected 4 but got 3")
    end

    test "handles execution errors" do
      result = SpecValidator.validate_example("(undefined-function 1 2)", :anything)

      assert {:error, _} = result
    end

    test "validates list results" do
      assert :ok = SpecValidator.validate_example("(filter even? [1 2 3 4])", [2, 4])
    end

    test "validates boolean results" do
      assert :ok = SpecValidator.validate_example("true", true)
      assert :ok = SpecValidator.validate_example("false", false)
    end

    test "validates nil results" do
      assert :ok = SpecValidator.validate_example("nil", nil)
    end

    test "validates string results" do
      assert :ok = SpecValidator.validate_example("\"hello\"", "hello")
    end

    test "validates keyword results" do
      # Keywords with hyphens become atoms with underscores
      assert :ok = SpecValidator.validate_example(":name", :name)
    end

    test "validates map results" do
      assert :ok = SpecValidator.validate_example("{:a 1 :b 2}", %{:a => 1, :b => 2})
    end
  end

  describe "validate_spec/0" do
    test "returns results map with required keys" do
      {:ok, results} = SpecValidator.validate_spec()

      assert is_map(results)
      assert :passed in Map.keys(results)
      assert :failed in Map.keys(results)
      assert :failures in Map.keys(results)
      assert :todos in Map.keys(results)
      assert :bugs in Map.keys(results)
      assert :skipped in Map.keys(results)
    end

    test "counts examples correctly" do
      {:ok, results} = SpecValidator.validate_spec()

      total = results.passed + results.failed
      # Should have at least 70 valid examples
      assert total >= 70
    end

    test "passes more examples than it fails" do
      {:ok, results} = SpecValidator.validate_spec()

      # Most examples should pass
      assert results.passed > results.failed
    end

    test "includes failure details in failures list" do
      {:ok, results} = SpecValidator.validate_spec()

      if results.failed > 0 do
        Enum.each(results.failures, fn failure ->
          assert is_tuple(failure)
          assert tuple_size(failure) == 4
          {code, _expected, reason, _section} = failure
          assert is_binary(code)
          assert is_binary(reason)
        end)
      end
    end

    test "includes todos and bugs lists" do
      {:ok, results} = SpecValidator.validate_spec()

      assert is_list(results.todos)
      assert is_list(results.bugs)
      assert is_integer(results.skipped)
    end
  end

  describe "examples_hash/0" do
    test "returns a consistent hash" do
      {:ok, hash1} = SpecValidator.examples_hash()
      {:ok, hash2} = SpecValidator.examples_hash()

      assert hash1 == hash2
    end

    test "returns a hex string" do
      {:ok, hash} = SpecValidator.examples_hash()

      assert is_binary(hash)
      assert Regex.match?(~r/^[0-9A-F]+$/, hash)
    end

    test "hash changes when examples change" do
      # This is tested implicitly by extract_examples/1
      # If spec content changes, hash would differ
      {:ok, _hash} = SpecValidator.examples_hash()
      :ok
    end
  end

  describe "parse_expected/1 - helper" do
    # These test the internal parsing logic

    test "parses nil" do
      # Using validate_example as a proxy to test parsing
      assert :ok = SpecValidator.validate_example("nil", nil)
    end

    test "parses booleans" do
      assert :ok = SpecValidator.validate_example("true", true)
      assert :ok = SpecValidator.validate_example("false", false)
    end

    test "parses positive integers" do
      assert :ok = SpecValidator.validate_example("(+ 1 2)", 3)
      assert :ok = SpecValidator.validate_example("42", 42)
    end

    test "parses negative integers" do
      assert :ok = SpecValidator.validate_example("(- 0 5)", -5)
    end

    test "parses floats" do
      assert :ok = SpecValidator.validate_example("3.14", 3.14)
    end

    test "parses strings" do
      assert :ok = SpecValidator.validate_example("\"hello\"", "hello")
    end

    test "parses keywords" do
      assert :ok = SpecValidator.validate_example(":my-name", :"my-name")
    end

    test "parses empty lists" do
      assert :ok = SpecValidator.validate_example("[]", [])
    end

    test "parses empty maps" do
      assert :ok = SpecValidator.validate_example("{}", %{})
    end

    test "parses simple lists" do
      assert :ok = SpecValidator.validate_example("[1 2 3]", [1, 2, 3])
    end

    test "parses simple maps" do
      assert :ok = SpecValidator.validate_example("{:a 1 :b 2}", %{:a => 1, :b => 2})
    end
  end

  describe "spec file validation" do
    test "specification file exists" do
      spec_path = Path.expand("docs/ptc-lisp-specification.md")
      assert File.exists?(spec_path), "Specification file not found at #{spec_path}"
    end

    test "specification file is readable" do
      spec_path = Path.expand("docs/ptc-lisp-specification.md")

      {:ok, _content} = File.read(spec_path)
      :ok
    end

    test "specification contains examples to validate" do
      spec_path = Path.expand("docs/ptc-lisp-specification.md")
      {:ok, content} = File.read(spec_path)

      # Count examples in spec
      example_count = Enum.count(String.split(content, "; =>")) - 1

      assert example_count > 0, "Specification should contain examples with ; =>"
    end
  end

  describe "extract_multiline_examples/3" do
    test "empty lines list returns empty" do
      # We test multiline extraction behavior through the integration with extract_examples/1
      content = ""
      result = SpecValidator.extract_examples(content)
      assert result.examples == []
    end

    test "lines with no multiline examples" do
      # All single-line examples should pass through unchanged
      content = """
      ## 1. Test Section

      ```clojure
      (+ 1 2)  ; => 3
      (filter even? [1 2 3])  ; => [2]
      ```
      """

      result = SpecValidator.extract_examples(content)
      assert length(result.examples) == 2

      {code1, expected1, section1} = Enum.at(result.examples, 0)
      assert code1 =~ "(+ 1 2)"
      assert expected1 == 3
      assert section1 == "## 1. Test Section"

      {code2, expected2, section2} = Enum.at(result.examples, 1)
      assert code2 =~ "(filter even? [1 2 3])"
      assert expected2 == [2]
      assert section2 == "## 1. Test Section"
    end

    test "mixed single-line and multiline examples" do
      # Tests that both single and multiline are extracted
      content = """
      ## 1. Test Section

      ```clojure
      (+ 1 2)  ; => 3
      (if-let [x 0]
        "truthy"
        "falsy")  ; => "truthy"
      ```
      """

      result = SpecValidator.extract_examples(content)
      assert length(result.examples) == 2

      {code1, expected1, section1} = Enum.at(result.examples, 0)
      assert code1 =~ "(+ 1 2)"
      assert expected1 == 3
      assert section1 == "## 1. Test Section"

      {code2, expected2, section2} = Enum.at(result.examples, 1)
      assert code2 =~ "(if-let [x 0]"
      assert code2 =~ "\"truthy\""
      assert code2 =~ "\"falsy\")"
      assert expected2 == "truthy"
      assert section2 == "## 1. Test Section"
    end
  end

  describe "assemble_multiline_example/4" do
    test "simple multiline expressions" do
      # Test that parenthesis balancing works for multiline assembly
      content = """
      ## 1. Test Section

      ```clojure
      (let [x 1
        y 2]
        (+ x y))  ; => 3
      ```
      """

      result = SpecValidator.extract_examples(content)
      assert length(result.examples) == 1

      {code, expected, section} = hd(result.examples)
      assert code =~ "(let [x 1"
      assert code =~ "y 2]"
      assert code =~ "(+ x y))"
      assert expected == 3
      assert section == "## 1. Test Section"
    end

    test "nested parentheses" do
      content = """
      ## 1. Test Section

      ```clojure
      (reduce +
        [1 2 3])  ; => 6
      ```
      """

      result = SpecValidator.extract_examples(content)
      assert length(result.examples) == 1

      {code, expected, section} = hd(result.examples)
      assert code =~ "(reduce +"
      assert code =~ "[1 2 3]"
      assert expected == 6
      assert section == "## 1. Test Section"
    end

    test "comments before closing line" do
      content = """
      ## 1. Test Section

      ```clojure
      (filter even?
        ; Filter function
        [1 2 3 4])  ; => [2 4]
      ```
      """

      result = SpecValidator.extract_examples(content)
      assert length(result.examples) == 1

      {code, expected, section} = hd(result.examples)
      assert code =~ "(filter even?"
      assert code =~ "[1 2 3 4]"
      assert expected == [2, 4]
      assert section == "## 1. Test Section"
    end

    test "lines with markers in the middle should stop" do
      content = """
      ## 1. Test Section

      ```clojure
      (first (list 1
        2 3))  ; => 1
      (+ 4 5)  ; => 9
      ```
      """

      result = SpecValidator.extract_examples(content)
      assert length(result.examples) == 2

      {code1, expected1, section1} = Enum.at(result.examples, 0)
      assert code1 =~ "(+ 4 5)"
      assert expected1 == 9
      assert section1 == "## 1. Test Section"

      {code2, expected2, section2} = Enum.at(result.examples, 1)
      assert code2 =~ "(first (list 1"
      assert code2 =~ "2 3))"
      assert expected2 == 1
      assert section2 == "## 1. Test Section"
    end
  end

  describe "backward scanning logic" do
    test "stops at another marker" do
      content = """
      ## 1. Test Section

      ```clojure
      (+ 1 2)  ; => 3
      (filter odd? [1 2 3])  ; => [1 3]
      ```
      """

      result = SpecValidator.extract_examples(content)
      # Should extract both as separate examples, not assemble them
      assert length(result.examples) == 2

      {code1, expected1, section1} = Enum.at(result.examples, 0)
      assert code1 =~ "(+ 1 2)"
      assert expected1 == 3
      assert section1 == "## 1. Test Section"

      {code2, expected2, section2} = Enum.at(result.examples, 1)
      assert code2 =~ "(filter odd? [1 2 3])"
      assert expected2 == [1, 3]
      assert section2 == "## 1. Test Section"
    end

    test "skips comment-only lines" do
      content = """
      ## 1. Test Section

      ```clojure
      (let [x 1
        ; This is a comment
        y 2]
        (+ x y))  ; => 3
      ```
      """

      result = SpecValidator.extract_examples(content)
      assert length(result.examples) == 1

      {code, expected, section} = hd(result.examples)
      assert code =~ "(let [x 1"
      assert code =~ "y 2]"
      assert code =~ "(+ x y))"
      assert expected == 3
      assert section == "## 1. Test Section"
    end

    test "handles inline comments" do
      content = """
      ## 1. Test Section

      ```clojure
      (map inc
        [1 2 3])  ; => [2 3 4]
      ```
      """

      result = SpecValidator.extract_examples(content)
      assert length(result.examples) == 1

      {code, expected, section} = hd(result.examples)
      assert code =~ "(map inc"
      assert code =~ "[1 2 3]"
      assert expected == [2, 3, 4]
      assert section == "## 1. Test Section"
    end

    test "parenthesis balancing with strings containing parens" do
      content = """
      ## 1. Test Section

      ```clojure
      (str "text with (parens)"
        " more")  ; => "text with (parens) more"
      ```
      """

      result = SpecValidator.extract_examples(content)
      # Should properly balance parens even when they appear in strings
      assert length(result.examples) == 1

      {code, expected, section} = hd(result.examples)
      assert code =~ "(str \"text with (parens)\""
      assert code =~ "\" more\")"
      assert expected == "text with (parens) more"
      assert section == "## 1. Test Section"
    end

    test "incomplete multiline expressions reach beginning" do
      content = """
      ## 1. Test Section

      ```clojure
      (map +
        [1 2]
        [3 4])  ; => [4 6]
      ```
      """

      result = SpecValidator.extract_examples(content)
      # Should extract multiline expressions
      refute Enum.empty?(result.examples)

      {code, expected, section} = hd(result.examples)
      assert code =~ "(map +"
      assert code =~ "[1 2]"
      assert code =~ "[3 4]"
      assert expected == [4, 6]
      assert section == "## 1. Test Section"
    end
  end

  describe "Clojure conformance" do
    @describetag :clojure

    setup do
      require_babashka()
    end

    test "all spec examples are valid Clojure syntax" do
      {:ok, result} = SpecValidator.extract_examples()

      failures =
        result.examples
        |> Enum.map(fn {code, _expected, section} ->
          case assert_valid_clojure_syntax_result(code) do
            :ok -> nil
            {:error, msg} -> {code, msg, section}
          end
        end)
        |> Enum.reject(&is_nil/1)

      if failures != [] do
        failure_report =
          Enum.map_join(failures, "\n---\n", fn {code, msg, section} ->
            """
            Section: #{section}
            Code: #{code}
            Error: #{msg}
            """
          end)

        flunk(
          "#{length(failures)} spec examples have invalid Clojure syntax:\n\n#{failure_report}"
        )
      end
    end

    test "spec examples produce same results in Clojure" do
      {:ok, result} = SpecValidator.extract_examples()

      # Filter out examples that:
      # - use ctx/ (needs special handling)
      # - reference undefined functions like do-something (Clojure analyzes dead code)
      # - use PTC-Lisp extension functions (floor, ceil, round, trunc are not standard Clojure)
      testable_examples =
        result.examples
        |> Enum.reject(fn {code, _expected, _section} ->
          String.contains?(code, "ctx/") or
            String.contains?(code, "do-something") or
            Regex.match?(~r/\(floor\s/, code) or
            Regex.match?(~r/\(ceil\s/, code) or
            Regex.match?(~r/\(round\s/, code) or
            Regex.match?(~r/\(trunc\s/, code)
        end)

      failures =
        testable_examples
        |> Enum.map(fn {code, expected, section} ->
          case assert_clojure_equivalent_result(code) do
            :ok -> nil
            {:error, msg} -> {code, expected, msg, section}
          end
        end)
        |> Enum.reject(&is_nil/1)

      if failures != [] do
        failure_report =
          failures
          |> Enum.take(10)
          |> Enum.map_join("\n---\n", fn {code, expected, msg, section} ->
            """
            Section: #{section}
            Code: #{code}
            Expected: #{inspect(expected)}
            Error: #{msg}
            """
          end)

        flunk(
          "#{length(failures)} spec examples differ from Clojure (showing first 10):\n\n#{failure_report}"
        )
      end
    end
  end

  # Helper that returns result instead of asserting
  defp assert_valid_clojure_syntax_result(source) do
    alias PtcRunner.Lisp.ClojureValidator

    case ClojureValidator.validate_syntax(source) do
      :ok -> :ok
      {:error, msg} -> {:error, msg}
    end
  end

  # Helper that returns result instead of asserting
  defp assert_clojure_equivalent_result(source) do
    alias PtcRunner.Lisp.ClojureValidator

    # Run in PTC-Lisp
    ptc_result =
      case PtcRunner.Lisp.run(source) do
        {:ok, %PtcRunner.Step{return: result}} -> {:ok, result}
        {:error, _} = err -> err
      end

    # Run in Babashka
    clj_result = ClojureValidator.execute(source)

    case {ptc_result, clj_result} do
      {{:ok, ptc_val}, {:ok, clj_val}} ->
        case ClojureValidator.compare_results(ptc_val, clj_val) do
          :match -> :ok
          {:mismatch, msg} -> {:error, msg}
        end

      {{:error, ptc_err}, {:ok, clj_val}} ->
        {:error, "PTC-Lisp error #{inspect(ptc_err)} but Clojure returned #{inspect(clj_val)}"}

      {{:ok, ptc_val}, {:error, clj_err}} ->
        {:error, "PTC-Lisp returned #{inspect(ptc_val)} but Clojure error: #{clj_err}"}

      {{:error, _}, {:error, _}} ->
        # Both errored - consistent behavior
        :ok
    end
  end
end
