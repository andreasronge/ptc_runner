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

  describe "declared annotation counter names" do
    test "a hyphenated declared counter is satisfied by its tool-boundary-normalized data key" do
      # `already-seen`/`net-new` are how the counters are declared (kebab-case,
      # matching `declarable_annotation?/2`). By the time `data` reaches here
      # it has already crossed the tool boundary, where
      # `PtcRunner.Lisp.KeyNormalizer.normalize_key/1` rewrites every hyphen
      # to an underscore — so the data keys are `already_seen`/`net_new`.
      declared = %{"records-checked" => ["already-seen", "net-new"]}

      assert SafeMetadata.annotation?(
               "records-checked",
               %{"already_seen" => 3, "net_new" => 1},
               declared
             )
    end

    test "declarable_annotation?/2 rejects an underscore in a declared name" do
      refute SafeMetadata.declarable_annotation?("records-checked", ["already_seen"])
    end

    test "a malformed declared counter with an underscore never validates" do
      # Defence in depth: `annotation?/3` re-checks `declarable_annotation?/2`
      # against the declared counters exactly as given. Normalizing those
      # declared names before this re-check would make it pass here, which
      # would defeat the point of keeping the check at all.
      malformed_declared = %{"records-checked" => ["already_seen"]}

      refute SafeMetadata.annotation?(
               "records-checked",
               %{"already_seen" => 1},
               malformed_declared
             )
    end
  end

  describe "failure taxonomy" do
    test "names framework kinds and fingerprints everything else" do
      assert SafeMetadata.failure_taxonomy(%{"kind" => "turn-limit"}) == %{
               failure_kind: "turn-limit"
             }

      assert %{failure_kind_fingerprint: fingerprint} =
               SafeMetadata.failure_taxonomy(%{"kind" => "budget-exceeded"})

      assert fingerprint == SafeMetadata.fingerprint("failure-kind:budget-exceeded")
    end

    test "names a declared application kind" do
      declared = ["budget-exceeded", "stale-snapshot"]

      assert SafeMetadata.failure_taxonomy(%{"kind" => "budget-exceeded"}, declared) == %{
               failure_kind: "budget-exceeded"
             }

      assert SafeMetadata.failure_taxonomy(%{kind: :budget_exceeded}, declared) == %{
               failure_kind: "budget-exceeded"
             }
    end

    test "fingerprints an undeclared kind even when a vocabulary is declared" do
      declared = ["budget-exceeded"]

      assert %{failure_kind_fingerprint: _} =
               SafeMetadata.failure_taxonomy(%{"kind" => "undeclared-kind"}, declared)
    end

    test "keeps framework kinds reachable alongside a declared vocabulary" do
      assert SafeMetadata.failure_taxonomy(%{"kind" => "turn-limit"}, ["budget-exceeded"]) ==
               %{failure_kind: "turn-limit"}
    end
  end

  describe "declarable failure kinds" do
    test "accepts bounded lowercase kebab-case identifiers" do
      assert SafeMetadata.declarable_failure_kind?("budget-exceeded")
      assert SafeMetadata.declarable_failure_kind?("a")
      assert SafeMetadata.declarable_failure_kind?(String.duplicate("a", 64))
    end

    test "rejects anything that could smuggle text into a trace" do
      refute SafeMetadata.declarable_failure_kind?("Budget Exceeded")
      refute SafeMetadata.declarable_failure_kind?("budget_exceeded")
      refute SafeMetadata.declarable_failure_kind?("customer: acme corp")
      refute SafeMetadata.declarable_failure_kind?("-leading-dash")
      refute SafeMetadata.declarable_failure_kind?("")
      refute SafeMetadata.declarable_failure_kind?(String.duplicate("a", 65))
      refute SafeMetadata.declarable_failure_kind?(:budget_exceeded)
      refute SafeMetadata.declarable_failure_kind?(nil)
    end

    test "rejects framework kinds so an application cannot shadow one" do
      refute SafeMetadata.declarable_failure_kind?("turn-limit")
      refute SafeMetadata.declarable_failure_kind?("capability-error")
    end
  end
end
