# Hybrid Planning vs Ad-hoc Spike Test (v2)

IO.puts("--- Starting Hybrid Pattern Spike Test (v2) ---")

# Load environment variables
PtcDemo.CLIBase.load_dotenv()

# Use Gemini for reasoning
model = "gemini"
IO.puts("Using model: #{model}")

# Define our mock toolset
email_tools = %{
  "email-finder" => fn _ ->
    IO.puts("   [Tool] Listing emails...")
    [
      %{id: 1, subject: "Urgent: Server Down", is_urgent: true},
      %{id: 2, subject: "Lunch?", is_urgent: false},
      %{id: 3, subject: "Urgent: Customer Complaint", is_urgent: true}
    ]
  end,
  "email-reader" => fn args ->
    id = args[:id] || args["id"]
    IO.puts("   [Tool] Reading email #{id}...")
    case id do
      1 -> %{body: "The production server is unresponsive."}
      3 -> %{body: "I can't log in to my account since yesterday."}
      _ -> %{body: "Nothing to see here."}
    end
  end,
  "reply-drafter" => fn args ->
    id = args[:email_id] || args["email_id"] || args[:id] || args["id"]
    text = args[:body] || args["body"]
    IO.puts("   [Tool] Created draft for email #{id}...")
    %{draft_id: 100 + id, status: "draft_saved", content: text}
  end
}

# We include the tools in the mission description so the LLM knows it HAS them
mission = """
MISSION: Process urgent emails: find them, read their bodies to understand the issue, and draft a short acknowledgement for each one.
AVAILABLE TOOLS: "email-finder", "email-reader", "reply-drafter"
"""

# --- EXPERIMENT 1: PURE AD-HOC ---
IO.puts("\n=== EXPERIMENT 1: PURE AD-HOC ===")
{:ok, _pid} = PtcDemo.LispAgent.start_link(model: model)

t1_start = System.monotonic_time(:millisecond)
case PtcDemo.LispAgent.ask(mission, tools: email_tools) do
  {:ok, answer} ->
    t1_end = System.monotonic_time(:millisecond)
    IO.puts("\nFinal Answer: #{answer}")
    stats = PtcDemo.LispAgent.stats()
    IO.puts("Ad-hoc Turns: #{stats.requests}, Tokens: #{stats.total_tokens}, Time: #{t1_end - t1_start}ms")
  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end

# Reset for next run
PtcDemo.LispAgent.reset()

# --- EXPERIMENT 2: HYBRID (PLAN -> EXECUTE) ---
IO.puts("\n=== EXPERIMENT 2: HYBRID (PLAN -> EXECUTE) ===")

# STEP 1: PLANNING (No tools)
IO.puts("\n--- Stage 1: Planning ---")
planning_prompt = "Think before you act. Plan how to perform this mission: #{mission}. Output your plan as a concise numbered list of steps."

# We'll use this to store the plan for the next stage
plan_for_exec = case PtcDemo.LispAgent.ask(planning_prompt, tools: %{}) do
  {:ok, plan} ->
    IO.puts("\nGenerated Plan:\n#{plan}")
    plan
  {:error, reason} ->
    IO.puts("Planning Error: #{inspect(reason)}")
    ""
end

# STEP 2: EXECUTION (Guided by plan)
IO.puts("\n--- Stage 2: Execution ---")
execution_prompt = """
MISSION: #{mission}
INITIAL PLAN (FOLLOW THIS):
#{plan_for_exec}

Execute the mission using your tools.
Use (ctx/last-result) to access the raw data returned by the MOST RECENT tool call.
You can store intermediate data in memory using (memory/put :key value) and access it via memory/key.
"""

t2_start = System.monotonic_time(:millisecond)
case PtcDemo.LispAgent.ask(execution_prompt, tools: email_tools) do
  {:ok, answer} ->
    t2_end = System.monotonic_time(:millisecond)
    IO.puts("\nFinal Answer: #{answer}")
    stats = PtcDemo.LispAgent.stats()
    IO.puts("Total Hybrid Turns: #{stats.requests}, Tokens: #{stats.total_tokens}, Total Time: #{t2_end - t2_start}ms")
  {:error, reason} ->
    IO.puts("Execution Error: #{inspect(reason)}")
end

IO.puts("\n--- Hybrid Pattern Spike Finished ---")
