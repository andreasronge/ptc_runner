defmodule PtcRunner.Kernel.SafeMetadataTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.SafeMetadata

  describe "agent-action annotation vocabulary" do
    test "accepts exactly turn and kind with the closed three-value vocabulary" do
      for kind <- ["tool-call", "protocol-error", "provider-error"] do
        assert SafeMetadata.annotation?("agent-action", %{"turn" => 0, "kind" => kind})
      end

      assert SafeMetadata.annotation?("agent-action", %{"turn" => 5, "kind" => "tool-call"})
    end

    test "bounds turn to 0..127" do
      assert SafeMetadata.annotation?("agent-action", %{"turn" => 127, "kind" => "tool-call"})
      refute SafeMetadata.annotation?("agent-action", %{"turn" => 128, "kind" => "tool-call"})
      refute SafeMetadata.annotation?("agent-action", %{"turn" => -1, "kind" => "tool-call"})
      refute SafeMetadata.annotation?("agent-action", %{"turn" => 1.0, "kind" => "tool-call"})
      refute SafeMetadata.annotation?("agent-action", %{"turn" => "0", "kind" => "tool-call"})
    end

    test "accepts the phased shape with phase, phase-turn, and mission" do
      for kind <- ["tool-call", "protocol-error", "provider-error"] do
        assert SafeMetadata.annotation?("agent-action", %{
                 "turn" => 3,
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
      refute SafeMetadata.annotation?("agent-action", %{"turn" => 0, "kind" => "thinking"})
      refute SafeMetadata.annotation?("agent-action", %{"turn" => 0, "kind" => nil})

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
end
