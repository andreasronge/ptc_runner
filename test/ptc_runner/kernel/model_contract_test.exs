defmodule PtcRunner.Kernel.ModelContractTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.ModelContract
  alias PtcRunner.Kernel.ValueContract

  test "value contract projection covers and deterministically orders a documented tagged union" do
    schema = %{
      "title" => "Decision",
      "description" => "One sealed outcome.",
      "oneOf" => [
        %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["kind", "reason"],
          "properties" => %{
            "reason" => %{"type" => "string", "description" => "Why it was rejected."},
            "kind" => %{"type" => "string", "const" => "rejected"}
          }
        },
        %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["kind", "digest"],
          "properties" => %{
            "kind" => %{"type" => "string", "const" => "accepted"},
            "digest" => %{"type" => "string", "format" => "sha256"}
          }
        }
      ]
    }

    assert {:ok, contract} = ValueContract.compile(schema)
    assert {:ok, {:object, projection}} = ModelContract.value_contract(contract)
    assert {"kind", "tagged_union"} in projection
    assert {"title", "Decision"} in projection
    assert {"description", "One sealed outcome."} in projection
    {"variants", [accepted, rejected]} = List.keyfind(projection, "variants", 0)

    assert {:object,
            [{"discriminator", {:object, [{"name", "kind"}, {"literal", "accepted"}]}}, _]} =
             accepted

    assert {:object,
            [{"discriminator", {:object, [{"name", "kind"}, {"literal", "rejected"}]}}, _]} =
             rejected

    assert {:ok, "sha256:" <> <<_::binary-size(64)>>} =
             ModelContract.projection_hash({:object, projection})
  end

  test "tagged union discriminator remains unambiguous with other const fields" do
    schema = %{
      "oneOf" =>
        for kind <- ["accepted", "rejected"] do
          %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["kind", "version"],
            "properties" => %{
              "kind" => %{"type" => "string", "const" => kind},
              "version" => %{"type" => "integer", "const" => 1}
            }
          }
        end
    }

    assert {:ok, contract} = ValueContract.compile(schema)
    assert {:ok, {:object, projection}} = ModelContract.value_contract(contract)
    {"variants", variants} = List.keyfind(projection, "variants", 0)

    assert Enum.map(variants, fn {:object, pairs} ->
             {"discriminator", {:object, discriminator}} =
               List.keyfind(pairs, "discriminator", 0)

             List.keyfind(discriminator, "literal", 0)
           end) == [{"literal", "accepted"}, {"literal", "rejected"}]
  end

  test "ignores invalid string-const discriminator candidates accepted as ordinary fields" do
    schema = %{
      "oneOf" =>
        for kind <- ["accepted", "rejected"] do
          %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["kind", "marker"],
            "properties" => %{
              "kind" => %{"type" => "string", "const" => kind},
              "marker" => %{
                "type" => "string",
                "const" => if(kind == "accepted", do: "", else: "ready")
              }
            }
          }
        end
    }

    assert {:ok, contract} = ValueContract.compile(schema)
    assert {:ok, {:object, _projection}} = ModelContract.value_contract(contract)
  end

  alias PtcRunner.Lisp.Signature

  test "keeps positional nullability and map-field presence separate" do
    {:ok, signature} =
      Signature.parse("(query :string?) -> {items [:string], limit :int?}")

    assert {:ok, projection} = ModelContract.function(signature)
    decoded = decode(projection)

    assert get_in(decoded, ["parameters", Access.at(0), "type", "nullable"]) == true

    fields = decoded["returns"]["fields"] |> Map.new(&{&1["name"], &1})
    assert fields["items"]["required"] == true
    assert fields["items"]["type"]["nullable"] == false
    assert fields["limit"]["required"] == false
    assert fields["limit"]["type"]["nullable"] == true
  end

  test "projects any as nullable because runtime validation accepts nil" do
    {:ok, signature} = Signature.parse("(value :any) -> :any")

    assert {:ok, projection} = ModelContract.function(signature)
    decoded = decode(projection)

    assert get_in(decoded, ["parameters", Access.at(0), "type", "nullable"]) == true
    assert get_in(decoded, ["returns", "nullable"]) == true
  end

  test "projects an unconstrained array item as nullable any" do
    input = %{
      "type" => "object",
      "properties" => %{"values" => %{"type" => "array"}},
      "required" => ["values"]
    }

    assert {:ok, projection} = ModelContract.capability(input, nil)
    decoded = decode(projection)

    assert get_in(decoded, [
             "parameters",
             Access.at(0),
             "type",
             "fields",
             Access.at(0),
             "type",
             "items"
           ]) ==
             %{"kind" => "any", "nullable" => true}
  end

  test "projects every accepted direct-schema constraint without making optional fields nullable" do
    input = %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "mode" => %{"type" => "string", "enum" => ["fast", "accurate"]},
        "query" => %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => 100,
          "format" => "sha256"
        },
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 20},
        "tags" => %{
          "type" => "array",
          "items" => %{"type" => "string", "const" => "fixed"},
          "minItems" => 1,
          "maxItems" => 3
        }
      },
      "required" => ["query"]
    }

    output = %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{"count" => %{"type" => "integer", "minimum" => 0}},
      "required" => ["count"]
    }

    assert {:ok, projection} = ModelContract.capability(input, output)
    decoded = decode(projection)
    arguments = get_in(decoded, ["parameters", Access.at(0), "type"])
    fields = Map.new(arguments["fields"], &{&1["name"], &1})

    assert arguments["closed"] == true
    assert fields["query"]["required"] == true
    assert fields["query"]["type"]["min_length"] == 1
    assert fields["query"]["type"]["max_length"] == 100
    assert fields["query"]["type"]["format"] == "sha256"

    assert fields["limit"]["required"] == false
    assert fields["limit"]["type"]["nullable"] == false
    assert fields["limit"]["type"]["minimum"] == 1
    assert fields["limit"]["type"]["maximum"] == 20

    assert fields["mode"]["type"]["enum"] == ["accurate", "fast"]
    assert fields["tags"]["type"]["min_items"] == 1
    assert fields["tags"]["type"]["max_items"] == 3
    assert get_in(fields, ["tags", "type", "items", "const"]) == "fixed"
    assert get_in(decoded, ["returns", "fields", Access.at(0), "type", "minimum"]) == 0
  end

  test "projects nullable kinds independently from required property presence" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "required_nullable" => %{"type" => ["null", "string"]},
        "optional_non_null" => %{"type" => "string"},
        "optional_nullable_object" => %{
          "type" => ["object", "null"],
          "properties" => %{"value" => %{"type" => "integer"}}
        }
      },
      "required" => ["required_nullable"]
    }

    assert {:ok, contract} = ValueContract.compile(schema)
    assert {:ok, projection} = ModelContract.value_contract(contract)
    decoded = decode(projection)
    fields = decoded["fields"] |> Map.new(&{&1["name"], &1})

    assert fields["required_nullable"]["required"] == true
    assert fields["required_nullable"]["type"] == %{"kind" => "string", "nullable" => true}
    assert fields["optional_non_null"]["required"] == false
    assert fields["optional_non_null"]["type"]["nullable"] == false
    assert fields["optional_nullable_object"]["required"] == false
    assert fields["optional_nullable_object"]["type"]["kind"] == "object"
    assert fields["optional_nullable_object"]["type"]["nullable"] == true

    reversed = put_in(schema, ["properties", "required_nullable", "type"], ["string", "null"])
    assert {:ok, reversed_contract} = ValueContract.compile(reversed)
    assert {:ok, reversed_projection} = ModelContract.value_contract(reversed_contract)
    assert projection == reversed_projection

    assert ModelContract.projection_hash(projection) ==
             ModelContract.projection_hash(reversed_projection)
  end

  test "omits JSON Schema keywords that do not apply to the node type" do
    input = %{
      "type" => "object",
      "properties" => %{
        "count" => %{"type" => "integer", "minLength" => 3, "minItems" => 2},
        "query" => %{"type" => "string", "minimum" => 10, "minItems" => 2},
        "tags" => %{"type" => "array", "minimum" => 10, "minLength" => 3}
      }
    }

    assert {:ok, projection} = ModelContract.capability(input, nil)
    decoded = decode(projection)

    fields =
      decoded
      |> get_in(["parameters", Access.at(0), "type", "fields"])
      |> Map.new(&{&1["name"], &1["type"]})

    refute Map.has_key?(fields["count"], "min_length")
    refute Map.has_key?(fields["count"], "min_items")
    refute Map.has_key?(fields["query"], "minimum")
    refute Map.has_key?(fields["query"], "min_items")
    refute Map.has_key?(fields["tags"], "minimum")
    refute Map.has_key?(fields["tags"], "min_length")
  end

  test "canonicalizes semantically unordered enum members" do
    schema = fn values ->
      %{
        "type" => "object",
        "properties" => %{"mode" => %{"type" => "string", "enum" => values}},
        "required" => ["mode"]
      }
    end

    assert {:ok, left} = ModelContract.capability(schema.(["fast", "safe"]), nil)
    assert {:ok, right} = ModelContract.capability(schema.(["safe", "fast"]), nil)
    assert DeterministicJSON.encode(left) == DeterministicJSON.encode(right)
  end

  test "direct call forms include required fields only and escape hostile property names" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "line\nbreak" => %{"type" => "string"},
        "nil" => %{"type" => "null"},
        "optional" => %{"type" => "string"},
        "query" => %{"type" => "string"}
      },
      "required" => ["query", "line\nbreak", "nil"]
    }

    assert ModelContract.capability_call("search", schema) ==
             ~S|(tool/search {"line\nbreak" value1, "nil" value2, "query" query})|
  end

  test "direct call placeholders cannot collide with valid field names" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "needs space" => %{"type" => "string"},
        "value1" => %{"type" => "string"},
        "value2" => %{"type" => "string"}
      },
      "required" => ["value2", "needs space", "value1"]
    }

    assert ModelContract.capability_call("search", schema) ==
             ~S|(tool/search {"needs space" value3, "value1" value1, "value2" value2})|
  end

  test "direct call forms escape Unicode line separators" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "line\u2028separator" => %{"type" => "string"},
        "paragraph\u2029separator" => %{"type" => "string"}
      },
      "required" => ["paragraph\u2029separator", "line\u2028separator"]
    }

    call = ModelContract.capability_call("search", schema)
    refute call =~ "\u2028"
    refute call =~ "\u2029"
    assert call =~ ~S|\u2028|
    assert call =~ ~S|\u2029|
  end

  defp decode(value) do
    assert {:ok, encoded} = DeterministicJSON.encode(value)
    Jason.decode!(encoded)
  end
end
