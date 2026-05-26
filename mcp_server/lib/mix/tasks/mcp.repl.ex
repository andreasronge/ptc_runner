defmodule Mix.Tasks.Mcp.Repl do
  use Mix.Task

  @shortdoc "Start an MCP-aware PTC-Lisp REPL"

  @moduledoc """
  Starts the human-facing PTC-Lisp REPL through `PtcRunnerMcp.Repl`.

  This task is for local development from the `mcp_server/` Mix project.
  The Mac and Docker distributions use the bundled `bin/ptc_lisp_repl`
  wrapper instead, so users of those artifacts do not need Erlang or
  Elixir installed.

      mix mcp.repl
      mix mcp.repl --display envelope
      mix mcp.repl --upstreams-config ./upstreams.json --display envelope
      mix mcp.repl --stateless --eval "(+ 1 2)"

  Options:

    * `--auto-session` - use `lisp_session_eval` when sessions are enabled.
    * `--session` - require a session-backed REPL.
    * `--stateless` - force stateless `lisp_eval`.
    * `--display MODE` - `text`, `envelope`, or `json`.
    * `--upstreams-config PATH` - load upstream MCP servers for discovery
      forms and `(tool/mcp-call ...)`.
    * `-e`, `--eval PROGRAM` - evaluate one program and exit.
  """

  @switches [
    auto_session: :boolean,
    session: :boolean,
    stateless: :boolean,
    display: :string,
    eval: :string,
    upstreams_config: :string,
    aggregator_read_only: :boolean,
    catalog_mode: :string,
    catalog_inline_max_chars: :integer,
    catalog_inline_max_tools: :integer,
    max_catalog_ops_per_program: :integer,
    max_catalog_result_bytes: :integer,
    max_upstream_response_bytes: :integer,
    max_upstream_calls_per_program: :integer,
    upstream_call_timeout_ms: :integer,
    max_program_bytes: :integer,
    max_context_bytes: :integer,
    max_concurrent_calls: :integer,
    program_timeout_ms: :integer,
    program_memory_limit_bytes: :integer,
    response_profile: :string,
    debug_tool: :boolean,
    debug_ring_size: :integer,
    max_debug_response_bytes: :integer,
    help: :boolean
  ]

  @aliases [e: :eval, h: :help]

  @app_keys [
    :upstreams_config,
    :aggregator_read_only,
    :catalog_mode,
    :catalog_inline_max_chars,
    :catalog_inline_max_tools,
    :max_catalog_ops_per_program,
    :max_catalog_result_bytes,
    :max_upstream_response_bytes,
    :max_upstream_calls_per_program,
    :upstream_call_timeout_ms,
    :max_program_bytes,
    :max_context_bytes,
    :max_concurrent_calls,
    :program_timeout_ms,
    :program_memory_limit_bytes,
    :response_profile,
    :debug_tool,
    :debug_ring_size,
    :max_debug_response_bytes
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    cond do
      invalid != [] ->
        Mix.raise("invalid option: #{invalid |> hd() |> elem(0)}")

      Keyword.get(opts, :help, false) ->
        Mix.shell().info(@moduledoc)

      true ->
        run_repl(opts)
    end
  end

  defp run_repl(opts) do
    args = app_args(opts)
    _supervisor = start_repl_runtime!(args)

    repl_opts = [session: session_mode(opts), display: Keyword.get(opts, :display, "text")]

    case Keyword.fetch(opts, :eval) do
      {:ok, program} ->
        program
        |> PtcRunnerMcp.Repl.eval(repl_opts)
        |> exit_eval_result()

      :error ->
        PtcRunnerMcp.Repl.start(repl_opts)
    end
  end

  defp app_args(opts) do
    opts
    |> Keyword.take(@app_keys)
    |> Map.new()
    |> maybe_enable_sessions(opts)
  end

  defp maybe_enable_sessions(args, opts) do
    if Keyword.get(opts, :session, false), do: Map.put(args, :sessions, true), else: args
  end

  defp start_repl_runtime!(args) do
    PtcRunner.Dotenv.load()
    {:ok, _apps} = Application.ensure_all_started(:telemetry)

    %{upstreams: upstreams, credentials: bindings, raw_envelope_policy: raw_envelope_policy} =
      PtcRunnerMcp.Application.load_aggregator_config(args)

    :ok = PtcRunnerMcp.Application.apply_aggregator_config(args, raw_envelope_policy)
    :ok = PtcRunnerMcp.Application.apply_catalog_config(args)
    :ok = PtcRunnerMcp.Application.apply_debug_config(args)
    :ok = PtcRunnerMcp.Application.apply_response_profile(args)
    :ok = PtcRunnerMcp.Application.apply_limits(args, aggregator?: upstreams != [])
    :ok = PtcRunnerMcp.Application.apply_sessions_config(args)
    :ok = PtcRunnerMcp.ConcurrencyGate.init()

    children = PtcRunnerMcp.Application.build_repl_children(upstreams, bindings)
    opts = [strategy: :rest_for_one, name: PtcRunnerMcp.ReplSupervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, pid}} ->
        pid

      {:error, reason} ->
        Mix.raise("could not start MCP REPL runtime: #{inspect(reason)}")
    end
  end

  defp session_mode(opts) do
    cond do
      Keyword.get(opts, :session, false) -> true
      Keyword.get(opts, :stateless, false) -> false
      true -> :auto
    end
  end

  defp exit_eval_result({:ok, text}), do: Mix.shell().info(text)

  defp exit_eval_result({:error, text}) do
    Mix.shell().error(text)
    System.halt(1)
  end
end
