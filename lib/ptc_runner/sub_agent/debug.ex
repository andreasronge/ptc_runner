defmodule PtcRunner.SubAgent.Debug do
  @moduledoc """
  Debug helpers for visualizing SubAgent execution.

  Provides functions to pretty-print execution traces and agent chains,
  making it easier to understand what happened during agent execution.

  ## Raw Response

  Turn structs always capture `raw_response` (the full LLM output including reasoning).
  Use `print_trace(step, raw: true)` to include this in the output.

  ## View Modes

  | View | Description |
  |------|-------------|
  | `:turns` (default) | Show programs + results from Turn structs |
  | `:compressed` | Show what the LLM sees (compressed format) |

  ## Examples

      # Default compact view
      {:ok, step} = SubAgent.run(agent, llm: llm)
      SubAgent.Debug.print_trace(step)

      # Include raw LLM response (reasoning)
      SubAgent.Debug.print_trace(step, raw: true)

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
    - `raw` - Include `raw_response` in turns view (default: `false`)
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

      # Show token usage
      iex> PtcRunner.SubAgent.Debug.print_trace(step, usage: true)
      :ok

  """
  @spec print_trace(Step.t(), keyword()) :: :ok
  def print_trace(step, opts \\ [])

  # Handle nil turns - fall back to trace for backward compatibility
  def print_trace(%Step{turns: nil, trace: nil}, _opts) do
    IO.puts("No trace available (trace disabled or not yet executed)")
    :ok
  end

  def print_trace(%Step{turns: nil, trace: trace} = step, opts) when is_list(trace) do
    # Backward compatibility: use trace if turns not available
    print_trace_from_trace(step, opts)
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
        Enum.each(turns, &print_turn(&1, show_raw))

      :compressed ->
        print_compressed_view(step)
    end

    if show_usage and usage do
      print_usage_summary(usage)
    end

    :ok
  end

  # Backward compatibility: handle old trace format
  defp print_trace_from_trace(%Step{trace: nil}, _opts) do
    IO.puts("No trace available (trace disabled or not yet executed)")
    :ok
  end

  defp print_trace_from_trace(%Step{trace: []}, _opts) do
    IO.puts("Empty trace")
    :ok
  end

  defp print_trace_from_trace(%Step{trace: trace, usage: usage}, opts) when is_list(trace) do
    show_raw = Keyword.get(opts, :raw, false)
    show_usage = Keyword.get(opts, :usage, false)

    Enum.each(trace, &print_legacy_turn(&1, show_raw))

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

  defp print_turn(%Turn{} = turn, show_raw) do
    header = " Turn #{turn.number} "

    IO.puts(
      "\n#{ansi(:cyan)}+-#{header}#{String.duplicate("-", @box_width - 3 - String.length(header))}+#{ansi(:reset)}"
    )

    # Print raw response (reasoning) if requested
    if show_raw and turn.raw_response do
      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)} #{ansi(:bold)}Raw Response:#{ansi(:reset)}")

      turn.raw_response
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
  defp print_compressed_view(%Step{turns: turns, memory: memory}) do
    header = " Compressed View "

    IO.puts(
      "\n#{ansi(:cyan)}+-#{header}#{String.duplicate("-", @box_width - 3 - String.length(header))}+#{ansi(:reset)}"
    )

    # Use compression strategy to render what LLM would see
    messages =
      SingleUserCoalesced.to_messages(turns, memory,
        system_prompt: "(system prompt omitted)",
        mission: "(mission)",
        tools: %{},
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
  # Private Helpers - Legacy trace format (backward compat)
  # ============================================================

  defp print_legacy_turn(turn_entry, show_raw) do
    turn_num = Map.get(turn_entry, :turn, 0)
    program = Map.get(turn_entry, :program, "")
    result = Map.get(turn_entry, :result, nil)
    tool_calls = Map.get(turn_entry, :tool_calls, [])
    prints = Map.get(turn_entry, :prints, [])
    llm_response = Map.get(turn_entry, :llm_response)
    reasoning = Map.get(turn_entry, :reasoning)

    header = " Turn #{turn_num} "

    IO.puts(
      "\n#{ansi(:cyan)}+-#{header}#{String.duplicate("-", @box_width - 3 - String.length(header))}+#{ansi(:reset)}"
    )

    # Print raw response/reasoning if requested and available
    if show_raw do
      cond do
        llm_response ->
          IO.puts("#{ansi(:cyan)}|#{ansi(:reset)} #{ansi(:bold)}Raw Response:#{ansi(:reset)}")

          llm_response
          |> String.split("\n")
          |> Enum.each(fn line ->
            IO.puts(
              "#{ansi(:cyan)}|#{ansi(:reset)}   #{ansi(:dim)}#{truncate_line(line, 80)}#{ansi(:reset)}"
            )
          end)

          IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}")

        reasoning ->
          IO.puts("#{ansi(:cyan)}|#{ansi(:reset)} #{ansi(:bold)}Reasoning:#{ansi(:reset)}")

          reasoning
          |> String.split("\n")
          |> Enum.each(fn line ->
            IO.puts(
              "#{ansi(:cyan)}|#{ansi(:reset)}   #{ansi(:dim)}#{truncate_line(line, 80)}#{ansi(:reset)}"
            )
          end)

          IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}")

        true ->
          :ok
      end
    end

    IO.puts("#{ansi(:cyan)}|#{ansi(:reset)} #{ansi(:bold)}Program:#{ansi(:reset)}")

    # Print program with indentation
    program
    |> String.split("\n")
    |> Enum.each(fn line ->
      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}   #{truncate_line(line, 80)}")
    end)

    # Print tool calls if any
    unless Enum.empty?(tool_calls) do
      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)} #{ansi(:bold)}Tools:#{ansi(:reset)}")

      Enum.each(tool_calls, fn call ->
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
    unless Enum.empty?(prints) do
      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)} #{ansi(:bold)}Output:#{ansi(:reset)}")

      Enum.each(prints, fn line ->
        IO.puts(
          "#{ansi(:cyan)}|#{ansi(:reset)}   #{ansi(:yellow)}#{truncate_line(line, 80)}#{ansi(:reset)}"
        )
      end)
    end

    # Print result
    IO.puts("#{ansi(:cyan)}|#{ansi(:reset)} #{ansi(:bold)}Result:#{ansi(:reset)}")
    result_lines = format_result(result)

    Enum.each(result_lines, fn line ->
      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}   #{truncate_line(line, 80)}")
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

  # Get turn count from either turns or trace
  defp get_turn_count(%Step{turns: turns}) when is_list(turns), do: length(turns)
  defp get_turn_count(%Step{trace: trace}) when is_list(trace), do: length(trace)
  defp get_turn_count(_step), do: 0

  # ============================================================
  # Private Helpers - Formatting
  # ============================================================

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

    if usage[:total_tokens] do
      IO.puts(
        "#{ansi(:cyan)}|#{ansi(:reset)}   Total tokens:  #{format_number(usage.total_tokens)}"
      )
    end

    if usage[:system_prompt_tokens] && usage.system_prompt_tokens > 0 do
      IO.puts(
        "#{ansi(:cyan)}|#{ansi(:reset)}   System prompt: #{format_number(usage.system_prompt_tokens)} #{ansi(:dim)}(est.)#{ansi(:reset)}"
      )
    end

    if usage[:duration_ms] do
      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}   Duration:      #{usage.duration_ms}ms")
    end

    if usage[:turns] do
      IO.puts("#{ansi(:cyan)}|#{ansi(:reset)}   Turns:         #{usage.turns}")
    end

    IO.puts("#{ansi(:cyan)}+#{String.duplicate("-", @box_width - 2)}+#{ansi(:reset)}")
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
