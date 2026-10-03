defmodule PtcRunner.Kernel.JSONSchemaBoundedTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ExecutionInput
  alias PtcRunner.Kernel.JSONSchema
  alias PtcRunner.Kernel.ValueContract

  @schema %{
    "type" => "object",
    "properties" => %{"ok" => %{"type" => "boolean"}},
    "required" => ["ok"]
  }

  test "runtime contracts refuse values exceeding the validation worker heap" do
    schema = %{
      "type" => "object",
      "properties" => %{"values" => %{"type" => "array", "items" => %{"type" => "integer"}}}
    }

    {:ok, contract} = ValueContract.compile(schema)
    value = %{"values" => List.duplicate(1, 3_000_000)}
    refute JSONSchema.valid?(contract.validator, value)
    refute ValueContract.valid?(contract, value)

    assert {%{value_kind: :unknown}, nil} =
             ValueContract.classify_with_evidence(contract, value)

    assert {:error, _reason} =
             ExecutionInput.new(value, :normal, contract)
  end

  test "bounded compilation matches host compilation for an admitted schema" do
    assert {:ok, normalized, compiled} = JSONSchema.compile(@schema)

    assert {:ok, ^normalized, bounded} =
             JSONSchema.compile_bounded(@schema, 1_000, 100_000_000)

    assert JSONSchema.valid?(compiled, %{"ok" => true})
    assert JSONSchema.valid?(bounded, %{"ok" => true})
    refute JSONSchema.valid?(bounded, %{"ok" => 1})
  end

  test "a proven invalid request schema is not compiler unavailability" do
    assert {:error, {:invalid_schema, %{rule: :unsupported_keyword}}} =
             JSONSchema.compile_bounded(
               %{"type" => "object", "$ref" => "#/$defs/value"},
               1_000,
               100_000_000
             )

    assert {:error, {:invalid_schema, %{rule: :not_a_schema_object}}} =
             JSONSchema.compile_bounded("not-an-object", 1_000, 100_000_000)
  end

  test "compiler heap exhaustion is unavailable rather than invalid" do
    assert {:unavailable, :heap_exceeded} =
             JSONSchema.compile_bounded(@schema, 1_000, 233)
  end
end
