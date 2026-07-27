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
end
