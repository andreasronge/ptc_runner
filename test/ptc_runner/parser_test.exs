defmodule PtcRunner.ParserTest do
  use ExUnit.Case

  describe "Parser.parse/1 - valid inputs" do
    test "parses valid JSON string with program map" do
      input = ~s({"program": {"op": "literal", "value": 42}})
      {:ok, result} = PtcRunner.Parser.parse(input)

      assert result == %{"op" => "literal", "value" => 42}
    end

    test "parses already-parsed map with program field" do
      input = %{"program" => %{"op" => "literal", "value" => 42}}
      {:ok, result} = PtcRunner.Parser.parse(input)

      assert result == %{"op" => "literal", "value" => 42}
    end

    test "parses empty program map" do
      input = ~s({"program": {}})
      {:ok, result} = PtcRunner.Parser.parse(input)

      assert result == %{}
    end

    test "parses program map with nested operations" do
      input = ~s({"program": {"op": "pipe", "steps": [{"op": "literal", "value": 1}]}})
      {:ok, result} = PtcRunner.Parser.parse(input)

      assert result["op"] == "pipe"
      assert is_list(result["steps"])
    end
  end

  describe "Parser.parse/1 - JSON decode errors" do
    test "returns parse error for invalid JSON string" do
      input = ~s({"program": invalid json})
      {:error, {:parse_error, message}} = PtcRunner.Parser.parse(input)

      assert message =~ "JSON decode error"
    end

    test "returns parse error for JSON with syntax error" do
      input = ~s({"program": {"op": "literal" "value": 42}})
      {:error, {:parse_error, message}} = PtcRunner.Parser.parse(input)

      assert message =~ "JSON decode error"
    end

    test "returns parse error for empty string" do
      input = ""
      {:error, {:parse_error, message}} = PtcRunner.Parser.parse(input)

      assert message =~ "JSON decode error"
    end
  end

  describe "Parser.parse/1 - missing program field" do
    test "returns error when JSON is valid but missing 'program' field" do
      input = ~s({"data": {}})
      {:error, {:parse_error, message}} = PtcRunner.Parser.parse(input)

      assert message == "Missing required field 'program'"
    end

    test "returns error when map is valid but missing 'program' field" do
      input = %{"data" => %{op: "literal"}}
      {:error, {:parse_error, message}} = PtcRunner.Parser.parse(input)

      assert message == "Missing required field 'program'"
    end

    test "returns error for empty JSON object" do
      input = ~s({})
      {:error, {:parse_error, message}} = PtcRunner.Parser.parse(input)

      assert message == "Missing required field 'program'"
    end

    test "returns error for empty map" do
      input = %{}
      {:error, {:parse_error, message}} = PtcRunner.Parser.parse(input)

      assert message == "Missing required field 'program'"
    end
  end

  describe "Parser.parse/1 - program field is not a map" do
    test "returns error when program value is a string" do
      input = ~s({"program": "not a map"})
      {:error, {:parse_error, message}} = PtcRunner.Parser.parse(input)

      assert message == "program must be a map"
    end

    test "returns error when program value is a list" do
      input = ~s({"program": [1, 2, 3]})
      {:error, {:parse_error, message}} = PtcRunner.Parser.parse(input)

      assert message == "program must be a map"
    end

    test "returns error when program value is a number" do
      input = ~s({"program": 42})
      {:error, {:parse_error, message}} = PtcRunner.Parser.parse(input)

      assert message == "program must be a map"
    end

    test "returns error when program value is null" do
      input = ~s({"program": null})
      {:error, {:parse_error, message}} = PtcRunner.Parser.parse(input)

      assert message == "program must be a map"
    end

    test "returns error when program value is boolean" do
      input = ~s({"program": true})
      {:error, {:parse_error, message}} = PtcRunner.Parser.parse(input)

      assert message == "program must be a map"
    end
  end

  describe "Parser.parse/1 - non-string, non-map input" do
    test "returns error for integer input" do
      input = 42
      {:error, {:parse_error, message}} = PtcRunner.Parser.parse(input)

      assert message =~ "Input must be a string or map"
      assert message =~ "42"
    end

    test "returns error for list input" do
      input = [1, 2, 3]
      {:error, {:parse_error, message}} = PtcRunner.Parser.parse(input)

      assert message =~ "Input must be a string or map"
    end

    test "returns error for nil input" do
      input = nil
      {:error, {:parse_error, message}} = PtcRunner.Parser.parse(input)

      assert message =~ "Input must be a string or map"
    end

    test "returns error for atom input" do
      input = :symbol
      {:error, {:parse_error, message}} = PtcRunner.Parser.parse(input)

      assert message =~ "Input must be a string or map"
    end

    test "returns error for boolean input" do
      input = true
      {:error, {:parse_error, message}} = PtcRunner.Parser.parse(input)

      assert message =~ "Input must be a string or map"
    end

    test "returns error for tuple input" do
      input = {:op, "literal"}
      {:error, {:parse_error, message}} = PtcRunner.Parser.parse(input)

      assert message =~ "Input must be a string or map"
    end
  end

  describe "Parser.parse/1 - map with non-map program field" do
    test "returns error for map with string program" do
      input = %{"program" => "not a map"}
      {:error, {:parse_error, message}} = PtcRunner.Parser.parse(input)

      assert message == "program must be a map"
    end

    test "returns error for map with list program" do
      input = %{"program" => [1, 2, 3]}
      {:error, {:parse_error, message}} = PtcRunner.Parser.parse(input)

      assert message == "program must be a map"
    end

    test "returns error for map with integer program" do
      input = %{"program" => 42}
      {:error, {:parse_error, message}} = PtcRunner.Parser.parse(input)

      assert message == "program must be a map"
    end
  end

  describe "Parser.parse/1 - complex valid programs" do
    test "parses program with multiple operations" do
      program = %{
        "op" => "let",
        "name" => "x",
        "value" => %{"op" => "literal", "value" => 10},
        "in" => %{"op" => "load", "name" => "x"}
      }

      input = %{"program" => program}
      {:ok, result} = PtcRunner.Parser.parse(input)

      assert result["op"] == "let"
      assert result["name"] == "x"
    end

    test "parses program with many fields" do
      program = %{
        "op" => "call",
        "function" => "test_func",
        "args" => [1, 2, 3],
        "extra_field" => "value"
      }

      input = %{"program" => program}
      {:ok, result} = PtcRunner.Parser.parse(input)

      assert result["op"] == "call"
      assert result["function"] == "test_func"
      assert result["extra_field"] == "value"
    end
  end
end
