defmodule Mix.Tasks.Ptc.Repl do
  @shortdoc "Direct bounded PTC-Lisp REPL"
  @moduledoc """
  Starts the direct Kernel PTC-Lisp REPL.

      mix ptc.repl
      mix ptc.repl -e "(+ 1 2)" -e "(+ *1 3)"
      mix ptc.repl -l setup.lisp
      mix ptc.repl script.lisp
      mix ptc.repl -
      mix ptc.repl --manifest ptc.json
      mix ptc.repl --manifest ptc.json --trace trace.jsonl

  Options:

    * `-e, --eval` — evaluate an expression; repeat to preserve definitions and
      `*1`/`*2`/`*3` history;
    * `-l, --load` — evaluate a setup file before expressions or interaction;
    * `-m, --manifest` — reuse a strict Kernel manifest's workflow bundle,
      capabilities, limits, input, labels, and event policy;
    * `-t, --trace` — append this session's canonical events to a JSONL file;
    * `-h, --help` — print this help without loading files or providers.

  A positional file runs as one script. `-` reads one script from standard
  input. With no script or `--eval`, the task starts an interactive multi-line
  REPL. Ctrl+D exits.
  """

  use Mix.Task

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Lisp.Format
  alias PtcRunner.Lisp.Registry

  @switches [
    eval: :keep,
    load: :string,
    manifest: :string,
    trace: :string,
    help: :boolean
  ]
  @aliases [e: :eval, l: :load, m: :manifest, t: :trace, h: :help]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, arguments, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("invalid ptc.repl options: #{inspect(invalid)}")

      length(arguments) > 1 ->
        Mix.raise("usage: mix ptc.repl [OPTIONS] [SCRIPT|-]")

      opts[:eval] && arguments != [] ->
        Mix.raise("cannot combine --eval with a script or stdin")

      true ->
        run_session(opts, arguments)
    end
  end

  defp run_session(opts, arguments) do
    with {:ok, config} <- load_config(opts[:manifest]),
         {:ok, session} <- ReplSession.new(config: config) do
      try do
        outcome = evaluate_mode(session, opts, arguments)
        finish(outcome, opts[:trace])
      rescue
        exception ->
          ReplSession.abort(session, :frontend_exception)
          reraise exception, __STACKTRACE__
      catch
        kind, reason ->
          ReplSession.abort(session, :frontend_exit)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    else
      {:error, reason} -> Mix.raise("ptc.repl setup failed: #{inspect(reason)}")
    end
  end

  defp load_config(nil), do: {:ok, nil}

  defp load_config(path) do
    with {:ok, registry} <- ProviderRegistry.new(),
         {:ok, built} <- RunBuilder.load_and_build(path, registry),
         do: {:ok, built.config}
  end

  defp evaluate_mode(session, opts, arguments) do
    with {:ok, session} <- maybe_load(session, opts[:load]) do
      cond do
        opts[:eval] -> run_sources(session, Keyword.get_values(opts, :eval))
        arguments == ["-"] -> read_stdin(session)
        arguments != [] -> run_file(session, hd(arguments))
        true -> interactive(session)
      end
    end
  end

  defp maybe_load(session, nil), do: {:ok, session}

  defp maybe_load(session, path) do
    with {:ok, source} <- File.read(path),
         {:ok, _step, session} <- evaluate(session, source, :noninteractive) do
      Mix.shell().info("Loaded #{path}")
      {:ok, session}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason, session}
      {:error, step, session} -> {:error, step, session}
    end
  end

  defp run_sources(session, sources) do
    Enum.reduce_while(sources, {:ok, session}, fn source, {:ok, current} ->
      case evaluate(current, source, :noninteractive) do
        {:ok, _step, next} -> {:cont, {:ok, next}}
        {:error, step, next} -> {:halt, {:error, step, next}}
      end
    end)
  end

  defp read_stdin(session) do
    case IO.read(:stdio, :eof) do
      source when is_binary(source) -> evaluate_outcome(session, source)
      :eof -> {:ok, session}
      {:error, reason} -> {:error, reason, session}
    end
  end

  defp run_file(session, path) do
    case File.read(path) do
      {:ok, source} -> evaluate_outcome(session, source)
      {:error, reason} -> {:error, reason, session}
    end
  end

  defp evaluate_outcome(session, source) do
    case evaluate(session, source, :noninteractive) do
      {:ok, _step, session} -> {:ok, session}
      {:error, step, session} -> {:error, step, session}
    end
  end

  defp interactive(session) do
    Mix.shell().info("PTC-Lisp REPL (Ctrl+D to exit; :help for commands)\n")
    loop(session)
  end

  defp loop(session) do
    case read_expression("ptc> ", "") do
      :eof ->
        Mix.shell().info("\nGoodbye!")
        {:ok, session}

      "" ->
        loop(session)

      ":" <> command ->
        handle_command(String.trim(command), session)
        loop(session)

      source ->
        case evaluate(session, source, :interactive) do
          {:ok, _step, next} -> loop(next)
          {:error, _step, next} -> loop(next)
        end
    end
  end

  defp read_expression(prompt, buffer) do
    case IO.gets(prompt) do
      :eof ->
        :eof

      line ->
        source = buffer <> line
        if balanced?(source), do: String.trim(source), else: read_expression("...> ", source)
    end
  end

  defp balanced?(source) do
    source
    |> String.graphemes()
    |> Enum.reduce_while({0, false, false}, fn
      _char, {depth, _quoted?, _escaped?} when depth < 0 -> {:halt, {-1, false, false}}
      "\\", {depth, true, false} -> {:cont, {depth, true, true}}
      _char, {depth, true, true} -> {:cont, {depth, true, false}}
      "\"", {depth, quoted?, false} -> {:cont, {depth, not quoted?, false}}
      "(", {depth, false, false} -> {:cont, {depth + 1, false, false}}
      ")", {depth, false, false} -> {:cont, {depth - 1, false, false}}
      _char, state -> {:cont, state}
    end)
    |> case do
      {0, false, false} -> true
      _state -> false
    end
  end

  defp evaluate(session, source, mode) do
    case ReplSession.eval(session, source) do
      {:ok, step, next} ->
        print_step(step)
        {:ok, step, next}

      {:error, step, next} ->
        message = format_error(step)
        if mode == :interactive, do: Mix.shell().info(message), else: Mix.shell().error(message)
        {:error, step, next}
    end
  end

  defp print_step(step) do
    Enum.each(step.prints, fn line -> Mix.shell().info(line) end)
    {formatted, _truncated?} = Format.to_clojure(step.return)
    Mix.shell().info(formatted)
  end

  defp format_error(%{fail: %{reason: reason, message: message}}),
    do: "Error (#{reason}): #{message}"

  defp finish({:ok, session}, trace_path) do
    persist_and_stop(session, trace_path)
  end

  defp finish({:error, %{} = step, session}, trace_path) do
    persist_and_stop(session, trace_path)
    Mix.raise(format_error(step))
  end

  defp finish({:error, reason, session}, trace_path) do
    persist_and_stop(session, trace_path)
    Mix.raise("ptc.repl failed: #{inspect(reason)}")
  end

  defp persist_and_stop(session, trace_path) do
    private? = EventSink.policy(session.config.event_sink) == :private

    with {:ok, events} <- ReplSession.close(session),
         :ok <- persist_trace(trace_path, events, private?) do
      :ok
    else
      {:error, reason} -> Mix.raise("ptc.repl trace failed: #{inspect(reason)}")
    end
  end

  defp persist_trace(nil, _events, _private?), do: :ok

  defp persist_trace(path, events, private?) do
    TraceLog.append_jsonl(path, events, private: private?)
  end

  defp handle_command("help", _session) do
    Mix.shell().info("""
    Commands:
      :doc <name>      Show core function documentation
      :find <pattern>  Search core functions
      :help            Show this help

    Successful results and definitions persist. *1, *2, and *3 read recent results.
    """)
  end

  defp handle_command("doc " <> name, _session) do
    case Registry.doc(String.trim(name)) do
      nil -> Mix.shell().info("No documentation found for: #{String.trim(name)}")
      entry -> Mix.shell().info(Enum.join(entry.signatures, "\n") <> "\n  " <> entry.description)
    end
  end

  defp handle_command("find " <> pattern, _session) do
    pattern
    |> String.trim()
    |> Registry.find_doc()
    |> Enum.each(fn entry ->
      Mix.shell().info("#{entry.name} — #{Enum.join(entry.signatures, " | ")}")
    end)
  end

  defp handle_command(_command, _session),
    do: Mix.shell().info("Unknown command. Available: :doc <name>, :find <pattern>, :help")
end
