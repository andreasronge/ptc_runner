# Real-upstream MCP payload benchmark.
#
# Runs the same Gmail-oriented tasks through two stdio MCP paths:
#
#   1. Native Gmail MCP server:
#        npx -y @gongrzhe/server-gmail-autoauth-mcp
#
#   2. PTC Runner aggregator:
#        ptc_runner_mcp start --upstreams-config <gmail-upstreams.json>
#
# The harness measures client-visible JSON-RPC frame bytes rather than
# only PTC's internal `ptc_metrics`, then reports cold and warm costs:
#
#   cold = initialize + initialized notification + tools/list + task call
#   warm = task call only
#
# Token counts are estimates: ceil(utf8_bytes / 4). The benchmark is a
# deterministic wire-cost harness; it does not measure real LLM
# reasoning/program-authoring behavior. Use it to find mechanical
# break-even points, then follow with a real-client eval for agent
# behavior.
#
# Usage from repo root or mcp_server/:
#
#   MIX_ENV=prod mix release --overwrite
#   mix run --no-start mcp_server/bench/real_mcp_payload_bench.exs
#
# Options:
#
#   --runs=N
#   --case=CASE_NAME
#   --out=PATH
#   --upstreams-config=PATH
#   --release-bin=PATH
#   --native-gmail-command='npx -y @gongrzhe/server-gmail-autoauth-mcp'

defmodule RealMcpPayloadBench.Cli do
  @moduledoc false

  def parse(argv) do
    {opts, _argv, invalid} =
      OptionParser.parse(argv,
        strict: [
          runs: :integer,
          case: :string,
          out: :string,
          upstreams_config: :string,
          release_bin: :string,
          native_gmail_command: :string,
          help: :boolean
        ],
        aliases: [h: :help]
      )

    if invalid != [] do
      abort("Invalid options: #{inspect(invalid)}")
    end

    if Keyword.get(opts, :help, false) do
      IO.puts("""
      Usage:
        mix run --no-start mcp_server/bench/real_mcp_payload_bench.exs [options]

      Options:
        --runs=N
        --case=CASE_NAME
        --out=PATH
        --upstreams-config=PATH
        --release-bin=PATH
        --native-gmail-command='npx -y @gongrzhe/server-gmail-autoauth-mcp'
      """)

      System.halt(0)
    end

    repo_root = repo_root()

    %{
      runs: Keyword.get(opts, :runs, 1),
      case: Keyword.get(opts, :case),
      out:
        Keyword.get(
          opts,
          :out,
          Path.join(repo_root, "tmp/real_mcp_payload_bench.json")
        ),
      upstreams_config:
        Keyword.get(
          opts,
          :upstreams_config,
          Path.expand("~/ptc-mcp-sandbox/upstreams.json")
        ),
      release_bin:
        Keyword.get(
          opts,
          :release_bin,
          Path.join(repo_root, "mcp_server/_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp")
        ),
      native_gmail_command:
        Keyword.get(opts, :native_gmail_command, "npx -y @gongrzhe/server-gmail-autoauth-mcp")
    }
  end

  defp repo_root do
    cwd = File.cwd!()

    cond do
      File.exists?(Path.join(cwd, "mcp_server/mix.exs")) -> cwd
      Path.basename(cwd) == "mcp_server" -> Path.expand("..", cwd)
      true -> cwd
    end
  end

  defp abort(message) do
    IO.puts(:stderr, message)
    System.halt(2)
  end
end

defmodule RealMcpPayloadBench.JsonRpc do
  @moduledoc false

  def initialize(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "real-mcp-payload-bench", "version" => "0.1.0"}
      }
    }
  end

  def initialized do
    %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}}
  end

  def tools_list(id), do: %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/list"}

  def tools_call(id, name, arguments) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    }
  end
end

defmodule RealMcpPayloadBench.McpSession do
  @moduledoc false

  defstruct [
    :name,
    :port,
    :os_pid,
    :buffer,
    :next_id,
    :overhead,
    :tools,
    :stderr_path
  ]

  def start(name, command_line, env \\ []) do
    stderr_path =
      Path.join(
        System.tmp_dir!(),
        "real_mcp_payload_bench_#{name}_#{System.unique_integer([:positive])}.stderr"
      )

    shell = "exec #{command_line} 2> #{shell_quote(stderr_path)}"

    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          {:args, ["-c", shell]},
          {:env, Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)}
        ]
      )

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    %__MODULE__{
      name: name,
      port: port,
      os_pid: os_pid,
      buffer: "",
      next_id: 1,
      overhead: %{},
      tools: [],
      stderr_path: stderr_path
    }
  end

  def handshake(session) do
    {session, init} =
      request(session, RealMcpPayloadBench.JsonRpc.initialize(session.next_id), 60_000)

    {session, initialized_bytes} = notify(session, RealMcpPayloadBench.JsonRpc.initialized())

    {session, tools} =
      request(session, RealMcpPayloadBench.JsonRpc.tools_list(session.next_id), 60_000)

    overhead = %{
      "initialize_request_bytes" => init.request_bytes,
      "initialize_response_bytes" => init.response_bytes,
      "initialized_notification_bytes" => initialized_bytes,
      "tools_list_request_bytes" => tools.request_bytes,
      "tools_list_response_bytes" => tools.response_bytes,
      "cold_overhead_bytes" =>
        init.request_bytes + init.response_bytes + initialized_bytes + tools.request_bytes +
          tools.response_bytes
    }

    tool_names =
      tools.reply
      |> get_in(["result", "tools"])
      |> List.wrap()
      |> Enum.map(& &1["name"])

    {%{session | overhead: overhead, tools: tool_names}, %{initialize: init, tools_list: tools}}
  end

  def call_tool(session, name, arguments, timeout_ms \\ 60_000) do
    request(
      session,
      RealMcpPayloadBench.JsonRpc.tools_call(session.next_id, name, arguments),
      timeout_ms
    )
  end

  def close(%__MODULE__{} = session) do
    if session.port do
      try do
        Port.close(session.port)
      catch
        _, _ -> :ok
      end
    end

    if session.os_pid do
      _ = System.cmd("/bin/sh", ["-c", "kill -9 #{session.os_pid} 2>/dev/null; true"])
    end

    _ = File.rm(session.stderr_path)
    :ok
  end

  defp request(session, frame, timeout_ms) do
    id = frame["id"]
    line = Jason.encode!(frame) <> "\n"
    started = System.monotonic_time(:millisecond)
    true = Port.command(session.port, line)
    {reply, raw_response, buffer} = receive_reply(session.port, id, session.buffer, timeout_ms)
    stopped = System.monotonic_time(:millisecond)

    result = %{
      id: id,
      request: frame,
      reply: reply,
      request_bytes: byte_size(line),
      response_bytes: byte_size(raw_response),
      latency_ms: stopped - started
    }

    {%{session | buffer: buffer, next_id: id + 1}, result}
  end

  defp notify(session, frame) do
    line = Jason.encode!(frame) <> "\n"
    true = Port.command(session.port, line)
    {session, byte_size(line)}
  end

  defp receive_reply(port, id, buffer, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_receive_reply(port, id, buffer, deadline)
  end

  defp do_receive_reply(port, id, buffer, deadline) do
    case extract_reply(buffer, id) do
      {:ok, reply, raw_line, rest} ->
        {reply, raw_line <> "\n", rest}

      {:incomplete, buffer} ->
        timeout = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {^port, {:data, chunk}} ->
            do_receive_reply(port, id, buffer <> chunk, deadline)

          {^port, {:exit_status, status}} ->
            raise "MCP session exited while waiting for id #{id}, status=#{inspect(status)}, buffer=#{inspect(buffer)}"
        after
          timeout ->
            raise "Timed out waiting for MCP reply id #{id}; buffer=#{inspect(buffer)}"
        end
    end
  end

  defp extract_reply(buffer, id) do
    case String.split(buffer, "\n", parts: 2) do
      [^buffer] ->
        {:incomplete, buffer}

      [line, rest] ->
        case Jason.decode(line) do
          {:ok, %{"jsonrpc" => "2.0", "id" => ^id} = reply} -> {:ok, reply, line, rest}
          _ -> extract_reply(rest, id)
        end
    end
  end

  def shell_quote(arg) do
    arg = to_string(arg)

    if Regex.match?(~r/\A[A-Za-z0-9_@%+=:,.\-\/]+\z/, arg) do
      arg
    else
      "'" <> String.replace(arg, "'", "'\\''") <> "'"
    end
  end
end

defmodule RealMcpPayloadBench.Cases do
  @moduledoc false

  def all do
    [
      %{
        name: "gmail_labels_tiny_bad_fit",
        category: "native_favorable",
        reason: "Small direct lookup; PTC adds program/envelope overhead.",
        native_tool: "list_email_labels",
        native_args: %{},
        ptc_program: """
        (let [r (tool/mcp-call {:server "gmail" :tool "list_email_labels" :args {}})
              txt (mcp/text r)]
          {:chars (count txt)
           :label-lines (count (filter #(.startsWith % "ID: ") (split-lines txt)))})
        """,
        ptc_signature: "() -> :any"
      },
      %{
        name: "gmail_recent_3_verbatim_bad_fit",
        category: "native_favorable",
        reason: "Result is already small and returned nearly verbatim.",
        native_tool: "search_emails",
        native_args: %{
          "query" => "newer_than:1d -in:sent -in:trash -in:spam",
          "maxResults" => 3
        },
        ptc_program: """
        (let [r (tool/mcp-call {:server "gmail"
                                :tool "search_emails"
                                :args {:query "newer_than:1d -in:sent -in:trash -in:spam"
                                       :maxResults 3}})]
          (mcp/text r))
        """,
        ptc_signature: "() -> :string"
      },
      %{
        name: "gmail_recent_30d_count_favorable",
        category: "ptc_favorable",
        reason: "Moderate search result reduced to counts and a tiny preview.",
        native_tool: "search_emails",
        native_args: %{
          "query" => "newer_than:30d -in:sent -in:trash -in:spam",
          "maxResults" => 100
        },
        ptc_program: """
        (let [r (tool/mcp-call {:server "gmail"
                                :tool "search_emails"
                                :args {:query "newer_than:30d -in:sent -in:trash -in:spam"
                                       :maxResults 100}})
              txt (mcp/text r)
              lines (split-lines txt)
              subjects (filter #(.startsWith % "Subject: ") lines)]
          {:matched-messages (count (filter #(.startsWith % "ID: ") lines))
           :subject-count (count subjects)
           :first-subjects (take 5 subjects)
           :source-chars (count txt)})
        """,
        ptc_signature: "() -> :any"
      },
      %{
        name: "gmail_receipts_180d_count_favorable",
        category: "ptc_favorable",
        reason: "Noisy receipt/invoice search reduced to a compact summary.",
        native_tool: "search_emails",
        native_args: %{
          "query" =>
            "newer_than:180d (invoice OR receipt OR faktura OR kvitto) -in:sent -in:trash -in:spam",
          "maxResults" => 100
        },
        ptc_program: """
        (let [r (tool/mcp-call {:server "gmail"
                                :tool "search_emails"
                                :args {:query "newer_than:180d (invoice OR receipt OR faktura OR kvitto) -in:sent -in:trash -in:spam"
                                       :maxResults 100}})
              txt (mcp/text r)
              lines (split-lines txt)
              subjects (filter #(.startsWith % "Subject: ") lines)
              senders (filter #(.startsWith % "From: ") lines)]
          {:matched-messages (count (filter #(.startsWith % "ID: ") lines))
           :subject-count (count subjects)
           :sender-count (count senders)
           :first-subjects (take 5 subjects)
           :source-chars (count txt)})
        """,
        ptc_signature: "() -> :any"
      },
      %{
        name: "gmail_unread_100_count_favorable",
        category: "ptc_favorable",
        reason: "Unread search reduced to counts instead of returning every item.",
        native_tool: "search_emails",
        native_args: %{
          "query" => "is:unread -in:sent -in:trash -in:spam",
          "maxResults" => 100
        },
        ptc_program: """
        (let [r (tool/mcp-call {:server "gmail"
                                :tool "search_emails"
                                :args {:query "is:unread -in:sent -in:trash -in:spam"
                                       :maxResults 100}})
              txt (mcp/text r)
              lines (split-lines txt)]
          {:matched-messages (count (filter #(.startsWith % "ID: ") lines))
           :subject-count (count (filter #(.startsWith % "Subject: ") lines))
           :from-count (count (filter #(.startsWith % "From: ") lines))
           :source-chars (count txt)})
        """,
        ptc_signature: "() -> :any"
      }
    ]
  end
end

defmodule RealMcpPayloadBench.Report do
  @moduledoc false

  def estimate_tokens(bytes), do: div(bytes + 3, 4)

  def summarize_case(case_def, native_overhead, ptc_overhead, native_call, ptc_call) do
    native_task_bytes = native_call.request_bytes + native_call.response_bytes
    ptc_task_bytes = ptc_call.request_bytes + ptc_call.response_bytes

    native_cold = native_overhead["cold_overhead_bytes"] + native_task_bytes
    ptc_cold = ptc_overhead["cold_overhead_bytes"] + ptc_task_bytes

    sc = get_in(ptc_call.reply, ["result", "structuredContent"]) || %{}
    ptc_metrics = Map.get(sc, "ptc_metrics")
    upstream_calls = Map.get(sc, "upstream_calls", [])

    %{
      "case" => case_def.name,
      "category" => case_def.category,
      "reason" => case_def.reason,
      "native" => %{
        "tool" => case_def.native_tool,
        "cold_bytes" => native_cold,
        "warm_bytes" => native_task_bytes,
        "cold_est_tokens" => estimate_tokens(native_cold),
        "warm_est_tokens" => estimate_tokens(native_task_bytes),
        "request_bytes" => native_call.request_bytes,
        "response_bytes" => native_call.response_bytes,
        "latency_ms" => native_call.latency_ms,
        "is_error" => get_in(native_call.reply, ["result", "isError"]) == true
      },
      "ptc" => %{
        "cold_bytes" => ptc_cold,
        "warm_bytes" => ptc_task_bytes,
        "cold_est_tokens" => estimate_tokens(ptc_cold),
        "warm_est_tokens" => estimate_tokens(ptc_task_bytes),
        "request_bytes" => ptc_call.request_bytes,
        "response_bytes" => ptc_call.response_bytes,
        "latency_ms" => ptc_call.latency_ms,
        "status" => Map.get(sc, "status"),
        "ptc_metrics" => ptc_metrics,
        "upstream_calls" =>
          Enum.map(upstream_calls, fn call ->
            Map.take(call, [
              "server",
              "tool",
              "status",
              "duration_ms",
              "result_bytes",
              "oversize",
              "reason"
            ])
          end)
      },
      "comparison" => %{
        "warm_delta_bytes_ptc_minus_native" => ptc_task_bytes - native_task_bytes,
        "cold_delta_bytes_ptc_minus_native" => ptc_cold - native_cold,
        "warm_ratio_ptc_over_native" => ratio(ptc_task_bytes, native_task_bytes),
        "cold_ratio_ptc_over_native" => ratio(ptc_cold, native_cold),
        "ptc_warm_wins" => ptc_task_bytes < native_task_bytes,
        "ptc_cold_wins" => ptc_cold < native_cold
      }
    }
  end

  def overhead_summary(native, ptc) do
    %{
      "native" => native,
      "ptc" => ptc,
      "both_available_catalog_lower_bound_bytes" =>
        native["cold_overhead_bytes"] + ptc["cold_overhead_bytes"],
      "both_available_catalog_lower_bound_est_tokens" =>
        estimate_tokens(native["cold_overhead_bytes"] + ptc["cold_overhead_bytes"])
    }
  end

  def print(results) do
    IO.puts("")
    IO.puts("Real MCP payload benchmark")
    IO.puts(String.duplicate("=", 80))
    IO.puts("Token estimate method: ceil(utf8_bytes / 4)")
    IO.puts("Cold = initialize + initialized notification + tools/list + task call")
    IO.puts("Warm = task call only")
    IO.puts("")

    Enum.each(results["cases"], fn row ->
      c = row["comparison"]
      native = row["native"]
      ptc = row["ptc"]

      IO.puts("#{row["case"]} [#{row["category"]}]")
      IO.puts("  #{row["reason"]}")

      IO.puts(
        "  native warm/cold est tokens: #{native["warm_est_tokens"]} / #{native["cold_est_tokens"]}, latency #{native["latency_ms"]}ms"
      )

      IO.puts(
        "  ptc    warm/cold est tokens: #{ptc["warm_est_tokens"]} / #{ptc["cold_est_tokens"]}, latency #{ptc["latency_ms"]}ms"
      )

      IO.puts(
        "  warm delta bytes ptc-native: #{c["warm_delta_bytes_ptc_minus_native"]}, ratio #{c["warm_ratio_ptc_over_native"]}, ptc_wins=#{c["ptc_warm_wins"]}"
      )

      case ptc["ptc_metrics"] do
        %{} = m ->
          IO.puts(
            "  ptc_metrics: upstream=#{m["upstream_result_bytes"]}B final=#{m["final_result_bytes"]}B ratio=#{inspect(m["payload_reduction_ratio"])}"
          )

        _ ->
          :ok
      end

      IO.puts("")
    end)

    overhead = results["overhead"]

    IO.puts("Catalog/session overhead")
    IO.puts("  native cold overhead bytes: #{overhead["native"]["cold_overhead_bytes"]}")
    IO.puts("  ptc cold overhead bytes:    #{overhead["ptc"]["cold_overhead_bytes"]}")

    IO.puts(
      "  both-available lower bound: #{overhead["both_available_catalog_lower_bound_est_tokens"]} est tokens"
    )
  end

  defp ratio(_num, 0), do: nil
  defp ratio(num, den), do: Float.round(num / den, 3)
end

opts = RealMcpPayloadBench.Cli.parse(System.argv())

unless File.exists?(opts.release_bin) do
  IO.puts(:stderr, "Release binary not found: #{opts.release_bin}")
  IO.puts(:stderr, "Run: cd mcp_server && MIX_ENV=prod mix release --overwrite")
  System.halt(2)
end

unless File.exists?(opts.upstreams_config) do
  IO.puts(:stderr, "Upstreams config not found: #{opts.upstreams_config}")
  System.halt(2)
end

cases =
  RealMcpPayloadBench.Cases.all()
  |> Enum.filter(fn c -> is_nil(opts.case) or c.name == opts.case end)

if cases == [] do
  IO.puts(:stderr, "No benchmark cases matched #{inspect(opts.case)}")
  System.halt(2)
end

ptc_command =
  [
    RealMcpPayloadBench.McpSession.shell_quote(opts.release_bin),
    "start",
    "--debug-tool",
    "--trace-dir",
    RealMcpPayloadBench.McpSession.shell_quote("/tmp/ptc-runner-real-mcp-payload-bench"),
    "--trace-payloads",
    "summary",
    "--upstreams-config",
    RealMcpPayloadBench.McpSession.shell_quote(opts.upstreams_config)
  ]
  |> Enum.join(" ")

native = RealMcpPayloadBench.McpSession.start("native_gmail", opts.native_gmail_command)

ptc =
  RealMcpPayloadBench.McpSession.start(
    "ptc_runner",
    ptc_command,
    [{"RELEASE_DISTRIBUTION", "none"}, {"PTC_RUNNER_MCP_LOG_LEVEL", "error"}]
  )

try do
  {native, _native_handshake} = RealMcpPayloadBench.McpSession.handshake(native)
  {ptc, _ptc_handshake} = RealMcpPayloadBench.McpSession.handshake(ptc)

  {native, ptc, all_rows} =
    Enum.reduce(1..opts.runs, {native, ptc, []}, fn run, {native, ptc, acc} ->
      {native, ptc, run_rows} =
        Enum.reduce(cases, {native, ptc, []}, fn case_def, {native, ptc, rows} ->
          {native_after, native_call} =
            RealMcpPayloadBench.McpSession.call_tool(
              native,
              case_def.native_tool,
              case_def.native_args
            )

          ptc_args = %{"program" => case_def.ptc_program}

          ptc_args =
            if case_def[:ptc_signature],
              do: Map.put(ptc_args, "signature", case_def.ptc_signature),
              else: ptc_args

          {ptc_after, ptc_call} =
            RealMcpPayloadBench.McpSession.call_tool(ptc, "ptc_lisp_execute", ptc_args)

          ptc = ptc_after

          row =
            RealMcpPayloadBench.Report.summarize_case(
              case_def,
              native.overhead,
              ptc.overhead,
              native_call,
              ptc_call
            )

          {native_after, ptc_after, [Map.put(row, "run", run) | rows]}
        end)

      {native, ptc, acc ++ Enum.reverse(run_rows)}
    end)

  result = %{
    "schema_version" => 1,
    "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
    "runs" => opts.runs,
    "method" => %{
      "estimated_tokens" => "ceil(utf8_bytes / 4)",
      "cold" => "initialize + initialized notification + tools/list + task request/response",
      "warm" => "task request/response only",
      "note" =>
        "This is a deterministic MCP wire benchmark. It does not measure LLM reasoning tokens, retries, or tool-choice quality."
    },
    "commands" => %{
      "native_gmail" => opts.native_gmail_command,
      "ptc_runner" => ptc_command
    },
    "tools" => %{"native" => native.tools, "ptc" => ptc.tools},
    "overhead" => RealMcpPayloadBench.Report.overhead_summary(native.overhead, ptc.overhead),
    "cases" => all_rows
  }

  File.mkdir_p!(Path.dirname(opts.out))
  File.write!(opts.out, Jason.encode!(result, pretty: true))
  RealMcpPayloadBench.Report.print(result)
  IO.puts("")
  IO.puts("Wrote #{opts.out}")
after
  RealMcpPayloadBench.McpSession.close(native)
  RealMcpPayloadBench.McpSession.close(ptc)
end
