# Test script to investigate why LLM uses ctx/results
#
# Run with: cd demo && mix run scripts/test_ctx_results.exs

# This prompt is closer to the real demo - notice NO explicit mention of memory/
# in the data inventory, and the results key in the tool output might confuse LLM
system_prompt = """
You are a PTC-Lisp program generator.

# Rules
1. Respond with EXACTLY ONE ```clojure code block
2. Use `(call "tool-name" args)` to invoke tools
3. Use `ctx/key` to access context data
4. Use `memory/key` for persistent state
5. Call `(return result)` when done

# Data Inventory

Available in `ctx/`:

| Key | Type | Sample |
|-----|------|--------|
| `ctx/employees` | `[{id :int, name :string}]` | [{:id 1 :name "Alice"}] |
| `ctx/products` | `[{id :int, name :string}]` | [{:id 1 :name "Widget"}] |

# Available Tools

### search
```
search(query :string, limit :int?) -> {results [{id :string, title :string}], has_more :bool, total :int}
```
Search documents by keyword.
Example: `(call "search" {:query "..." :limit 10})`

### return
```
return(data :any) -> :exit-success
```
Complete the mission.
"""

# Simulated search result (what would be returned by the search tool)
search_result = """
{:results [{:id "doc1" :title "Remote Work Guidelines"} {:id "doc2" :title "Home Office Setup"} {:id "doc3" :title "Remote Security Policy"}] :has_more false :total 3}
"""

# Test with the NEW format_execution_result output (what we just implemented)
execution_feedback_new = """
Result: #{String.trim(search_result)}

Stored in memory. Access via: memory/results, memory/has_more, memory/total
"""

analyze_response = fn response ->
  cond do
    String.contains?(response, "ctx/results") ->
      "WARNING: LLM used ctx/results (hallucinated - not in context!)"

    String.contains?(response, "memory/results") ->
      "OK: LLM used memory/results"

    String.contains?(response, "(call \"search\"") ->
      "OK: LLM called search tool"

    String.contains?(response, "(pluck :title") ->
      "OK: LLM used pluck on some data"

    String.contains?(response, "(return") ->
      "OK: LLM returned a result"

    true ->
      "Other pattern"
  end
end

IO.puts("=== Turn 1: Initial Request ===\n")

messages_turn1 = [
  %{role: :system, content: system_prompt},
  %{role: :user, content: "Search for documents about remote work and return the titles"}
]

case PtcDemo.LLM.generate_text("openrouter:google/gemini-2.5-flash", messages_turn1) do
  {:ok, response} ->
    IO.puts("LLM Response:")
    IO.puts(response.content)
    IO.puts("\nAnalysis: #{analyze_response.(response.content)}")

    # Test Turn 2 with the NEW feedback format (includes memory hints)
    IO.puts("\n=== Turn 2: With NEW memory guidance format ===\n")
    IO.puts("Feedback to LLM:")
    IO.puts(execution_feedback_new)

    messages_turn2 = [
      %{role: :system, content: system_prompt},
      %{role: :user, content: "Search for documents about remote work and return the titles"},
      %{role: :assistant, content: "```clojure\n(call \"search\" {:query \"remote work\"})\n```"},
      %{role: :user, content: execution_feedback_new}
    ]

    case PtcDemo.LLM.generate_text("openrouter:google/gemini-2.5-flash", messages_turn2) do
      {:ok, response2} ->
        IO.puts("LLM Response:")
        IO.puts(response2.content)
        IO.puts("\nAnalysis: #{analyze_response.(response2.content)}")

      {:error, reason} ->
        IO.puts("Error in Turn 2: #{inspect(reason)}")
    end

  {:error, reason} ->
    IO.puts("Error in Turn 1: #{inspect(reason)}")
end
