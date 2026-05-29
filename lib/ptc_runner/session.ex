defmodule PtcRunner.Session do
  @moduledoc """
  Stateful PTC-Lisp session for embedding applications.

  A session owns only the REPL state that `PtcRunner.Lisp.run/2` already
  understands: explicit `(def ...)` memory and the bounded `*1`/`*2`/`*3`
  turn history. Durable chat messages, user identity, persistence, and tool
  configuration stay with the embedding application. Runtime options can be
  stored as session defaults or passed per evaluation.

  ## Examples

      iex> session = PtcRunner.Session.new(timeout: 1_000)
      iex> {{:ok, step}, session} = PtcRunner.Session.eval(session, "(def x 41)")
      iex> step.memory["x"]
      41
      iex> {{:ok, step}, _session} = PtcRunner.Session.eval(session, "(inc x)")
      iex> step.return
      42

      iex> session = PtcRunner.Session.new(history_depth: 2)
      iex> {{:ok, _}, session} = PtcRunner.Session.eval(session, "1")
      iex> {{:ok, _}, session} = PtcRunner.Session.eval(session, "2")
      iex> {{:ok, step}, _session} = PtcRunner.Session.eval(session, "*1")
      iex> step.return
      2
  """

  alias PtcRunner.Step
  alias PtcRunner.Upstream.Runtime, as: UpstreamRuntime

  @default_history_depth 3

  defstruct memory: %{},
            turn_history: [],
            history_depth: @default_history_depth,
            run_opts: [],
            upstream_runtime: nil

  @type t :: %__MODULE__{
          memory: map(),
          turn_history: [term()],
          history_depth: non_neg_integer(),
          run_opts: keyword(),
          upstream_runtime: struct() | pid() | nil
        }

  @typedoc """
  Result of `eval/3`: the normal `PtcRunner.Lisp.run/2` result paired with the
  session state to use for the next turn.
  """
  @type eval_result :: {{:ok, Step.t()} | {:error, Step.t()}, t()}

  @doc """
  Create a new stateful PTC-Lisp session.

  ## Options

    * `:memory` - initial Lisp memory map (default: `%{}`)
    * `:turn_history` - initial result history, oldest first (default: `[]`)
    * `:history_depth` - maximum stored result count for `*1`, `*2`, `*3`
      references (default: `3`)
    * `:upstream_runtime` - optional `PtcRunner.Upstream.Runtime` handle used
      to evaluate programs through configured upstream MCP/OpenAPI tools

  Any other options are stored as default `PtcRunner.Lisp.run/2` options and
  merged with per-eval options.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    history_depth =
      opts
      |> Keyword.get(:history_depth, @default_history_depth)
      |> normalize_history_depth!()

    {upstream_runtime, run_opts} = Keyword.pop(opts, :upstream_runtime)

    %__MODULE__{
      memory: Keyword.get(run_opts, :memory, %{}),
      turn_history: trim_history(Keyword.get(run_opts, :turn_history, []), history_depth),
      history_depth: history_depth,
      run_opts: Keyword.drop(run_opts, [:memory, :turn_history, :history_depth]),
      upstream_runtime: upstream_runtime
    }
  end

  @doc """
  Evaluate PTC-Lisp source with this session's memory and turn history.

  Session default options and per-call `opts` are passed through to
  `PtcRunner.Lisp.run/2`, then the session's `:memory` and `:turn_history` are
  applied. This lets embedding callers pass normal runtime options such as
  `:tools`, `:context`, `:timeout`, or upstream options while the session
  remains the owner of REPL state. If the session was created with
  `:upstream_runtime`, evaluation goes through `PtcRunner.Upstream.Runtime`.

  On success, the returned session stores `step.memory` and appends
  `step.return` to the bounded history. On error, the returned session is the
  original session, preserving the prior memory and history.
  """
  @spec eval(t(), String.t(), keyword()) :: eval_result()
  def eval(%__MODULE__{} = session, source, opts \\ [])
      when is_binary(source) and is_list(opts) do
    run_opts =
      session.run_opts
      |> Keyword.merge(opts)
      |> Keyword.put(:memory, session.memory)
      |> Keyword.put(:turn_history, session.turn_history)

    case run_lisp(session, source, run_opts) do
      {:ok, %Step{} = step} ->
        updated = %{
          session
          | memory: step.memory,
            turn_history: append_history(session.turn_history, step.return, session.history_depth)
        }

        {{:ok, step}, updated}

      {:error, %Step{} = step} ->
        {{:error, step}, session}
    end
  end

  defp append_history(history, value, history_depth) do
    trim_history(history ++ [value], history_depth)
  end

  defp trim_history(history, history_depth) when is_list(history) and is_integer(history_depth) do
    history
    |> Enum.take(-max(history_depth, 0))
  end

  defp normalize_history_depth!(depth) when is_integer(depth) and depth >= 0, do: depth

  defp normalize_history_depth!(depth) do
    raise ArgumentError, ":history_depth must be a non-negative integer, got: #{inspect(depth)}"
  end

  defp run_lisp(%__MODULE__{upstream_runtime: nil}, source, opts) do
    PtcRunner.Lisp.run(source, opts)
  end

  defp run_lisp(%__MODULE__{upstream_runtime: runtime}, source, opts) do
    UpstreamRuntime.run_lisp(runtime, source, opts)
  end
end
