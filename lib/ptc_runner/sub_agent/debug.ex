defmodule PtcRunner.SubAgent.Debug do
  @moduledoc """
  Debug helpers for visualizing SubAgent execution.

  Provides functions to pretty-print execution traces and agent chains,
  making it easier to understand what happened during agent execution.

  ## Raw Mode

  Use `print_trace(step, raw: true)` to see the complete LLM interaction:
  - **Raw Input**: Messages sent to the LLM (excluding system prompt)
  - **Raw Response**: Full LLM output including reasoning
  - Lines shown exactly as-is (no wrapping or truncation)

  For all messages including the system prompt, use `messages: true` instead.
  Note: `messages: true` wraps long lines to 160 chars.

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
  @line_width 160

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
    - `usage` - Show token usage, tool call statistics, and compression summary (default: `false`)

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
    original_prompt = step.original_prompt

    case view do
      :turns ->
        show_raw = opts[:raw] == true
        show_all_messages = opts[:messages] == true
        raw_mode = show_raw and not show_all_messages
        Enum.each(turns, &print_turn(&1, show_raw, show_all_messages, raw_mode, original_prompt))

      :compressed ->
        print_compressed_view(step)
    end

    if show_usage and usage do
      print_usage_summary(usage)

      # Print tool call statistics
      print_tool_stats(turns)

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

  defp print_turn(%Turn{} = turn, show_raw, show_all_messages, raw_mode, original_prompt) do
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

    # Show original mission template on first turn (when raw mode is on)
    # This helps distinguish template variables from hardcoded values
    if turn.number == 1 and show_raw and original_prompt do
      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)} #{ansi(:bold)}Mission:#{ansi(:reset)}")
      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}   #{original_prompt}")
      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}")
    end

    # Print messages sent to LLM
    # - show_all_messages: show all messages including system prompt
    # - show_raw: show messages excluding system prompt and placeholder content
    if (show_all_messages || show_raw) and turn.messages do
      messages_to_show =
        if show_all_messages do
          turn.messages
        else
          # For raw mode, exclude system messages
          Enum.reject(turn.messages, fn msg ->
            Map.get(msg, :role) == :system
          end)
        end

      unless Enum.empty?(messages_to_show) do
        label = if show_all_messages, do: "Messages sent to LLM:", else: "Raw Input:"
        IO.puts("#{ansi(:cyan)}|#{ansi(:reset)} #{ansi(:bold)}#{label}#{ansi(:reset)}")
        Enum.each(messages_to_show, &print_message(&1, raw_mode))
        IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}")
      end
    end

    # Print raw response (reasoning) if requested
    if show_raw and turn.raw_response do
      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)} #{ansi(:bold)}Raw Response:#{ansi(:reset)}")

      turn.raw_response
      |> redact_program()
      |> String.split("\n")
      |> fit_lines(raw_mode, @line_width)
      |> Enum.each(fn line ->
        IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}   #{ansi(:dim)}#{line}#{ansi(:reset)}")
      end)

      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}")
    end

    # Print program or JSON mode indicator
    print_program_section(turn, raw_mode)

    # Print tool calls if any
    print_tool_calls(turn.tool_calls)

    # Print println output if any
    unless Enum.empty?(turn.prints) do
      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)} #{ansi(:bold)}Output:#{ansi(:reset)}")

      turn.prints
      |> fit_lines(raw_mode, @line_width)
      |> Enum.each(fn line ->
        IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}   #{ansi(:yellow)}#{line}#{ansi(:reset)}")
      end)
    end

    # Print result
    IO.puts("#{ansi(:cyan)}|#{ansi(:reset)} #{ansi(:bold)}Result:#{ansi(:reset)}")
    result_lines = format_result(turn.result)

    result_lines
    |> fit_lines(raw_mode, @line_width)
    |> Enum.each(fn line ->
      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}   #{line}")
    end)

    IO.puts("#{ansi(:cyan)}+#{String.duplicate("-", @box_width - 2)}+#{ansi(:reset)}")
  end

  # Print program section (or JSON mode indicator)
  defp print_program_section(turn, raw_mode) do
    cond do
      turn.program ->
        IO.puts("#{ansi(:cyan)}|#{ansi(:reset)} #{ansi(:bold)}Program:#{ansi(:reset)}")

        turn.program
        |> String.split("\n")
        |> fit_lines(raw_mode, @line_width)
        |> Enum.each(fn line ->
          IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}   #{line}")
        end)

      turn.success? ->
        # JSON mode - no program, show response format
        IO.puts("#{ansi(:cyan)}|#{ansi(:reset)} #{ansi(:bold)}Response:#{ansi(:reset)}")
        IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}   #{ansi(:dim)}(JSON mode)#{ansi(:reset)}")

      true ->
        IO.puts("#{ansi(:cyan)}|#{ansi(:reset)} #{ansi(:bold)}Program:#{ansi(:reset)}")
        IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}   #{ansi(:dim)}(parsing failed)#{ansi(:reset)}")
    end
  end

  # Print tool calls section (uses Clojure format to match what LLM sees)
  defp print_tool_calls([]), do: :ok

  defp print_tool_calls(tool_calls) do
    IO.puts("#{ansi(:cyan)}|#{ansi(:reset)} #{ansi(:bold)}Tools:#{ansi(:reset)}")

    Enum.each(tool_calls, fn call ->
      tool_name = Map.get(call, :name, "unknown")
      tool_args = Map.get(call, :args, %{})
      tool_result = Map.get(call, :result, nil)

      {args_str, _} = Format.to_clojure(tool_args, limit: 3, printable_limit: 60)
      {result_str, _} = Format.to_clojure(tool_result, limit: 3, printable_limit: 60)

      IO.puts(
        "#{ansi(:cyan)}|#{ansi(:reset)}   #{ansi(:green)}->#{ansi(:reset)} #{tool_name}(#{args_str})"
      )

      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}     #{ansi(:green)}<-#{ansi(:reset)} #{result_str}")
    end)
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

  # Format result for display (multi-line, uses Clojure format to match LLM)
  defp format_result(result) do
    {str, _truncated} = Format.to_clojure(result, limit: 5, printable_limit: 200)
    String.split(str, "\n")
  end

  # Format data compactly for inline display (single line, Clojure format)
  defp format_compact(data) do
    {str, _truncated} = Format.to_clojure(data, limit: 3, printable_limit: 60)
    str
  end

  # Fit lines to max length - raw mode shows full lines, normal mode wraps
  defp fit_lines(lines, raw_mode, max_length) do
    if raw_mode do
      # Raw mode: show lines exactly as-is, no wrapping or truncation
      lines
    else
      Enum.flat_map(lines, &wrap_line(&1, max_length))
    end
  end

  # Wrap a line to max length, returning a list of wrapped lines
  defp wrap_line(line, max_length) do
    if String.length(line) <= max_length do
      [line]
    else
      do_wrap_line(line, max_length, [])
    end
  end

  defp do_wrap_line("", _max_length, acc), do: Enum.reverse(acc)

  defp do_wrap_line(line, max_length, acc) do
    if String.length(line) <= max_length do
      Enum.reverse([line | acc])
    else
      {chunk, rest} = String.split_at(line, max_length)
      do_wrap_line(rest, max_length, [chunk | acc])
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

  # Print tool call statistics from all turns
  defp print_tool_stats(turns) do
    # Collect all tool calls from all turns
    all_calls =
      turns
      |> Enum.flat_map(fn turn -> turn.tool_calls || [] end)

    if Enum.empty?(all_calls) do
      :ok
    else
      # Group by tool name and collect call info
      stats =
        all_calls
        |> Enum.group_by(fn call -> Map.get(call, :name, "unknown") end)
        |> Enum.map(fn {name, calls} ->
          {name, length(calls), Enum.map(calls, &Map.get(&1, :args, %{}))}
        end)
        |> Enum.sort_by(fn {_name, count, _args} -> -count end)

      header = " Tool Calls "

      IO.puts(
        "\n#{ansi(:cyan)}+-#{header}#{String.duplicate("-", @box_width - 3 - String.length(header))}+#{ansi(:reset)}"
      )

      Enum.each(stats, fn {name, count, args_list} ->
        IO.puts(
          "#{ansi(:cyan)}|#{ansi(:reset)}   #{ansi(:green)}#{name}#{ansi(:reset)} × #{count}"
        )

        # Show sample arguments (first 3 calls, using Clojure format to match LLM)
        args_list
        |> Enum.take(3)
        |> Enum.with_index(1)
        |> Enum.each(fn {args, idx} ->
          {args_str, _} = Format.to_clojure(args, limit: 3, printable_limit: 50)

          IO.puts(
            "#{ansi(:cyan)}|#{ansi(:reset)}     #{ansi(:dim)}#{idx}. #{args_str}#{ansi(:reset)}"
          )
        end)

        if length(args_list) > 3 do
          IO.puts(
            "#{ansi(:cyan)}|#{ansi(:reset)}     #{ansi(:dim)}... +#{length(args_list) - 3} more#{ansi(:reset)}"
          )
        end
      end)

      IO.puts("#{ansi(:cyan)}+#{String.duplicate("-", @box_width - 2)}+#{ansi(:reset)}")
    end
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
  defp print_message(msg, raw_mode) do
    role = Map.get(msg, :role, :unknown)
    content = Map.get(msg, :content, "")
    char_count = String.length(content)

    IO.puts(
      "#{ansi(:cyan)}|#{ansi(:reset)}   #{ansi(:bold)}[#{role}]#{ansi(:reset)} (#{char_count} chars)"
    )

    # Print each line of content with proper box formatting
    content
    |> String.split("\n")
    |> fit_lines(raw_mode, @line_width)
    |> Enum.each(fn line ->
      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}     #{ansi(:dim)}#{line}#{ansi(:reset)}")
    end)
  end

  # ANSI color helpers
  @ansi_codes %{
    reset: IO.ANSI.reset(),
    cyan: IO.ANSI.cyan(),
    green: IO.ANSI.green(),
    red: IO.ANSI.red(),
    yellow: IO.ANSI.yellow(),
    bold: IO.ANSI.bright(),
    dim: IO.ANSI.faint()
  }

  defp ansi(code), do: Map.get(@ansi_codes, code, "")
end
