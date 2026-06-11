defmodule Mix.Tasks.Ptc.Repl do
  @shortdoc "Interactive PTC-Lisp REPL with turn history (*1, *2, *3)"
  @moduledoc """
  Starts an interactive REPL for testing PTC-Lisp expressions.

  ## Usage

      mix ptc.repl                      # Interactive REPL (default)
      mix ptc.repl -l user.clj          # Load user-code file, then interactive
      mix ptc.repl --prelude crm.clj    # Attach a deployment prelude
      mix ptc.repl --log-prelude        # Attach the built-in turn-log prelude
      mix ptc.repl --prelude crm.clj -e "(ns-publics 'crm)"
      mix ptc.repl --prelude crm.clj --show-prompt-inventory
      mix ptc.repl -e "(+ 1 2)"         # Eval and print result
      mix ptc.repl --upstreams-config upstreams.json -e "(tool/servers)"
      mix ptc.repl -e "(def x 1)" -e "(* x 2)"  # Chain evals (memory persists)
      mix ptc.repl script.clj           # Run script file
      mix ptc.repl -                    # Run from stdin

  ## Options

    * `-e, --eval` - Evaluate expression and print result (can be repeated)
    * `-l, --load` - Load file before entering interactive mode
    * `-p, --prelude` - Compile a deployment prelude file and attach it to every
      evaluation (protected namespaces, public exports, discovery). SEPARATE
      from `-l/--load`, which loads ordinary user code.
    * `--log-prelude` - Attach the built-in read-only `log/` introspection
      prelude to the REPL's default in-memory turn-log sink. Mutually exclusive
      with `--prelude` until general prelude composition is defined.
    * `--show-prompt-inventory` - Print the prelude's compact prompt inventory
      (the same rendering SubAgent execution injects) before evaluating.
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
  alias PtcRunner.Lisp.Prelude.Compiler, as: PreludeCompiler
  alias PtcRunner.Lisp.Prelude.PromptInventory
  alias PtcRunner.Lisp.Registry
  alias PtcRunner.SubAgent.Loop.ResponseHandler
  alias PtcRunner.TraceLog
  alias PtcRunner.TraceLog.{Analyzer, Introspection, MemorySink}
  alias PtcRunner.Upstream.Eval, as: UpstreamEval
  alias PtcRunner.Upstream.Runtime, as: UpstreamRuntime

  @switches [
    eval: :keep,
    load: :string,
    prelude: :string,
    log_prelude: :boolean,
    show_prompt_inventory: :boolean,
    help: :boolean,
    upstreams_config: :string,
    max_tool_calls: :integer,
    max_catalog_ops: :integer,
    upstream_call_timeout_ms: :integer,
    max_upstream_response_bytes: :integer,
    catalog_mode: :string,
    catalog_snapshot_mode: :string
  ]
  @aliases [e: :eval, l: :load, p: :prelude, h: :help]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, _invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    # `--help` must stay side-effect-free: load the prelude (and print the
    # inventory) only AFTER ruling out help, so `--help --prelude missing.clj`
    # shows help instead of raising a file error.
    if opts[:help] do
      print_help()
    else
      validate_prelude_opts!(opts)
      prelude = load_prelude(opts)
      if opts[:show_prompt_inventory], do: print_prompt_inventory(prelude)

      # Each run drives a `PtcRunner.Session` (the canonical external turn
      # driver, plan D1): it owns memory + `*1/*2/*3` history and emits a turn
      # event per eval. A default in-memory turn-log sink is enabled so
      # "analyze my last session" (`:turns`) works with no filesystem setup.
      with_session = fn fun ->
        with_upstream_runtime(opts, fn runtime ->
          {:ok, sink} = TraceLog.start_memory_sink()
          fun.(build_session(runtime, prelude, sink, opts))
        end)
      end

      cond do
        rest == ["-"] ->
          with_session.(&run_stdin/1)

        rest != [] ->
          with_session.(&run_file(hd(rest), &1))

        opts[:eval] ->
          with_session.(&run_evals(Keyword.get_values(opts, :eval), &1))

        opts[:load] ->
          with_session.(&load_and_repl(opts[:load], &1))

        true ->
          with_session.(&interactive_repl/1)
      end
    end
  end

  # Builds the session that owns REPL state for this run. The optional upstream
  # runtime and compiled prelude are bound here so every eval attaches the SAME
  # artifact (the prelude rides as a default run option).
  defp build_session(runtime, prelude, sink, opts) do
    opts =
      cond do
        prelude ->
          [prelude: prelude]

        opts[:log_prelude] ->
          [
            prelude: compile_introspection_prelude!(),
            tools: Introspection.tools(sink)
          ]

        true ->
          []
      end

    PtcRunner.Session.new([upstream_runtime: runtime] ++ opts)
  end

  defp compile_introspection_prelude! do
    case PreludeCompiler.compile(Introspection.prelude_source()) do
      {:ok, prelude} ->
        prelude

      {:error, error} ->
        Mix.raise("Built-in log/ prelude compile error (#{error.reason}): #{error.message}")
    end
  end

  defp validate_prelude_opts!(opts) do
    if opts[:prelude] && opts[:log_prelude] do
      Mix.raise("--log-prelude is mutually exclusive with --prelude")
    end
  end

  @doc """
  Compiles a deployment prelude source file into a
  `%PtcRunner.Lisp.Prelude{}` artifact — the SAME compiler, protected-namespace
  tables, and export records SubAgent execution uses. Raises `Mix.Error` on a
  missing file or a prelude compile/validation failure.
  """
  @spec compile_prelude!(Path.t()) :: PtcRunner.Lisp.Prelude.t()
  def compile_prelude!(path) do
    source =
      case File.read(path) do
        {:ok, source} ->
          source

        {:error, reason} ->
          Mix.raise("Error reading prelude #{path}: #{:file.format_error(reason)}")
      end

    case PreludeCompiler.compile(source) do
      {:ok, prelude} ->
        prelude

      {:error, error} ->
        Mix.raise("Prelude compile error (#{error.reason}): #{error.message}")
    end
  end

  defp load_prelude(opts) do
    case opts[:prelude] do
      nil -> nil
      path -> compile_prelude!(path)
    end
  end

  defp print_prompt_inventory(nil), do: :ok

  defp print_prompt_inventory(prelude) do
    case PromptInventory.render(prelude) do
      nil -> :ok
      text -> IO.puts(text <> "\n")
    end
  end

  defp print_help do
    IO.puts(@moduledoc)
  end

  defp run_stdin(session) do
    case IO.read(:stdio, :eof) do
      {:error, reason} ->
        IO.puts(:stderr, "Error reading stdin: #{reason}")
        System.halt(1)

      source ->
        run_source(source, session)
    end
  end

  defp run_file(path, session) do
    case File.read(path) do
      {:ok, source} ->
        run_source(source, session)

      {:error, reason} ->
        IO.puts(:stderr, "Error reading #{path}: #{:file.format_error(reason)}")
        System.halt(1)
    end
  end

  defp run_evals(exprs, session) do
    # run_source halts on error, so we can use a simple reduce over sessions.
    Enum.reduce(exprs, session, fn expr, sess ->
      {:ok, next} = run_source(expr, sess)
      next
    end)
  end

  defp run_source(source, session) do
    case PtcRunner.Session.eval(session, source) do
      {{:ok, step}, session} ->
        print_captured_output(step.prints)
        {output, _truncated?} = Format.to_clojure(step.return)
        IO.puts(output)
        {:ok, session}

      {{:error, step}, _session} ->
        IO.puts(:stderr, format_error(step.fail))
        System.halt(1)
    end
  end

  defp interactive_repl(session) do
    IO.puts("PTC-Lisp REPL (Ctrl+D to exit)")
    IO.puts("Type :help for commands, :doc <name> for function docs\n")

    loop(session)
  end

  defp load_and_repl(path, session) do
    case File.read(path) do
      {:ok, source} ->
        case PtcRunner.Session.eval(session, source) do
          {{:ok, step}, session} ->
            print_captured_output(step.prints)
            IO.puts("Loaded #{path}")
            IO.puts("PTC-Lisp REPL (Ctrl+D to exit)")
            IO.puts("Type :help for commands, :doc <name> for function docs\n")
            loop(session)

          {{:error, step}, _session} ->
            IO.puts(:stderr, format_error(step.fail))
            System.halt(1)
        end

      {:error, reason} ->
        IO.puts(:stderr, "Error reading #{path}: #{:file.format_error(reason)}")
        System.halt(1)
    end
  end

  defp loop(session) do
    case read_expression("ptc> ", "") do
      :eof ->
        IO.puts("\nGoodbye!")

      "" ->
        # Ignore empty lines, only Ctrl+D exits
        loop(session)

      ":" <> meta ->
        handle_meta(String.trim(meta), session)
        loop(session)

      input ->
        loop(evaluate(input, session))
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

  defp evaluate(input, session) do
    case PtcRunner.Session.eval(session, input) do
      {{:ok, step}, session} ->
        # Show truncated output exactly like LLM feedback sees
        print_captured_output(step.prints)
        {output, _truncated?} = ResponseHandler.format_execution_result(step.return)
        IO.puts(output)
        session

      {{:error, step}, session} ->
        IO.puts(format_error(step.fail))
        session
    end
  end

  defp print_captured_output([]), do: :ok

  defp print_captured_output(prints) do
    Enum.each(prints, &IO.puts/1)
  end

  defp handle_meta("help", _session) do
    IO.puts("""
    Commands:
      :doc <name>      Show documentation for a function
      :find <pattern>  Search functions by name or description
      :apropos <pat>   Alias for :find
      :tools           Show configured upstream tools
      :turns           Summarize recorded turns (this REPL session)
      :help            Show this help

    Turn history: *1, *2, *3 reference last 3 results
    Ctrl+D to exit
    """)
  end

  defp handle_meta("doc " <> name, session) do
    case Registry.doc(String.trim(name)) do
      nil -> print_upstream_doc(String.trim(name), session.upstream_runtime)
      entry -> print_doc(entry)
    end
  end

  defp handle_meta("find " <> pattern, session),
    do: print_search_results(String.trim(pattern), session.upstream_runtime)

  defp handle_meta("apropos " <> pattern, session),
    do: print_search_results(String.trim(pattern), session.upstream_runtime)

  defp handle_meta("tools", session), do: print_tools(session.upstream_runtime)

  defp handle_meta("turns", _session), do: print_turns()

  defp handle_meta(_, _session) do
    IO.puts(
      "Unknown command. Available: :doc <name>, :find <pattern>, :apropos <pattern>, :tools, :turns"
    )
  end

  defp print_tools(nil), do: IO.puts("No upstream runtime configured")
  defp print_tools(runtime), do: IO.puts(UpstreamRuntime.catalog_text(runtime))

  # Summarize the in-memory turn log enabled by default for this REPL run. This
  # is the "analyze my last session" affordance — turn records with no
  # filesystem setup (plan P2).
  defp print_turns do
    case TraceLog.active_memory_sinks() do
      [] ->
        IO.puts("No turn-log sink active")

      [sink | _] ->
        case Analyzer.sessions(MemorySink.events(sink)) do
          [] ->
            IO.puts("No turns recorded yet")

          summaries ->
            Enum.each(summaries, fn s ->
              IO.puts(
                "  #{s.correlation_id} (#{s.driver}): #{s.turns} turns, " <>
                  "#{s.committed} committed, #{s.failed} failed, #{s.tool_calls} tool calls"
              )
            end)
        end
    end
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

  # `session` is `{runtime, prelude}`. The prelude artifact is attached to every
  # evaluation via the same `:prelude` opt SubAgent execution uses. With an
  # upstream runtime present, also pass `:runtime` so attach-time `requires`
  # validation runs against it.
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
