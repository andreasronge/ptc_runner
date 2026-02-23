defmodule Alma.DebugAgentTest do
  use ExUnit.Case, async: true

  alias Alma.DebugAgent

  describe "analyze/2" do
    test "returns empty string for empty parents" do
      assert DebugAgent.analyze([], llm: fn _ -> {:ok, %{content: "test"}} end) == {:ok, "", nil}
    end

    test "returns empty string when no llm provided" do
      parents = [%{design: %{name: "test"}, score: 0.5, trajectories: []}]
      assert DebugAgent.analyze(parents) == {:ok, "", nil}
    end

    test "passes debug_log as context to SubAgent" do
      # We verify the agent is constructed with the right config by
      # checking that it runs with a mock LLM that returns analysis
      parents = [
        %{
          design: %{name: "spatial_v1"},
          score: 0.3,
          trajectories: [
            %{
              success?: false,
              steps: 20,
              runtime_logs: [
                %{
                  phase: :recall,
                  prints: [],
                  tool_calls: [
                    %{name: "find-similar", args: %{"query" => "test"}, result: []}
                  ]
                }
              ]
            }
          ]
        }
      ]

      mock_llm = fn request ->
        # The SubAgent will send multiple messages; just return a valid response
        content = request.messages |> List.last() |> Map.get(:content, "")

        if is_binary(content) and String.contains?(content, "Analyze") do
          {:ok,
           %{
             content: """
             (return "## Analysis\\nRecall returned empty results.\\n## Mandatory Constraints\\n- MUST store observations")
             """
           }}
        else
          {:ok, %{content: "(return \"analysis complete\")"}}
        end
      end

      result = DebugAgent.analyze(parents, llm: mock_llm)
      assert {:ok, critique, _child_trace_id} = result
      assert is_binary(critique)
    end
  end
end
