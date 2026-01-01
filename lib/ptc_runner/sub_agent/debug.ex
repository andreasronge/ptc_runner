defmodule PtcRunner.SubAgent.Debug do
  @moduledoc """
  Debug helpers for visualizing SubAgent execution.

  Provides functions to pretty-print execution traces and agent chains,
  making it easier to understand what happened during agent execution.

  ## Examples

      iex> {:ok, step} = PtcRunner.SubAgent.run(agent, llm: llm, context: %{}, debug: true)
      iex> PtcRunner.SubAgent.Debug.print_trace(step)
      # Prints formatted trace to stdout

      iex> steps = [step1, step2, step3]
      iex> PtcRunner.SubAgent.Debug.print_chain(steps)
      # Prints chained execution flow

  """

  alias PtcRunner.Step

  @box_width 60

  @doc """
  Pretty-print a SubAgent execution trace.

  Displays each turn with its prompt, program, tool calls, and results
  in a formatted box-drawing style.

  ## Parameters

  - `step` - A `%Step{}` struct with trace data

  ## Examples

      iex> {:ok, step} = PtcRunner.SubAgent.run(agent, llm: llm, context: %{user: "alice"})
      iex> PtcRunner.SubAgent.Debug.print_trace(step)
      :ok

  """
  @spec print_trace(Step.t()) :: :ok
  def print_trace(%Step{trace: nil}) do
    IO.puts("No trace available (trace disabled or not yet executed)")
    :ok
  end

  def print_trace(%Step{trace: []}) do
    IO.puts("Empty trace")
    :ok
  end

  def print_trace(%Step{trace: trace}) when is_list(trace) do
    Enum.each(trace, &print_turn/1)
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

    # Print result
    IO.puts("#{ansi(:cyan)}│#{ansi(:reset)} #{ansi(:bold)}Result:#{ansi(:reset)}")
    result_lines = format_result(result)

    Enum.each(result_lines, fn line ->
      IO.puts("#{ansi(:cyan)}│#{ansi(:reset)}   #{truncate_line(line, 80)}")
    end)

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
      formatted = inspect(result, pretty: true, limit: 5, width: 80)

      if String.length(formatted) > 200 do
        [String.slice(formatted, 0, 197) <> "..."]
      else
        String.split(formatted, "\n")
      end
    end
  end

  defp format_result(result) when is_list(result) do
    formatted = inspect(result, pretty: true, limit: 5, width: 80)

    if String.length(formatted) > 200 do
      [String.slice(formatted, 0, 197) <> "..."]
    else
      String.split(formatted, "\n")
    end
  end

  defp format_result(result) do
    formatted = inspect(result, pretty: true, limit: 5, width: 80)
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
        inspect(data, limit: 3, pretty: false, width: 60)
      end
    end
  end

  defp format_compact(data) when is_list(data) do
    cond do
      data == [] ->
        "[]"

      length(data) <= 3 ->
        inspect(data, limit: 3, pretty: false, width: 60)

      true ->
        sample = Enum.take(data, 3) |> inspect(limit: 3, pretty: false)
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
    formatted = inspect(data, limit: 3, pretty: false, width: 60)

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

  # ANSI color helpers
  defp ansi(:reset), do: IO.ANSI.reset()
  defp ansi(:cyan), do: IO.ANSI.cyan()
  defp ansi(:green), do: IO.ANSI.green()
  defp ansi(:red), do: IO.ANSI.red()
  defp ansi(:bold), do: IO.ANSI.bright()
  defp ansi(:dim), do: IO.ANSI.faint()
end
