defmodule PtcRunner.Kernel.ValueContractTest do
  use ExUnit.Case, async: true

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
             ValueContract.classify(contract, %{
               "decision" => "propose-change",
               "reason" => "wrong branch"
             })

    secret = "must-not-escape"

    leaked =
      ValueContract.classify(contract, %{"decision" => "no-change", secret => secret})

    refute inspect(leaked) =~ secret
    assert leaked.undeclared_key_count == 1

    # An undeclared key is reported by keyword and location only. Its name is
    # model-authored, so naming it would put caller content into a public error
    # by the same route the rejected value is withheld from.
    assert %{path: "(root)", kind: :additionalProperties} in leaked.violations
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
    assert %{path: "candidate.content", kind: :type} in classification.violations
    refute Enum.any?(classification.violations, &(&1.path == "reason"))
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
