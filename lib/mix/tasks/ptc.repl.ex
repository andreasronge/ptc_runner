defmodule Mix.Tasks.Ptc.Repl do
  @shortdoc "Interactive PTC-Lisp REPL with turn history (*1, *2, *3)"
  @moduledoc """
  Starts an interactive REPL for testing PTC-Lisp expressions.

  ## Usage

      mix ptc.repl                      # Interactive REPL (default)
      mix ptc.repl -l prelude.clj       # Load file, then interactive
      mix ptc.repl -e "(+ 1 2)"         # Eval and print result
      mix ptc.repl --upstreams-config upstreams.json -e "(tool/servers)"
      mix ptc.repl -e "(def x 1)" -e "(* x 2)"  # Chain evals (memory persists)
      mix ptc.repl script.clj           # Run script file
      mix ptc.repl -                    # Run from stdin

  ## Options

    * `-e, --eval` - Evaluate expression and print result (can be repeated)
    * `-l, --load` - Load file before entering interactive mode
    * `--upstreams-config` - Root upstream JSON config path
      (or `PTC_RUNNER_UPSTREAMS`)
    * `--max-tool-calls` - Per-evaluation `tool/call` cap
    * `--max-catalog-ops` - Per-evaluation discovery form cap
    * `--upstream-call-timeout-ms` - Per-upstream-call timeout
    * `--max-upstream-response-bytes` - Per-upstream response cap
    * `--catalog-mode` - Catalog exposure mode: `auto`, `inline`, or `lazy`
    * `--catalog-snapshot-mode` - Catalog snapshot mode: `live` or `frozen`
    * `-h, --help` - Print this help

  ## Features

  - Evaluate PTC-Lisp expressions interactively
  - Multi-line input: continues prompting until parens are balanced
  - Turn history: `*1`, `*2`, `*3` reference last 3 results
  - Memory persists between evaluations
  - Optional upstream runtime for `(tool/call ...)`, `(tool/servers)`,
    `dir`, `doc`, `meta`, and `apropos`
  - Exit with Ctrl+D

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
  alias PtcRunner.Lisp.Registry
  alias PtcRunner.SubAgent.Loop.ResponseHandler
  alias PtcRunner.Upstream.Eval, as: UpstreamEval
  alias PtcRunner.Upstream.Runtime, as: UpstreamRuntime

  @switches [
    eval: :keep,
    load: :string,
    help: :boolean,
    upstreams_config: :string,
    max_tool_calls: :integer,
    max_catalog_ops: :integer,
    upstream_call_timeout_ms: :integer,
    max_upstream_response_bytes: :integer,
    catalog_mode: :string,
    catalog_snapshot_mode: :string
  ]
  @aliases [e: :eval, l: :load, h: :help]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, _invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    cond do
      opts[:help] ->
        print_help()

      rest == ["-"] ->
        with_upstream_runtime(opts, &run_stdin(&1))

      rest != [] ->
        with_upstream_runtime(opts, &run_file(hd(rest), &1))

      opts[:eval] ->
        with_upstream_runtime(opts, &run_evals(Keyword.get_values(opts, :eval), &1))

      opts[:load] ->
        with_upstream_runtime(opts, &load_and_repl(opts[:load], &1))

      true ->
        with_upstream_runtime(opts, &interactive_repl(&1))
    end
  end

  defp print_help do
    IO.puts(@moduledoc)
  end

  defp run_stdin(runtime) do
    case IO.read(:stdio, :eof) do
      {:error, reason} ->
        IO.puts(:stderr, "Error reading stdin: #{reason}")
        System.halt(1)

      source ->
        run_source(source, %{}, runtime)
    end
  end

  defp run_file(path, runtime) do
    case File.read(path) do
      {:ok, source} ->
        run_source(source, %{}, runtime)

      {:error, reason} ->
        IO.puts(:stderr, "Error reading #{path}: #{:file.format_error(reason)}")
        System.halt(1)
    end
  end

  defp run_evals(exprs, runtime) do
    # run_source halts on error, so we can use simple reduce
    Enum.reduce(exprs, %{}, fn expr, memory ->
      {:ok, new_memory} = run_source(expr, memory, runtime)
      new_memory
    end)
  end

  defp run_source(source, memory, runtime) do
    case run_lisp(source, [memory: memory], runtime) do
      {:ok, step} ->
        print_captured_output(step.prints)
        {output, _truncated?} = Format.to_clojure(step.return)
        IO.puts(output)
        {:ok, step.memory}

      {:error, step} ->
        IO.puts(:stderr, format_error(step.fail))
        System.halt(1)
    end
  end

  defp interactive_repl(runtime) do
    IO.puts("PTC-Lisp REPL (Ctrl+D to exit)")
    IO.puts("Type :help for commands, :doc <name> for function docs\n")

    loop([], %{}, runtime)
  end

  defp load_and_repl(path, runtime) do
    case File.read(path) do
      {:ok, source} ->
        case run_lisp(source, [], runtime) do
          {:ok, step} ->
            print_captured_output(step.prints)
            IO.puts("Loaded #{path}")
            IO.puts("PTC-Lisp REPL (Ctrl+D to exit)")
            IO.puts("Type :help for commands, :doc <name> for function docs\n")
            loop([], step.memory, runtime)

          {:error, step} ->
            IO.puts(:stderr, format_error(step.fail))
            System.halt(1)
        end

      {:error, reason} ->
        IO.puts(:stderr, "Error reading #{path}: #{:file.format_error(reason)}")
        System.halt(1)
    end
  end

  defp loop(history, memory, runtime) do
    case read_expression("ptc> ", "") do
      :eof ->
        IO.puts("\nGoodbye!")

      "" ->
        # Ignore empty lines, only Ctrl+D exits
        loop(history, memory, runtime)

      ":" <> meta ->
        handle_meta(String.trim(meta), runtime)
        loop(history, memory, runtime)

      input ->
        {history, memory} = evaluate(input, history, memory, runtime)
        loop(history, memory, runtime)
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

  defp evaluate(input, history, memory, runtime) do
    case run_lisp(input, [turn_history: history, memory: memory], runtime) do
      {:ok, step} ->
        # Show truncated output exactly like LLM feedback sees
        print_captured_output(step.prints)
        {output, _truncated?} = ResponseHandler.format_execution_result(step.return)
        IO.puts(output)
        new_history = (history ++ [step.return]) |> Enum.take(-3)
        {new_history, step.memory}

      {:error, step} ->
        IO.puts(format_error(step.fail))
        {history, memory}
    end
  end

  defp print_captured_output([]), do: :ok

  defp print_captured_output(prints) do
    Enum.each(prints, &IO.puts/1)
  end

  defp handle_meta("help", _runtime) do
    IO.puts("""
    Commands:
      :doc <name>      Show documentation for a function
      :find <pattern>  Search functions by name or description
      :apropos <pat>   Alias for :find
      :tools           Show configured upstream tools
      :help            Show this help

    Turn history: *1, *2, *3 reference last 3 results
    Ctrl+D to exit
    """)
  end

  defp handle_meta("doc " <> name, runtime) do
    case Registry.doc(String.trim(name)) do
      nil -> print_upstream_doc(String.trim(name), runtime)
      entry -> print_doc(entry)
    end
  end

  defp handle_meta("find " <> pattern, runtime),
    do: print_search_results(String.trim(pattern), runtime)

  defp handle_meta("apropos " <> pattern, runtime),
    do: print_search_results(String.trim(pattern), runtime)

  defp handle_meta("tools", nil), do: IO.puts("No upstream runtime configured")

  defp handle_meta("tools", runtime) do
    IO.puts(UpstreamRuntime.catalog_text(runtime))
  end

  defp handle_meta(_, _runtime) do
    IO.puts(
      "Unknown command. Available: :doc <name>, :find <pattern>, :apropos <pattern>, :tools"
    )
  end

  defp print_doc(entry) do
    IO.puts("-------------------------")
    IO.puts(Enum.join(entry.signatures, "\n"))
    IO.puts("  #{entry.description}")
    if entry.notes, do: IO.puts("\n  #{entry.notes}")

    if entry.examples != [] do
      IO.puts("\nExamples:")

      Enum.each(entry.examples, fn {code, result} ->
        IO.puts("  #{code}")
        IO.puts("  ;; => #{result}")
      end)
    end

    if entry.see_also != [] do
      IO.puts("\nSee also: #{Enum.join(entry.see_also, ", ")}")
    end

    IO.puts("-------------------------")
  end

  defp print_search_results(pattern, runtime) do
    case Registry.find_doc(pattern) do
      [] ->
        print_upstream_apropos(pattern, runtime)

      results ->
        Enum.each(results, fn entry ->
          sigs = Enum.join(entry.signatures, " | ")
          IO.puts("  #{entry.name} — #{sigs}")
          if entry.description != "", do: IO.puts("    #{entry.description}")
        end)

        IO.puts("\n#{length(results)} result(s)")
    end
  end

  defp format_error(%{reason: reason, message: message}) do
    reason_str = reason |> to_string() |> String.replace("_", " ")
    "Error (#{reason_str}): #{message}"
  end

  defp run_lisp(source, opts, nil), do: PtcRunner.Lisp.run(source, opts)

  defp run_lisp(source, opts, runtime) do
    UpstreamEval.run_lisp(runtime, source, opts)
  end

  defp with_upstream_runtime(opts, fun) do
    case upstream_runtime_opts(opts) do
      nil ->
        fun.(nil)

      runtime_opts ->
        case UpstreamRuntime.start_link(runtime_opts) do
          {:ok, runtime} ->
            try do
              fun.(runtime)
            after
              UpstreamRuntime.stop(runtime)
            end

          {:error, reason} ->
            IO.puts(:stderr, "Error starting upstream runtime: #{inspect(reason)}")
            System.halt(1)
        end
    end
  end

  defp upstream_runtime_opts(opts) do
    config_path = opts[:upstreams_config] || System.get_env("PTC_RUNNER_UPSTREAMS")

    if config_path do
      [
        config_path: config_path,
        catalog_exposure_mode: mode(opts[:catalog_mode], [:auto, :inline, :lazy], :auto),
        catalog_snapshot_mode: mode(opts[:catalog_snapshot_mode], [:frozen, :live], :live)
      ]
      |> maybe_put(:max_tool_calls, opts[:max_tool_calls])
      |> maybe_put(:max_catalog_ops, opts[:max_catalog_ops])
      |> maybe_put(:call_timeout_ms, opts[:upstream_call_timeout_ms])
      |> maybe_put(:max_response_bytes, opts[:max_upstream_response_bytes])
    end
  end

  defp mode(nil, _allowed, default), do: default

  defp mode(value, allowed, default) do
    Enum.find(allowed, default, &(Atom.to_string(&1) == value))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp print_upstream_doc(name, nil), do: IO.puts("No documentation found for: #{name}")

  defp print_upstream_doc(name, runtime) do
    ref = if String.contains?(name, "/"), do: name, else: nil

    if ref do
      case discovery_once(runtime, :doc, [ref]) do
        {:ok, text} -> IO.puts(text)
        _ -> IO.puts("No documentation found for: #{name}")
      end
    else
      IO.puts("No documentation found for: #{name}")
    end
  end

  defp print_upstream_apropos(pattern, nil), do: IO.puts("No matches for: #{pattern}")

  defp print_upstream_apropos(pattern, runtime) do
    case discovery_once(runtime, :apropos, [pattern]) do
      {:ok, []} ->
        IO.puts("No matches for: #{pattern}")

      {:ok, lines} ->
        Enum.each(lines, &IO.puts("  #{&1}"))
        IO.puts("\n#{length(lines)} upstream result(s)")

      _ ->
        IO.puts("No matches for: #{pattern}")
    end
  end

  defp discovery_once(runtime, operation, args) do
    {result, _records} =
      UpstreamEval.with_run_context(runtime, [], fn context ->
        exec = UpstreamEval.eval_options(context)[:discovery_exec]
        exec.(operation, args)
      end)

    result
  end
end
