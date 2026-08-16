defmodule PtcRunner.Kernel.ContractSchemaDiagnosticTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandPath
  alias PtcRunner.Kernel.ContractSchemaDiagnostic
  alias PtcRunner.Kernel.DiagnosticCatalog
  alias PtcRunner.Kernel.ValueContract

  # A rule the compiler can emit but this boundary has no message for degrades
  # silently to the catalog literal, which is the blind refusal this closed
  # vocabulary exists to remove. The counts pin drift in both directions.
  test "every emitted rule has one message, and no message outlives its rule" do
    rules = ContractSchemaDiagnostic.rules()

    assert Enum.uniq(rules) == rules

    {rendered, unrendered} =
      Enum.split_with(rules, &match?({:ok, _message}, ContractSchemaDiagnostic.message(&1)))

    assert unrendered == [:unsupported_schema]
    assert length(ContractSchemaDiagnostic.messages()) == length(rendered)
  end

  test "every rule message is admitted by the catalog and the published schema" do
    fallback = DiagnosticCatalog.fetch!(:application, :contract_invalid).message
    admitted = ContractSchemaDiagnostic.message_schema(fallback)["enum"]

    for message <- ContractSchemaDiagnostic.messages() do
      assert ContractSchemaDiagnostic.valid_message?(message)
      assert DiagnosticCatalog.valid_message?(:application, :contract_invalid, message)
      assert message in admitted
    end

    assert fallback in admitted
    refute ContractSchemaDiagnostic.valid_message?(fallback)
    refute ContractSchemaDiagnostic.valid_message?("contract schema is bad")
  end

  test "the compiler reports one rule per authoring mistake" do
    object = fn node -> %{"type" => "object", "properties" => %{"f" => node}} end

    cases = [
      {object.(%{"enum" => [1, 2]}), :type_missing, [property: "properties", property: "f"]},
      {object.(%{"type" => "intger"}), :unsupported_type,
       [property: "properties", property: "f", property: "type"]},
      {object.(%{"type" => "integer", "multipleOf" => 7}), :unsupported_keyword,
       [property: "properties", property: "f", property: "multipleOf"]},
      {object.(%{"type" => "integer", "minimum" => 2, "maximum" => 1}), :bounds_inverted,
       [property: "properties", property: "f", property: "minimum"]},
      {object.(%{"type" => "string", "format" => "date-time"}), :unsupported_format,
       [property: "properties", property: "f", property: "format"]},
      {object.(%{"type" => "string", "items" => %{"type" => "string"}}), :keyword_not_applicable,
       [property: "properties", property: "f", property: "items"]},
      {object.(%{"type" => "string", "minLength" => "one"}), :invalid_keyword_value,
       [property: "properties", property: "f", property: "minLength"]},
      {%{"type" => "object", "properties" => %{}, "required" => ["absent"]},
       :required_property_undeclared, [property: "required"]},
      {%{"type" => "array", "items" => %{"type" => "string"}}, :root_not_object, []},
      {%{"$schema" => "not-a-dialect", "type" => "object"}, :unsupported_dialect,
       [property: "$schema"]},
      {%{"type" => "object", "properties" => %{"f" => %{"type" => "string", "enum" => []}}},
       :invalid_keyword_value, [property: "properties", property: "f", property: "enum"]}
    ]

    for {schema, rule, segments} <- cases do
      assert {:error, {:invalid_value_contract, rejection}} = ValueContract.compile(schema),
             "expected #{inspect(rule)} for #{inspect(schema)}"

      assert rejection.rule == rule
      assert rejection.segments == segments
      assert {:ok, _message} = ContractSchemaDiagnostic.message(rule)
    end
  end

  test "a location is minted only when it resolves in the submitted document" do
    document = %{
      "type" => "object",
      "properties" => %{"f" => %{"type" => "intger"}},
      "oneOf" => [%{"type" => "object"}]
    }

    assert %{rule: :unsupported_type, path: %CommandPath{} = path} =
             ContractSchemaDiagnostic.detail(document, %{
               rule: :unsupported_type,
               segments: [property: "properties", property: "f", property: "type"]
             })

    assert CommandPath.to_pointer(path) == "/properties/f/type"

    assert {:ok, indexed} =
             CommandPath.value_contract_schema(document, property: "oneOf", index: 0)

    assert CommandPath.to_pointer(indexed) == "/oneOf/0"

    for fabricated <- [
          [property: "properties", property: "absent"],
          [property: "oneOf", index: 1],
          [property: "properties", index: 0],
          [property: "type", property: "nested"],
          ["properties"]
        ] do
      assert {:error, :invalid_command_path} =
               CommandPath.value_contract_schema(document, fabricated)

      assert %{rule: :unsupported_type, path: nil} =
               ContractSchemaDiagnostic.detail(document, %{
                 rule: :unsupported_type,
                 segments: fabricated
               })
    end
  end
end
