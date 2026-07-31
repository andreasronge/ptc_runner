defmodule PtcRunner.Kernel.ValueContractTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandContractAuthority
  alias PtcRunner.Kernel.CommandPath
  alias PtcRunner.Kernel.ExecutionInput
  alias PtcRunner.Kernel.ValueContract

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
             matched_branch: "propose-change",
             missing_required: ["candidate"]
           } =
             classified =
             ValueContract.classify(contract, %{
               "decision" => "propose-change",
               "reason" => "wrong branch"
             })

    refute Map.has_key?(classified, :branch_index)

    secret = "must-not-escape"

    leaked =
      ValueContract.classify(contract, %{"decision" => "no-change", secret => secret})

    refute inspect(leaked) =~ secret
    assert leaked.undeclared_key_count == 1

    # An undeclared key is reported by keyword and location only. Its name is
    # model-authored, so naming it would put caller content into a public error
    # by the same route the rejected value is withheld from.
    assert Enum.any?(leaked.violations, &(&1.segments == []))
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
    assert classification.missing_required == ["reason"]

    refute Enum.any?(
             classification.violations,
             &(&1.kind == :const and &1.segments == [{:property, "decision"}])
           )
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

  test "reports the selected branch's fault, not another branch's undeclared keys" do
    assert {:ok, contract} = ValueContract.compile(report_schema())

    classification =
      ValueContract.classify(contract, %{
        "kind" => "report",
        "facts" => [%{"citations" => []}]
      })

    assert classification.matched_branch == "report"

    # The selected branch fails on one thing: an empty `citations` array. Every
    # key of this value is also undeclared in the *other* branch, which rejects
    # each of them through `additionalProperties: false`. Those rejections carry
    # no information the caller can act on, and reporting one of them instead
    # sends a correcting model to the wrong field.
    assert %{
             kind: :minItems,
             segments: [{:property, "facts"}, {:index, 0}, {:property, "citations"}]
           } in classification.violations

    refute Enum.any?(classification.violations, &(&1.kind == :boolean_schema))
  end

  test "reports a missing required key of the selected branch" do
    assert {:ok, contract} = ValueContract.compile(report_schema())

    classification = ValueContract.classify(contract, %{"kind" => "report"})

    assert classification.matched_branch == "report"
    assert "facts" in classification.missing_required
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

  # A union whose selected branch is index 0 and whose fault is nested. The
  # `decision_schema/0` union above happens to select index 1, which is why its
  # violations came out right by accident of ordering rather than by selection.
  defp report_schema do
    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "oneOf" => [
        %{
          "type" => "object",
          "required" => ["kind", "facts"],
          "properties" => %{
            "kind" => %{"type" => "string", "const" => "report"},
            "facts" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "required" => ["citations"],
                "properties" => %{
                  "citations" => %{
                    "type" => "array",
                    "minItems" => 1,
                    "items" => %{"type" => "string"}
                  }
                }
              }
            }
          }
        },
        %{
          "type" => "object",
          "required" => ["kind", "reason"],
          "properties" => %{
            "kind" => %{"type" => "string", "const" => "withheld"},
            "reason" => %{"type" => "string", "maxLength" => 1_000}
          }
        }
      ]
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
