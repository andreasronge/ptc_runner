# Coordinator + Worker delegation test (Claude Code style)
#
# The coordinator has NO data — only an analyst tool (worker sub-agent).
# It must: 1) decide what to ask, 2) call the analyst, 3) inspect results,
# 4) decide if more info is needed or assemble the answer.
#
#
# Usage:
#   cd demo && mix run scripts/coordinator_test.exs
#
# Set OPENROUTER_API_KEY in .env or environment.

alias PtcDemo.{CLIBase, SampleData}
alias PtcRunner.SubAgent

CLIBase.load_dotenv()
CLIBase.ensure_api_key!()

model = System.get_env("COORDINATOR_MODEL") || "openrouter:google/gemini-3.1-flash-lite-preview"
timeout = 60_000

IO.puts("=== Coordinator + Worker Test ===")
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

# --- Datasets (only the worker sees these) ---

datasets = %{
  "products" => SampleData.products(),
  "orders" => SampleData.orders(),
  "employees" => SampleData.employees(),
  "expenses" => SampleData.expenses()
}

# --- Worker: function tool that spawns a SubAgent ---

worker_agent =
  SubAgent.new(
    prompt: "{{question}}",
    signature: "(question :string) -> :any",
    context_descriptions: SampleData.context_descriptions(),
    system_prompt: %{
      prefix: "You are a data analyst. Answer the question precisely using the datasets.",
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

# --- Coordinator: no data, only the analyst tool ---

coordinator =
  SubAgent.new(
    prompt: "{{mission}}",
    signature: "(mission :string) -> :map",
    tools: %{
      "analyst" =>
        {analyst_tool,
         signature: "(question :string) -> :any",
         description:
           "Answers a data analysis question using datasets not available to you. " <>
             "Datasets: employees (id, department, salary, remote, level), " <>
             "expenses (employee_id, amount, category, status), " <>
             "orders (customer_id, total, created_at, status), " <>
             "products (category, price, stock). " <>
             "Ask focused questions that return simple values (numbers, lists, maps)."}
    },
    system_prompt: %{
      prefix: """
      You are a coordinator. You have NO direct data access.
      Use the analyst tool to query datasets. Use println to inspect results.
      When you have all the data you need, write your final answer as the last expression (no println).
      """,
      language_spec: :explicit_return
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
        "Return a map with :remote_avg (number), :office_avg (number), and :remote_higher (boolean).",
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
  },
  %{
    name: "Department with highest avg salary",
    mission:
      "Find which department has the highest average salary. " <>
        "Return a map with :department (string) and :avg_salary (number).",
    check: fn result ->
      is_map(result) and
        Map.has_key?(result, :department) and
        Map.has_key?(result, :avg_salary)
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
      turns = length(step.turns)

      passed = test.check.(result)
      status = if passed, do: "PASS", else: "FAIL"
      IO.puts("\nResult: #{inspect(result, limit: 10, pretty: true)}")
      IO.puts("Turns: #{turns}")
      IO.puts("#{status}\n")

    {:error, step} ->
      SubAgent.Debug.print_trace(step, raw: true)
      IO.puts("\nERROR: #{inspect(step.fail)}\n")
  end
end
