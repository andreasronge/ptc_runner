defmodule Mix.Tasks.Ptc.Repl do
  @shortdoc "Interactive PTC-Lisp REPL with turn history (*1, *2, *3)"
  @moduledoc """
  Starts an interactive REPL for testing PTC-Lisp expressions.

  ## Usage

      mix ptc.repl                      # Interactive REPL (default)
      mix ptc.repl -e "(+ 1 2)"         # Eval and print result
      mix ptc.repl -e "(def x 1)" -e "(* x 2)"  # Chain evals (memory persists)
      mix ptc.repl script.clj           # Run script file
      mix ptc.repl -                    # Run from stdin

  ## Options

    * `-e, --eval` - Evaluate expression and print result (can be repeated)
    * `-h, --help` - Print this help

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
  alias PtcRunner.SubAgent.Loop.ResponseHandler

  @switches [eval: :keep, help: :boolean]
  @aliases [e: :eval, h: :help]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, _invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    cond do
      opts[:help] ->
        print_help()

      rest == ["-"] ->
        run_stdin()

      rest != [] ->
        run_file(hd(rest))

      opts[:eval] ->
        run_evals(Keyword.get_values(opts, :eval))

      true ->
        interactive_repl()
    end
  end

  defp print_help do
    IO.puts(@moduledoc)
  end

  defp run_stdin do
    case IO.read(:stdio, :eof) do
      {:error, reason} ->
        IO.puts(:stderr, "Error reading stdin: #{reason}")
        System.halt(1)

      source ->
        run_source(source)
    end
  end

  defp run_file(path) do
    case File.read(path) do
      {:ok, source} ->
        run_source(source)

      {:error, reason} ->
        IO.puts(:stderr, "Error reading #{path}: #{:file.format_error(reason)}")
        System.halt(1)
    end
  end

  defp run_evals(exprs) do
    # run_source halts on error, so we can use simple reduce
    Enum.reduce(exprs, %{}, fn expr, memory ->
      {:ok, new_memory} = run_source(expr, memory)
      new_memory
    end)
  end

  defp run_source(source, memory \\ %{}) do
    case PtcRunner.Lisp.run(source, memory: memory) do
      {:ok, step} ->
        IO.puts(Format.to_clojure(step.return))
        {:ok, step.memory}

      {:error, step} ->
        IO.puts(:stderr, format_error(step.fail))
        System.halt(1)
    end
  end

  defp interactive_repl do
    IO.puts("PTC-Lisp REPL (Ctrl+D or empty line to exit)")
    IO.puts("Turn history: *1, *2, *3 reference last 3 results\n")

    loop([], %{})
  end

  defp loop(history, memory) do
    case read_expression("ptc> ", "") do
      :eof ->
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
        :eof

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
        # Show truncated output exactly like LLM feedback sees
        IO.puts(ResponseHandler.format_execution_result(step.return))
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
