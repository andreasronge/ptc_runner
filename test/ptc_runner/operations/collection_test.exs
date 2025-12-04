defmodule PtcRunner.Operations.CollectionTest do
  use ExUnit.Case

  # Pipe operation
  test "pipe chains operations" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 3]},
        {"op": "count"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 3
  end

  test "empty pipe returns nil" do
    program = ~s({"program": {"op": "pipe", "steps": []}})
    {:ok, result, _metrics} = PtcRunner.run(program)

    assert result == nil
  end

  # Merge operation - combine objects tests
  test "merge with two objects" do
    program = ~s({"program": {
      "op": "merge",
      "objects": [
        {"op": "literal", "value": {"a": 1, "b": 2}},
        {"op": "literal", "value": {"c": 3}}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == %{"a" => 1, "b" => 2, "c" => 3}
  end

  test "merge with override (later object wins)" do
    program = ~s({"program": {
      "op": "merge",
      "objects": [
        {"op": "literal", "value": {"a": 1, "b": 2}},
        {"op": "literal", "value": {"a": 10}}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == %{"a" => 10, "b" => 2}
  end

  test "merge with empty objects list" do
    program = ~s({"program": {
      "op": "merge",
      "objects": []
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == %{}
  end

  test "merge with single object" do
    program = ~s({"program": {
      "op": "merge",
      "objects": [
        {"op": "literal", "value": {"a": 1}}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == %{"a" => 1}
  end

  test "merge with three objects" do
    program = ~s({"program": {
      "op": "merge",
      "objects": [
        {"op": "literal", "value": {"a": 1}},
        {"op": "literal", "value": {"b": 2}},
        {"op": "literal", "value": {"c": 3}}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == %{"a" => 1, "b" => 2, "c" => 3}
  end

  test "merge with variables" do
    program = ~s({"program": {
      "op": "let",
      "name": "obj1",
      "value": {"op": "literal", "value": {"a": 1}},
      "in": {
        "op": "let",
        "name": "obj2",
        "value": {"op": "literal", "value": {"b": 2}},
        "in": {
          "op": "merge",
          "objects": [
            {"op": "var", "name": "obj1"},
            {"op": "var", "name": "obj2"}
          ]
        }
      }
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == %{"a" => 1, "b" => 2}
  end

  test "merge fails on non-map input" do
    program = ~s({"program": {
      "op": "merge",
      "objects": [
        {"op": "literal", "value": [1, 2, 3]}
      ]
    }})

    {:error, {:execution_error, message}} = PtcRunner.run(program)
    assert String.contains?(message, "merge requires map values")
  end

  test "merge validation fails when objects field is missing" do
    program = ~s({"program": {
      "op": "merge"
    }})

    {:error, {:validation_error, message}} = PtcRunner.run(program)
    assert String.contains?(message, "requires field 'objects'")
  end

  test "merge validation fails when objects is not a list" do
    program = ~s({"program": {
      "op": "merge",
      "objects": 42
    }})

    {:error, {:validation_error, message}} = PtcRunner.run(program)
    assert String.contains?(message, "must be a list")
  end

  # Concat operation - combine lists tests
  test "concat with two lists" do
    program = ~s({"program": {
      "op": "concat",
      "lists": [
        {"op": "literal", "value": [1, 2]},
        {"op": "literal", "value": [3, 4]}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == [1, 2, 3, 4]
  end

  test "concat with three lists" do
    program = ~s({"program": {
      "op": "concat",
      "lists": [
        {"op": "literal", "value": [1]},
        {"op": "literal", "value": [2, 3]},
        {"op": "literal", "value": [4]}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == [1, 2, 3, 4]
  end

  test "concat with empty lists list" do
    program = ~s({"program": {
      "op": "concat",
      "lists": []
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == []
  end

  test "concat with single list" do
    program = ~s({"program": {
      "op": "concat",
      "lists": [
        {"op": "literal", "value": [1, 2, 3]}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == [1, 2, 3]
  end

  test "concat with variables" do
    program = ~s({"program": {
      "op": "let",
      "name": "list1",
      "value": {"op": "literal", "value": [1, 2]},
      "in": {
        "op": "let",
        "name": "list2",
        "value": {"op": "literal", "value": [3, 4]},
        "in": {
          "op": "concat",
          "lists": [
            {"op": "var", "name": "list1"},
            {"op": "var", "name": "list2"}
          ]
        }
      }
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == [1, 2, 3, 4]
  end

  test "concat fails on non-list input" do
    program = ~s({"program": {
      "op": "concat",
      "lists": [
        {"op": "literal", "value": {"a": 1}}
      ]
    }})

    {:error, {:execution_error, message}} = PtcRunner.run(program)
    assert String.contains?(message, "concat requires list values")
  end

  test "concat validation fails when lists field is missing" do
    program = ~s({"program": {
      "op": "concat"
    }})

    {:error, {:validation_error, message}} = PtcRunner.run(program)
    assert String.contains?(message, "requires field 'lists'")
  end

  test "concat validation fails when lists is not a list" do
    program = ~s({"program": {
      "op": "concat",
      "lists": "not a list"
    }})

    {:error, {:validation_error, message}} = PtcRunner.run(program)
    assert String.contains?(message, "must be a list")
  end

  # Zip operation - zip lists tests
  test "zip with two equal-length lists" do
    program = ~s({"program": {
      "op": "zip",
      "lists": [
        {"op": "literal", "value": [1, 2, 3]},
        {"op": "literal", "value": ["a", "b", "c"]}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == [[1, "a"], [2, "b"], [3, "c"]]
  end

  test "zip with unequal-length lists (stops at shortest)" do
    program = ~s({"program": {
      "op": "zip",
      "lists": [
        {"op": "literal", "value": [1, 2, 3]},
        {"op": "literal", "value": ["a", "b"]}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == [[1, "a"], [2, "b"]]
  end

  test "zip with empty lists list" do
    program = ~s({"program": {
      "op": "zip",
      "lists": []
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == []
  end

  test "zip with single list" do
    program = ~s({"program": {
      "op": "zip",
      "lists": [
        {"op": "literal", "value": [1, 2, 3]}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == [[1], [2], [3]]
  end

  test "zip with three lists" do
    program = ~s({"program": {
      "op": "zip",
      "lists": [
        {"op": "literal", "value": [1, 2]},
        {"op": "literal", "value": ["a", "b"]},
        {"op": "literal", "value": [true, false]}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == [[1, "a", true], [2, "b", false]]
  end

  test "zip with one empty inner list" do
    program = ~s({"program": {
      "op": "zip",
      "lists": [
        {"op": "literal", "value": []},
        {"op": "literal", "value": [1, 2]}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == []
  end

  test "zip fails on non-list input" do
    program = ~s({"program": {
      "op": "zip",
      "lists": [
        {"op": "literal", "value": 42}
      ]
    }})

    {:error, {:execution_error, message}} = PtcRunner.run(program)
    assert String.contains?(message, "zip requires list values")
  end

  test "zip validation fails when lists field is missing" do
    program = ~s({"program": {
      "op": "zip"
    }})

    {:error, {:validation_error, message}} = PtcRunner.run(program)
    assert String.contains?(message, "requires field 'lists'")
  end

  test "zip validation fails when lists is not a list" do
    program = ~s({"program": {
      "op": "zip",
      "lists": {"a": 1}
    }})

    {:error, {:validation_error, message}} = PtcRunner.run(program)
    assert String.contains?(message, "must be a list")
  end

  # E2E test combining multiple operations
  test "E2E: combine operations with let and merge/concat" do
    program = ~s({"program": {
      "op": "let",
      "name": "user",
      "value": {"op": "literal", "value": {"id": 1, "name": "Alice"}},
      "in": {
        "op": "let",
        "name": "order",
        "value": {"op": "literal", "value": {"total": 100, "status": "shipped"}},
        "in": {
          "op": "let",
          "name": "combined",
          "value": {
            "op": "merge",
            "objects": [
              {"op": "var", "name": "user"},
              {"op": "var", "name": "order"}
            ]
          },
          "in": {
            "op": "var",
            "name": "combined"
          }
        }
      }
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == %{"id" => 1, "name" => "Alice", "total" => 100, "status" => "shipped"}
  end
end
