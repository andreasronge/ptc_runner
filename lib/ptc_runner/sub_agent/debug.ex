defmodule PtcRunner.SubAgent.Debug do
  @moduledoc """
  Debug helpers for visualizing SubAgent execution.

  Provides functions to pretty-print execution traces and agent chains,
  making it easier to understand what happened during agent execution.

  ## Debug Option

  Enable debug mode via the `:debug` option on `SubAgent.run/2`:

      {:ok, step} = SubAgent.run(agent, llm: llm, debug: true)

  When debug mode is enabled, trace entries store the exact message contents:
  - `llm_response` - The assistant message (LLM output, stored as-is)
  - `llm_feedback` - The user message (execution feedback, after truncation)

  These are exactly what's in the messages array sent to the LLM.
  Use `print_trace(step, messages: true)` to view this data.

  ## Trace Option

  Control trace collection via the `:trace` option:

  | Value | Behavior |
  |-------|----------|
  | `true` (default) | Always collect trace |
  | `false` | Never collect trace |
  | `:on_error` | Only include trace on failure |

  ## Examples

      # Default compact view
      {:ok, step} = SubAgent.run(agent, llm: llm, debug: true)
      SubAgent.Debug.print_trace(step)

      # Show full LLM messages (requires debug: true)
      SubAgent.Debug.print_trace(step, messages: true)

      # Print agent chain
      SubAgent.Debug.print_chain([step1, step2, step3])

  """

  alias PtcRunner.Lisp.Format
  alias PtcRunner.Step

  @box_width 60

  @doc """
  Pretty-print a SubAgent execution trace.

  Displays each turn with its program, tool calls, and results
  in a formatted box-drawing style.

  ## Parameters

  - `step` - A `%Step{}` struct with trace data
  - `opts` - Keyword list of options:
    - `messages: true` - Show full LLM response and feedback (requires `debug: true` during execution)
    - `system: true` - Show the system prompt in each turn (default: `false` when `messages: true`)
    - `usage: true` - Show token usage summary after the trace

  ## Examples

      # Default compact view
      iex> {:ok, step} = PtcRunner.SubAgent.run(agent, llm: llm, context: %{})
      iex> PtcRunner.SubAgent.Debug.print_trace(step)
      :ok

      # Show full LLM messages (requires debug: true during execution)
      iex> {:ok, step} = PtcRunner.SubAgent.run(agent, llm: llm, debug: true)
      iex> PtcRunner.SubAgent.Debug.print_trace(step, messages: true)
      :ok

      # Show token usage
      iex> PtcRunner.SubAgent.Debug.print_trace(step, usage: true)
      :ok

  """
  @spec print_trace(Step.t(), keyword()) :: :ok
  def print_trace(step, opts \\ [])

  def print_trace(%Step{trace: nil}, _opts) do
    IO.puts("No trace available (trace disabled or not yet executed)")
    :ok
  end

  def print_trace(%Step{trace: []}, _opts) do
    IO.puts("Empty trace")
    :ok
  end

  def print_trace(%Step{trace: trace, usage: usage}, opts) when is_list(trace) do
    show_messages = Keyword.get(opts, :messages, false)
    show_usage = Keyword.get(opts, :usage, false)

    if show_messages do
      Enum.each(trace, &print_turn_with_messages(&1, opts))
    else
      Enum.each(trace, &print_turn/1)
    end

    if show_usage and usage do
      print_usage_summary(usage)
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
      "\n#{ansi(:cyan)}┌─#{label}#{String.duplicate("─", @box_width - 3 - String.length(label))}┐#{ansi(:reset)}"
    )

    steps
    |> Enum.with_index(1)
    |> Enum.each(fn {step, index} ->
      print_chain_step(step, index, length(steps))
    end)

    IO.puts("#{ansi(:cyan)}└#{String.duplicate("─", @box_width - 2)}┘#{ansi(:reset)}\n")

    :ok
  end

  # ============================================================
  # Private Helpers
  # ============================================================

  defp print_turn(turn_entry) do
    turn_num = Map.get(turn_entry, :turn, 0)
    program = Map.get(turn_entry, :program, "")
    result = Map.get(turn_entry, :result, nil)
    tool_calls = Map.get(turn_entry, :tool_calls, [])
    prints = Map.get(turn_entry, :prints, [])

    header = " Turn #{turn_num} "

    IO.puts(
      "\n#{ansi(:cyan)}┌─#{header}#{String.duplicate("─", @box_width - 3 - String.length(header))}┐#{ansi(:reset)}"
    )

    IO.puts("#{ansi(:cyan)}│#{ansi(:reset)} #{ansi(:bold)}Program:#{ansi(:reset)}")

    # Print program with indentation
    program
    |> String.split("\n")
    |> Enum.each(fn line ->
      IO.puts("#{ansi(:cyan)}│#{ansi(:reset)}   #{truncate_line(line, 80)}")
    end)

    # Print tool calls if any
    unless Enum.empty?(tool_calls) do
      IO.puts("#{ansi(:cyan)}│#{ansi(:reset)} #{ansi(:bold)}Tools:#{ansi(:reset)}")

      Enum.each(tool_calls, fn call ->
        tool_name = Map.get(call, :name, "unknown")
        tool_args = Map.get(call, :args, %{})
        tool_result = Map.get(call, :result, nil)

        args_str = format_compact(tool_args)
        result_str = format_compact(tool_result)

        IO.puts(
          "#{ansi(:cyan)}│#{ansi(:reset)}   #{ansi(:green)}→#{ansi(:reset)} #{tool_name}(#{args_str})"
        )

        IO.puts(
          "#{ansi(:cyan)}│#{ansi(:reset)}     #{ansi(:green)}←#{ansi(:reset)} #{result_str}"
        )
      end)
    end

    # Print println output if any
    unless Enum.empty?(prints) do
      IO.puts("#{ansi(:cyan)}│#{ansi(:reset)} #{ansi(:bold)}Output:#{ansi(:reset)}")

      Enum.each(prints, fn line ->
        IO.puts(
          "#{ansi(:cyan)}│#{ansi(:reset)}   #{ansi(:yellow)}#{truncate_line(line, 80)}#{ansi(:reset)}"
        )
      end)
    end

    # Print result
    IO.puts("#{ansi(:cyan)}│#{ansi(:reset)} #{ansi(:bold)}Result:#{ansi(:reset)}")
    result_lines = format_result(result)

    Enum.each(result_lines, fn line ->
      IO.puts("#{ansi(:cyan)}│#{ansi(:reset)}   #{truncate_line(line, 80)}")
    end)

    IO.puts("#{ansi(:cyan)}└#{String.duplicate("─", @box_width - 2)}┘#{ansi(:reset)}")
  end

  # Print turn with full LLM messages (for messages: true option)
  defp print_turn_with_messages(turn_entry, opts) do
    turn_num = Map.get(turn_entry, :turn, 0)
    program = Map.get(turn_entry, :program, "")
    reasoning = Map.get(turn_entry, :reasoning)
    result = Map.get(turn_entry, :result, nil)
    tool_calls = Map.get(turn_entry, :tool_calls, [])
    prints = Map.get(turn_entry, :prints, [])
    llm_feedback = Map.get(turn_entry, :llm_feedback)

    header = " Turn #{turn_num} "
    system_prompt = Map.get(turn_entry, :system_prompt)
    show_system = Keyword.get(opts, :system, false)

    IO.puts(
      "\n#{ansi(:cyan)}┌─#{header}#{String.duplicate("─", @box_width - 3 - String.length(header))}┐#{ansi(:reset)}"
    )

    # Print System Prompt
    if show_system and system_prompt do
      IO.puts("#{ansi(:cyan)}│#{ansi(:reset)} #{ansi(:bold)}System Prompt:#{ansi(:reset)}")

      system_prompt
      |> String.split("\n")
      |> Enum.each(fn line ->
        IO.puts("#{ansi(:cyan)}│#{ansi(:reset)}   #{ansi(:dim)}#{line}#{ansi(:reset)}")
      end)

      IO.puts("#{ansi(:cyan)}│#{ansi(:reset)}")
    end

    # Print reasoning (everything except the code block)
    IO.puts("#{ansi(:cyan)}│#{ansi(:reset)} #{ansi(:bold)}Reasoning:#{ansi(:reset)}")

    if reasoning do
      reasoning
      |> String.split("\n")
      |> Enum.each(fn line ->
        IO.puts("#{ansi(:cyan)}│#{ansi(:reset)}   #{ansi(:dim)}#{line}#{ansi(:reset)}")
      end)
    else
      IO.puts("#{ansi(:cyan)}│#{ansi(:reset)}   #{ansi(:dim)}(none)#{ansi(:reset)}")
    end

    IO.puts("#{ansi(:cyan)}│#{ansi(:reset)}")

    # Print extracted program
    IO.puts("#{ansi(:cyan)}│#{ansi(:reset)} #{ansi(:bold)}Program:#{ansi(:reset)}")

    program
    |> String.split("\n")
    |> Enum.each(fn line ->
      IO.puts("#{ansi(:cyan)}│#{ansi(:reset)}   #{ansi(:green)}#{line}#{ansi(:reset)}")
    end)

    # Print tool calls if any
    unless Enum.empty?(tool_calls) do
      IO.puts("#{ansi(:cyan)}│#{ansi(:reset)}")
      IO.puts("#{ansi(:cyan)}│#{ansi(:reset)} #{ansi(:bold)}Tools:#{ansi(:reset)}")

      Enum.each(tool_calls, fn call ->
        tool_name = Map.get(call, :name, "unknown")
        tool_args = Map.get(call, :args, %{})
        tool_result = Map.get(call, :result, nil)

        args_str = format_compact(tool_args)
        result_str = format_compact(tool_result)

        IO.puts(
          "#{ansi(:cyan)}│#{ansi(:reset)}   #{ansi(:green)}→#{ansi(:reset)} #{tool_name}(#{args_str})"
        )

        IO.puts(
          "#{ansi(:cyan)}│#{ansi(:reset)}     #{ansi(:green)}←#{ansi(:reset)} #{result_str}"
        )
      end)
    end

    # Print println output if any
    unless Enum.empty?(prints) do
      IO.puts("#{ansi(:cyan)}│#{ansi(:reset)}")
      IO.puts("#{ansi(:cyan)}│#{ansi(:reset)} #{ansi(:bold)}Output:#{ansi(:reset)}")

      Enum.each(prints, fn line ->
        IO.puts(
          "#{ansi(:cyan)}│#{ansi(:reset)}   #{ansi(:yellow)}#{truncate_line(line, 80)}#{ansi(:reset)}"
        )
      end)
    end

    IO.puts("#{ansi(:cyan)}│#{ansi(:reset)}")

    # Print result (full, not truncated)
    IO.puts("#{ansi(:cyan)}│#{ansi(:reset)} #{ansi(:bold)}Result:#{ansi(:reset)}")
    result_str = Format.to_string(result, pretty: true, limit: :infinity)

    result_str
    |> String.split("\n")
    |> Enum.each(fn line ->
      IO.puts("#{ansi(:cyan)}│#{ansi(:reset)}   #{line}")
    end)

    IO.puts("#{ansi(:cyan)}│#{ansi(:reset)}")

    # Print feedback to LLM (user message in messages array - truncated)
    IO.puts(
      "#{ansi(:cyan)}│#{ansi(:reset)} #{ansi(:bold)}User Message (feedback, truncated):#{ansi(:reset)}"
    )

    if llm_feedback do
      llm_feedback
      |> String.split("\n")
      |> Enum.each(fn line ->
        IO.puts("#{ansi(:cyan)}│#{ansi(:reset)}   #{ansi(:yellow)}#{line}#{ansi(:reset)}")
      end)
    else
      IO.puts("#{ansi(:cyan)}│#{ansi(:reset)}   #{ansi(:dim)}(none - final turn)#{ansi(:reset)}")
    end

    IO.puts("#{ansi(:cyan)}└#{String.duplicate("─", @box_width - 2)}┘#{ansi(:reset)}")
  end

  defp print_chain_step(step, index, total) do
    status =
      case step.fail do
        nil -> ansi(:green) <> "✓" <> ansi(:reset)
        _fail -> ansi(:red) <> "✗" <> ansi(:reset)
      end

    turns = if step.trace, do: length(step.trace), else: 0
    duration_ms = get_in(step.usage, [:duration_ms]) || 0

    IO.puts("#{ansi(:cyan)}│#{ansi(:reset)}")
    IO.puts("#{ansi(:cyan)}│#{ansi(:reset)} #{status} Step #{index}/#{total}")

    if step.fail do
      reason = step.fail.reason
      message = step.fail.message
      IO.puts("#{ansi(:cyan)}│#{ansi(:reset)}   #{ansi(:red)}Error:#{ansi(:reset)} #{reason}")
      IO.puts("#{ansi(:cyan)}│#{ansi(:reset)}   #{ansi(:red)}Message:#{ansi(:reset)} #{message}")
    else
      return_preview = format_compact(step.return)

      IO.puts(
        "#{ansi(:cyan)}│#{ansi(:reset)}   #{ansi(:bold)}Return:#{ansi(:reset)} #{return_preview}"
      )
    end

    IO.puts(
      "#{ansi(:cyan)}│#{ansi(:reset)}   #{ansi(:dim)}Turns:#{ansi(:reset)} #{turns} | #{ansi(:dim)}Duration:#{ansi(:reset)} #{duration_ms}ms"
    )

    # Add arrow between steps (except for last step)
    if index < total do
      IO.puts("#{ansi(:cyan)}│#{ansi(:reset)}   #{ansi(:dim)}↓#{ansi(:reset)}")
    end
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
      "\n#{ansi(:cyan)}┌─#{header}#{String.duplicate("─", @box_width - 3 - String.length(header))}┐#{ansi(:reset)}"
    )

    if usage[:input_tokens] do
      IO.puts(
        "#{ansi(:cyan)}│#{ansi(:reset)}   Input tokens:  #{format_number(usage.input_tokens)}"
      )
    end

    if usage[:output_tokens] do
      IO.puts(
        "#{ansi(:cyan)}│#{ansi(:reset)}   Output tokens: #{format_number(usage.output_tokens)}"
      )
    end

    if usage[:total_tokens] do
      IO.puts(
        "#{ansi(:cyan)}│#{ansi(:reset)}   Total tokens:  #{format_number(usage.total_tokens)}"
      )
    end

    if usage[:system_prompt_tokens] && usage.system_prompt_tokens > 0 do
      IO.puts(
        "#{ansi(:cyan)}│#{ansi(:reset)}   System prompt: #{format_number(usage.system_prompt_tokens)} #{ansi(:dim)}(est.)#{ansi(:reset)}"
      )
    end

    if usage[:duration_ms] do
      IO.puts("#{ansi(:cyan)}│#{ansi(:reset)}   Duration:      #{usage.duration_ms}ms")
    end

    if usage[:turns] do
      IO.puts("#{ansi(:cyan)}│#{ansi(:reset)}   Turns:         #{usage.turns}")
    end

    IO.puts("#{ansi(:cyan)}└#{String.duplicate("─", @box_width - 2)}┘#{ansi(:reset)}")
  end

  # Format number with thousand separators
  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_number(n), do: "#{n}"

  # ANSI color helpers
  defp ansi(:reset), do: IO.ANSI.reset()
  defp ansi(:cyan), do: IO.ANSI.cyan()
  defp ansi(:green), do: IO.ANSI.green()
  defp ansi(:red), do: IO.ANSI.red()
  defp ansi(:yellow), do: IO.ANSI.yellow()
  defp ansi(:bold), do: IO.ANSI.bright()
  defp ansi(:dim), do: IO.ANSI.faint()
end
