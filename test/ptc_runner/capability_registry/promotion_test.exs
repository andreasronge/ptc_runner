defmodule PtcRunner.CapabilityRegistry.PromotionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.CapabilityRegistry.{Promotion, Registry}

  @sample_plan %{
    agents: %{
      "worker" => %{tools: ["search", "parse"]}
    },
    tasks: [
      %{id: "t1", agent: "worker", type: :task},
      %{id: "t2", agent: "worker", type: :task, depends_on: ["t1"]}
    ]
  }

  describe "extract_pattern/1" do
    test "produces consistent hash for same structure" do
      hash1 = Promotion.extract_pattern(@sample_plan)
      hash2 = Promotion.extract_pattern(@sample_plan)
      assert hash1 == hash2
    end

    test "produces different hash for different structure" do
      plan2 = %{
        agents: %{"other" => %{tools: ["different"]}},
        tasks: [%{id: "t1", agent: "other", type: :task}]
      }

      hash1 = Promotion.extract_pattern(@sample_plan)
      hash2 = Promotion.extract_pattern(plan2)
      assert hash1 != hash2
    end

    test "ignores task input differences" do
      plan1 = put_in(@sample_plan, [:tasks, Access.at(0), :input], "input A")
      plan2 = put_in(@sample_plan, [:tasks, Access.at(0), :input], "input B")

      hash1 = Promotion.extract_pattern(plan1)
      hash2 = Promotion.extract_pattern(plan2)
      assert hash1 == hash2
    end
  end

  describe "track_pattern/4" do
    test "creates new candidate for new pattern" do
      registry = Registry.new()

      updated = Promotion.track_pattern(registry, @sample_plan, :success, mission: "test")

      candidates = Promotion.list_candidates(updated)
      assert length(candidates) == 1

      [candidate] = candidates
      assert candidate.status == :candidate
      assert length(candidate.occurrences) == 1
    end

    test "increments occurrences for existing pattern" do
      registry =
        Registry.new()
        |> Promotion.track_pattern(@sample_plan, :success, mission: "test1")
        |> Promotion.track_pattern(@sample_plan, :success, mission: "test2")
        |> Promotion.track_pattern(@sample_plan, :success, mission: "test3")

      candidates = Promotion.list_candidates(registry)
      [candidate] = candidates
      assert length(candidate.occurrences) == 3
    end
  end

  describe "check_promotion_threshold/2" do
    test "flags candidates that reach threshold" do
      registry =
        Registry.new()
        |> Promotion.track_pattern(@sample_plan, :success, mission: "m1")
        |> Promotion.track_pattern(@sample_plan, :success, mission: "m2")
        |> Promotion.track_pattern(@sample_plan, :success, mission: "m3")

      flagged = Promotion.check_promotion_threshold(registry, threshold: 3)
      assert length(flagged) == 1
    end

    test "ignores candidates below threshold" do
      registry =
        Registry.new()
        |> Promotion.track_pattern(@sample_plan, :success, mission: "m1")
        |> Promotion.track_pattern(@sample_plan, :success, mission: "m2")

      flagged = Promotion.check_promotion_threshold(registry, threshold: 3)
      assert flagged == []
    end

    test "counts only successes" do
      registry =
        Registry.new()
        |> Promotion.track_pattern(@sample_plan, :success, mission: "m1")
        |> Promotion.track_pattern(@sample_plan, :failure, mission: "m2")
        |> Promotion.track_pattern(@sample_plan, :success, mission: "m3")

      flagged = Promotion.check_promotion_threshold(registry, threshold: 3)
      assert flagged == []
    end
  end

  describe "flag_for_review/2" do
    test "changes candidate status to flagged" do
      hash = Promotion.extract_pattern(@sample_plan)

      registry =
        Registry.new()
        |> Promotion.track_pattern(@sample_plan, :success)
        |> Promotion.flag_for_review(hash)

      candidate = Promotion.get_candidate(registry, hash)
      assert candidate.status == :flagged
    end
  end

  describe "promote_as_tool/4" do
    test "creates tool and marks promoted" do
      hash = Promotion.extract_pattern(@sample_plan)

      registry =
        Registry.new()
        |> Promotion.track_pattern(@sample_plan, :success)

      {:ok, updated} =
        Promotion.promote_as_tool(registry, hash, "new_tool",
          code: "(defn new-tool [x] x)",
          signature: "(x :any) -> :any",
          tags: ["auto"]
        )

      # Tool should be registered
      tool = Registry.get_tool(updated, "new_tool")
      assert tool != nil
      assert tool.source == :smithed
      assert tool.layer == :composed

      # Candidate should be promoted
      candidate = Promotion.get_candidate(updated, hash)
      assert candidate.status == :promoted
    end

    test "requires code" do
      hash = Promotion.extract_pattern(@sample_plan)

      registry =
        Registry.new()
        |> Promotion.track_pattern(@sample_plan, :success)

      {:error, :code_required} = Promotion.promote_as_tool(registry, hash, "bad_tool")
    end

    test "returns error for missing candidate" do
      registry = Registry.new()

      {:error, :candidate_not_found} =
        Promotion.promote_as_tool(registry, "nonexistent", "tool", code: "x")
    end
  end

  describe "promote_as_skill/5" do
    test "creates skill and marks promoted" do
      hash = Promotion.extract_pattern(@sample_plan)

      registry =
        Registry.new()
        |> Promotion.track_pattern(@sample_plan, :success)

      {:ok, updated} =
        Promotion.promote_as_skill(
          registry,
          hash,
          "new_skill",
          "When doing this pattern, remember to...",
          tags: ["workflow"],
          applies_to: ["search"]
        )

      # Skill should be registered
      skill = Registry.get_skill(updated, "new_skill")
      assert skill != nil
      assert skill.source == :learned
      assert skill.prompt =~ "remember to"

      # Candidate should be promoted
      candidate = Promotion.get_candidate(updated, hash)
      assert candidate.status == :promoted
    end
  end

  describe "reject_promotion/3" do
    test "marks candidate as rejected" do
      hash = Promotion.extract_pattern(@sample_plan)

      registry =
        Registry.new()
        |> Promotion.track_pattern(@sample_plan, :success)
        |> Promotion.reject_promotion(hash, "too specific")

      candidate = Promotion.get_candidate(registry, hash)
      assert candidate.status == :rejected
      assert candidate.rejection_reason == "too specific"
    end

    test "rejected candidates not flagged again" do
      hash = Promotion.extract_pattern(@sample_plan)

      registry =
        Registry.new()
        |> Promotion.track_pattern(@sample_plan, :success)
        |> Promotion.track_pattern(@sample_plan, :success)
        |> Promotion.track_pattern(@sample_plan, :success)
        |> Promotion.reject_promotion(hash, "not useful")

      # Even with 3 successes, rejected candidate won't be flagged
      flagged = Promotion.check_promotion_threshold(registry, threshold: 3)
      assert flagged == []
    end
  end

  describe "list_flagged/1" do
    test "returns only flagged candidates" do
      hash = Promotion.extract_pattern(@sample_plan)

      other_plan = %{agents: %{"a" => %{}}, tasks: [%{id: "x", agent: "a", type: :task}]}

      registry =
        Registry.new()
        |> Promotion.track_pattern(@sample_plan, :success)
        |> Promotion.track_pattern(other_plan, :success)
        |> Promotion.flag_for_review(hash)

      flagged = Promotion.list_flagged(registry)
      assert length(flagged) == 1
      assert hd(flagged).pattern_hash == hash
    end
  end
end
