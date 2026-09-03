defmodule PtcRunner.Kernel.SafeMetadataTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.SafeMetadata

  describe "agent-action annotation vocabulary" do
    test "accepts exactly turn and kind with the closed action vocabulary" do
      for kind <- [
            "tool-call",
            "protocol-error",
            "provider-error",
            "max-calls",
            "model-output-truncated"
          ] do
        assert SafeMetadata.annotation?("agent-action", action(0, kind))
      end

      assert SafeMetadata.annotation?("agent-action", action(5, "tool-call"))
    end

    test "bounds turn to 0..127" do
      assert SafeMetadata.annotation?("agent-action", %{
               action(127, "tool-call")
               | "max_turns" => 128
             })

      refute SafeMetadata.annotation?("agent-action", action(128, "tool-call"))
      refute SafeMetadata.annotation?("agent-action", action(6, "tool-call"))
      refute SafeMetadata.annotation?("agent-action", action(-1, "tool-call"))
      refute SafeMetadata.annotation?("agent-action", action(1.0, "tool-call"))
      refute SafeMetadata.annotation?("agent-action", action("0", "tool-call"))
    end

    test "accepts the phased shape with phase, phase-turn, and mission" do
      for kind <- [
            "tool-call",
            "protocol-error",
            "provider-error",
            "max-calls",
            "model-output-truncated"
          ] do
        assert SafeMetadata.annotation?("agent-action", %{
                 "turn" => 3,
                 "max_turns" => 6,
                 "invocation" => "agent-0123456789abcdef",
                 "kind" => kind,
                 "phase" => 1,
                 "phase_turn" => 0,
                 "mission" => "synthesize"
               })
      end
    end

    test "bounds the phased fields and refuses a partial phased shape" do
      phased = %{
        "turn" => 0,
        "max_turns" => 6,
        "invocation" => "agent-0123456789abcdef",
        "kind" => "tool-call",
        "phase" => 0,
        "phase_turn" => 0,
        "mission" => "case-derived"
      }

      refute SafeMetadata.annotation?("agent-action", %{phased | "phase" => 8})
      refute SafeMetadata.annotation?("agent-action", %{phased | "phase" => -1})
      refute SafeMetadata.annotation?("agent-action", %{phased | "phase_turn" => 128})
      refute SafeMetadata.annotation?("agent-action", %{phased | "mission" => ""})
      refute SafeMetadata.annotation?("agent-action", %{phased | "mission" => "No Spaces Here"})

      refute SafeMetadata.annotation?(
               "agent-action",
               %{phased | "mission" => String.duplicate("m", 129)}
             )

      # A phased record either carries all three phase fields or none: a
      # partial shape would be a new, unreviewed vocabulary.
      refute SafeMetadata.annotation?("agent-action", Map.delete(phased, "mission"))
      refute SafeMetadata.annotation?("agent-action", Map.delete(phased, "phase_turn"))
      refute SafeMetadata.annotation?("agent-action", Map.put(phased, "reason", "extra"))
    end

    test "rejects extra keys, missing keys, and arbitrary kinds" do
      refute SafeMetadata.annotation?("agent-action", %{
               "turn" => 0,
               "kind" => "tool-call",
               "reason" => "wrong-tool-name"
             })

      refute SafeMetadata.annotation?("agent-action", %{"turn" => 0})
      refute SafeMetadata.annotation?("agent-action", %{"kind" => "tool-call"})
      refute SafeMetadata.annotation?("agent-action", action(0, "thinking"))
      refute SafeMetadata.annotation?("agent-action", action(0, nil))

      refute SafeMetadata.annotation?("agent-action", %{
               "turn" => 0,
               "kind" => "tool-call",
               "source" => "(return 42)"
             })
    end

    test "keeps the progress vocabulary and rejects unknown types" do
      assert SafeMetadata.annotation?("progress", %{"stage" => "started"})

      refute SafeMetadata.annotation?("progress", %{
               "stage" => "started",
               "source" => "(return 42)"
             })

      refute SafeMetadata.annotation?("progress", %{"turn" => 0, "kind" => "tool-call"})
      refute SafeMetadata.annotation?("agent-step", %{"turn" => 0, "kind" => "tool-call"})
    end
  end

  describe "published workflow annotation vocabulary" do
    @source Path.expand("../../../lib/ptc_runner/kernel/safe_metadata.ex", __DIR__)
    @contract Path.expand("../../../docs/maintainers/trace-log-contract.md", __DIR__)

    # Clause order of every accepting SafeMetadata.annotation?/2 head. A new
    # type or key set must land in docs/maintainers/trace-log-contract.md in the same
    # change, or this test fails.
    @published [
      {"progress", ["stage"]},
      {"agent-action", ["turn", "max_turns", "invocation", "kind"]},
      {"agent-action",
       ["turn", "max_turns", "invocation", "kind", "phase", "phase_turn", "mission"]}
    ]

    test "annotation?/2 accepting clauses are exactly the published rows" do
      assert accepting_annotation_clauses(@source) == @published
    end

    test "docs/maintainers/trace-log-contract.md publishes those types, keys, and enumerations" do
      source = File.read!(@source)
      section = workflow_annotation_section(File.read!(@contract))
      [progress_row, agent_row] = published_table_rows(section)
      stages = attribute_list(source, :progress_stages)
      kinds = attribute_list(source, :agent_action_kinds)
      bounds = annotation_field_bounds(source)

      assert stages == ~w(started planning executing validating completed failed)

      assert kinds ==
               ~w(tool-call protocol-error provider-error max-calls model-output-truncated)

      assert progress_row =~ ~s("progress")
      refute progress_row =~ "agent-action"
      assert progress_row =~ ~s("stage")
      refute progress_row =~ ~s("turn")

      for stage <- stages do
        assert progress_row =~ stage
      end

      unescaped_progress = String.replace(progress_row, "\\", "")
      assert unescaped_progress =~ Enum.join(stages, " | ")

      assert agent_row =~ ~s("agent-action")
      refute agent_row =~ "progress"
      assert agent_row =~ "exactly four keys or exactly seven"

      [base_key, phased_key] = String.split(agent_row, "or that plus", parts: 2)

      assert base_key =~ ~s("turn": #{bounds.turn})
      assert base_key =~ ~s("max_turns": 1..128)
      assert base_key =~ ~s("invocation")
      assert base_key =~ ~s("kind")
      refute base_key =~ "phase"
      refute base_key =~ "mission"

      assert phased_key =~ ~s("phase": #{bounds.phase})
      assert phased_key =~ ~s("phase_turn": #{bounds.phase_turn})
      assert phased_key =~ ~s("mission")

      for kind <- kinds do
        assert base_key =~ kind
      end

      unescaped_kinds = String.replace(base_key, "\\", "")
      assert unescaped_kinds =~ Enum.join(kinds, " | ")

      assert section =~ "a lowercase letter, then up to #{bounds.mission_max} letters, digits"
      assert source =~ ~s|~r/\\A[a-z][a-z0-9._-]{0,#{bounds.mission_max}}\\z/|
    end
  end

  defp action(turn, kind) do
    %{
      "turn" => turn,
      "max_turns" => 6,
      "invocation" => "agent-0123456789abcdef",
      "kind" => kind
    }
  end

  describe "capability rejection class" do
    test "keeps known Kernel envelope atoms readable" do
      assert SafeMetadata.rejection_class(%{
               status: :error,
               kind: :invalid_annotation,
               reason: :invalid_workflow_annotation,
               details: "PRIVATE PAYLOAD"
             }) == %{kind: :invalid_annotation, reason: :invalid_workflow_annotation}
    end

    test "fingerprints unrecognized atoms instead of copying them" do
      class =
        SafeMetadata.rejection_class(%{
          status: :error,
          kind: :secret_rejection_kind,
          reason: :secret_rejection_reason
        })

      assert class == %{
               kind_fingerprint:
                 SafeMetadata.fingerprint("capability-kind:secret_rejection_kind"),
               reason_fingerprint:
                 SafeMetadata.fingerprint("capability-reason:secret_rejection_reason")
             }

      refute inspect(class) =~ "secret_rejection"
    end

    test "fingerprints an unknown reason beside a known kind" do
      class =
        SafeMetadata.rejection_class(%{
          status: :error,
          kind: :protocol_error,
          reason: :secret_rejection_reason
        })

      assert class.kind == :protocol_error
      refute Map.has_key?(class, :reason)

      assert class.reason_fingerprint ==
               SafeMetadata.fingerprint("capability-reason:secret_rejection_reason")
    end

    test "omits non-atoms and successful envelopes" do
      assert SafeMetadata.rejection_class(%{
               status: :error,
               kind: "PRIVATE_KIND",
               reason: "PRIVATE_REASON"
             }) == %{}

      assert SafeMetadata.rejection_class(%{status: :ok, kind: :invalid_annotation}) == %{}
    end
  end

  describe "capability refusal key" do
    test "joins environment with known kind and reason" do
      assert SafeMetadata.capability_refusal_key(:workflow, %{
               status: :error,
               kind: :limit_exceeded,
               reason: :capability_quota
             }) == "workflow/limit_exceeded/capability_quota"

      assert SafeMetadata.capability_refusal_key(:workflow, %{
               status: :error,
               kind: :limit_exceeded,
               reason: :llm_total_tokens
             }) == "workflow/limit_exceeded/llm_total_tokens"

      assert SafeMetadata.capability_refusal_key(:mission, %{
               status: :error,
               kind: :limit_exceeded,
               reason: :llm_cost_microusd
             }) == "mission/limit_exceeded/llm_cost_microusd"
    end

    test "budget_refusal requires a diagnostic-valid reservation tuple" do
      envelope = %{
        status: :error,
        kind: :limit_exceeded,
        reason: :llm_cost_microusd,
        details: %{limit: :llm_cost_microusd, limit_value: 250, requested: 1, remaining: 0}
      }

      assert {:ok, %{limit: :llm_cost_microusd, requested: 1, remaining: 0}} =
               SafeMetadata.budget_refusal(envelope)

      refute match?(
               {:ok, _details},
               SafeMetadata.budget_refusal(put_in(envelope, [:details, :requested], 0))
             )

      refute match?(
               {:ok, _details},
               SafeMetadata.budget_refusal(put_in(envelope, [:details, :remaining], 251))
             )
    end

    test "uses fingerprints and unknown for the remaining class fields" do
      kind_fingerprint = SafeMetadata.fingerprint("capability-kind:secret_rejection_kind")
      reason_fingerprint = SafeMetadata.fingerprint("capability-reason:secret_rejection_reason")

      assert SafeMetadata.capability_refusal_key(:mission, %{
               status: :error,
               kind: :secret_rejection_kind,
               reason: :secret_rejection_reason
             }) == "mission/#{kind_fingerprint}/#{reason_fingerprint}"

      assert SafeMetadata.capability_refusal_key(:workflow, %{
               status: :error,
               kind: :event_sink_error
             }) == "workflow/event_sink_error/unknown"

      assert SafeMetadata.capability_refusal_key(:workflow, %{
               status: :error,
               kind: "PRIVATE_KIND",
               reason: "PRIVATE_REASON"
             }) == "workflow/unknown/unknown"
    end
  end

  describe "LLM provider failure taxonomy" do
    test "retains only a closed class from the nested provider envelope" do
      failure = %{
        kind: :llm_provider_error,
        reason: %{
          status: :error,
          kind: :provider_error,
          reason: :payment_required,
          retryable?: false,
          details: "PRIVATE PROVIDER MESSAGE"
        }
      }

      assert SafeMetadata.llm_provider_failure(failure) ==
               %{llm_provider_failure: :payment_required, llm_provider_retryable?: false}

      refute inspect(SafeMetadata.llm_provider_failure(failure)) =~ "PRIVATE"
    end

    test "rejects lookalike and unknown nested values" do
      assert SafeMetadata.llm_provider_failure(%{
               kind: :other,
               reason: %{reason: :authentication_failed, retryable?: false}
             }) == %{}

      assert SafeMetadata.llm_provider_failure(%{
               kind: :llm_provider_error,
               reason: %{reason: :private_provider_kind, retryable?: false}
             }) == %{}

      assert SafeMetadata.llm_provider_failure(%{
               kind: :llm_provider_error,
               reason: %{reason: :payment_required}
             }) == %{}
    end
  end

  defp accepting_annotation_clauses(path) do
    {_ast, clauses} =
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:def, _, [{:when, _, [{:annotation?, _, [type, data]} | _]} | _]} = node, acc ->
          {node, [annotation_clause_row(type, data) | acc]}

        {:def, _, [{:annotation?, _, [type, data]} | _]} = node, acc ->
          {node, [annotation_clause_row(type, data) | acc]}

        node, acc ->
          {node, acc}
      end)

    clauses
    |> Enum.reverse()
    |> Enum.reject(&(&1 == :catchall))
  end

  defp annotation_clause_row(type, _data) when is_tuple(type), do: :catchall

  defp annotation_clause_row(type, {:=, _, [map_pattern, _name]}) when is_binary(type) do
    {type, map_pattern_keys(map_pattern)}
  end

  defp map_pattern_keys({:%{}, _, pairs}) do
    Enum.map(pairs, fn {key, _value} -> key end)
  end

  defp workflow_annotation_section(contract) do
    case String.split(contract, "Workflow annotations are host stamped", parts: 2) do
      [_before, rest] ->
        rest
        |> String.split("\n## ", parts: 2)
        |> hd()

      _missing ->
        flunk(
          "docs/maintainers/trace-log-contract.md has no workflow-annotation vocabulary section"
        )
    end
  end

  defp published_table_rows(section) do
    rows =
      section
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "| `"))
      |> Enum.reject(&String.contains?(&1, "annotation_type"))

    assert length(rows) == 2,
           "expected exactly two published annotation rows, got: #{inspect(rows)}"

    rows
  end

  defp attribute_list(source, name) do
    pattern = ~r/@#{name} ~w\(([^)]+)\)/

    case Regex.run(pattern, source, capture: :all_but_first) do
      [body] -> String.split(body)
      _missing -> flunk("SafeMetadata is missing @#{name} ~w(...)")
    end
  end

  defp annotation_field_bounds(source) do
    turn = integer_bound(source, ~r/turn >= 0 and turn <= (\d+)/)
    phase = integer_bound(source, ~r/phase >= 0 and phase <= (\d+)/)
    phase_turn = integer_bound(source, ~r/phase_turn >= 0 and phase_turn <= (\d+)/)
    mission_max = integer_bound(source, ~r/\[a-z0-9\._-\]\{0,(\d+)\}/)

    %{
      turn: "0..#{turn}",
      phase: "0..#{phase}",
      phase_turn: "0..#{phase_turn}",
      mission_max: mission_max
    }
  end

  defp integer_bound(source, pattern) do
    case Regex.run(pattern, source, capture: :all_but_first) do
      [digits] -> String.to_integer(digits)
      _missing -> flunk("SafeMetadata annotation?/2 is missing #{inspect(pattern)}")
    end
  end
end
