defmodule PtcRunner.ValidatorTest do
  use ExUnit.Case

  describe "Validator.validate/1 - valid operations" do
    test "validates valid literal operation" do
      ast = %{"op" => "literal", "value" => 42}
      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "validates operation with all valid fields" do
      ast = %{
        "op" => "filter",
        "where" => %{"op" => "eq", "field" => "status", "value" => "active"}
      }

      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "validates nested operation in expr field" do
      ast = %{
        "op" => "map",
        "expr" => %{"op" => "literal", "value" => 1}
      }

      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "validates let operation with nested expressions" do
      ast = %{
        "op" => "let",
        "name" => "x",
        "value" => %{"op" => "literal", "value" => 10},
        "in" => %{"op" => "load", "name" => "x"}
      }

      assert :ok = PtcRunner.Validator.validate(ast)
    end
  end

  describe "Validator.validate/1 - invalid input types" do
    test "returns error for non-map input (list)" do
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate([1, 2, 3])
      assert message =~ "AST must be a map"
    end

    test "returns error for non-map input (string)" do
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate("not a map")
      assert message =~ "AST must be a map"
    end

    test "returns error for non-map input (nil)" do
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(nil)
      assert message =~ "AST must be a map"
    end

    test "returns error for non-map input (integer)" do
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(42)
      assert message =~ "AST must be a map"
    end
  end

  describe "Validator.validate/1 - missing op field" do
    test "returns error when 'op' field is missing" do
      ast = %{"value" => 42}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message == "Missing required field 'op'"
    end

    test "returns error for empty map (no op)" do
      ast = %{}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message == "Missing required field 'op'"
    end

    test "returns error when op is nil" do
      ast = %{"op" => nil, "value" => 42}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message == "Missing required field 'op'"
    end
  end

  describe "Validator.validate/1 - unknown operation" do
    test "returns error for unknown operation" do
      ast = %{"op" => "unknown_op"}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message =~ "Unknown operation 'unknown_op'"
    end

    test "suggests similar operation (typo correction)" do
      ast = %{"op" => "litral"}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message =~ "Did you mean 'literal'?"
    end

    test "suggests operation for partial match" do
      ast = %{"op" => "fil"}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message =~ "Did you mean 'filter'?"
    end

    test "no suggestion for completely unknown operation" do
      ast = %{"op" => "xyz123"}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message == "Unknown operation 'xyz123'"
    end
  end

  describe "Validator.validate/1 - nth validation" do
    test "validates nth with non-negative index" do
      ast = %{"op" => "nth", "index" => 0}
      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "validates nth with positive index" do
      ast = %{"op" => "nth", "index" => 5}
      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "returns error for missing index field" do
      ast = %{"op" => "nth"}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message == "Operation 'nth' requires field 'index'"
    end

    test "returns error for negative index" do
      ast = %{"op" => "nth", "index" => -1}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message =~ "index must be non-negative"
    end

    test "returns error for non-integer index" do
      ast = %{"op" => "nth", "index" => "0"}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message =~ "must be an integer"
    end

    test "returns error for float index" do
      ast = %{"op" => "nth", "index" => 1.5}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message =~ "must be an integer"
    end
  end

  describe "Validator.validate/1 - select validation" do
    test "validates select with string fields list" do
      ast = %{"op" => "select", "fields" => ["name", "age"]}
      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "validates select with empty fields list" do
      ast = %{"op" => "select", "fields" => []}
      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "returns error for missing fields" do
      ast = %{"op" => "select"}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message == "Operation 'select' requires field 'fields'"
    end

    test "returns error when fields is not a list" do
      ast = %{"op" => "select", "fields" => "name"}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message == "Field 'fields' must be a list"
    end

    test "returns error when fields contains non-string element" do
      ast = %{"op" => "select", "fields" => ["name", 42]}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message =~ "All field names in 'fields' must be strings"
    end

    test "returns error when fields is a map" do
      ast = %{"op" => "select", "fields" => %{"name" => true}}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message == "Field 'fields' must be a list"
    end
  end

  describe "Validator.validate/1 - get validation" do
    test "validates get with string path list" do
      ast = %{"op" => "get", "path" => ["user", "name"]}
      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "validates get with single element path" do
      ast = %{"op" => "get", "path" => ["field"]}
      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "validates get with field parameter" do
      ast = %{"op" => "get", "field" => "name"}
      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "validates get with empty path" do
      ast = %{"op" => "get", "path" => []}
      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "returns error for missing field and path" do
      ast = %{"op" => "get"}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message == "Operation 'get' requires either 'field' or 'path'"
    end

    test "returns error when both field and path are provided" do
      ast = %{"op" => "get", "field" => "name", "path" => ["user", "name"]}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message == "Operation 'get' accepts 'field' or 'path', not both"
    end

    test "returns error when path is not a list" do
      ast = %{"op" => "get", "path" => "field"}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message == "Field 'path' must be a list"
    end

    test "returns error when path contains non-string element" do
      ast = %{"op" => "get", "path" => ["user", 42]}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message =~ "All path elements in 'path' must be strings"
    end

    test "returns error when path is a map" do
      ast = %{"op" => "get", "path" => %{"user" => true}}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message == "Field 'path' must be a list"
    end

    test "returns error when field is not a string" do
      ast = %{"op" => "get", "field" => 123}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message == "Field 'field' must be a string"
    end
  end

  describe "Validator.validate/1 - let validation" do
    test "validates let with all required fields" do
      ast = %{
        "op" => "let",
        "name" => "x",
        "value" => %{"op" => "literal", "value" => 10},
        "in" => %{"op" => "literal", "value" => 20}
      }

      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "returns error when let is missing name field" do
      ast = %{
        "op" => "let",
        "value" => %{"op" => "literal", "value" => 10},
        "in" => %{"op" => "literal", "value" => 20}
      }

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "requires field 'name'"
    end

    test "returns error when let name is not a string" do
      ast = %{
        "op" => "let",
        "name" => 42,
        "value" => %{"op" => "literal", "value" => 10},
        "in" => %{"op" => "literal", "value" => 20}
      }

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "Field 'name' must be a string"
    end

    test "returns error when let value is invalid expression" do
      ast = %{
        "op" => "let",
        "name" => "x",
        "value" => "not an expression",
        "in" => %{"op" => "literal", "value" => 20}
      }

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "Node must be a map"
    end

    test "returns error when let in is invalid expression" do
      ast = %{
        "op" => "let",
        "name" => "x",
        "value" => %{"op" => "literal", "value" => 10},
        "in" => nil
      }

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "Node must be a map"
    end
  end

  describe "Validator.validate/1 - field type validation" do
    test "validates string field in filter where" do
      ast = %{
        "op" => "filter",
        "where" => %{"op" => "eq", "field" => "status", "value" => "active"}
      }

      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "returns error when expr field is not a valid operation" do
      ast = %{"op" => "filter", "where" => %{"op" => "bad_op"}}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message =~ "Unknown operation"
    end

    test "validates non_neg_integer field correctly" do
      ast = %{"op" => "nth", "index" => 10}
      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "returns error for negative non_neg_integer field" do
      ast = %{"op" => "nth", "index" => -1}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message =~ "non-negative"
    end

    test "returns error when non_neg_integer field is not an integer" do
      ast = %{"op" => "nth", "index" => "10"}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message =~ "must be an integer"
    end

    test "validates list of expressions field type correctly" do
      ast = %{
        "op" => "merge",
        "objects" => [
          %{"op" => "literal", "value" => %{"a" => 1}},
          %{"op" => "literal", "value" => %{"b" => 2}}
        ]
      }

      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "returns error when list field contains non-expression" do
      ast = %{
        "op" => "merge",
        "objects" => [
          %{"op" => "literal", "value" => %{"a" => 1}},
          "not an expression"
        ]
      }

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message =~ "Node must be a map"
    end
  end

  describe "Validator.validate/1 - list field validation" do
    test "validates {:list, :expr} field type" do
      ast = %{
        "op" => "pipe",
        "steps" => [
          %{"op" => "literal", "value" => 1},
          %{"op" => "literal", "value" => 2}
        ]
      }

      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "returns error when {:list, :expr} contains invalid expression" do
      ast = %{
        "op" => "pipe",
        "steps" => [
          %{"op" => "literal", "value" => 1},
          "not an expression"
        ]
      }

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "Node must be a map"
    end

    test "validates {:list, :string} field type via concat" do
      ast = %{
        "op" => "concat",
        "lists" => [
          %{"op" => "literal", "value" => ["hello"]},
          %{"op" => "literal", "value" => ["world"]}
        ]
      }

      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "returns error when {:list, :expr} field is not a list" do
      ast = %{
        "op" => "pipe",
        "steps" => "not a list"
      }

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message =~ "Field 'steps' must be a list"
    end

    test "returns error when {:list, :expr} field is a map" do
      ast = %{
        "op" => "pipe",
        "steps" => %{"op" => "literal", "value" => 1}
      }

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)

      assert message =~ "Field 'steps' must be a list"
    end
  end

  describe "Validator.validate/1 - nested validation errors" do
    test "catches error in deeply nested expression" do
      ast = %{
        "op" => "let",
        "name" => "x",
        "value" => %{
          "op" => "literal",
          "value" => 10
        },
        "in" => %{
          "op" => "let",
          "name" => "y",
          "value" => %{"op" => "unknown"},
          "in" => %{"op" => "literal", "value" => 20}
        }
      }

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "Unknown operation"
    end

    test "catches error in pipe steps" do
      ast = %{
        "op" => "pipe",
        "steps" => [
          %{"op" => "literal", "value" => 1},
          %{"op" => "bad_op"}
        ]
      }

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "Unknown operation"
    end

    test "catches missing required field in nested operation" do
      ast = %{
        "op" => "let",
        "name" => "x",
        "value" => %{
          "op" => "nth"
        },
        "in" => %{"op" => "literal", "value" => 20}
      }

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "Operation 'nth' requires field 'index'"
    end

    test "catches error in let value with invalid expression" do
      ast = %{
        "op" => "let",
        "name" => "x",
        "value" => "not an expression",
        "in" => %{"op" => "literal", "value" => 20}
      }

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "Node must be a map"
    end

    test "catches error in let in with invalid expression" do
      ast = %{
        "op" => "let",
        "name" => "x",
        "value" => %{"op" => "literal", "value" => 10},
        "in" => nil
      }

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "Node must be a map"
    end
  end

  describe "Validator.validate/1 - any field type" do
    test "validates :any field type accepts anything" do
      ast = %{"op" => "literal", "value" => 42}
      assert :ok = PtcRunner.Validator.validate(ast)

      ast2 = %{"op" => "literal", "value" => "string"}
      assert :ok = PtcRunner.Validator.validate(ast2)

      ast3 = %{"op" => "literal", "value" => [1, 2, 3]}
      assert :ok = PtcRunner.Validator.validate(ast3)

      ast4 = %{"op" => "literal", "value" => %{"a" => 1}}
      assert :ok = PtcRunner.Validator.validate(ast4)

      ast5 = %{"op" => "literal", "value" => nil}
      assert :ok = PtcRunner.Validator.validate(ast5)
    end
  end

  describe "Validator.validate/1 - expr field validation" do
    test "validates :expr field type with valid operation" do
      ast = %{
        "op" => "map",
        "expr" => %{"op" => "literal", "value" => 1}
      }

      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "returns error when :expr field contains invalid operation" do
      ast = %{
        "op" => "map",
        "expr" => %{"op" => "bad_op"}
      }

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "Unknown operation"
    end

    test "returns error when :expr field is not a map" do
      ast = %{
        "op" => "map",
        "expr" => "not an expression"
      }

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "Node must be a map"
    end

    test "returns error when expr field has missing required field" do
      ast = %{
        "op" => "map",
        "expr" => %{"op" => "filter"}
      }

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "Operation 'filter' requires field 'where'"
    end
  end

  describe "Validator.validate/1 - type validation edge cases" do
    test "string field validation error for non-string value" do
      ast = %{
        "op" => "call",
        "tool" => 42
      }

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "Field 'tool' must be a string"
    end

    test "non_neg_integer field validation error message for non-integer" do
      ast = %{"op" => "nth", "index" => "not an integer"}

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "must be an integer"
    end

    test "validates list of strings with all strings" do
      # Using select operation which requires fields to be a list of strings
      ast = %{"op" => "select", "fields" => ["a", "b", "c"]}
      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "list of strings validation error when non-string element" do
      # Using select which needs fields to be all strings
      ast = %{"op" => "select", "fields" => ["a", 123, "c"]}

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "All field names in 'fields' must be strings"
    end

    test "list of strings validation error when not a list" do
      ast = %{"op" => "select", "fields" => "just_a_string"}

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "Field 'fields' must be a list"
    end

    test "validates path with all string elements" do
      ast = %{"op" => "get", "path" => ["a", "b", "c"]}
      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "path validation error when non-string element" do
      ast = %{"op" => "get", "path" => ["a", 42, "c"]}

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "All path elements in 'path' must be strings"
    end

    test "path validation error when not a list" do
      ast = %{"op" => "get", "path" => "single_string"}

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "Field 'path' must be a list"
    end
  end

  describe "Validator.validate/1 - special field value types" do
    test "validates :any type with various values" do
      ast1 = %{"op" => "literal", "value" => 42}
      assert :ok = PtcRunner.Validator.validate(ast1)

      ast2 = %{"op" => "literal", "value" => false}
      assert :ok = PtcRunner.Validator.validate(ast2)

      ast3 = %{"op" => "literal", "value" => %{}}
      assert :ok = PtcRunner.Validator.validate(ast3)
    end

    test "validates map field type with map value" do
      ast = %{"op" => "merge", "objects" => [%{"op" => "literal", "value" => %{"key" => "val"}}]}
      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "literal operation accepts list value" do
      ast = %{"op" => "literal", "value" => [1, 2, 3]}
      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "validates operations with no required fields" do
      ast = %{"op" => "first"}
      assert :ok = PtcRunner.Validator.validate(ast)
    end
  end

  describe "Validator.validate/1 - coverage for non_neg_integer validation" do
    test "non_neg_integer validates zero correctly" do
      ast = %{"op" => "nth", "index" => 0}
      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "non_neg_integer validates large positive integer" do
      ast = %{"op" => "nth", "index" => 9999}
      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "non_neg_integer rejects float" do
      ast = %{"op" => "nth", "index" => 3.14}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "must be an integer"
    end
  end

  describe "Validator.validate/1 - coverage for list validation paths" do
    test "validates empty list of expressions" do
      ast = %{"op" => "pipe", "steps" => []}
      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "validates single element list of expressions" do
      ast = %{"op" => "pipe", "steps" => [%{"op" => "literal", "value" => 1}]}
      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "validates list with multiple valid expressions" do
      ast = %{
        "op" => "pipe",
        "steps" => [
          %{"op" => "literal", "value" => 1},
          %{"op" => "literal", "value" => 2},
          %{"op" => "literal", "value" => 3}
        ]
      }

      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "list of expressions validation catches invalid in first position" do
      ast = %{
        "op" => "pipe",
        "steps" => [
          "invalid",
          %{"op" => "literal", "value" => 2}
        ]
      }

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "Node must be a map"
    end

    test "validates select with single field" do
      ast = %{"op" => "select", "fields" => ["single_field"]}
      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "validates get with single path element" do
      ast = %{"op" => "get", "path" => ["single"]}
      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "validates get with nested path" do
      ast = %{"op" => "get", "path" => ["users", "0", "name"]}
      assert :ok = PtcRunner.Validator.validate(ast)
    end
  end

  describe "Validator.validate/1 - field validation ordering" do
    test "validates all fields in generic operation" do
      ast = %{
        "op" => "eq",
        "field" => "status",
        "value" => "active"
      }

      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "returns error for missing required field even with other fields present" do
      ast = %{
        "op" => "eq",
        "field" => "status"
      }

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "Operation 'eq' requires field 'value'"
    end
  end

  describe "Validator.validate/1 - generic field validation paths" do
    test "validates all required fields are present" do
      ast = %{
        "op" => "eq",
        "field" => "price",
        "value" => 100
      }

      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "validates field with type any accepts all values" do
      ast1 = %{"op" => "literal", "value" => 42}
      assert :ok = PtcRunner.Validator.validate(ast1)

      ast2 = %{"op" => "literal", "value" => "string"}
      assert :ok = PtcRunner.Validator.validate(ast2)

      ast3 = %{"op" => "literal", "value" => nil}
      assert :ok = PtcRunner.Validator.validate(ast3)

      ast4 = %{"op" => "literal", "value" => [1, 2]}
      assert :ok = PtcRunner.Validator.validate(ast4)

      ast5 = %{"op" => "literal", "value" => %{"key" => "val"}}
      assert :ok = PtcRunner.Validator.validate(ast5)
    end

    test "validates string field with string value" do
      ast = %{
        "op" => "eq",
        "field" => "name",
        "value" => "John"
      }

      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "returns error for string field with non-string value" do
      ast = %{
        "op" => "eq",
        "field" => 42,
        "value" => "active"
      }

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "Field 'field' must be a string"
    end

    test "validates map field with map value" do
      ast = %{
        "op" => "merge",
        "objects" => [%{"op" => "literal", "value" => %{"a" => 1}}]
      }

      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "validates expr field with valid nested expression" do
      ast = %{
        "op" => "map",
        "expr" => %{"op" => "literal", "value" => 1}
      }

      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "returns error for expr field with invalid nested expression" do
      ast = %{
        "op" => "map",
        "expr" => %{"op" => "unknown_op"}
      }

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "Unknown operation"
    end

    test "validates optional fields are skipped when missing" do
      ast = %{"op" => "call", "tool" => "fetch_data"}

      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "validates optional fields are validated when present" do
      ast = %{
        "op" => "call",
        "tool" => "fetch_data",
        "args" => %{"id" => 123}
      }

      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "returns error for optional field with wrong type" do
      ast = %{
        "op" => "call",
        "tool" => "fetch_data",
        "args" => [1, 2, 3]
      }

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "Field 'args' must be a map"
    end
  end

  describe "Validator.validate/1 - multiple field validation" do
    test "validates all fields in multi-field operation" do
      ast = %{
        "op" => "if",
        "condition" => %{"op" => "literal", "value" => true},
        "then" => %{"op" => "literal", "value" => 1},
        "else" => %{"op" => "literal", "value" => 2}
      }

      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "returns error when if operation missing required field" do
      ast = %{
        "op" => "if",
        "condition" => %{"op" => "literal", "value" => true}
      }

      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message =~ "Operation 'if' requires field"
    end

    test "validates operations with many fields" do
      ast = %{
        "op" => "and",
        "conditions" => [
          %{"op" => "eq", "field" => "status", "value" => "active"},
          %{"op" => "gt", "field" => "age", "value" => 18}
        ]
      }

      assert :ok = PtcRunner.Validator.validate(ast)
    end
  end

  describe "Validator.validate/1 - comprehensive field coverage" do
    test "validates operations with mixed field types" do
      ast = %{
        "op" => "if",
        "condition" => %{"op" => "literal", "value" => true},
        "then" => %{"op" => "literal", "value" => 1},
        "else" => %{"op" => "literal", "value" => 2}
      }

      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "validates boolean values in fields" do
      ast = %{"op" => "literal", "value" => true}
      assert :ok = PtcRunner.Validator.validate(ast)

      ast2 = %{"op" => "literal", "value" => false}
      assert :ok = PtcRunner.Validator.validate(ast2)
    end

    test "validates complex nested structures" do
      ast = %{
        "op" => "let",
        "name" => "complex",
        "value" => %{
          "op" => "pipe",
          "steps" => [
            %{"op" => "literal", "value" => [1, 2, 3]},
            %{"op" => "count"}
          ]
        },
        "in" => %{"op" => "load", "name" => "complex"}
      }

      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "rejects operations with completely wrong structure" do
      ast = %{"wrong_field" => "value"}
      {:error, {:validation_error, message}} = PtcRunner.Validator.validate(ast)
      assert message == "Missing required field 'op'"
    end

    test "validates list with mixed element types via pipe" do
      ast = %{
        "op" => "pipe",
        "steps" => [
          %{"op" => "literal", "value" => 1},
          %{"op" => "literal", "value" => 2},
          %{"op" => "literal", "value" => 3},
          %{"op" => "literal", "value" => 4}
        ]
      }

      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "catches errors in deeply nested list of expressions" do
      ast = %{
        "op" => "pipe",
        "steps" => [
          %{"op" => "literal", "value" => 1},
          %{"op" => "literal", "value" => 2},
          %{"op" => "invalid"}
        ]
      }

      {:error, {:validation_error, _msg}} = PtcRunner.Validator.validate(ast)
    end

    test "validates or operation with conditions" do
      ast = %{
        "op" => "or",
        "conditions" => [
          %{"op" => "eq", "field" => "status", "value" => "active"},
          %{"op" => "eq", "field" => "status", "value" => "pending"}
        ]
      }

      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "validates not operation" do
      ast = %{
        "op" => "not",
        "condition" => %{"op" => "eq", "field" => "active", "value" => true}
      }

      assert :ok = PtcRunner.Validator.validate(ast)
    end

    test "validates var operation" do
      ast = %{"op" => "var", "name" => "x"}
      assert :ok = PtcRunner.Validator.validate(ast)
    end
  end
end
