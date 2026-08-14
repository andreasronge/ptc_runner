defmodule PtcRunner.Kernel.ValueContractTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandContractAuthority
  alias PtcRunner.Kernel.CommandPath
  alias PtcRunner.Kernel.CommandSource
  alias PtcRunner.Kernel.ExecutionInput
  alias PtcRunner.Kernel.ValueContract
  alias PtcRunner.Kernel.ValueContractDiagnostic

  test "compiles and validates an ordinary bounded object contract" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "task" => %{"type" => "string", "minLength" => 1, "maxLength" => 100}
      },
      "required" => ["task"]
    }

    assert {:ok, contract} = ValueContract.compile(schema)
    assert contract.schema["additionalProperties"] == false
    assert ValueContract.valid?(contract, %{"task" => "inspect"})
    refute ValueContract.valid?(contract, %{"task" => ""})
    refute ValueContract.valid?(contract, %{"task" => "inspect", "extra" => true})
  end

  test "accepts only a bounded root tagged union with one shared discriminator" do
    schema = decision_schema()

    assert {:ok, contract} = ValueContract.compile(schema)

    assert ValueContract.valid?(contract, %{
             "decision" => "no-change",
             "reason" => "No recurring failure"
           })

    assert ValueContract.valid?(contract, %{
             "decision" => "propose-change",
             "candidate" => %{"content" => "(ns agent.core)"}
           })

    refute ValueContract.valid?(contract, %{
             "decision" => "propose-change",
             "reason" => "wrong branch"
           })

    refute ValueContract.valid?(contract, %{
             "decision" => "unknown",
             "reason" => "not declared"
           })
  end

  # Diagnosing "the model returned the discriminator instead of the map" cost
  # three live runs, because the rejection named neither the expected shape nor
  # what arrived. Everything reported here comes from the schema; the value
  # contributes only its JSON kind and a count.
  test "explains a rejection without disclosing the rejected value" do
    assert {:ok, contract} = ValueContract.compile(decision_schema())

    assert %{value_kind: :string, matched_branch: nil, discriminator: "decision"} =
             bare = ValueContract.classify(contract, "no-change")

    assert "no-change" in bare.expected_branches

    assert %{
             value_kind: :object,
             matched_branch: "propose-change"
           } =
             classified =
             ValueContract.classify(contract, %{
               "decision" => "propose-change",
               "reason" => "wrong branch"
             })

    refute Map.has_key?(classified, :branch_index)
    refute Map.has_key?(classified, :missing_required)
    refute Map.has_key?(classified, :undeclared_key_count)

    assert Enum.any?(classified.violations, fn violation ->
             violation[:segments] == [] and
               violation[:allowed_keys] == ["candidate", "decision"] and
               violation[:missing_required] == ["candidate"] and
               violation[:undeclared_key_count] == 1
           end)

    secret = "must-not-escape"

    leaked =
      ValueContract.classify(contract, %{"decision" => "no-change", secret => secret})

    refute inspect(leaked) =~ secret

    # An undeclared key is reported by count, safe location, and the schema's
    # allowed names. Its caller-authored name never enters the public error.
    assert Enum.any?(leaked.violations, fn violation ->
             violation[:segments] == [] and
               violation[:allowed_keys] == ["decision", "reason"] and
               violation[:missing_required] == ["reason"] and
               violation[:undeclared_key_count] == 1
           end)
  end

  # Keyword keys are the commonest authoring mistake in PTC-Lisp, and they fail
  # the JSON-value guard before any schema keyword runs. Reporting an empty
  # violation list for them says "nothing is wrong" about a rejected value.
  test "reports a value that is not JSON-like, which produces no violations" do
    assert {:ok, contract} = ValueContract.compile(decision_schema())

    assert %{json_value: false, violations: []} =
             ValueContract.classify(contract, %{decision: "no-change", reason: "keyword keys"})

    assert %{json_value: true} =
             ValueContract.classify(contract, %{"decision" => "no-change"})
  end

  test "locates a nested violation by path within the matched branch" do
    assert {:ok, contract} = ValueContract.compile(decision_schema())

    classification =
      ValueContract.classify(contract, %{
        "decision" => "propose-change",
        "candidate" => %{"content" => 42}
      })

    assert classification.matched_branch == "propose-change"

    # Only the selected branch is reported. The branches the discriminator did
    # not choose fail too, on required keys they were never given, and burying
    # the real fault under those is what made the original error unusable.
    assert %{
             segments: [{:property, "candidate"}, {:property, "content"}],
             kind: :type
           } in classification.violations

    refute Enum.any?(
             classification.violations,
             &(&1.segments == [{:property, "reason"}])
           )
  end

  test "attributes all violations by tagged-union branch identity rather than detail position" do
    assert {:ok, contract} = ValueContract.compile(decision_schema())

    classification =
      ValueContract.classify(contract, %{
        "decision" => "no-change"
      })

    assert classification.matched_branch == "no-change"

    assert Enum.any?(classification.violations, fn violation ->
             violation[:segments] == [] and
               violation[:allowed_keys] == ["decision", "reason"] and
               violation[:missing_required] == ["reason"]
           end)

    refute Enum.any?(
             classification.violations,
             &(&1.kind == :const and &1.segments == [{:property, "decision"}])
           )
  end

  test "reports nested object diagnostics without caller-authored keys or values" do
    assert {:ok, contract} = ValueContract.compile(nested_report_schema())

    caller_key_a = "submitted-timestamp"
    caller_key_b = "submitted-description"
    caller_value = "private-value"

    classification =
      ValueContract.classify(contract, %{
        "kind" => "report",
        "timeline" => [
          %{
            caller_key_a => caller_value,
            caller_key_b => caller_value,
            "citations" => []
          },
          %{
            caller_key_a => caller_value,
            "statement" => "second item",
            "citations" => []
          }
        ]
      })

    refute Map.has_key?(classification, :missing_required)
    refute Map.has_key?(classification, :undeclared_key_count)

    diagnostics =
      Enum.filter(classification.violations, &Map.has_key?(&1, :allowed_keys))

    assert Enum.any?(diagnostics, fn violation ->
             violation.segments == [{:property, "timeline"}, {:index, 0}] and
               violation.allowed_keys == ["citations", "observed_at", "statement"] and
               violation.missing_required == ["observed_at", "statement"] and
               violation.undeclared_key_count == 2
           end)

    assert Enum.any?(diagnostics, fn violation ->
             violation.segments == [{:property, "timeline"}, {:index, 1}] and
               violation.allowed_keys == ["citations", "observed_at", "statement"] and
               violation.missing_required == ["observed_at"] and
               violation.undeclared_key_count == 1
           end)

    rendered = inspect(classification)
    refute rendered =~ caller_key_a
    refute rendered =~ caller_key_b
    refute rendered =~ caller_value
  end

  test "does not call extension keys undeclared in an open root object" do
    assert {:ok, contract} =
             ValueContract.compile(%{
               "type" => "object",
               "additionalProperties" => true,
               "properties" => %{"required_key" => %{"type" => "string"}},
               "required" => ["required_key"]
             })

    classification = ValueContract.classify(contract, %{"extension" => "private-value"})
    diagnostic = Enum.find(classification.violations, &(&1.segments == []))

    assert diagnostic.missing_required == ["required_key"]
    refute Map.has_key?(diagnostic, :allowed_keys)
    refute Map.has_key?(diagnostic, :undeclared_key_count)
    refute inspect(classification) =~ "extension"
    refute inspect(classification) =~ "private-value"
  end

  test "does not call extension keys undeclared in a nested open object" do
    assert {:ok, contract} =
             ValueContract.compile(%{
               "type" => "object",
               "properties" => %{
                 "payload" => %{
                   "type" => "object",
                   "additionalProperties" => true,
                   "properties" => %{"required_key" => %{"type" => "string"}},
                   "required" => ["required_key"]
                 }
               },
               "required" => ["payload"]
             })

    classification =
      ValueContract.classify(contract, %{
        "payload" => %{"extension" => "private-value"}
      })

    diagnostic =
      Enum.find(
        classification.violations,
        &(&1.segments == [{:property, "payload"}])
      )

    assert diagnostic.missing_required == ["required_key"]
    refute Map.has_key?(diagnostic, :allowed_keys)
    refute Map.has_key?(diagnostic, :undeclared_key_count)
    refute inspect(classification) =~ "extension"
    refute inspect(classification) =~ "private-value"
  end

  test "bounds sorted schema-name guidance by count and encoded bytes" do
    short_names = for index <- 1..40, do: "field-#{String.pad_leading("#{index}", 2, "0")}"

    assert {:ok, count_contract} =
             ValueContract.compile(%{
               "type" => "object",
               "properties" => Map.new(short_names, &{&1, %{"type" => "string"}}),
               "required" => short_names
             })

    count_classification = ValueContract.classify(count_contract, %{"caller-only" => "hidden"})

    count_diagnostic =
      Enum.find(count_classification.violations, &Map.has_key?(&1, :allowed_keys))

    assert count_diagnostic.allowed_keys == Enum.take(Enum.sort(short_names), 32)
    assert count_diagnostic.allowed_key_count == 40
    assert count_diagnostic.allowed_keys_truncated
    assert count_diagnostic.missing_required == Enum.take(Enum.sort(short_names), 32)
    assert count_diagnostic.missing_required_count == 40
    assert count_diagnostic.missing_required_truncated
    refute inspect(count_classification) =~ "caller-only"

    long_names = ["a" <> String.duplicate("x", 2_999), "b" <> String.duplicate("y", 2_999)]

    assert {:ok, byte_contract} =
             ValueContract.compile(%{
               "type" => "object",
               "properties" => Map.new(long_names, &{&1, %{"type" => "string"}})
             })

    byte_classification = ValueContract.classify(byte_contract, %{"caller-only" => "hidden"})
    byte_diagnostic = Enum.find(byte_classification.violations, &Map.has_key?(&1, :allowed_keys))

    assert byte_diagnostic.allowed_keys == [hd(long_names)]
    assert byte_diagnostic.allowed_key_count == 2
    assert byte_diagnostic.allowed_keys_truncated
  end

  test "object type failures carry only schema-derived allowed keys" do
    assert {:ok, contract} =
             ValueContract.compile(%{
               "type" => "object",
               "properties" => %{
                 "payload" => %{
                   "type" => "object",
                   "properties" => %{"answer" => %{"type" => "integer"}},
                   "required" => ["answer"]
                 }
               },
               "required" => ["payload"]
             })

    classification = ValueContract.classify(contract, %{"payload" => 42})

    assert %{allowed_keys: ["answer"]} =
             diagnostic =
             Enum.find(classification.violations, fn violation ->
               violation.kind == :type and
                 violation.segments == [{:property, "payload"}]
             end)

    refute Map.has_key?(diagnostic, :missing_required)
    refute Map.has_key?(diagnostic, :undeclared_key_count)
  end

  test "retains only locally declared path segments and RFC 6901-escapes them" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "declared/at~root" => %{
          "type" => "object",
          "properties" => %{"safe" => %{"type" => "integer"}}
        },
        "elsewhere" => %{
          "type" => "object",
          "properties" => %{"secret" => %{"type" => "integer"}}
        }
      }
    }

    assert {:ok, contract} = ValueContract.compile(schema)

    escaped =
      ValueContract.classify(contract, %{
        "declared/at~root" => %{"safe" => "wrong"},
        "elsewhere" => %{"secret" => 1}
      })

    assert %{segments: [{:property, "declared/at~root"}, {:property, "safe"}]} =
             Enum.find(escaped.violations, &(&1.kind == :type))

    {_classification, evidence} =
      ValueContract.classify_with_evidence(contract, %{
        "declared/at~root" => %{"safe" => "wrong"}
      })

    assert {:ok, authority} = CommandContractAuthority.new(evidence)

    assert {:ok, path} =
             CommandPath.contract(authority, [
               {:property, "declared/at~root"},
               {:property, "safe"}
             ])

    assert CommandPath.to_pointer(path) == "/declared~1at~0root/safe"

    local_only =
      ValueContract.classify(contract, %{
        "declared/at~root" => %{"secret" => "must-not-be-retained"},
        "elsewhere" => %{"secret" => 1}
      })

    assert Enum.any?(
             local_only.violations,
             &(&1.segments == [{:property, "declared/at~root"}])
           )

    refute Enum.any?(
             local_only.violations,
             &(&1.segments == [
                 {:property, "declared/at~root"},
                 {:property, "secret"}
               ])
           )
  end

  test "rejects a mutated compiled contract as path authority" do
    assert {:ok, contract} =
             ValueContract.compile(%{
               "type" => "object",
               "properties" => %{"safe" => %{"type" => "integer"}}
             })

    forged = %{
      contract
      | schema: %{
          "type" => "object",
          "properties" => %{"caller-secret" => %{"type" => "string"}}
        }
    }

    refute ValueContract.sealed?(forged)
    refute ValueContract.valid?(forged, %{"caller-secret" => "hidden"})

    assert {:error, :invalid_input} =
             ExecutionInput.new(%{"caller-secret" => "hidden"}, :normal, forged)

    assert {:error, :invalid_command_path} =
             CommandPath.contract(forged, [{:property, "caller-secret"}])
  end

  test "contract path authority is restricted to the classified tagged-union branch" do
    assert {:ok, contract} = ValueContract.compile(decision_schema())

    assert {:error, {:input_contract_failed, classification}} =
             ExecutionInput.new(
               %{"decision" => "no-change", "reason" => 42},
               :normal,
               contract
             )

    assert {:ok, path} =
             CommandPath.contract(classification.contract_authority, [
               {:property, "reason"}
             ])

    assert CommandPath.to_pointer(path) == "/reason"

    assert {:error, :invalid_command_path} =
             CommandPath.contract(classification.contract_authority, [
               {:property, "candidate"}
             ])
  end

  test "command diagnostics prefer declared leaves and name missing properties" do
    assert {:ok, contract} =
             ValueContract.compile(%{
               "type" => "object",
               "properties" => %{"answer" => %{"type" => "integer"}},
               "required" => ["answer"]
             })

    {:ok, source} = CommandSource.new(:result_contract, "result.schema.json")

    for value <- [%{"answer" => "wrong", "extra" => 1}, %{}] do
      assert {:ok, classification} = ValueContractDiagnostic.classify(contract, value)

      assert {_bound_source, %CommandPath{} = path} =
               ValueContractDiagnostic.diagnostic_parts(source, classification)

      assert CommandPath.to_pointer(path) == "/answer"
    end

    assert {:ok, missing} = ValueContractDiagnostic.classify(contract, %{})

    assert Enum.any?(missing.violations, fn
             %{missing_required: ["answer"], path: path} -> CommandPath.to_pointer(path) == ""
             _other -> false
           end)

    assert {:ok, union_contract} = ValueContract.compile(decision_schema())
    assert {:ok, union_classification} = ValueContractDiagnostic.classify(union_contract, %{})

    assert {_bound_source, %CommandPath{} = discriminator_path} =
             ValueContractDiagnostic.diagnostic_parts(source, union_classification)

    assert CommandPath.to_pointer(discriminator_path) == "/decision"

    assert {:error, :invalid_command_path} =
             CommandPath.contract(union_classification.contract_authority, [
               {:property, "reason"}
             ])

    assert {:ok, unmatched} =
             ValueContractDiagnostic.classify(union_contract, %{
               "decision" => "unknown",
               "reason" => "still declared in one branch"
             })

    refute Enum.any?(unmatched.violations, &Map.has_key?(&1, :allowed_keys))
    refute Enum.any?(unmatched.violations, &Map.has_key?(&1, :undeclared_key_count))

    assert {_bound_source, %CommandPath{} = unmatched_path} =
             ValueContractDiagnostic.diagnostic_parts(source, unmatched)

    assert CommandPath.to_pointer(unmatched_path) == "/decision"
  end

  test "nested object diagnostics retain the selected branch's attested path" do
    schema = %{
      "oneOf" => [
        nested_branch("left", "left_value"),
        nested_branch("right", "right_value")
      ]
    }

    assert {:ok, contract} = ValueContract.compile(schema)

    assert {:error, {:input_contract_failed, classification}} =
             ExecutionInput.new(
               %{
                 "kind" => "left",
                 "payload" => %{"caller-only" => "private-value"}
               },
               :normal,
               contract
             )

    assert %{allowed_keys: ["left_value"], missing_required: ["left_value"]} =
             diagnostic =
             Enum.find(classification.violations, &Map.has_key?(&1, :allowed_keys))

    assert CommandPath.to_pointer(diagnostic.path) == "/payload"
    refute Map.has_key?(diagnostic, :segments)
    refute inspect(classification) =~ "right_value"
    refute inspect(classification) =~ "caller-only"
    refute inspect(classification) =~ "private-value"
  end

  test "rejects ambiguous, mismatched, repeated, open, and excessive union branches" do
    [no_change, propose] = decision_schema()["oneOf"]

    ambiguous =
      Enum.map([no_change, propose], fn branch ->
        branch
        |> put_in(["properties", "kind"], %{
          "type" => "string",
          "const" => branch["properties"]["decision"]["const"]
        })
        |> Map.update!("required", &["kind" | &1])
      end)

    mismatched =
      put_in(
        propose,
        ["properties"],
        Map.put(propose["properties"], "action", %{
          "type" => "string",
          "const" => "propose-change"
        })
      )
      |> Map.update!("required", fn required -> ["action" | List.delete(required, "decision")] end)

    repeated = put_in(propose, ["properties", "decision", "const"], "no-change")
    open = Map.put(propose, "additionalProperties", true)

    invalid = [
      %{"oneOf" => [no_change]},
      %{"oneOf" => ambiguous},
      %{"oneOf" => [no_change, mismatched]},
      %{"oneOf" => [no_change, repeated]},
      %{"oneOf" => [no_change, open]},
      %{"oneOf" => List.duplicate(no_change, 17)}
    ]

    for schema <- invalid do
      assert {:error, :invalid_value_contract} = ValueContract.compile(schema)
    end
  end

  test "does not enable general composition or references" do
    invalid = [
      %{"oneOf" => [branch("a"), branch("b")], "$ref" => "#/$defs/decision"},
      %{"allOf" => [branch("a"), branch("b")]},
      %{
        "oneOf" => [
          branch("a"),
          put_in(branch("b"), ["properties", "nested"], %{
            "oneOf" => [%{"type" => "string"}, %{"type" => "null"}]
          })
        ]
      },
      %{
        "oneOf" => [
          branch("a"),
          put_in(branch("b"), ["properties", "value"], %{
            "type" => "string",
            "pattern" => "^unsafe"
          })
        ]
      }
    ]

    for schema <- invalid do
      assert {:error, :invalid_value_contract} = ValueContract.compile(schema)
    end
  end

  defp decision_schema do
    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "title" => "Candidate decision",
      "oneOf" => [
        %{
          "type" => "object",
          "properties" => %{
            "decision" => %{"type" => "string", "const" => "no-change"},
            "reason" => %{"type" => "string", "maxLength" => 1_000}
          },
          "required" => ["decision", "reason"]
        },
        %{
          "type" => "object",
          "properties" => %{
            "decision" => %{"type" => "string", "const" => "propose-change"},
            "candidate" => %{
              "type" => "object",
              "properties" => %{
                "content" => %{"type" => "string", "maxLength" => 32_000}
              },
              "required" => ["content"]
            }
          },
          "required" => ["decision", "candidate"]
        }
      ]
    }
  end

  defp nested_report_schema do
    %{
      "oneOf" => [
        %{
          "type" => "object",
          "required" => ["kind", "timeline"],
          "properties" => %{
            "kind" => %{"type" => "string", "const" => "report"},
            "timeline" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "required" => ["observed_at", "statement", "citations"],
                "properties" => %{
                  "observed_at" => %{"type" => "string"},
                  "statement" => %{"type" => "string"},
                  "citations" => %{"type" => "array", "items" => %{"type" => "string"}}
                }
              }
            }
          }
        },
        %{
          "type" => "object",
          "properties" => %{
            "kind" => %{"type" => "string", "const" => "withheld"}
          },
          "required" => ["kind"]
        }
      ]
    }
  end

  defp nested_branch(kind, field) do
    %{
      "type" => "object",
      "properties" => %{
        "kind" => %{"type" => "string", "const" => kind},
        "payload" => %{
          "type" => "object",
          "properties" => %{field => %{"type" => "integer"}},
          "required" => [field]
        }
      },
      "required" => ["kind", "payload"]
    }
  end

  defp branch(value) do
    %{
      "type" => "object",
      "properties" => %{
        "decision" => %{"type" => "string", "const" => value}
      },
      "required" => ["decision"]
    }
  end
end
