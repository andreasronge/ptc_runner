defmodule PtcRunner.SubAgent.Debug do
  @moduledoc """
  Debug helpers for visualizing SubAgent execution.

  Provides functions to pretty-print execution traces and agent chains,
  making it easier to understand what happened during agent execution.

  ## Raw Mode

  Use `print_trace(step, raw: true)` to see the complete LLM interaction:
  - **Raw Input**: Messages sent to the LLM (excluding system prompt)
  - **Raw Response**: Full LLM output including reasoning

  For all messages including the system prompt, use `messages: true` instead.

  ## View Modes

  | View | Description |
  |------|-------------|
  | `:turns` (default) | Show programs + results from Turn structs |
  | `:compressed` | Show what the LLM sees (compressed format) |

  ## Examples

      # Default compact view
      {:ok, step} = SubAgent.run(agent, llm: llm)
      SubAgent.Debug.print_trace(step)

      # Include raw input and raw response
      SubAgent.Debug.print_trace(step, raw: true)

      # Show all messages including system prompt
      SubAgent.Debug.print_trace(step, messages: true)

      # Show compressed view (what LLM sees)
      SubAgent.Debug.print_trace(step, view: :compressed)

      # Print agent chain
      SubAgent.Debug.print_chain([step1, step2, step3])

  """

  alias PtcRunner.Lisp.Format
  alias PtcRunner.Step
  alias PtcRunner.SubAgent.Compression.SingleUserCoalesced
  alias PtcRunner.Turn

  @box_width 60

  @doc """
  Pretty-print a SubAgent execution trace.

  Displays each turn with its program, tool calls, and results
  in a formatted box-drawing style.

  ## Parameters

  - `step` - A `%Step{}` struct with trace data
  - `opts` - Keyword list of options:
    - `view` - `:turns` (default) or `:compressed` - perspective to render
    - `raw` - Include raw input (messages, excluding system prompt) and raw response (default: `false`)
    - `messages` - Show all messages sent to LLM including system prompt (default: `false`)
    - `usage` - Show token usage summary after the trace (default: `false`)

  ## Examples

      # Default compact view
      iex> {:ok, step} = PtcRunner.SubAgent.run(agent, llm: llm, context: %{})
      iex> PtcRunner.SubAgent.Debug.print_trace(step)
      :ok

      # Include raw LLM response
      iex> PtcRunner.SubAgent.Debug.print_trace(step, raw: true)
      :ok

      # Show compressed view
      iex> PtcRunner.SubAgent.Debug.print_trace(step, view: :compressed)
      :ok

      # Show messages sent to LLM (verify compression)
      iex> PtcRunner.SubAgent.Debug.print_trace(step, messages: true)
      :ok

      # Show token usage
      iex> PtcRunner.SubAgent.Debug.print_trace(step, usage: true)
      :ok

  """
  @spec print_trace(Step.t(), keyword()) :: :ok
  def print_trace(step, opts \\ [])

  def print_trace(%Step{turns: nil}, _opts) do
    IO.puts("No trace available (trace disabled or not yet executed)")
    :ok
  end

  def print_trace(%Step{turns: []}, _opts) do
    IO.puts("Empty trace")
    :ok
  end

  def print_trace(%Step{turns: turns, usage: usage} = step, opts) when is_list(turns) do
    view = Keyword.get(opts, :view, :turns)
    show_usage = Keyword.get(opts, :usage, false)

    case view do
      :turns ->
        show_raw = Keyword.get(opts, :raw, false)
        show_all_messages = Keyword.get(opts, :messages, false)
        Enum.each(turns, &print_turn(&1, show_raw, show_all_messages))

      :compressed ->
        print_compressed_view(step)
    end

    if show_usage and usage do
      print_usage_summary(usage)

      # Print compression stats if available
      if compression = Map.get(usage, :compression) do
        print_compression_summary(compression)
      end
    end

    :ok
  end

  @doc """
  Pretty-print a chain of SubAgent executions.

  Shows the flow of data between multiple agent steps in a pipeline.

  ## Parameters

  - `steps` - List of `%Step{}` structs representing a chain

  ## Examples

      iex> step1 = PtcRunner.SubAgent.run!(agent1, llm: llm)
      iex> step2 = PtcRunner.SubAgent.then!(step1, agent2, llm: llm)
      iex> PtcRunner.SubAgent.Debug.print_chain([step1, step2])
      :ok

  """
  @spec print_chain([Step.t()]) :: :ok
  def print_chain([]), do: :ok

  def print_chain(steps) when is_list(steps) do
    label = " Agent Chain "

    IO.puts(
      "\n#{ansi(:cyan)}+-#{label}#{String.duplicate("-", @box_width - 3 - String.length(label))}+#{ansi(:reset)}"
    )

    steps
    |> Enum.with_index(1)
    |> Enum.each(fn {step, index} ->
      print_chain_step(step, index, length(steps))
    end)

    IO.puts("#{ansi(:cyan)}+#{String.duplicate("-", @box_width - 2)}+#{ansi(:reset)}\n")

    :ok
  end

  # ============================================================
  # Private Helpers - Turn-based (new format)
  # ============================================================

  defp print_turn(%Turn{} = turn, show_raw, show_all_messages) do
    # Build header with message count indicator
    msg_indicator =
      case turn.messages do
        nil -> ""
        msgs when is_list(msgs) -> " (#{length(msgs)} msgs)"
      end

    header = " Turn #{turn.number}#{msg_indicator} "

    IO.puts(
      "\n#{ansi(:cyan)}+-#{header}#{String.duplicate("-", @box_width - 3 - String.length(header))}+#{ansi(:reset)}"
    )

    # Print messages sent to LLM
    # - show_all_messages: show all messages including system prompt
    # - show_raw: show messages excluding system prompt and placeholder content
    if (show_all_messages || show_raw) and turn.messages do
      messages_to_show =
        if show_all_messages do
          turn.messages
        else
          # For raw mode, exclude system messages and placeholder content
          Enum.reject(turn.messages, fn msg ->
            Map.get(msg, :role) == :system or placeholder_message?(msg)
          end)
        end

      unless Enum.empty?(messages_to_show) do
        label = if show_all_messages, do: "Messages sent to LLM:", else: "Raw Input:"
        IO.puts("#{ansi(:cyan)}|#{ansi(:reset)} #{ansi(:bold)}#{label}#{ansi(:reset)}")
        Enum.each(messages_to_show, &print_message/1)
        IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}")
      end
    end

    # Print raw response (reasoning) if requested
    if show_raw and turn.raw_response do
      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)} #{ansi(:bold)}Raw Response:#{ansi(:reset)}")

      turn.raw_response
      |> redact_program()
      |> String.split("\n")
      |> Enum.each(fn line ->
        IO.puts(
          "#{ansi(:cyan)}|#{ansi(:reset)}   #{ansi(:dim)}#{truncate_line(line, 80)}#{ansi(:reset)}"
        )
      end)

      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}")
    end

    # Print program
    IO.puts("#{ansi(:cyan)}|#{ansi(:reset)} #{ansi(:bold)}Program:#{ansi(:reset)}")

    if turn.program do
      turn.program
      |> String.split("\n")
      |> Enum.each(fn line ->
        IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}   #{truncate_line(line, 80)}")
      end)
    else
      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}   #{ansi(:dim)}(parsing failed)#{ansi(:reset)}")
    end

    # Print tool calls if any
    unless Enum.empty?(turn.tool_calls) do
      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)} #{ansi(:bold)}Tools:#{ansi(:reset)}")

      Enum.each(turn.tool_calls, fn call ->
        tool_name = Map.get(call, :name, "unknown")
        tool_args = Map.get(call, :args, %{})
        tool_result = Map.get(call, :result, nil)

        args_str = format_compact(tool_args)
        result_str = format_compact(tool_result)

        IO.puts(
          "#{ansi(:cyan)}|#{ansi(:reset)}   #{ansi(:green)}->#{ansi(:reset)} #{tool_name}(#{args_str})"
        )

        IO.puts(
          "#{ansi(:cyan)}|#{ansi(:reset)}     #{ansi(:green)}<-#{ansi(:reset)} #{result_str}"
        )
      end)
    end

    # Print println output if any
    unless Enum.empty?(turn.prints) do
      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)} #{ansi(:bold)}Output:#{ansi(:reset)}")

      Enum.each(turn.prints, fn line ->
        IO.puts(
          "#{ansi(:cyan)}|#{ansi(:reset)}   #{ansi(:yellow)}#{truncate_line(line, 80)}#{ansi(:reset)}"
        )
      end)
    end

    # Print result
    IO.puts("#{ansi(:cyan)}|#{ansi(:reset)} #{ansi(:bold)}Result:#{ansi(:reset)}")
    result_lines = format_result(turn.result)

    Enum.each(result_lines, fn line ->
      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}   #{truncate_line(line, 80)}")
    end)

    IO.puts("#{ansi(:cyan)}+#{String.duplicate("-", @box_width - 2)}+#{ansi(:reset)}")
  end

  # Print compressed view using SingleUserCoalesced compression
  defp print_compressed_view(%Step{turns: turns, memory: memory, prompt: prompt, tools: tools}) do
    header = " Compressed View "

    IO.puts(
      "\n#{ansi(:cyan)}+-#{header}#{String.duplicate("-", @box_width - 3 - String.length(header))}+#{ansi(:reset)}"
    )

    # Use compression strategy to render what LLM would see
    {messages, _stats} =
      SingleUserCoalesced.to_messages(turns, memory,
        system_prompt: "(system prompt omitted)",
        prompt: prompt || "(mission not available)",
        tools: tools || %{},
        data: %{},
        turns_left: 0
      )

    # Print each message
    Enum.each(messages, fn msg ->
      role_color = if msg.role == :system, do: :dim, else: :yellow

      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)} #{ansi(:bold)}[#{msg.role}]#{ansi(:reset)}")

      msg.content
      |> String.split("\n")
      |> Enum.each(fn line ->
        IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}   #{ansi(role_color)}#{line}#{ansi(:reset)}")
      end)

      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}")
    end)

    IO.puts("#{ansi(:cyan)}+#{String.duplicate("-", @box_width - 2)}+#{ansi(:reset)}")
  end

  # ============================================================
  # Private Helpers - Chain
  # ============================================================

  defp print_chain_step(step, index, total) do
    status =
      case step.fail do
        nil -> ansi(:green) <> "ok" <> ansi(:reset)
        _fail -> ansi(:red) <> "X" <> ansi(:reset)
      end

    turns = get_turn_count(step)
    duration_ms = get_in(step.usage, [:duration_ms]) || 0

    IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}")
    IO.puts("#{ansi(:cyan)}|#{ansi(:reset)} #{status} Step #{index}/#{total}")

    if step.fail do
      reason = step.fail.reason
      message = step.fail.message
      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}   #{ansi(:red)}Error:#{ansi(:reset)} #{reason}")
      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}   #{ansi(:red)}Message:#{ansi(:reset)} #{message}")
    else
      return_preview = format_compact(step.return)

      IO.puts(
        "#{ansi(:cyan)}|#{ansi(:reset)}   #{ansi(:bold)}Return:#{ansi(:reset)} #{return_preview}"
      )
    end

    IO.puts(
      "#{ansi(:cyan)}|#{ansi(:reset)}   #{ansi(:dim)}Turns:#{ansi(:reset)} #{turns} | #{ansi(:dim)}Duration:#{ansi(:reset)} #{duration_ms}ms"
    )

    # Add arrow between steps (except for last step)
    if index < total do
      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}   #{ansi(:dim)}v#{ansi(:reset)}")
    end
  end

  # Get turn count from turns
  defp get_turn_count(%Step{turns: turns}) when is_list(turns), do: length(turns)
  defp get_turn_count(_step), do: 0

  # ============================================================
  # Private Helpers - Formatting
  # ============================================================

  @doc false
  # Replace code blocks with placeholder to avoid duplication with Program section.
  # Exported for testing.
  def redact_program(text) do
    Regex.replace(~r/```(?:lisp|clojure)?\s*[\s\S]+?\s*```/, text, "[program: see below]")
  end

  # Format result for display
  defp format_result(result) when is_binary(result) do
    if String.length(result) > 200 do
      [String.slice(result, 0, 197) <> "..."]
    else
      String.split(result, "\n")
    end
  end

  defp format_result(result) when is_map(result) do
    if map_size(result) == 0 do
      ["{}"]
    else
      formatted = Format.to_string(result, pretty: true, limit: 5, width: 80)

      if String.length(formatted) > 200 do
        [String.slice(formatted, 0, 197) <> "..."]
      else
        String.split(formatted, "\n")
      end
    end
  end

  defp format_result(result) when is_list(result) do
    formatted = Format.to_string(result, pretty: true, limit: 5, width: 80)

    if String.length(formatted) > 200 do
      [String.slice(formatted, 0, 197) <> "..."]
    else
      String.split(formatted, "\n")
    end
  end

  defp format_result(result) do
    formatted = Format.to_string(result, pretty: true, limit: 5, width: 80)
    String.split(formatted, "\n")
  end

  # Format data compactly for inline display
  defp format_compact(data) when is_map(data) do
    if map_size(data) == 0 do
      "{}"
    else
      keys =
        data
        |> Map.keys()
        |> Enum.take(3)
        |> Enum.map_join(", ", &inspect/1)

      if map_size(data) > 3 do
        "{#{keys}, ... (#{map_size(data)} keys)}"
      else
        Format.to_string(data, limit: 3, pretty: false, width: 60)
      end
    end
  end

  defp format_compact(data) when is_list(data) do
    cond do
      data == [] ->
        "[]"

      length(data) <= 3 ->
        Format.to_string(data, limit: 3, pretty: false, width: 60)

      true ->
        sample = Enum.take(data, 3) |> Format.to_string(limit: 3, pretty: false)
        "#{sample}... (#{length(data)} items)"
    end
  end

  defp format_compact(data) when is_binary(data) do
    if String.length(data) > 50 do
      inspect(String.slice(data, 0, 47) <> "...")
    else
      inspect(data)
    end
  end

  defp format_compact(data) do
    formatted = Format.to_string(data, limit: 3, pretty: false, width: 60)

    if String.length(formatted) > 50 do
      String.slice(formatted, 0, 47) <> "..."
    else
      formatted
    end
  end

  # Truncate a line to max length
  defp truncate_line(line, max_length) do
    if String.length(line) > max_length do
      String.slice(line, 0, max_length - 3) <> "..."
    else
      line
    end
  end

  # Print usage summary
  defp print_usage_summary(usage) do
    header = " Usage "

    IO.puts(
      "\n#{ansi(:cyan)}+-#{header}#{String.duplicate("-", @box_width - 3 - String.length(header))}+#{ansi(:reset)}"
    )

    if usage[:input_tokens] do
      IO.puts(
        "#{ansi(:cyan)}|#{ansi(:reset)}   Input tokens:  #{format_number(usage.input_tokens)}"
      )
    end

    if usage[:output_tokens] do
      IO.puts(
        "#{ansi(:cyan)}|#{ansi(:reset)}   Output tokens: #{format_number(usage.output_tokens)}"
      )
    end

    # Show system prompt size with ratio of input tokens
    if usage[:system_prompt_tokens] && usage.system_prompt_tokens > 0 do
      ratio_str = format_system_prompt_ratio(usage)

      IO.puts(
        "#{ansi(:cyan)}|#{ansi(:reset)}   System prompt: #{format_number(usage.system_prompt_tokens)} #{ansi(:dim)}(est. size#{ratio_str})#{ansi(:reset)}"
      )
    end

    if usage[:memory_bytes] && usage.memory_bytes > 0 do
      IO.puts(
        "#{ansi(:cyan)}|#{ansi(:reset)}   Memory:        #{format_bytes(usage.memory_bytes)}"
      )
    end

    if usage[:duration_ms] do
      IO.puts(
        "#{ansi(:cyan)}|#{ansi(:reset)}   Duration:      #{format_number(usage.duration_ms)}ms"
      )
    end

    if usage[:turns] do
      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}   Turns:         #{usage.turns}")
    end

    IO.puts("#{ansi(:cyan)}+#{String.duplicate("-", @box_width - 2)}+#{ansi(:reset)}")
  end

  # Print compression statistics summary
  defp print_compression_summary(compression) do
    header = " Compression "

    IO.puts(
      "\n#{ansi(:cyan)}+-#{header}#{String.duplicate("-", @box_width - 3 - String.length(header))}+#{ansi(:reset)}"
    )

    IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}   Strategy:     #{compression.strategy}")

    IO.puts(
      "#{ansi(:cyan)}|#{ansi(:reset)}   Turns:        #{compression.turns_compressed} compressed"
    )

    # Tool calls
    if compression.tool_calls_total > 0 do
      dropped_str =
        if compression.tool_calls_dropped > 0,
          do: " #{ansi(:yellow)}(#{compression.tool_calls_dropped} dropped)#{ansi(:reset)}",
          else: ""

      IO.puts(
        "#{ansi(:cyan)}|#{ansi(:reset)}   Tool calls:   #{compression.tool_calls_shown}/#{compression.tool_calls_total} shown#{dropped_str}"
      )
    end

    # Printlns
    if compression.printlns_total > 0 do
      dropped_str =
        if compression.printlns_dropped > 0,
          do: " #{ansi(:yellow)}(#{compression.printlns_dropped} dropped)#{ansi(:reset)}",
          else: ""

      IO.puts(
        "#{ansi(:cyan)}|#{ansi(:reset)}   Printlns:     #{compression.printlns_shown}/#{compression.printlns_total} shown#{dropped_str}"
      )
    end

    # Error turns collapsed
    if compression.error_turns_collapsed > 0 do
      IO.puts(
        "#{ansi(:cyan)}|#{ansi(:reset)}   Errors:       #{compression.error_turns_collapsed} turn(s) collapsed"
      )
    end

    IO.puts("#{ansi(:cyan)}+#{String.duplicate("-", @box_width - 2)}+#{ansi(:reset)}")
  end

  # Calculate system prompt ratio of input tokens
  defp format_system_prompt_ratio(usage) do
    turns = Map.get(usage, :turns, 1)
    input_tokens = Map.get(usage, :input_tokens, 0)
    system_prompt_tokens = Map.get(usage, :system_prompt_tokens, 0)

    if turns > 0 and input_tokens > 0 and system_prompt_tokens > 0 do
      # System prompt is sent with each turn
      total_system_tokens = system_prompt_tokens * turns
      ratio = Float.round(total_system_tokens / input_tokens * 100, 0) |> trunc()
      ", ~#{ratio}% of input"
    else
      ""
    end
  end

  # Format bytes to human-readable string
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  # Format number with thousand separators
  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_number(n), do: "#{n}"

  # Print a single message with role and content
  defp print_message(msg) do
    role = Map.get(msg, :role, :unknown)
    content = Map.get(msg, :content, "")
    char_count = String.length(content)

    IO.puts(
      "#{ansi(:cyan)}|#{ansi(:reset)}   #{ansi(:bold)}[#{role}]#{ansi(:reset)} (#{char_count} chars)"
    )

    # Print each line of content with proper box formatting
    content
    |> String.split("\n")
    |> Enum.each(&print_message_line/1)
  end

  defp print_message_line(line) do
    truncated_line = truncate_line(line, 500)
    IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}     #{ansi(:dim)}#{truncated_line}#{ansi(:reset)}")
  end

  # Check if a message contains only placeholder content (no real data)
  # These are filtered out in raw mode to reduce noise
  # Returns false for all messages - placeholder text is no longer generated
  defp placeholder_message?(_msg), do: false

  # ANSI color helpers
  defp ansi(:reset), do: IO.ANSI.reset()
  defp ansi(:cyan), do: IO.ANSI.cyan()
  defp ansi(:green), do: IO.ANSI.green()
  defp ansi(:red), do: IO.ANSI.red()
  defp ansi(:yellow), do: IO.ANSI.yellow()
  defp ansi(:bold), do: IO.ANSI.bright()
  defp ansi(:dim), do: IO.ANSI.faint()
end
