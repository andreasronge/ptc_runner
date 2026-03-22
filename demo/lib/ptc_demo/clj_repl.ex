defmodule PtcDemo.CljRepl do
  @moduledoc """
  Long-lived Clojure REPL process for executing PTC-Lisp programs.

  Starts a `clj` process, loads a prelude with tool stubs and data bindings,
  then accepts expressions via `eval/2` and returns results.

  Uses a sentinel protocol: after each expression, a unique marker is printed
  so we can reliably detect where output ends.
  """

  use GenServer

  require Logger

  @sentinel "::PTC_SENTINEL::"
  @startup_timeout 30_000
  @eval_timeout 10_000

  # --- Public API ---

  def start_link(opts \\ []) do
    prelude = Keyword.get(opts, :prelude, default_prelude_path())
    GenServer.start_link(__MODULE__, %{prelude: prelude}, name: __MODULE__)
  end

  def stop do
    GenServer.stop(__MODULE__)
  end

  @doc "Evaluate a Clojure expression and return the cleaned output."
  def eval(expr, timeout \\ @eval_timeout) do
    GenServer.call(__MODULE__, {:eval, expr}, timeout + 5_000)
  end

  @doc "Evaluate and return raw output including REPL prompts."
  def eval_raw(expr, timeout \\ @eval_timeout) do
    GenServer.call(__MODULE__, {:eval_raw, expr}, timeout + 5_000)
  end

  @doc "Run a multi-turn REPL session. Takes a list of expressions, returns list of outputs."
  def session(expressions) when is_list(expressions) do
    Enum.map(expressions, &eval/1)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(%{prelude: prelude}) do
    port =
      Port.open({:spawn, "clj -M"}, [
        :binary,
        :use_stdio,
        :stderr_to_stdout,
        {:line, 65_536}
      ])

    state = %{
      port: port,
      buffer: "",
      waiting: nil,
      lines: [],
      raw: false
    }

    # Wait for initial REPL prompt
    state = collect_until_prompt(state, @startup_timeout)

    # Load prelude
    send_expr(port, "(load-file \"#{prelude}\")")
    state = collect_until_prompt(state, @startup_timeout)
    Logger.debug("CljRepl: prelude loaded")

    {:ok, state}
  end

  @preview_vars "(__preview-vars)"

  @impl true
  def handle_call({:eval, expr}, from, state) do
    send_expr(state.port, expr)
    send_expr(state.port, @preview_vars)
    send_expr(state.port, "(println \"#{@sentinel}\")")

    {:noreply, %{state | waiting: from, lines: [], raw: false}}
  end

  def handle_call({:eval_raw, expr}, from, state) do
    send_expr(state.port, expr)
    send_expr(state.port, @preview_vars)
    send_expr(state.port, "(println \"#{@sentinel}\")")

    {:noreply, %{state | waiting: from, lines: [], raw: true}}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    cond do
      # Sentinel found — we have all the output
      String.contains?(line, @sentinel) ->
        raw_output =
          state.lines
          |> Enum.reverse()
          |> Enum.join("\n")
          |> String.trim()

        output = if state.raw, do: raw_output, else: clean_output(raw_output)

        if state.waiting do
          GenServer.reply(state.waiting, {:ok, output})
        end

        {:noreply, %{state | waiting: nil, lines: [], buffer: ""}}

      # Accumulate lines
      true ->
        {:noreply, %{state | lines: [line | state.lines]}}
    end
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: state.buffer <> chunk}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port: port}) do
    Port.close(port)
    :ok
  end

  # --- Private helpers ---

  defp send_expr(port, expr) do
    Port.command(port, expr <> "\n")
  end

  defp default_prelude_path do
    Path.join([File.cwd!(), "priv", "clj_prelude.clj"])
  end

  # Strip "user=> " prompts and trailing "nil" from println
  defp clean_output(raw) do
    raw
    |> String.split("\n")
    |> Enum.map(fn line ->
      line
      |> String.replace(~r/^(user|tool|data)=> /, "")
      |> String.replace(~r/^#'[a-z]+\/\S+$/, "")
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reject(&(&1 == "nil"))
    |> Enum.join("\n")
    |> String.trim()
  end

  # Block until we see "user=> " or similar REPL prompt (used only during init)
  defp collect_until_prompt(state, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect_until_prompt(state, deadline)
  end

  defp do_collect_until_prompt(state, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Logger.warning("CljRepl: timeout waiting for REPL prompt")
      state
    else
      receive do
        {port, {:data, {:eol, _line}}} when port == state.port ->
          do_collect_until_prompt(state, deadline)

        {port, {:data, {:noeol, chunk}}} when port == state.port ->
          # Check if the chunk ends with a REPL prompt
          if String.contains?(chunk, "=> ") do
            state
          else
            do_collect_until_prompt(state, deadline)
          end
      after
        min(remaining, 500) ->
          # Check if we've been quiet long enough (REPL is ready)
          state
      end
    end
  end
end
