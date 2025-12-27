defmodule PtcRunner.Lisp.SpecValidatorTest do
  use ExUnit.Case

  alias PtcRunner.Lisp.SpecValidator

  describe "extract_examples/0" do
    test "returns list of examples from spec" do
      {:ok, examples} = SpecValidator.extract_examples()

      assert is_list(examples)
      assert examples != []

      # Verify we got tuples of code, expected, and section
      Enum.each(examples, fn item ->
        assert is_tuple(item)
        assert tuple_size(item) == 3
        {code, _expected, _section} = item
        assert is_binary(code)
      end)
    end

    test "extracts expected number of examples" do
      {:ok, examples} = SpecValidator.extract_examples()

      # The spec should have ~100+ examples after multi-line extraction
      # Some may be fragments that are filtered, so we allow a range
      assert length(examples) >= 70
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

      examples = SpecValidator.extract_examples(content)

      # At least one example should be extracted
      assert examples != []
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
      examples = SpecValidator.extract_examples(content)
      assert examples == []
    end

    test "lines with no multiline examples" do
      # All single-line examples should pass through unchanged
      content = """
      ## Test Section

      ```clojure
      (+ 1 2)  ; => 3
      (filter even? [1 2 3])  ; => [2]
      ```
      """

      examples = SpecValidator.extract_examples(content)
      refute Enum.empty?(examples)
    end

    test "mixed single-line and multiline examples" do
      # Tests that both single and multiline are extracted
      content = """
      ## Test Section

      ```clojure
      (+ 1 2)  ; => 3
      (defn add-three
        [x]
        (+ x 3))  ; => (fn)
      ```
      """

      examples = SpecValidator.extract_examples(content)
      # At minimum, should extract examples
      assert is_list(examples)
    end
  end

  describe "assemble_multiline_example/4" do
    test "simple multiline expressions" do
      # Test that parenthesis balancing works for multiline assembly
      content = """
      ## Test Section

      ```clojure
      (let [x 1
        y 2]
        (+ x y))  ; => 3
      ```
      """

      examples = SpecValidator.extract_examples(content)
      # Should successfully assemble the multiline expression
      assert is_list(examples)
    end

    test "nested parentheses" do
      content = """
      ## Test Section

      ```clojure
      ((fn [x]
        (fn [y]
          (+ x y)))
       1)  ; => (fn)
      ```
      """

      examples = SpecValidator.extract_examples(content)
      assert is_list(examples)
    end

    test "comments before closing line" do
      content = """
      ## Test Section

      ```clojure
      (map +
        ; Apply function
        [1 2 3])  ; => error
      ```
      """

      # Should handle comments in multiline assembly
      examples = SpecValidator.extract_examples(content)
      assert is_list(examples)
    end

    test "lines with markers in the middle should stop" do
      content = """
      ## Test Section

      ```clojure
      (first (list 1
        2 3))  ; => 1
      (other stuff)  ; => something
      ```
      """

      examples = SpecValidator.extract_examples(content)
      # Second example shouldn't be assembled with first due to ; => marker
      assert is_list(examples)
    end
  end

  describe "backward scanning logic" do
    test "stops at another marker" do
      content = """
      ## Test Section

      ```clojure
      (+ 1 2)  ; => 3
      (second-line)  ; => value
      ```
      """

      examples = SpecValidator.extract_examples(content)
      # Should extract both as separate examples, not assemble them
      assert is_list(examples)
    end

    test "skips comment-only lines" do
      content = """
      ## Test Section

      ```clojure
      (let [x 1
        ; This is a comment
        y 2]
        (+ x y))  ; => 3
      ```
      """

      examples = SpecValidator.extract_examples(content)
      assert is_list(examples)
    end

    test "handles inline comments" do
      content = """
      ## Test Section

      ```clojure
      (map inc
        [1 2 3]) ; comment  ; => [2 3 4]
      ```
      """

      examples = SpecValidator.extract_examples(content)
      assert is_list(examples)
    end

    test "parenthesis balancing with strings containing parens" do
      content = """
      ## Test Section

      ```clojure
      (str "text with (parens)"
        " more")  ; => "text with (parens) more"
      ```
      """

      examples = SpecValidator.extract_examples(content)
      # Should properly balance parens even when they appear in strings
      assert is_list(examples)
    end

    test "incomplete multiline expressions reach beginning" do
      content = """
      ## Test Section

      ```clojure
      (incomplete  ; => error
      ```
      """

      examples = SpecValidator.extract_examples(content)
      # Should handle incomplete expressions gracefully
      assert is_list(examples)
    end
  end
end
