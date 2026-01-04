defmodule Mix.Tasks.Ptc.Repl do
  @shortdoc "Interactive PTC-Lisp REPL with turn history (*1, *2, *3)"
  @moduledoc """
  Starts an interactive REPL for testing PTC-Lisp expressions.

  ## Usage

      mix ptc.repl

  ## Features

  - Evaluate PTC-Lisp expressions interactively
  - Multi-line input: continues prompting until parens are balanced
  - Turn history: `*1`, `*2`, `*3` reference last 3 results
  - Memory persists between evaluations
  - Exit with Ctrl+D or empty line

  ## Example Session

      ptc> (+ 1 2)
      3
      ptc> (* *1 10)
      30
      ptc> {:sum *1, :product *2}
      %{sum: 30, product: 30}
  """

  use Mix.Task

  alias PtcRunner.Lisp.Format

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    IO.puts("PTC-Lisp REPL (Ctrl+D or empty line to exit)")
    IO.puts("Turn history: *1, *2, *3 reference last 3 results\n")

    loop([], %{})
  end

  defp loop(history, memory) do
    case read_expression("ptc> ", "") do
      nil ->
        IO.puts("\nGoodbye!")

      "" ->
        IO.puts("Goodbye!")

      input ->
        {history, memory} = evaluate(input, history, memory)
        loop(history, memory)
    end
  end

  defp read_expression(prompt, buffer) do
    case IO.gets(prompt) do
      :eof ->
        nil

      line ->
        combined = buffer <> line

        if balanced?(combined) do
          String.trim(combined)
        else
          read_expression("...> ", combined)
        end
    end
  end

  defp balanced?(str) do
    str
    |> String.graphemes()
    |> Enum.reduce_while(0, fn
      _, n when n < 0 -> {:halt, -1}
      "(", n -> {:cont, n + 1}
      ")", n -> {:cont, n - 1}
      _, n -> {:cont, n}
    end)
    |> Kernel.==(0)
  end

  defp evaluate(input, history, memory) do
    case PtcRunner.Lisp.run(input, turn_history: history, memory: memory) do
      {:ok, step} ->
        IO.puts(Format.to_string(step.return, pretty: true))
        new_history = (history ++ [step.return]) |> Enum.take(-3)
        {new_history, step.memory}

      {:error, step} ->
        IO.puts(format_error(step.fail))
        {history, memory}
    end
  end

  defp format_error(%{reason: reason, message: message}) do
    reason_str = reason |> to_string() |> String.replace("_", " ")
    "Error (#{reason_str}): #{message}"
  end
end
