defmodule PtcRunnerMcp.Repl do
  @moduledoc """
  Human-facing PTC-Lisp REPL for a running `ptc_runner_mcp` node.

  This module is intended to be launched from remote IEx:

      PtcRunnerMcp.Repl.start()

  It evaluates through the MCP tool facade, so aggregator mode, response
  profiles, output limits, and upstream MCP call feedback match what an
  MCP client sees. When stateful session tools are enabled, the REPL
  automatically starts one session and uses `lisp_session_eval`; otherwise
  it falls back to stateless `lisp_eval`.
  """

  alias PtcRunnerMcp.{Sessions, Tools}

  defstruct mode: :stateless,
            display: :text,
            session_id: nil,
            owner_context: nil,
            context: %{}

  @display_modes [:text, :envelope, :json]

  @type state :: %__MODULE__{
          mode: :stateless | :session,
          display: :text | :envelope | :json,
          session_id: String.t() | nil,
          owner_context: map() | nil,
          context: map()
        }

  @doc """
  Start an interactive PTC-Lisp REPL in the current shell.

  Options:

    * `:context` - JSON-like map passed as the `context` argument.
    * `:display` - `:text` (default), `:envelope`, or `:json`.
    * `:session` - `true`, `false`, or `:auto` (default). `:auto` uses
      a stateful `lisp_session_eval` session when sessions are enabled.
  """
  @spec start(keyword()) :: :ok
  def start(opts \\ []) when is_list(opts) do
    state = init(opts)

    IO.puts("PTC-Lisp MCP REPL (Ctrl+D or :quit to exit)")
    IO.puts("Mode: #{mode_label(state)}")
    IO.puts("Display: #{state.display}")
    IO.puts("Type :help for commands.\n")

    loop(state)
  end

  @doc """
  Evaluate one PTC-Lisp program and return the rendered MCP tool output.

  This is useful from remote IEx when an interactive prompt is too much:

      PtcRunnerMcp.Repl.eval("(+ 1 2)")
  """
  @spec eval(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def eval(program, opts \\ []) when is_binary(program) and is_list(opts) do
    state = init(opts)

    try do
      case eval_in_state(program, state) do
        {:ok, text, _display} -> {:ok, text}
        {:error, text, _display} -> {:error, text}
      end
    after
      close_session(state)
    end
  end

  @spec init(keyword()) :: state()
  defp init(opts) do
    context = Keyword.get(opts, :context, %{})
    display = parse_display!(Keyword.get(opts, :display, :text))
    session = Keyword.get(opts, :session, :auto)

    cond do
      session == true ->
        start_session!(context, display)

      session == :auto and Sessions.enabled?() ->
        start_session!(context, display)

      true ->
        %__MODULE__{mode: :stateless, display: display, context: context}
    end
  end

  defp start_session!(context, display) do
    owner_context = %{transport: :stdio, instance_id: "remote_repl"}

    case Sessions.call(%{
           "name" => "lisp_session_start",
           "arguments" => %{"owner" => owner_context}
         }) do
      %{"isError" => false, "structuredContent" => %{"session_id" => session_id}}
      when is_binary(session_id) ->
        %__MODULE__{
          mode: :session,
          display: display,
          session_id: session_id,
          owner_context: owner_context,
          context: context
        }

      envelope ->
        raise ArgumentError,
              "could not start PTC-Lisp REPL session: #{text_content(envelope)}"
    end
  end

  defp loop(%__MODULE__{} = state) do
    case read_expression("ptc> ", "") do
      :eof ->
        close_session(state)
        IO.puts("\nGoodbye.")
        :ok

      "" ->
        loop(state)

      ":" <> command ->
        case handle_command(String.trim(command), state) do
          {:continue, next_state} -> loop(next_state)
          :halt -> :ok
        end

      input ->
        input
        |> eval_in_state(state)
        |> print_eval_result()

        loop(state)
    end
  end

  defp eval_in_state(program, %__MODULE__{mode: :session} = state) do
    %{
      "name" => "lisp_session_eval",
      "arguments" => %{
        "session_id" => state.session_id,
        "program" => program,
        "context" => state.context,
        "owner" => state.owner_context
      }
    }
    |> Sessions.call()
    |> rendered_result(state.display)
  end

  defp eval_in_state(program, %__MODULE__{mode: :stateless, display: display, context: context}) do
    %{"name" => "lisp_eval", "arguments" => %{"program" => program, "context" => context}}
    |> Tools.call()
    |> rendered_result(display)
  end

  defp handle_command("help", state) do
    IO.puts("""
    Commands:
      :help                  Show this help
      :mode                  Show whether this REPL is stateless or session-backed
      :display               Show the current display mode
      :display text          Show terminal-oriented tool text
      :display envelope      Show the full pretty JSON MCP tool response envelope
      :display json          Show the full compact JSON MCP tool response envelope
      :tools                 List advertised MCP tools
      :quit                  Exit the REPL

    Evaluate PTC-Lisp directly at the prompt. In aggregator mode,
    upstream MCP tools are available from programs through
    (tool/mcp-call ...), and discovery forms such as (apropos ...)
    use the running server's upstream catalog.
    """)

    {:continue, state}
  end

  defp handle_command("display", state) do
    IO.puts("#{state.display}")
    {:continue, state}
  end

  defp handle_command("display " <> value, state) do
    display = parse_display(String.trim(value))

    case display do
      {:ok, display} ->
        IO.puts("Display: #{display}")
        {:continue, %{state | display: display}}

      :error ->
        IO.puts("Unknown display mode. Available: text, envelope, json")
        {:continue, state}
    end
  end

  defp handle_command("mode", state) do
    IO.puts(mode_label(state))
    {:continue, state}
  end

  defp handle_command("tools", state) do
    Tools.list()
    |> Map.get("tools", [])
    |> Enum.map(&Map.get(&1, "name", "<unnamed>"))
    |> Enum.each(&IO.puts("  #{&1}"))

    {:continue, state}
  end

  defp handle_command(command, state) when command in ["quit", "q", "exit"] do
    close_session(state)
    IO.puts("Goodbye.")
    :halt
  end

  defp handle_command(_, state) do
    IO.puts("Unknown command. Available: :help, :mode, :display, :tools, :quit")
    {:continue, state}
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

  defp balanced?(source) do
    source
    |> String.graphemes()
    |> Enum.reduce_while(
      %{counts: {0, 0, 0}, string?: false, escape?: false, comment?: false, char?: false},
      &scan_char/2
    )
    |> case do
      %{counts: {0, 0, 0}, string?: false, escape?: false, char?: false} -> true
      _ -> false
    end
  end

  defp scan_char("\n", %{comment?: true} = state), do: {:cont, %{state | comment?: false}}
  defp scan_char(_, %{comment?: true} = state), do: {:cont, state}
  defp scan_char(_, %{char?: true} = state), do: {:cont, %{state | char?: false}}
  defp scan_char(";", %{string?: false} = state), do: {:cont, %{state | comment?: true}}

  defp scan_char("\\", %{string?: true, escape?: false} = state),
    do: {:cont, %{state | escape?: true}}

  defp scan_char(_, %{string?: true, escape?: true} = state),
    do: {:cont, %{state | escape?: false}}

  defp scan_char("\"", %{string?: true} = state), do: {:cont, %{state | string?: false}}
  defp scan_char(_, %{string?: true} = state), do: {:cont, state}
  defp scan_char("\"", state), do: {:cont, %{state | string?: true}}
  defp scan_char("\\", state), do: {:cont, %{state | char?: true}}
  defp scan_char("(", state), do: update_counts(state, {1, 0, 0})
  defp scan_char(")", state), do: update_counts(state, {-1, 0, 0})
  defp scan_char("[", state), do: update_counts(state, {0, 1, 0})
  defp scan_char("]", state), do: update_counts(state, {0, -1, 0})
  defp scan_char("{", state), do: update_counts(state, {0, 0, 1})
  defp scan_char("}", state), do: update_counts(state, {0, 0, -1})
  defp scan_char(_, state), do: {:cont, state}

  defp update_counts(%{counts: {p, b, br}} = state, {dp, db, dbr}) do
    next = {p + dp, b + db, br + dbr}

    if negative_count?(next) do
      {:halt, %{state | counts: {-1, -1, -1}}}
    else
      {:cont, %{state | counts: next}}
    end
  end

  defp negative_count?({p, b, br}), do: p < 0 or b < 0 or br < 0

  defp rendered_result(%{"isError" => true} = envelope, display),
    do: {:error, render_envelope(envelope, display), display}

  defp rendered_result(%{"isError" => false} = envelope, display),
    do: {:ok, render_envelope(envelope, display), display}

  defp rendered_result(envelope, _display), do: {:error, inspect(envelope, pretty: true), :text}

  defp render_envelope(envelope, :text), do: text_content(envelope)
  defp render_envelope(envelope, :envelope), do: Jason.encode!(envelope, pretty: true)
  defp render_envelope(envelope, :json), do: Jason.encode!(envelope)

  defp text_content(%{"content" => [%{"type" => "text", "text" => text} | _]})
       when is_binary(text),
       do: text

  defp text_content(%{"structuredContent" => structured}) when is_map(structured) do
    Jason.encode!(structured, pretty: true)
  end

  defp text_content(envelope), do: inspect(envelope, pretty: true)

  defp print_eval_result({:ok, text, _display}), do: IO.puts(text)
  defp print_eval_result({:error, text, :text}), do: IO.puts("Error:\n#{text}")
  defp print_eval_result({:error, text, _display}), do: IO.puts(text)

  defp parse_display!(display) do
    case parse_display(display) do
      {:ok, display} -> display
      :error -> raise ArgumentError, "unknown REPL display mode: #{inspect(display)}"
    end
  end

  defp parse_display(display) when display in @display_modes, do: {:ok, display}

  defp parse_display(display) when is_binary(display) do
    display
    |> String.trim()
    |> String.downcase()
    |> then(fn value ->
      case value do
        "text" -> {:ok, :text}
        "envelope" -> {:ok, :envelope}
        "json" -> {:ok, :json}
        _ -> :error
      end
    end)
  end

  defp parse_display(_), do: :error

  defp mode_label(%__MODULE__{mode: :session, session_id: session_id}) do
    "session-backed lisp_session_eval (session_id=#{session_id})"
  end

  defp mode_label(%__MODULE__{mode: :stateless}), do: "stateless lisp_eval"

  defp close_session(%__MODULE__{mode: :session, session_id: session_id, owner_context: owner}) do
    _ =
      Sessions.call(%{
        "name" => "lisp_session_close",
        "arguments" => %{
          "session_id" => session_id,
          "owner" => owner,
          "reason" => "remote_repl_closed"
        }
      })

    :ok
  end

  defp close_session(%__MODULE__{}), do: :ok
end
