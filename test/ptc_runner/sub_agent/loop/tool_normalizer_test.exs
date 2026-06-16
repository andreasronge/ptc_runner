defmodule PtcRunner.SubAgent.Loop.ToolNormalizerTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Loop.ToolNormalizer
  alias PtcRunner.Tool

  describe "normalize/3" do
    test "drops private keyword-form tools from executable native dispatch" do
      agent = SubAgent.new(prompt: "test", tools: %{}, max_turns: 1)

      tools =
        ToolNormalizer.normalize(
          %{
            "public" => fn _ -> "ok" end,
            "secret" => {fn _ -> "secret" end, visibility: :private}
          },
          %{agent_id: "agent-1"},
          agent
        )

      assert Map.has_key?(tools, "public")
      refute Map.has_key?(tools, "secret")
    end

    test "drops private Tool structs from executable native dispatch" do
      agent = SubAgent.new(prompt: "test", tools: %{}, max_turns: 1)

      tools =
        ToolNormalizer.normalize(
          %{
            "public" => fn _ -> "ok" end,
            "secret" => %Tool{
              name: "secret",
              function: fn _ -> "secret" end,
              visibility: :private
            }
          },
          %{agent_id: "agent-1"},
          agent
        )

      assert Map.has_key?(tools, "public")
      refute Map.has_key?(tools, "secret")
    end

    test "drops invalid visibility tools from executable native dispatch" do
      agent = SubAgent.new(prompt: "test", tools: %{}, max_turns: 1)

      tools =
        ToolNormalizer.normalize(
          %{
            "public" => fn _ -> "ok" end,
            "secret" => {fn _ -> "secret" end, visibility: "private"}
          },
          %{agent_id: "agent-1"},
          agent
        )

      assert Map.has_key?(tools, "public")
      refute Map.has_key?(tools, "secret")
    end

    test "keeps private tools for PTC-Lisp runtime inventory when requested" do
      agent = SubAgent.new(prompt: "test", tools: %{}, max_turns: 1)

      tools =
        ToolNormalizer.normalize(
          %{
            "public" => fn _ -> "ok" end,
            "secret" => {fn _ -> "secret" end, visibility: :private}
          },
          %{agent_id: "agent-1"},
          agent,
          include_private: true
        )

      assert Map.has_key?(tools, "public")
      assert Map.has_key?(tools, "secret")
    end
  end
end
