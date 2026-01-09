# REPL Feedback Format Spike
#
# Tests different message feedback formats to see how LLMs respond.
# Run with: cd demo && mix run spikes/repl_feedback_spike.exs
#
# Compares:
# - :full       - Current format (full program shown each turn)
# - :repl       - REPL transcript style (#'user/foo acknowledgments)
# - :summary    - Summarized (definitions + output, no code)
# - :compressed - Old ASSISTANT messages replaced with summaries (no old code visible)

# Load .env from parent directory
env_file = if File.exists?("../.env"), do: "../.env", else: ".env"

if File.exists?(env_file) do
  env_file
  |> Dotenvy.source!()
  |> Enum.each(fn {key, value} ->
    unless System.get_env(key), do: System.put_env(key, value)
  end)
end

defmodule ReplFeedbackSpike do
  @moduledoc """
  Spike to test different feedback formats for multi-turn PTC-Lisp execution.
  """

  # Configure model - can override with PTC_DEMO_MODEL env var
  # Use presets: gemini, sonnet, haiku, gpt, deepseek
  @default_model "openrouter:google/gemini-2.5-flash"

  # Simple system prompt (static for prompt caching)
  @system_prompt """
  You are a data analyst. Write PTC-Lisp programs to answer questions.

  ## Available Context (ctx/ namespace)
  - ctx/products - list of products with :name, :price, :category

  ## PTC-Lisp Basics
  - Define values: (def name value)
  - Define functions: (defn name "docstring" [args] body)
  - Print output: (println "text" value)
  - Filter: (filter pred coll)
  - Map: (map fn coll)
  - Count: (count coll)
  - Access context: ctx/products
  - Finish: (return value)

  ## Tools (call with tool/ prefix)
  - (tool/search-reviews category) - Search customer reviews, returns text summary
  - (tool/get-inventory) - Get warehouse inventory report, returns text

  ## Rules
  - Use ctx/ prefix for provided data
  - Use tool/ prefix for tool calls
  - Your definitions (def/defn) are bare symbols in user namespace
  - Multi-turn: definitions persist between turns
  - Tool results are returned as text - read and process them

  ## IMPORTANT: Multi-turn workflow
  - Turn 1: Call tools or explore data. Do NOT return yet.
  - Turn 2: Process results based on what you learned. Do NOT return yet.
  - Turn 3+: Return the final answer.
  - NEVER call (return ...) before turn 3.
  """

  # Alternate prompt for tool-focused tasks
  @tool_task "Which electronics products are both well-reviewed (rating >= 4.0) AND in stock? Return their names as a list."

  # Sample data
  @products [
    %{name: "Laptop", price: 1200, category: "Electronics"},
    %{name: "Mouse", price: 25, category: "Electronics"},
    %{name: "Desk", price: 350, category: "Furniture"},
    %{name: "Chair", price: 150, category: "Furniture"},
    %{name: "Monitor", price: 400, category: "Electronics"},
    %{name: "Keyboard", price: 75, category: "Electronics"},
    %{name: "Lamp", price: 45, category: "Furniture"}
  ]

  # Simulated tool responses (unstructured text)
  @tool_responses %{
    "search_reviews" => """
    Customer Review Summary for Electronics:
    - Laptop: Highly rated, customers love the performance but complain about battery life. Average rating 4.5/5.
    - Mouse: Mixed reviews, some say it's too small. Average rating 3.2/5.
    - Monitor: Excellent color accuracy, professionals recommend it. Average rating 4.8/5.
    - Keyboard: Comfortable typing, but loud keys. Average rating 4.0/5.
    Note: Only products with rating >= 4.0 are recommended for corporate purchases.
    """,
    "get_inventory" => """
    Warehouse Inventory Report (as of today):
    Laptop - 23 units in stock, 5 on backorder
    Mouse - OUT OF STOCK, expected restock in 2 weeks
    Desk - 12 units available
    Chair - 45 units, overstocked
    Monitor - 8 units, low stock warning
    Keyboard - 67 units available
    Lamp - 30 units available
    Recommendation: Prioritize restocking Mouse and Monitor.
    """
  }

  def tool_task, do: @tool_task

  def run(opts \\ []) do
    model = System.get_env("PTC_DEMO_MODEL") || @default_model
    format = Keyword.get(opts, :format, :all)

    task =
      Keyword.get(opts, :task, "Find all products over $100, count them, and return the count")

    IO.puts("=" |> String.duplicate(60))
    IO.puts("REPL Feedback Format Spike")
    IO.puts("Model: #{model}")
    IO.puts("Task: #{task}")
    IO.puts("=" |> String.duplicate(60))

    formats = if format == :all, do: [:full, :repl, :summary, :compressed], else: [format]

    results =
      for fmt <- formats do
        IO.puts("\n" <> String.duplicate("-", 60))
        IO.puts("Testing format: #{fmt}")
        IO.puts(String.duplicate("-", 60))

        result = run_conversation(model, task, fmt)
        {fmt, result}
      end

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("SUMMARY")
    IO.puts(String.duplicate("=", 60))

    for {fmt, result} <- results do
      status = if result.success, do: "✓", else: "✗"
      IO.puts("#{status} #{fmt}: #{result.turns} turns, #{result.total_tokens} tokens")
      if result.error, do: IO.puts("  Error: #{result.error}")
    end
  end

  def run_conversation(model, task, format) do
    # Initialize state
    state = %{
      messages: [%{role: :user, content: task}],
      # Simulated memory (def bindings)
      memory: %{},
      turn: 1,
      max_turns: 5,
      total_tokens: 0,
      format: format,
      # For compressed format: track summaries of each turn
      turn_summaries: []
    }

    loop(model, state)
  end

  defp loop(model, %{turn: turn, max_turns: max} = state) when turn > max do
    IO.puts("\n[Max turns reached]")

    %{
      success: false,
      error: "max_turns_exceeded",
      turns: turn - 1,
      total_tokens: state.total_tokens
    }
  end

  defp loop(model, state) do
    IO.puts("\n--- Turn #{state.turn} ---")

    # Call LLM
    case call_llm(model, state) do
      {:ok, response, tokens} ->
        state = %{state | total_tokens: state.total_tokens + tokens}
        IO.puts("\n[LLM Response]")
        IO.puts(response)

        # Parse and execute
        case parse_and_execute(response, state.memory) do
          {:return, value, _memory} ->
            IO.puts("\n[Returned] #{inspect(value)}")

            %{
              success: true,
              error: nil,
              turns: state.turn,
              total_tokens: state.total_tokens,
              value: value
            }

          {:continue, output, new_memory, definitions} ->
            # Format feedback based on strategy
            feedback =
              format_feedback(
                state.format,
                output,
                new_memory,
                definitions,
                state.turn,
                state.max_turns
              )

            IO.puts("\n[Feedback to LLM]")
            IO.puts(feedback)

            # Build turn summary for compressed format
            turn_summary = build_turn_summary(definitions, output)

            # Add to messages
            new_messages =
              state.messages ++
                [
                  %{role: :assistant, content: response},
                  %{role: :user, content: feedback}
                ]

            loop(model, %{
              state
              | messages: new_messages,
                memory: new_memory,
                turn: state.turn + 1,
                turn_summaries: state.turn_summaries ++ [turn_summary]
            })

          {:error, error} ->
            IO.puts("\n[Error] #{error}")
            # Continue with error feedback
            feedback =
              format_error_feedback(state.format, error, response, state.turn, state.max_turns)

            new_messages =
              state.messages ++
                [
                  %{role: :assistant, content: response},
                  %{role: :user, content: feedback}
                ]

            loop(model, %{state | messages: new_messages, turn: state.turn + 1})
        end

      {:error, error} ->
        IO.puts("\n[LLM Error] #{inspect(error)}")

        %{
          success: false,
          error: inspect(error),
          turns: state.turn,
          total_tokens: state.total_tokens
        }
    end
  end

  # --- Feedback Formatting ---

  defp format_feedback(:full, output, memory, definitions, turn, max_turns) do
    # Current style: show everything
    parts = []
    parts = if output != "", do: parts ++ [output], else: parts

    parts =
      if map_size(memory) > 0 do
        stored = memory |> Map.keys() |> Enum.join(", ")
        parts ++ ["Stored (access as symbols): #{stored}"]
      else
        parts
      end

    parts = parts ++ [turn_info(turn, max_turns)]
    Enum.join(parts, "\n\n")
  end

  defp format_feedback(:repl, output, _memory, definitions, turn, max_turns) do
    # REPL transcript style - like Clojure REPL output
    acks =
      Enum.map(definitions, fn {name, info} ->
        case info.kind do
          :function -> "#'user/#{name}  ; function/#{info.arity}"
          :data -> "#'user/#{name}  ; #{format_type(info.value)}"
        end
      end)

    parts = acks
    parts = if output != "", do: parts ++ [output], else: parts
    parts = parts ++ [turn_info(turn, max_turns)]

    Enum.join(parts, "\n")
  end

  # Compressed uses same feedback as REPL style
  defp format_feedback(:compressed, output, memory, definitions, turn, max_turns) do
    format_feedback(:repl, output, memory, definitions, turn, max_turns)
  end

  defp format_feedback(:summary, output, _memory, definitions, turn, max_turns) do
    # Summarized: just definitions (with docstrings) + output, no code
    funcs =
      definitions
      |> Enum.filter(fn {_, info} -> info.kind == :function end)
      |> Enum.map(fn {name, info} ->
        doc = if info[:doc], do: " - #{info.doc}", else: ""
        "  #{name}/#{info.arity}#{doc}"
      end)

    data =
      definitions
      |> Enum.filter(fn {_, info} -> info.kind == :data end)
      |> Enum.map(fn {name, info} ->
        "  #{name}: #{format_type(info.value)}"
      end)

    parts = []
    parts = if funcs != [], do: parts ++ ["Defined functions:"] ++ funcs, else: parts
    parts = if data != [], do: parts ++ ["Defined data:"] ++ data, else: parts
    parts = if output != "", do: parts ++ ["", "Output:", output], else: parts
    parts = parts ++ ["", turn_info(turn, max_turns)]

    Enum.join(parts, "\n")
  end

  defp format_error_feedback(format, error, _response, turn, max_turns) do
    # For errors, all formats show the error + original code
    """
    Error: #{error}

    #{turn_info(turn, max_turns)}

    Please fix the error and try again.
    """
  end

  defp turn_info(turn, max_turns) do
    remaining = max_turns - turn

    if remaining == 0 do
      "⚠️ FINAL TURN - you must call (return value) now."
    else
      "Turn #{turn + 1} of #{max_turns} (#{remaining} remaining)"
    end
  end

  defp format_type(value) when is_list(value), do: "list[#{length(value)}]"
  defp format_type(value) when is_map(value), do: "map"
  defp format_type(value) when is_integer(value), do: "int"
  defp format_type(value) when is_float(value), do: "float"
  defp format_type(value) when is_binary(value), do: "string"
  defp format_type(_), do: "any"

  # Build a summary of what happened in a turn (for compressed format)
  # Goal: Give LLM enough context to continue WITHOUT seeing previous code
  defp build_turn_summary(definitions, output) do
    parts = []

    # Summarize definitions with more detail
    def_parts =
      definitions
      |> Enum.map(fn {name, info} ->
        case info.kind do
          :function ->
            doc = if info[:doc], do: " - #{info.doc}", else: ""
            "; Defined function: #{name}/#{info.arity}#{doc}"

          :data ->
            # Include sample data for lists/maps so LLM knows structure
            sample = format_data_sample(info.value)
            "; Defined: #{name} = #{sample}"
        end
      end)

    parts = parts ++ def_parts

    # Include FULL output - this is what the LLM learned!
    # Truncating destroys the information the LLM needs
    parts =
      if output != "" do
        # Limit to 500 chars to be reasonable, but show more than 50
        truncated =
          if String.length(output) > 500, do: String.slice(output, 0, 500) <> "...", else: output

        parts ++ ["; Output:\n#{truncated}"]
      else
        parts
      end

    if parts == [] do
      "; (no definitions or output)"
    else
      Enum.join(parts, "\n")
    end
  end

  # Format a data value with sample content so LLM understands structure
  defp format_data_sample(value) when is_list(value) do
    len = length(value)

    if len == 0 do
      "[] (empty list)"
    else
      sample = hd(value)
      sample_str = inspect(sample, limit: 3, pretty: false)
      "list[#{len}], sample: #{String.slice(sample_str, 0, 100)}"
    end
  end

  defp format_data_sample(value) when is_map(value) do
    keys = Map.keys(value) |> Enum.take(5) |> Enum.join(", ")
    "map with keys: #{keys}"
  end

  defp format_data_sample(value) do
    inspect(value, limit: 3) |> String.slice(0, 50)
  end

  # --- LLM Call ---

  defp call_llm(model, state) do
    # For compressed format, rebuild messages with summaries
    messages = build_messages_for_llm(state)
    full_messages = [%{role: :system, content: @system_prompt} | messages]

    # Debug: show FULL messages being sent
    IO.puts("\n" <> String.duplicate("=", 40))
    IO.puts("FULL MESSAGES TO LLM (format: #{state.format})")
    IO.puts(String.duplicate("=", 40))

    IO.puts("\n[SYSTEM PROMPT]")
    IO.puts(@system_prompt)

    for msg <- messages do
      IO.puts("\n[#{String.upcase(to_string(msg.role))}]")
      IO.puts(msg.content)
    end

    IO.puts("\n" <> String.duplicate("-", 40))

    case LLMClient.generate_text(model, full_messages, receive_timeout: 60_000) do
      {:ok, %{content: text, tokens: tokens}} ->
        total = Map.get(tokens, :total_tokens, 0)
        {:ok, text || "", total}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # For non-compressed formats, use messages as-is
  defp build_messages_for_llm(%{format: format, messages: messages}) when format != :compressed do
    messages
  end

  # For compressed format, rebuild with summaries for old turns
  defp build_messages_for_llm(%{
         format: :compressed,
         messages: messages,
         turn_summaries: summaries
       }) do
    # Get the initial user message (task)
    [initial | rest] = messages

    # Rebuild: for each old turn, use summary instead of full program
    # rest is pairs of [assistant, user, assistant, user, ...]
    compressed = compress_message_pairs(rest, summaries, [])

    [initial | compressed]
  end

  defp compress_message_pairs([], _summaries, acc), do: Enum.reverse(acc)

  defp compress_message_pairs([assistant, user | rest], [summary | summaries], acc) do
    # Replace assistant content with summary
    compressed_assistant = %{role: :assistant, content: summary}
    compress_message_pairs(rest, summaries, [user, compressed_assistant | acc])
  end

  # Last pair (current turn) - keep as-is (no summary yet)
  defp compress_message_pairs([assistant], [], acc) do
    Enum.reverse([assistant | acc])
  end

  defp compress_message_pairs([assistant, user], [], acc) do
    Enum.reverse([user, assistant | acc])
  end

  defp compress_message_pairs(msgs, summaries, acc) do
    # Fallback - keep remaining messages as-is
    Enum.reverse(acc) ++ msgs
  end

  # --- Parse and Execute (simplified) ---

  defp parse_and_execute(response, memory) do
    # Extract code block
    code = extract_code(response)

    if code == nil do
      {:error, "No code block found"}
    else
      # Very simplified execution - just pattern match common forms
      execute_simplified(code, memory)
    end
  end

  defp extract_code(response) do
    # Try to find code block (accept clojure, lisp, ptclisp, or no language)
    cond do
      response =~ ~r/```(?:clojure|lisp|ptclisp)?\n(.*?)```/s ->
        [[_, code]] = Regex.scan(~r/```(?:clojure|lisp|ptclisp)?\n(.*?)```/s, response)
        String.trim(code)

      response =~ ~r/^\s*\(/ ->
        String.trim(response)

      true ->
        nil
    end
  end

  defp execute_simplified(code, memory) do
    # This is a VERY simplified executor for the spike
    # Just handles common patterns to test feedback formats

    # Check for (return ...)
    if code =~ ~r/\(return\s+/ do
      # Extract return value (simplified)
      case Regex.run(~r/\(return\s+(\[.*?\]|[\d]+|[a-z_-]+)\)/s, code) do
        [_, value] ->
          result = parse_value(value, memory)
          {:return, result, memory}

        _ ->
          {:return, :ok, memory}
      end
    else
      # Check for tool calls first
      tool_outputs = execute_tool_calls(code)

      # Accumulate defs
      defs = Regex.scan(~r/\(def\s+([a-z_-]+)\s+/, code)

      {new_memory, definitions} =
        Enum.reduce(defs, {memory, %{}}, fn [_, name], {mem, defs} ->
          value = simulate_def(name, code, mem)

          {
            Map.put(mem, name, value),
            Map.put(defs, name, %{kind: :data, value: value})
          }
        end)

      # Accumulate defns
      defns = Regex.scan(~r/\(defn\s+([a-z_-]+)\s+"([^"]*)"\s+\[([^\]]*)\]/, code)

      definitions =
        Enum.reduce(defns, definitions, fn [_, name, doc, args], defs ->
          arity = if args == "", do: 0, else: length(String.split(args, ~r/\s+/))
          Map.put(defs, name, %{kind: :function, arity: arity, doc: doc})
        end)

      # Look for println
      prints = Regex.scan(~r/\(println\s+"([^"]+)"[^)]*\)/, code)

      println_output =
        Enum.map(prints, fn [_, text] ->
          simulate_println(text, code, new_memory)
        end)
        |> Enum.join("\n")

      # Combine tool outputs and println outputs
      all_outputs =
        [tool_outputs, println_output] |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")

      {:continue, all_outputs, new_memory, definitions}
    end
  end

  # Execute any tool calls found in the code
  defp execute_tool_calls(code) do
    tool_calls = []

    # Check for search-reviews
    tool_calls =
      if code =~ ~r/tool\/search-reviews/ do
        result = @tool_responses["search_reviews"]
        tool_calls ++ ["[tool/search-reviews result]\n#{result}"]
      else
        tool_calls
      end

    # Check for get-inventory
    tool_calls =
      if code =~ ~r/tool\/get-inventory/ do
        result = @tool_responses["get_inventory"]
        tool_calls ++ ["[tool/get-inventory result]\n#{result}"]
      else
        tool_calls
      end

    Enum.join(tool_calls, "\n")
  end

  defp parse_value(value, memory) do
    cond do
      value =~ ~r/^\d+$/ -> String.to_integer(value)
      Map.has_key?(memory, value) -> memory[value]
      true -> value
    end
  end

  defp simulate_def(name, code, _memory) do
    # Very rough simulation
    cond do
      code =~ ~r/filter.*price.*>.*100/ or code =~ ~r/filter.*>\s*100/ ->
        Enum.filter(@products, fn p -> p.price > 100 end)

      code =~ ~r/filter.*category.*Electronics/ ->
        Enum.filter(@products, fn p -> p.category == "Electronics" end)

      code =~ ~r/ctx\/products/ ->
        @products

      true ->
        []
    end
  end

  defp simulate_println(text, code, memory) do
    # Try to figure out what value to show
    cond do
      code =~ ~r/println.*count/ ->
        # Find what we're counting
        cond do
          Map.has_key?(memory, "expensive") -> "#{text} #{length(memory["expensive"])}"
          Map.has_key?(memory, "filtered") -> "#{text} #{length(memory["filtered"])}"
          true -> "#{text} #{length(@products)}"
        end

      true ->
        text
    end
  end
end

# Run the spike
case System.argv() do
  ["--format", format] ->
    ReplFeedbackSpike.run(format: String.to_atom(format))

  ["--format", format, "--tool"] ->
    ReplFeedbackSpike.run(format: String.to_atom(format), task: ReplFeedbackSpike.tool_task())

  ["--tool"] ->
    ReplFeedbackSpike.run(task: ReplFeedbackSpike.tool_task())

  ["--tool", "--format", format] ->
    ReplFeedbackSpike.run(format: String.to_atom(format), task: ReplFeedbackSpike.tool_task())

  ["--task", task] ->
    ReplFeedbackSpike.run(task: task)

  _ ->
    ReplFeedbackSpike.run()
end
