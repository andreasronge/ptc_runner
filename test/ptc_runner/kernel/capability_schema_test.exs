defmodule PtcRunner.Kernel.CapabilitySchemaTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.TestSupport.TestHelpers

  @accepted_schema %{
    "type" => "object",
    "title" => "Request",
    "description" => "Every supported keyword",
    "properties" => %{
      "name" => %{
        "type" => "string",
        "description" => "A bounded enum",
        "enum" => ["Ada", "Grace"],
        "minLength" => 3,
        "maxLength" => 5
      },
      "fixed" => %{"type" => "string", "const" => "v1"},
      "count" => %{"type" => "integer", "minimum" => 1, "maximum" => 10},
      "ratio" => %{"type" => "number", "minimum" => 0, "maximum" => 1},
      "enabled" => %{"type" => "boolean"},
      "nothing" => %{"type" => "null"},
      "tags" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "minItems" => 1,
        "maxItems" => 2
      },
      "nested" => %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "string"}},
        "required" => ["value"],
        "additionalProperties" => true
      }
    },
    "required" => ["name", "fixed", "count", "ratio", "enabled", "nothing", "tags"]
  }

  @valid_arguments %{
    "name" => "Ada",
    "fixed" => "v1",
    "count" => 2,
    "ratio" => 0.5,
    "enabled" => true,
    "nothing" => nil,
    "tags" => ["one"],
    "nested" => %{"value" => "ok", "extension" => true}
  }

  test "freezes normalized schemas and effect into safe metadata" do
    output_schema = %{
      "type" => "object",
      "properties" => %{"ok" => %{"type" => "boolean"}},
      "required" => ["ok"]
    }

    assert {:ok, capability} =
             Capability.new(
               name: "schema-fixture",
               description: "Schema fixture",
               input_schema: @accepted_schema,
               output_schema: output_schema,
               effect: :read,
               callback: fn _ -> {:ok, %{"ok" => true}} end
             )

    assert Capability.metadata(capability) == %{
             name: "schema-fixture",
             description: "Schema fixture",
             model_visible: true,
             input_schema: Map.put(@accepted_schema, "additionalProperties", false),
             output_schema: Map.put(output_schema, "additionalProperties", false),
             effect: :read
           }
  end

  test "requires an input schema and rejects effects outside the closed vocabulary" do
    assert {:error, :invalid_capability} =
             Capability.new(name: "missing-schema", callback: fn _ -> {:ok, %{}} end)

    assert {:error, :invalid_capability} =
             Capability.new(
               name: "bad-effect",
               input_schema: %{"type" => "object"},
               effect: :network,
               callback: fn _ -> {:ok, %{}} end
             )
  end

  test "schema and semantic validation both pass before callback execution" do
    parent = self()

    assert {:ok, capability} =
             Capability.new(
               name: "checked",
               input_schema: @accepted_schema,
               validate: fn arguments ->
                 if arguments["count"] == 2, do: :ok, else: {:error, "count rejected"}
               end,
               callback: fn arguments ->
                 send(parent, {:called, arguments})
                 {:ok, %{}}
               end
             )

    {:ok, environment} = WorkflowEnvironment.new(capabilities: [capability])
    {:ok, state} = RunState.start(Limits.defaults())

    assert %{status: :ok, value: %{}} =
             Dispatcher.dispatch(
               state,
               :workflow,
               environment,
               "checked",
               @valid_arguments,
               TestHelpers.dispatch_context(state, :workflow, 100),
               nil,
               nil
             )

    assert_receive {:called, @valid_arguments}

    invalid_schema = Map.put(@valid_arguments, "extra", true)

    assert %{status: :error, kind: :protocol_error, reason: :invalid_arguments} =
             Dispatcher.dispatch(
               state,
               :workflow,
               environment,
               "checked",
               invalid_schema,
               TestHelpers.dispatch_context(state, :workflow, 100),
               nil,
               nil
             )

    semantic_rejection = Map.put(@valid_arguments, "count", 3)

    assert %{status: :error, kind: :protocol_error, reason: :invalid_arguments} =
             Dispatcher.dispatch(
               state,
               :workflow,
               environment,
               "checked",
               semantic_rejection,
               TestHelpers.dispatch_context(state, :workflow, 100),
               nil,
               nil
             )

    refute_received {:called, ^invalid_schema}
    refute_received {:called, ^semantic_rejection}
  end

  test "advertised output schema rejects a mismatched provider success" do
    assert {:ok, capability} =
             Capability.new(
               name: "bad-output",
               input_schema: %{"type" => "object"},
               output_schema: %{
                 "type" => "object",
                 "properties" => %{"ok" => %{"type" => "boolean"}},
                 "required" => ["ok"]
               },
               callback: fn _ -> {:ok, %{"ok" => "not-boolean"}} end
             )

    {:ok, environment} = WorkflowEnvironment.new(capabilities: [capability])
    {:ok, state} = RunState.start(Limits.defaults())

    assert %{
             status: :error,
             kind: :invalid_result,
             reason: :output_schema_mismatch,
             retryable?: false
           } =
             Dispatcher.dispatch(
               state,
               :workflow,
               environment,
               "bad-output",
               %{},
               TestHelpers.dispatch_context(state, :workflow, 100),
               nil,
               nil
             )
  end

  test "rejects unsupported keywords, union types, and non-object roots" do
    invalid_schemas = [
      %{"type" => "object", "$ref" => "#/$defs/value"},
      %{"type" => "object", "allOf" => []},
      %{"type" => "object", "if" => %{"type" => "object"}},
      %{"type" => "object", "pattern" => "^value"},
      %{"type" => "object", "patternProperties" => %{}},
      %{"type" => "object", "unevaluatedProperties" => false},
      %{"type" => ["object", "null"]},
      %{"type" => "string"}
    ]

    for schema <- invalid_schemas do
      assert {:error, :invalid_capability} = capability_with_schema(schema)
    end
  end

  test "rejects input property names that cannot survive the Lisp tool boundary" do
    schemas = [
      %{
        "type" => "object",
        "properties" => %{"user-id" => %{"type" => "integer"}},
        "required" => ["user-id"]
      },
      %{
        "type" => "object",
        "properties" => %{
          "nested" => %{
            "type" => "object",
            "properties" => %{"user-id" => %{"type" => "integer"}}
          }
        }
      },
      %{
        "type" => "object",
        "properties" => %{
          "user-id" => %{"type" => "integer"},
          "user_id" => %{"type" => "integer"}
        }
      },
      %{
        "type" => "object",
        "additionalProperties" => true,
        "const" => %{"user-id" => 1}
      },
      %{
        "type" => "object",
        "properties" => %{
          "filter" => %{
            "type" => "object",
            "additionalProperties" => true,
            "enum" => [%{"user-id" => 1}]
          }
        }
      }
    ]

    for schema <- schemas do
      assert {:error, :invalid_capability} = capability_with_schema(schema)
    end
  end

  test "rejects excessive depth, properties, enums, and encoded bytes" do
    too_deep =
      Enum.reduce(1..16, %{"type" => "string"}, fn index, child ->
        %{
          "type" => "object",
          "properties" => %{"level-#{index}" => child}
        }
      end)

    too_many_properties =
      Map.new(1..129, fn index -> {"p#{index}", %{"type" => "string"}} end)
      |> then(&%{"type" => "object", "properties" => &1})

    too_many_enum_members = %{
      "type" => "object",
      "properties" => %{"value" => %{"type" => "integer", "enum" => Enum.to_list(1..257)}}
    }

    too_large = %{
      "type" => "object",
      "description" => String.duplicate("x", 65_536)
    }

    for schema <- [too_deep, too_many_properties, too_many_enum_members, too_large] do
      assert {:error, :invalid_capability} = capability_with_schema(schema)
    end
  end

  test "deterministic JSON sorts maps recursively and rejects duplicate ordered keys" do
    value = %{"z" => [%{"b" => 2, "a" => 1}], "a" => "å"}

    assert {:ok, ~s({"a":"å","z":[{"a":1,"b":2}]})} = DeterministicJSON.encode(value)

    assert {:ok, ~s({"z":1,"a":{"a":3,"b":2}})} =
             DeterministicJSON.encode({:object, [{"z", 1}, {"a", %{"b" => 2, "a" => 3}}]})

    assert {:error, :duplicate_key} =
             DeterministicJSON.encode({:object, [{"same", 1}, {"same", 2}]})
  end

  defp capability_with_schema(schema) do
    Capability.new(name: "invalid-schema", input_schema: schema, callback: fn _ -> {:ok, %{}} end)
  end
end
