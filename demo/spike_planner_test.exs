# Planner SubAgent Spike Test

IO.puts("--- Starting Planner SubAgent Spike Test ---")

# Load environment variables
PtcDemo.CLIBase.load_dotenv()

# Use Gemini for better reasoning in planning
model = "gemini"
IO.puts("Using model: #{model}")

# Start the LispAgent
# We provide a "create_plan" tool which is what the Planner Agent should call
{:ok, _pid} = PtcDemo.LispAgent.start_link(model: model)

# Define the "Planning Tools" that the agent will use to submit its work
plan_tools = %{
  "create_plan" => fn args ->
    IO.puts("\n[PLAN CREATED]")
    IO.inspect(args, label: "Plan Data")
    %{status: "success", plan_id: "plan_123"}
  end
}

# We also give it some info about what tools are available in the wider system
# so it can reference them in its plan.
available_tools_info = """
Available system tools for your plan:
- "email-finder": {} -> [{:id, :subject, :is_urgent}]
- "email-reader": {:id} -> {:body}
- "reply-drafter": {:email_id, :body} -> {:draft_id}
"""

question = """
You are a Planning Agent. Your goal is to create a multi-step plan to:
1. Find all urgent emails.
2. For each urgent email, get its full body.
3. Draft a short acknowledgment for each one.

Use the "create_plan" tool to submit your plan.
A plan consists of a goal and a list of steps.
Each step should have: :id, :task, :tools (list of tool names), :needs (list of IDs it depends on), and :output (what it provides).

Current context:
#{available_tools_info}
"""

IO.puts("\nPrompting Planner Agent...")

case PtcDemo.LispAgent.ask(question, tools: plan_tools) do
  {:ok, answer} ->
    IO.puts("\nFinal Response from Agent: #{answer}")

    IO.puts("\n--- Execution Trace ---")
    trace = PtcDemo.LispAgent.trace()
    Enum.each(trace, fn step ->
       IO.puts("\nSTEP #{step.iteration}:")
       if step[:program], do: IO.puts("Program:\n#{step.program}")
       if step[:tool_calls] && step.tool_calls != [] do
         IO.inspect(step.tool_calls, label: "Tool Calls")
       end
    end)

  {:error, reason} ->
    IO.puts("\nError: #{inspect(reason)}")
end

IO.puts("\n--- Planner Spike Test Finished ---")
