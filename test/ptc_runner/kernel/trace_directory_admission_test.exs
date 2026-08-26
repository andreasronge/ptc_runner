defmodule PtcRunner.Kernel.TraceDirectoryAdmissionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.TraceDirectoryAdmission

  test "canonical filename claims use the frozen ASCII grammar" do
    maximum_stem = "a" <> String.duplicate("z", 255)
    valid = ["a.jsonl", "A-1._z.jsonl", maximum_stem <> ".jsonl", "run.private.jsonl"]

    for name <- valid do
      kind = if String.ends_with?(name, ".private.jsonl"), do: :private, else: :sanitized

      run_id =
        name |> String.replace_suffix(".private.jsonl", "") |> String.replace_suffix(".jsonl", "")

      assert {:ok, %{filename_run_claim: ^run_id, source_name: ^name, reasons: []}} =
               evidence(name, kind, [event(run_id, "trace")])
    end

    invalid = [
      ".jsonl",
      "-run.jsonl",
      "bad name.jsonl",
      <<"bad", 0, ".jsonl">>,
      <<"bad", 255, ".jsonl">>,
      String.duplicate("a", 257) <> ".jsonl"
    ]

    for name <- invalid do
      assert {:ok,
              %{
                raw_name: ^name,
                filename_run_claim: nil,
                source_name: nil,
                reasons: [:invalid_filename]
              }} = evidence(name, :sanitized, [event("embedded", "trace")])
    end
  end

  test "the reserved private suffix determines source class" do
    assert {:error, :invalid_evidence} =
             evidence("secret.private.jsonl", :sanitized, [event("secret.private", "trace")])

    assert {:error, :invalid_evidence} =
             evidence("secret.jsonl", :private, [event("secret", "trace")])
  end

  test "malformed syntax retains only the filename claim" do
    assert {:ok, evidence} =
             TraceDirectoryAdmission.evidence(
               "claimed.jsonl",
               :sanitized,
               :malformed_jsonl
             )

    assert evidence.filename_run_claim == "claimed"
    assert evidence.embedded_run_claims == []
    assert evidence.embedded_trace_claims == []
    assert evidence.reasons == [:malformed_jsonl]
  end

  test "the claim graph isolates a complete transitive component" do
    assert {:ok, first} = evidence("one.jsonl", :sanitized, [event("one", "trace-a")])

    assert {:ok, bridge} =
             evidence("two.jsonl", :sanitized, [
               event("one", "trace-b"),
               Map.put(event("two", "trace-b"), "sequence", 2)
             ])

    assert {:ok, third} = evidence("three.jsonl", :sanitized, [event("three", "trace-b")])
    assert {:ok, healthy} = evidence("healthy.jsonl", :sanitized, [event("healthy", "trace-ok")])

    assert {:ok, classification} =
             TraceDirectoryAdmission.classify([healthy, third, bridge, first])

    assert [%{source_name: "healthy.jsonl"}] = classification.admitted

    assert [component] = classification.isolated
    assert component.source_names == ["one.jsonl", "three.jsonl", "two.jsonl"]
    assert component.run_claims == ["one", "three", "two"]
    assert component.trace_claims == ["trace-a", "trace-b"]

    assert component.reasons == [
             :filename_run_mismatch,
             :run_identity_conflict,
             :trace_identity_conflict
           ]

    assert classification.known_isolated_run_ids == MapSet.new(["one", "three", "two"])
  end

  test "classification ordering is independent of input order and omits unsafe names" do
    unsafe_name = <<"unsafe", 255, ".jsonl">>
    assert {:ok, unsafe} = evidence(unsafe_name, :sanitized, [event("unsafe", "trace-u")])
    assert {:ok, alpha} = evidence("alpha.jsonl", :sanitized, [event("alpha", "trace-a")])

    assert {:ok, forward} = TraceDirectoryAdmission.classify([unsafe, alpha])
    assert {:ok, reverse} = TraceDirectoryAdmission.classify([alpha, unsafe])
    assert forward == reverse

    assert [admitted, isolated] = forward.components
    assert admitted.source_names == ["alpha.jsonl"]
    assert isolated.source_names == []
    assert isolated.source_count == 1
    assert isolated.sources_omitted_count == 1
    assert isolated.reasons == [:invalid_filename]
    assert hd(isolated.sources).raw_name == unsafe_name
  end

  test "reason order is closed and deterministic" do
    assert {:ok, evidence} =
             TraceDirectoryAdmission.evidence(
               "wrong.jsonl",
               :sanitized,
               {:decoded,
                [
                  event("embedded", "trace")
                  |> Map.put("schema_version", 3)
                  |> Map.put("sequence", 0)
                  |> Map.put("timestamp", "invalid")
                ]}
             )

    assert evidence.reasons == [
             :unsupported_version,
             :filename_run_mismatch,
             :sequence_conflict,
             :malformed_event
           ]

    assert TraceDirectoryAdmission.reason_order() == [
             :invalid_filename,
             :not_regular,
             :unreadable,
             :malformed_jsonl,
             :unsupported_version,
             :filename_run_mismatch,
             :run_identity_conflict,
             :trace_identity_conflict,
             :sequence_conflict,
             :lifecycle_conflict,
             :malformed_event
           ]
  end

  test "producer-grade semantics are part of evidence construction" do
    malformed = event("malformed", "trace") |> put_in(["data", "missions"], nil)
    assert {:ok, malformed_evidence} = evidence("malformed.jsonl", :sanitized, [malformed])
    assert malformed_evidence.reasons == [:malformed_event]

    later_event =
      event("sequence", "trace")
      |> Map.put("type", "custom")
      |> Map.put("data", %{})

    duplicate_sequence = [event("sequence", "trace"), later_event]
    assert {:ok, sequence_evidence} = evidence("sequence.jsonl", :sanitized, duplicate_sequence)
    assert sequence_evidence.reasons == [:sequence_conflict]

    duplicate_start = [
      event("lifecycle", "trace"),
      Map.put(event("lifecycle", "trace"), "sequence", 2)
    ]

    assert {:ok, lifecycle_evidence} = evidence("lifecycle.jsonl", :sanitized, duplicate_start)
    assert lifecycle_evidence.reasons == [:lifecycle_conflict]

    malformed_duplicate_start =
      duplicate_start
      |> List.update_at(1, &Map.put(&1, "timestamp", "invalid"))

    assert {:ok, combined_evidence} =
             evidence("lifecycle.jsonl", :sanitized, malformed_duplicate_start)

    assert combined_evidence.reasons == [:lifecycle_conflict, :malformed_event]

    overlong_run_id = String.duplicate("r", 257)

    invalid_identity =
      event(overlong_run_id, "trace")
      |> Map.put("type", "custom")
      |> Map.put("data", %{})

    assert {:ok, invalid_identity_evidence} =
             evidence("expected.jsonl", :sanitized, [invalid_identity])

    assert invalid_identity_evidence.reasons == [:filename_run_mismatch, :malformed_event]

    invalid_type = event("invalid-type", "trace") |> Map.put("type", "INVALID")

    assert {:ok, invalid_type_evidence} =
             evidence("invalid-type.jsonl", :sanitized, [invalid_type])

    assert invalid_type_evidence.reasons == [:malformed_event]

    invalid_evaluation =
      event("evaluation", "trace")
      |> Map.put("sequence", 2)
      |> Map.put("type", "evaluation-started")
      |> Map.put("data", %{
        "evaluation_id" => "",
        "environment" => "workflow",
        "parent_evaluation_id" => nil
      })

    assert {:ok, evaluation_evidence} =
             evidence("evaluation.jsonl", :sanitized, [
               event("evaluation", "trace"),
               invalid_evaluation
             ])

    assert evaluation_evidence.reasons == [:lifecycle_conflict]

    forbidden_parent =
      event("parent", "trace")
      |> Map.put("sequence", 2)
      |> Map.put("type", "custom")
      |> Map.put("data", %{"parent_evaluation_id" => "parent-eval"})

    assert {:ok, parent_evidence} =
             evidence("parent.jsonl", :sanitized, [event("parent", "trace"), forbidden_parent])

    assert parent_evidence.reasons == [:lifecycle_conflict]
  end

  test "classify refuses forged evidence without raising" do
    assert {:ok, valid} = evidence("valid.jsonl", :sanitized, [event("valid", "trace")])
    unsupported = Map.put(event("valid", "trace"), "schema_version", 3)

    for forged <- [
          Map.delete(valid, :status),
          %{valid | source_name: <<255>>},
          %{valid | reasons: [:unknown_reason]},
          %{valid | events: [unsupported], status: {:decoded, [unsupported]}}
        ] do
      assert {:error, :invalid_evidence} = TraceDirectoryAdmission.classify([forged])
    end
  end

  defp evidence(name, kind, events),
    do: TraceDirectoryAdmission.evidence(name, kind, {:decoded, events})

  defp event(run_id, trace_id) do
    %{
      "schema_version" => 2,
      "run_id" => run_id,
      "trace_id" => trace_id,
      "sequence" => 1,
      "timestamp" => "2026-08-26T00:00:00Z",
      "type" => "run-started",
      "data" => %{"missions" => %{}}
    }
  end
end
