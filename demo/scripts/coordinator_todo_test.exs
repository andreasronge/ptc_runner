# Coordinator + Worker + Todo test (Claude Code style)
#
# The coordinator manages its own task list via a todo tool,
# delegates work to an analyst tool, and returns when done.
#
# Usage:
#   cd demo && mix run scripts/coordinator_todo_test.exs

alias PtcDemo.{CLIBase, SampleData}
alias PtcRunner.SubAgent

CLIBase.load_dotenv()
CLIBase.ensure_api_key!()

model = System.get_env("COORDINATOR_MODEL") || "openrouter:google/gemini-3.1-flash-lite-preview"
timeout = 60_000

IO.puts("=== Coordinator + Todo Test ===")
IO.puts("Model: #{model}\n")

# --- LLM callback ---

llm = fn %{system: system, messages: messages} ->
  full_messages = [%{role: :system, content: system} | messages]

  case PtcRunner.LLM.ReqLLMAdapter.generate_text(model, full_messages,
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

# --- Todo tool: Agent-backed task list ---

{:ok, todo_pid} = Agent.start_link(fn -> {1, []} end)

format_todos = fn ->
  {_next_id, todos} = Agent.get(todo_pid, & &1)

  if todos == [] do
    "(empty)"
  else
    todos
    |> Enum.reverse()
    |> Enum.map(fn {id, text, status} ->
      mark = if status == :done, do: "[x]", else: "[ ]"
      "#{mark} #{id}. #{text}"
    end)
    |> Enum.join("\n")
  end
end

reset_todos = fn ->
  Agent.update(todo_pid, fn _ -> {1, []} end)
end

todo_tool = fn args ->
  action = Map.get(args, "action")

  case action do
    "add" ->
      text = Map.get(args, "text", "untitled")

      Agent.update(todo_pid, fn {next_id, todos} ->
        {next_id + 1, [{next_id, text, :pending} | todos]}
      end)

      format_todos.()

    "done" ->
      task_id = Map.get(args, "id")

      Agent.update(todo_pid, fn {next_id, todos} ->
        updated =
          Enum.map(todos, fn
            {^task_id, text, _} -> {task_id, text, :done}
            other -> other
          end)

        {next_id, updated}
      end)

      format_todos.()

    "list" ->
      format_todos.()

    _ ->
      "Unknown action '#{action}'. Use: add, done, or list"
  end
end

# --- Coordinator ---

coordinator =
  SubAgent.new(
    prompt: "{{mission}}",
    signature: "(mission :string) -> :map",
    tools: %{
      "analyst" =>
        {analyst_tool,
         signature: "(question :string) -> :any",
         description:
           "Query datasets. Available: employees (id, department, salary, remote, level), " <>
             "expenses (employee_id, amount, category, status), " <>
             "orders (customer_id, total, created_at, status), " <>
             "products (category, price, stock)."},
      "todo" =>
        {todo_tool,
         signature: "(action :string, text :string?, id :int?) -> :string",
         description:
           "Manage your task list. Actions: " <>
             "'add' (text required) — add a task, " <>
             "'done' (id required) — mark task complete, " <>
             "'list' — show current tasks. " <>
             "Returns the current todo list after each action."}
    },
    system_prompt: %{
      prefix: """
      You are a coordinator. You have NO direct data access.

      Workflow:
      1. Use the todo tool to plan your steps
      2. Use the analyst tool to gather data
      3. Use println to inspect results and track progress
      4. Mark tasks done with the todo tool as you complete them
      5. When all tasks are done, write your final answer (no println)
      """,
      language_spec: :explicit_return
    },
    max_turns: 8,
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
  }
]

# --- Run ---

for test <- tests do
  IO.puts("--- #{test.name} ---")
  IO.puts("Mission: #{String.slice(test.mission, 0, 80)}...\n")

  # Reset todo list between tests
  reset_todos.()

  case SubAgent.run(coordinator,
         llm: llm,
         context: %{"mission" => test.mission},
         debug: true
       ) do
    {:ok, step} ->
      SubAgent.Debug.print_trace(step, raw: true, usage: true)
      result = step.return
      turns = length(step.turns)

      IO.puts("\nTodo list at end:")
      IO.puts(format_todos.())

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
