defmodule PtcRunnerMcp.OutputSchemaArgTest do
  @moduledoc """
  Coverage for the `output_schema` argument of
  `tools/call name: "ptc_lisp_execute"`.

  Covers:

    * Successful JSON Schema → validated field in response
    * Validation failure (type mismatch) → `validation_error`
    * Unsupported JSON Schema features → `args_error`
    * Legacy `signature` rejection
    * Scalar, array, and nested object schemas
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.{ConcurrencyGate, Limits, Tools}

  setup do
    Limits.set(Limits.defaults())
    ConcurrencyGate.reset()
    :ok
  end

  defp call(args) do
    Tools.call(%{"name" => "ptc_lisp_execute", "arguments" => args})
  end

  describe "output_schema shape validation" do
    test "non-object output_schema returns args_error" do
      env = call(%{"program" => "1", "output_schema" => "not an object"})

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["reason"] == "args_error"
      assert sc["message"] =~ "output_schema"
    end

    test "missing type key returns args_error" do
      env = call(%{"program" => "1", "output_schema" => %{"properties" => %{}}})

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["reason"] == "args_error"
      assert sc["message"] =~ "output_schema"
      assert sc["message"] =~ "type"
    end

    test "unsupported type returns args_error" do
      env = call(%{"program" => "1", "output_schema" => %{"type" => "null"}})

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["reason"] == "args_error"
      assert sc["message"] =~ "unsupported type"
    end

    test "unsupported JSON Schema key returns args_error listing the key" do
      env =
        call(%{
          "program" => "1",
          "output_schema" => %{"type" => "integer", "minimum" => 0}
        })

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["reason"] == "args_error"
      assert sc["message"] =~ "minimum"
    end

    test "$ref is rejected" do
      env =
        call(%{
          "program" => "1",
          "output_schema" => %{"type" => "object", "$ref" => "#/definitions/Foo"}
        })

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "args_error"
    end

    test "oneOf combinator is rejected" do
      env =
        call(%{
          "program" => "1",
          "output_schema" => %{
            "type" => "object",
            "oneOf" => [%{"type" => "string"}, %{"type" => "integer"}]
          }
        })

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "args_error"
    end

    test "array without items is rejected" do
      env = call(%{"program" => "1", "output_schema" => %{"type" => "array"}})

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["reason"] == "args_error"
      assert sc["message"] =~ "items"
    end

    test "consumes no permit on validation failure" do
      call(%{"program" => "1", "output_schema" => %{"type" => "null"}})
      assert ConcurrencyGate.in_flight() == 0
    end
  end

  describe "legacy signature rejection" do
    test "signature present returns args_error" do
      env =
        call(%{
          "program" => "{:count 1}",
          "signature" => "() -> {count :int}"
        })

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["reason"] == "args_error"
      assert sc["message"] =~ "no longer supported"
    end

    test "output_schema with null signature is rejected" do
      env =
        call(%{
          "program" => "{:count 1}",
          "output_schema" => %{
            "type" => "object",
            "properties" => %{"count" => %{"type" => "integer"}},
            "required" => ["count"]
          },
          "signature" => nil
        })

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "args_error"
      assert env["structuredContent"]["message"] =~ "no longer supported"
    end

    test "null output_schema is rejected" do
      env =
        call(%{
          "program" => "{:count 1}",
          "output_schema" => nil
        })

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "args_error"
      assert env["structuredContent"]["message"] =~ "output_schema"
    end

    test ~S|signature: "any" is rejected| do
      env =
        call(%{
          "program" => "{:count 1}",
          "output_schema" => %{
            "type" => "object",
            "properties" => %{"count" => %{"type" => "integer"}},
            "required" => ["count"]
          },
          "signature" => "any"
        })

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "args_error"
      assert env["structuredContent"]["message"] =~ "no longer supported"
    end
  end

  describe "successful schema → validated field" do
    test "object schema with required fields" do
      env =
        call(%{
          "program" => "{:count (+ 1 2 3 4) :label \"test\"}",
          "output_schema" => %{
            "type" => "object",
            "properties" => %{
              "count" => %{"type" => "integer"},
              "label" => %{"type" => "string"}
            },
            "required" => ["count", "label"]
          }
        })

      assert env["isError"] == false
      sc = env["structuredContent"]
      assert sc["status"] == "ok"
      assert sc["validated"] == %{"count" => 10, "label" => "test"}
    end

    test "scalar integer schema" do
      env =
        call(%{
          "program" => "(+ 1 2)",
          "output_schema" => %{"type" => "integer"}
        })

      assert env["isError"] == false
      assert env["structuredContent"]["validated"] == 3
    end

    test "scalar string schema" do
      env =
        call(%{
          "program" => ~s|"hello"|,
          "output_schema" => %{"type" => "string"}
        })

      assert env["isError"] == false
      assert env["structuredContent"]["validated"] == "hello"
    end

    test "scalar boolean schema" do
      env =
        call(%{
          "program" => "true",
          "output_schema" => %{"type" => "boolean"}
        })

      assert env["isError"] == false
      assert env["structuredContent"]["validated"] == true
    end

    test "scalar number schema" do
      env =
        call(%{
          "program" => "3.14",
          "output_schema" => %{"type" => "number"}
        })

      assert env["isError"] == false
      assert env["structuredContent"]["validated"] == 3.14
    end

    test "array of integers schema" do
      env =
        call(%{
          "program" => "[1 2 3]",
          "output_schema" => %{
            "type" => "array",
            "items" => %{"type" => "integer"}
          }
        })

      assert env["isError"] == false
      assert env["structuredContent"]["validated"] == [1, 2, 3]
    end

    test "nested object schema" do
      env =
        call(%{
          "program" => "{:user {:name \"Alice\" :age 30}}",
          "output_schema" => %{
            "type" => "object",
            "properties" => %{
              "user" => %{
                "type" => "object",
                "properties" => %{
                  "name" => %{"type" => "string"},
                  "age" => %{"type" => "integer"}
                },
                "required" => ["name", "age"]
              }
            },
            "required" => ["user"]
          }
        })

      assert env["isError"] == false
      sc = env["structuredContent"]
      assert sc["validated"] == %{"user" => %{"name" => "Alice", "age" => 30}}
    end

    test "object with optional fields — missing field omitted from validated" do
      env =
        call(%{
          "program" => "{:count 5}",
          "output_schema" => %{
            "type" => "object",
            "properties" => %{
              "count" => %{"type" => "integer"},
              "label" => %{"type" => "string"}
            },
            "required" => ["count"]
          }
        })

      assert env["isError"] == false
      sc = env["structuredContent"]
      assert sc["validated"]["count"] == 5
    end

    test "empty properties → empty map validated" do
      env =
        call(%{
          "program" => "{}",
          "output_schema" => %{
            "type" => "object",
            "properties" => %{}
          }
        })

      assert env["isError"] == false
      assert env["structuredContent"]["validated"] == %{}
    end

    test "cross-language smoke: filter+reduce over data/orders" do
      program = """
      (let [big (filter #(> (get % "total") 10) data/orders)]
        {:count (count big) :sum (reduce + (map #(get % "total") big))})
      """

      env =
        call(%{
          "program" => program,
          "context" => %{
            "orders" => [
              %{"total" => 12},
              %{"total" => 7},
              %{"total" => 33}
            ]
          },
          "output_schema" => %{
            "type" => "object",
            "properties" => %{
              "count" => %{"type" => "integer"},
              "sum" => %{"type" => "integer"}
            },
            "required" => ["count", "sum"]
          }
        })

      assert env["isError"] == false
      sc = env["structuredContent"]
      assert sc["status"] == "ok"
      assert sc["validated"] == %{"count" => 2, "sum" => 45}
    end
  end

  describe "schema mismatch → validation_error" do
    test "string return when schema expects integer" do
      env =
        call(%{
          "program" => ~s|"hello"|,
          "output_schema" => %{"type" => "integer"}
        })

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["status"] == "error"
      assert sc["reason"] == "validation_error"
      assert is_binary(sc["message"])
    end

    test "wrong-typed field surfaces validation_error" do
      env =
        call(%{
          "program" => ~s|{:count "not a number"}|,
          "output_schema" => %{
            "type" => "object",
            "properties" => %{"count" => %{"type" => "integer"}},
            "required" => ["count"]
          }
        })

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "validation_error"
    end

    test "missing required field surfaces validation_error" do
      env =
        call(%{
          "program" => ~s|{:name "Alice"}|,
          "output_schema" => %{
            "type" => "object",
            "properties" => %{
              "name" => %{"type" => "string"},
              "age" => %{"type" => "integer"}
            },
            "required" => ["name", "age"]
          }
        })

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "validation_error"
    end

    test "additionalProperties: false rejects an undeclared field" do
      env =
        call(%{
          "program" => ~s|{:x 1 :extra 2}|,
          "output_schema" => %{
            "type" => "object",
            "properties" => %{"x" => %{"type" => "integer"}},
            "required" => ["x"],
            "additionalProperties" => false
          }
        })

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["reason"] == "validation_error"
      assert sc["message"] =~ "unexpected field"
    end

    test "additionalProperties: false still accepts an exact match" do
      env =
        call(%{
          "program" => ~s|{:x 1}|,
          "output_schema" => %{
            "type" => "object",
            "properties" => %{"x" => %{"type" => "integer"}},
            "required" => ["x"],
            "additionalProperties" => false
          }
        })

      assert env["isError"] == false
      assert env["structuredContent"]["validated"] == %{"x" => 1}
    end

    test "absent additionalProperties tolerates extra fields" do
      env =
        call(%{
          "program" => ~s|{:x 1 :extra 2}|,
          "output_schema" => %{
            "type" => "object",
            "properties" => %{"x" => %{"type" => "integer"}},
            "required" => ["x"]
          }
        })

      assert env["isError"] == false
      assert env["structuredContent"]["validated"] == %{"x" => 1, "extra" => 2}
    end
  end

  describe "required validation" do
    test "required entry not declared as a property is an args_error" do
      env =
        call(%{
          "program" => "1",
          "output_schema" => %{
            "type" => "object",
            "properties" => %{"x" => %{"type" => "integer"}},
            "required" => ["missing"]
          }
        })

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["reason"] == "args_error"
      assert sc["message"] =~ "missing"
    end

    test "non-string required entry is an args_error" do
      env =
        call(%{
          "program" => "1",
          "output_schema" => %{
            "type" => "object",
            "properties" => %{"x" => %{"type" => "integer"}},
            "required" => [123]
          }
        })

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["reason"] == "args_error"
    end

    test "non-boolean additionalProperties is an args_error" do
      env =
        call(%{
          "program" => "1",
          "output_schema" => %{
            "type" => "object",
            "properties" => %{},
            "additionalProperties" => %{"type" => "string"}
          }
        })

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["reason"] == "args_error"
      assert sc["message"] =~ "additionalProperties"
    end
  end

  describe "description anchors" do
    test "output_schema description mentions JSON Schema" do
      %{"tools" => [tool]} = Tools.list()
      desc = tool["inputSchema"]["properties"]["output_schema"]["description"]
      assert desc =~ "JSON Schema"
    end

    test "signature is not advertised" do
      %{"tools" => [tool]} = Tools.list()
      refute Map.has_key?(tool["inputSchema"]["properties"], "signature")
    end

    test "authoring card keeps output_schema out of no-tools prompt text" do
      card = Tools.authoring_card()
      refute card =~ "output_schema"
    end
  end
end
