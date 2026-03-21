# Coordinator + Worker delegation test
#
# Tests whether a coordinator agent can decompose a complex task
# and delegate sub-questions to a worker agent — similar to how
# Claude Code spawns sub-agents.
#
# The coordinator has NO data — it can only delegate to the worker.
# The worker has all datasets and answers focused questions.
#
# Usage:
#   cd demo && mix run scripts/coordinator_test.exs
#
# Set OPENROUTER_API_KEY in .env or environment.

alias PtcDemo.{CLIBase, SampleData, SearchTool}
alias PtcRunner.SubAgent

CLIBase.load_dotenv()
CLIBase.ensure_api_key!()

model = System.get_env("COORDINATOR_MODEL") || "openrouter:google/gemini-3.1-flash-lite-preview"
timeout = 60_000

IO.puts("=== Coordinator + Worker Delegation Test ===")
IO.puts("Model: #{model}\n")

# --- LLM callback ---

llm = fn %{system: system, messages: messages} ->
  full_messages = [%{role: :system, content: system} | messages]

  case LLMClient.generate_text(model, full_messages,
         receive_timeout: timeout,
         req_http_options: [retry: :transient, max_retries: 3]
       ) do
    {:ok, %{content: text, tokens: tokens}} ->
      {:ok, %{content: text || "", tokens: tokens}}

    {:error, reason} ->
      {:error, "LLM error: #{inspect(reason)}"}
  end
end

# --- Datasets (only for the worker) ---

datasets = %{
  "products" => SampleData.products(),
  "orders" => SampleData.orders(),
  "employees" => SampleData.employees(),
  "expenses" => SampleData.expenses()
}

# --- Worker: a function tool that internally runs a SubAgent ---
# This is the key pattern: the worker is a plain function tool from
# the coordinator's perspective, but internally spawns a full SubAgent
# with its own LLM call and data access.

worker_agent =
  SubAgent.new(
    prompt: "{{question}}",
    signature: "(question :string) -> :any",
    context_descriptions: SampleData.context_descriptions(),
    system_prompt: %{
      prefix:
        "You are a data analyst. Answer the question precisely using the datasets provided.",
      language_spec: :single_shot
    },
    max_turns: 1
  )

analyst_tool = fn %{"question" => question} ->
  case SubAgent.run(worker_agent,
         llm: llm,
         context: Map.put(datasets, "question", question)
       ) do
    {:ok, step} -> step.return
    {:error, step} -> {:error, step.fail.message}
  end
end

# --- Coordinator agent: decomposes and delegates ---
# The coordinator has NO datasets — it can only call the analyst tool.
# It must break the problem into sub-questions and combine results.

coordinator =
  SubAgent.new(
    prompt: "{{mission}}",
    signature: "(mission :string) -> :map",
    tools: %{
      "analyst" =>
        {analyst_tool,
         signature: "(question :string) -> :any",
         description:
           "Answers a data analysis question. Delegates to a sub-agent with full dataset access. " <>
             "Available datasets: employees (200 records with id, department, salary, remote, level), " <>
             "expenses (800 records with employee_id, amount, category, status), " <>
             "orders (1000 records with customer_id, total, created_at, status), " <>
             "products (500 records with category, price, stock). " <>
             "Ask focused questions that return simple values (numbers, lists, maps)."}
    },
    system_prompt: %{
      prefix: """
      You are a coordinator that breaks down complex data analysis tasks.
      You have an analyst tool that can query datasets and return results.
      Break the mission into focused sub-questions, call the analyst for each,
      then combine the results into the final answer.
      You do NOT have direct access to data — you must use the analyst tool.
      """,
      language_spec: :multi_turn
    },
    max_turns: 6,
    timeout: 120_000,
    max_heap: 50_000_000
  )

# --- Test cases ---

tests = [
  %{
    name: "Remote vs Office expenses",
    mission:
      "Compare average expense amounts between remote and office employees. " <>
        "Ask the analyst for the average expense amount for remote employees, " <>
        "then ask for the average expense amount for office employees. " <>
        "Return a map with :remote_avg, :office_avg, and :remote_higher (boolean).",
    check: fn result ->
      is_map(result) and
        Map.has_key?(result, :remote_avg) and
        Map.has_key?(result, :office_avg) and
        Map.has_key?(result, :remote_higher)
    end
  },
  %{
    name: "Customer tier segmentation",
    mission:
      "Calculate total spend per customer from orders, segment into tiers " <>
        "(Bronze <$1000, Silver <$5000, Gold >= $5000), " <>
        "return count per tier as a map with keys :bronze, :silver, :gold.",
    check: fn result ->
      is_map(result) and
        Map.has_key?(result, :bronze) and
        Map.has_key?(result, :silver) and
        Map.has_key?(result, :gold)
    end
  }
]

# --- Run ---

for test <- tests do
  IO.puts("--- #{test.name} ---")
  IO.puts("Mission: #{String.slice(test.mission, 0, 80)}...\n")

  case SubAgent.run(coordinator,
         llm: llm,
         context: %{"mission" => test.mission},
         debug: true
       ) do
    {:ok, step} ->
      SubAgent.Debug.print_trace(step, raw: true, usage: true)
      result = step.return

      passed = test.check.(result)
      status = if passed, do: "PASS", else: "FAIL"
      IO.puts("\nResult: #{inspect(result, limit: 10, pretty: true)}")
      IO.puts("#{status}\n")

    {:error, step} ->
      SubAgent.Debug.print_trace(step, raw: true)
      IO.puts("\nERROR: #{inspect(step.fail)}\n")
  end
end
