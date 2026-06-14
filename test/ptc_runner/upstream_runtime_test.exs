defmodule PtcRunner.UpstreamRuntimeTest do
  use ExUnit.Case, async: true

  alias PtcRunner.TraceLog.{Analyzer, Introspection}
  alias PtcRunner.Upstream.Credentials
  alias PtcRunner.Upstream.Eval
  alias PtcRunner.Upstream.RunContext
  alias PtcRunner.Upstream.Runtime

  @schema Path.expand("../../mcp_server/test/fixtures/openapi/observatory.openapi.json", __DIR__)
  @bench_planted_turn_log_dir "/Users/andreasronge/ptc-bench-comparison/agent-runs/planted-ptc/run-logs/turn-log"

  # The hand-rolled TCP fixtures read requests with a bounded recv timeout. Keep
  # it well above the client's `call_timeout_ms` (5s) so that under heavy parallel
  # test load a slow client send never makes the fixture give up mid-request and
  # crash on the `{:ok, chunk} =` match (which surfaced as a flaky empty step).
  @fixture_recv_timeout_ms 15_000

  test "starts a root runtime from OpenAPI config and exposes discovery" do
    {:ok, runtime} = Runtime.start_link(config: config())

    try do
      assert [%{"name" => "observatory", "tool_count" => 2}] = Runtime.catalog_snapshot(runtime)

      assert {:ok, step} = Eval.run_lisp(runtime, "(tool/servers)")
      assert [%{"name" => "observatory", "tool_count" => 2}] = step.return

      assert {:ok, dir_step} = Eval.run_lisp(runtime, "(dir 'observatory)")
      assert Enum.any?(dir_step.return, &String.contains?(&1, "observatory/list-traces"))

      assert {:ok, doc_step} = Eval.run_lisp(runtime, "(doc 'observatory/list-traces)")
      assert doc_step.return == nil
      assert Enum.join(doc_step.prints, "\n") =~ "observatory/list-traces"
    after
      Runtime.stop(runtime)
    end
  end

  test "merges caller host tools with the upstream call tool (tool: preludes work on the upstream path)" do
    # Regression: the bridge used to OVERWRITE caller `:tools` with the synthetic
    # `"call"` tool, so a host-bound `tool:` prelude (here the log/ introspection
    # prelude) failed attach on the upstream path even though the host granted it.
    {:ok, runtime} = Runtime.start_link(config: config())

    events = [
      %{"event" => "turn", "session_id" => "sess", "data" => %{"program" => "(def x 1)"}}
    ]

    try do
      assert {:ok, step} =
               Eval.run_lisp(runtime, ~S|(get (log/programs "sess") "items")|,
                 prelude: Introspection.prelude_source(),
                 tools: Introspection.tools(events)
               )

      assert step.return == ["(def x 1)"]

      # The tuple-list `tools:` shape `Lisp.run/2` accepts must merge too.
      assert {:ok, list_step} =
               Eval.run_lisp(runtime, ~S|(get (log/programs "sess") "items")|,
                 prelude: Introspection.prelude_source(),
                 tools: Map.to_list(Introspection.tools(events))
               )

      assert list_step.return == ["(def x 1)"]
    after
      Runtime.stop(runtime)
    end
  end

  test "run_lisp creates fresh per-run tool counters and drains records" do
    {:ok, runtime} = Runtime.start_link(config: config())

    program = ~S|(tool/call {:server "observatory" :tool "list-traces" :args {:org_id "acme"}})|

    try do
      {{:ok, first}, first_records} =
        Eval.run_lisp_with_records(runtime, program, max_tool_calls: 0)

      {{:ok, second}, second_records} =
        Eval.run_lisp_with_records(runtime, program, max_tool_calls: 0)

      assert first.return == %{ok: false, reason: :cap_exhausted, message: "cap_exhausted"}
      assert second.return == first.return

      assert [%{"status" => "error", "reason" => "cap_exhausted"}] = first_records
      assert [%{"status" => "error", "reason" => "cap_exhausted"}] = second_records

      refute_received {:upstream_call_recorded, _ref, _entry}
    after
      Runtime.stop(runtime)
    end
  end

  test "tool/call accepts qualified symbol form" do
    {:ok, runtime} = Runtime.start_link(config: config())

    program = ~S|(tool/call 'observatory/list-traces {:org_id "acme"})|

    try do
      {{:ok, step}, records} =
        Eval.run_lisp_with_records(runtime, program, max_tool_calls: 0)

      assert step.return == %{ok: false, reason: :cap_exhausted, message: "cap_exhausted"}
      assert [%{"server" => "observatory", "tool" => "list-traces"}] = records
    after
      Runtime.stop(runtime)
    end
  end

  test "run_lisp executes OpenAPI tool calls and drains success records" do
    {:ok, server} =
      start_http_fixture(%{
        "traces" => [
          %{"id" => "trace-1", "org_id" => "acme"}
        ]
      })

    {:ok, runtime} =
      Runtime.start_link(config: config(base_url: server.base_url, allow_insecure_http: true))

    program =
      ~S|(tool/call {:server "observatory" :tool "list-traces" :args {:org_id "acme" :limit 1}})|

    try do
      {{:ok, step}, records} = Eval.run_lisp_with_records(runtime, program)

      assert step.return == %{
               ok: true,
               value: %{"traces" => [%{"id" => "trace-1", "org_id" => "acme"}]},
               value_kind: :json
             }

      assert [
               %{
                 "server" => "observatory",
                 "tool" => "list-traces",
                 "status" => "ok",
                 "oversize" => false
               }
             ] = records

      assert_receive {:http_fixture_request, request}, 1_000
      assert request =~ "GET /api/v1/traces?"
      assert request =~ "org_id=acme"
      assert request =~ "limit=1"
    after
      Runtime.stop(runtime)
    end
  end

  test "run_lisp executes an OpenAPI tool with a path parameter, encoding the value into the path" do
    {:ok, server} =
      start_http_fixture(%{"id" => "org/42", "org_id" => "acme", "status" => "ok"})

    {:ok, runtime} =
      Runtime.start_link(config: config(base_url: server.base_url, allow_insecure_http: true))

    # `get-trace` maps to GET /api/v1/traces/{trace_id} with `org_id` as a query
    # arg. The slash in the trace id must be percent-encoded into a single path
    # segment, never leak into the query, and never appear as a literal
    # `{trace_id}` placeholder.
    program =
      ~S|(tool/call {:server "observatory" :tool "get-trace" :args {:trace_id "org/42" :org_id "acme"}})|

    try do
      {{:ok, step}, records} = Eval.run_lisp_with_records(runtime, program)

      assert step.return == %{
               ok: true,
               value: %{"id" => "org/42", "org_id" => "acme", "status" => "ok"},
               value_kind: :json
             }

      assert [%{"server" => "observatory", "tool" => "get-trace", "status" => "ok"}] = records

      # Assert the exact request line: a substring match could miss extra/garbled
      # query params or a literal `{trace_id}` segment.
      assert_receive {:http_fixture_request, request}, 1_000
      assert request_line(request) == "GET /api/v1/traces/org%2F42?org_id=acme HTTP/1.1"
    after
      Runtime.stop(runtime)
    end
  end

  test "run_lisp executes a path-only OpenAPI tool with no query string" do
    {:ok, server} = start_http_fixture(%{"trace_id" => "org/42", "cost_usd" => 1.5})

    {:ok, runtime} =
      Runtime.start_link(
        config:
          config(
            base_url: server.base_url,
            allow_insecure_http: true,
            operations: ["get_trace_cost"]
          )
      )

    # `get-trace-cost` has only a path param, so the URL must carry no `?` and no
    # query string at all (build_url's `encode_query([]) -> nil`).
    program =
      ~S|(tool/call {:server "observatory" :tool "get-trace-cost" :args {:trace_id "org/42"}})|

    try do
      {{:ok, step}, _records} = Eval.run_lisp_with_records(runtime, program)

      assert step.return.ok == true

      assert_receive {:http_fixture_request, request}, 1_000
      assert request_line(request) == "GET /api/v1/traces/org%2F42/cost HTTP/1.1"
      refute request =~ "?"
    after
      Runtime.stop(runtime)
    end
  end

  test "run_lisp encodes a boolean query parameter on a path-parameterized OpenAPI tool" do
    {:ok, server} = start_http_fixture(%{"steps" => []})

    {:ok, runtime} =
      Runtime.start_link(
        config:
          config(
            base_url: server.base_url,
            allow_insecure_http: true,
            operations: ["list_trace_steps"]
          )
      )

    # `list-trace-steps` mixes a path param (`trace_id`) with a boolean query
    # param (`summary`); the boolean must serialize as `summary=true`.
    program =
      ~S|(tool/call {:server "observatory" :tool "list-trace-steps" :args {:trace_id "trace-42" :summary true}})|

    try do
      {{:ok, step}, _records} = Eval.run_lisp_with_records(runtime, program)

      assert step.return.ok == true

      assert_receive {:http_fixture_request, request}, 1_000
      assert request_line(request) == "GET /api/v1/traces/trace-42/steps?summary=true HTTP/1.1"
    after
      Runtime.stop(runtime)
    end
  end

  test "run_lisp rejects a non-scalar OpenAPI query argument with a clear error" do
    {:ok, runtime} =
      Runtime.start_link(config: config(operations: ["list_trace_steps"]))

    # OpenAPI v1 only supports scalar query values. A list-valued `summary` must
    # be rejected with an actionable :upstream_error rather than silently dropped
    # or crashing the runtime.
    program =
      ~S|(tool/call {:server "observatory" :tool "list-trace-steps" :args {:trace_id "t1" :summary []}})|

    try do
      {{:ok, step}, _records} = Eval.run_lisp_with_records(runtime, program)

      assert step.return.ok == false
      assert step.return.reason == :upstream_error
      assert step.return.message =~ "unsupported query arg 'summary'"
    after
      Runtime.stop(runtime)
    end
  end

  test "run_lisp joins an OpenAPI base_url path prefix ahead of the operation path" do
    {:ok, server} = start_http_fixture(%{"id" => "org/42"})

    {:ok, runtime} =
      Runtime.start_link(
        config: config(base_url: server.base_url <> "/proxy", allow_insecure_http: true)
      )

    # A base_url with its own path prefix must be joined before the operation
    # path, without dropping or doubling the `/`.
    program =
      ~S|(tool/call {:server "observatory" :tool "get-trace" :args {:trace_id "org/42" :org_id "acme"}})|

    try do
      {{:ok, step}, _records} = Eval.run_lisp_with_records(runtime, program)

      assert step.return.ok == true

      assert_receive {:http_fixture_request, request}, 1_000
      assert request_line(request) == "GET /proxy/api/v1/traces/org%2F42?org_id=acme HTTP/1.1"
    after
      Runtime.stop(runtime)
    end
  end

  test "run_lisp rejects an OpenAPI call missing a required path parameter" do
    {:ok, runtime} = Runtime.start_link(config: config())

    # `trace_id` is a required path param in the compiled schema, so omitting it
    # is rejected at arg validation (before OpenAPI.call/build_url is reached),
    # which keeps a malformed `{trace_id}` URL from ever being constructed.
    program =
      ~S|(tool/call {:server "observatory" :tool "get-trace" :args {:org_id "acme"}})|

    try do
      {{:error, step}, _records} = Eval.run_lisp_with_records(runtime, program)

      assert step.fail.reason == :runtime_error
      assert step.fail.message =~ "missing required args trace_id"
    after
      Runtime.stop(runtime)
    end
  end

  test "run_lisp caps an oversized OpenAPI response as a recoverable response_too_large fault" do
    # Body far exceeds the per-run byte cap; the runtime must surface a
    # recoverable tool result instead of buffering the whole payload (memory
    # safety) or crashing the run.
    big_body = %{"traces" => Enum.map(1..50, &%{"id" => "trace-#{&1}", "org_id" => "acme"})}
    {:ok, server} = start_http_fixture(big_body)

    {:ok, runtime} =
      Runtime.start_link(
        config:
          config(
            base_url: server.base_url,
            allow_insecure_http: true,
            operations: ["list_traces"]
          )
      )

    program =
      ~S|(tool/call {:server "observatory" :tool "list-traces" :args {:org_id "acme"}})|

    try do
      {{:ok, step}, records} =
        Eval.run_lisp_with_records(runtime, program, max_response_bytes: 64)

      assert step.return.ok == false
      assert step.return.reason == :response_too_large

      assert [%{"status" => "error", "reason" => "response_too_large", "oversize" => true}] =
               records

      # The cap must apply to the *response*: prove the GET was actually sent,
      # so a regression that short-circuits before Req.request can't pass.
      assert_receive {:http_fixture_request, request}, 1_000
      assert request_line(request) =~ "GET /api/v1/traces?"
    after
      Runtime.stop(runtime)
    end
  end

  test "run_lisp preserves the HTTP error reason for a non-2xx OpenAPI response with an oversized body" do
    # A 422 whose error body exceeds the byte cap must still surface the real
    # status-derived reason (:tool_error), NOT collapse to :response_too_large.
    # The byte cap only fails 2xx success payloads loudly; for errors the actual
    # failure reason is the actionable signal and must not be masked. Memory is
    # still bounded by the streaming cap regardless of status.
    big_error = %{"error" => String.duplicate("x", 5_000)}
    {:ok, server} = start_http_fixture(big_error, status: "422 Unprocessable Entity")

    {:ok, runtime} =
      Runtime.start_link(
        config:
          config(
            base_url: server.base_url,
            allow_insecure_http: true,
            operations: ["list_traces"]
          )
      )

    program =
      ~S|(tool/call {:server "observatory" :tool "list-traces" :args {:org_id "acme"}})|

    try do
      {{:ok, step}, records} =
        Eval.run_lisp_with_records(runtime, program, max_response_bytes: 64)

      assert step.return.ok == false
      assert step.return.reason == :tool_error

      assert [%{"status" => "error", "reason" => "tool_error"}] = records

      # Prove the request actually reached the upstream, so :tool_error comes
      # from mapping the 422 response, not from a pre-request failure.
      assert_receive {:http_fixture_request, request}, 1_000
      assert request_line(request) =~ "GET /api/v1/traces?"
    after
      Runtime.stop(runtime)
    end
  end

  test "run_lisp apropos surfaces upstream tools from the live catalog, ranked above local builtins" do
    # apropos is how the LLM finds upstream tools; a regression leaves them
    # callable but invisible. The upstream tool must out-rank local builtins for
    # a query matching its name. Uses the local schema file, so no network.
    {:ok, runtime} = Runtime.start_link(config: config())

    program = ~S|(apropos "list-traces" {:limit 1})|

    try do
      {:ok, step} = Eval.run_lisp(runtime, program)

      # limit 1 -> the single top hit must be the upstream tool, not a local
      # builtin. Match the ref prefix only, so the description text isn't brittle.
      assert ["observatory/list-traces" <> _] = step.return
      assert [%{operation: :apropos, outcome: :ok, reason: nil}] = step.catalog_ops
    after
      Runtime.stop(runtime)
    end
  end

  test "root runtime can call an MCP stdio upstream" do
    script = write_stdio_fixture!()

    config = stdio_fixture_config(script)

    {:ok, runtime} = Runtime.start_link(config: config, catalog_snapshot_mode: :frozen)

    try do
      assert [%{"name" => "fixture", "tool_count" => 1}] = Runtime.catalog_snapshot(runtime)

      program = ~S|(tool/call 'fixture/echo {:message "hello"})|
      {{:ok, step}, records} = Eval.run_lisp_with_records(runtime, program)

      assert step.return == %{
               ok: true,
               value: %{"echo" => %{"message" => "hello"}},
               value_kind: :json
             }

      assert [%{"server" => "fixture", "tool" => "echo", "status" => "ok"}] = records
    after
      Runtime.stop(runtime)
    end
  end

  test "run context drains all records from pmap tool calls" do
    script = write_stdio_fixture!()

    config = stdio_fixture_config(script)

    {:ok, runtime} = Runtime.start_link(config: config, catalog_snapshot_mode: :frozen)

    program =
      ~S|(pmap (fn [message] (tool/call 'fixture/echo {:message message})) ["a" "b" "c" "d"])|

    try do
      {{:ok, step}, records} = Eval.run_lisp_with_records(runtime, program)

      assert Enum.map(step.return, &get_in(&1, [:value, "echo", "message"])) == [
               "a",
               "b",
               "c",
               "d"
             ]

      assert length(records) == 4
      assert records |> Enum.map(& &1["server"]) |> Enum.uniq() == ["fixture"]
      assert records |> Enum.map(& &1["tool"]) |> Enum.uniq() == ["echo"]
      assert records |> Enum.map(& &1["status"]) |> Enum.uniq() == ["ok"]

      assert records |> Enum.map(&get_in(&1, ["result_overview", "value_kind"])) |> Enum.uniq() ==
               ["json"]
    after
      Runtime.stop(runtime)
    end
  end

  test "large upstream pages are usable by the program while the in-eval tool ledger is bounded" do
    script = write_large_page_stdio_fixture!()
    config = stdio_fixture_config(script)

    {:ok, runtime} = Runtime.start_link(config: config, catalog_snapshot_mode: :frozen)

    program = """
    (reduce
      +
      0
      (map
        (fn [i]
          (let [r (tool/call 'fixture/page {:page i})]
            (if (r :ok)
              (count (get (r :value) "rows"))
              0)))
        (range 20)))
    """

    try do
      {{:ok, step}, records} =
        Eval.run_lisp_with_records(runtime, program,
          max_tool_call_result_bytes: 300,
          max_heap: 350_000
        )

      assert step.return == 100_000

      assert length(step.tool_calls) == 20
      assert Enum.all?(step.tool_calls, &(&1[:name] == "call"))
      assert Enum.all?(step.tool_calls, &(&1[:result_truncated] == true))

      assert Enum.all?(
               step.tool_calls,
               &(is_binary(&1[:result]) and byte_size(&1[:result]) <= 300)
             )

      assert length(records) == 20

      assert Enum.all?(
               records,
               &match?(%{"server" => "fixture", "tool" => "page", "status" => "ok"}, &1)
             )

      assert Enum.all?(
               records,
               &(get_in(&1, ["result_overview", "shape"]) == "map keys=[\"rows\"] count=1")
             )
    after
      Runtime.stop(runtime)
    end
  end

  @tag :e2e
  test "large-file MCP upstream can back the log introspection prelude API" do
    first_path =
      write_jsonl_file!("ptc_runner_large_file_logs_a", [
        turn_event("session-a", 1, "(tool/servers)", []),
        turn_event("session-a", 2, ~S|(doc "observatory/list-traces")|, []),
        turn_event("session-a", 3, ~S|(tool/call 'observatory/list-traces {:limit 2})|, [
          %{"server" => "observatory", "tool" => "list-traces", "outcome" => "ok"}
        ]),
        turn_event("session-a", 4, ~S|(tool/call 'observatory/get-trace {:id "t1"})|, [
          %{"server" => "observatory", "tool" => "get-trace", "outcome" => "ok"}
        ])
      ])

    second_path =
      write_jsonl_file!("ptc_runner_large_file_logs_b", [
        turn_event("session-b", 1, "(tool/servers)", []),
        turn_event("session-b", 2, ~S|(dir "observatory")|, []),
        turn_event("session-c", 1, ~S|(tool/call 'observatory/batch {})|, [
          %{"server" => "observatory", "tool" => "first", "outcome" => "ok"},
          %{"server" => "observatory", "tool" => "second", "outcome" => "ok"},
          %{"server" => "observatory", "tool" => "third", "outcome" => "ok"}
        ])
      ])

    {:ok, runtime} =
      Runtime.start_link(config: large_file_mcp_config(), catalog_snapshot_mode: :frozen)

    program = ~S"""
    (let [sessions-page (log/sessions {:limit 10})
          sessions (get sessions-page "items")
          programs-page (log/programs "session-a" {:limit 10})
          programs (get programs-page "items")
          calls-page (log/tool-calls "session-a" {:limit 10})
          calls (get calls-page "items")
          final-turns-page (log/turns "session-a" {:limit 4})
          final-calls-page (log/tool-calls "session-a" {:limit 2})
          chunked-calls-page (log/tool-calls "session-c" {:limit 2})
          chunked-calls-next-page (log/tool-calls "session-c" {:limit 2 :cursor (get chunked-calls-page "next_cursor")})
          turn-page (log/turns-page "session-a" 1 2)
          empty-turn-page (log/turns-page "session-a" 2 2)]
      {"sessions" sessions
       "programs" programs
       "callTools" (map (fn [call] (get call "tool")) calls)
       "finalTurnsHasMore" (get final-turns-page "has_more")
       "finalCallsHasMore" (get final-calls-page "has_more")
       "chunkedCallTools" [(map (fn [call] (get call "tool")) (get chunked-calls-page "items"))
                           (map (fn [call] (get call "tool")) (get chunked-calls-next-page "items"))]
       "turnPage" (map (fn [turn] [(get turn "turn") (get turn "program")]) turn-page)
       "emptyTurnPage" empty-turn-page})
    """

    try do
      assert {:ok, step} =
               Eval.run_lisp(runtime, program,
                 prelude: large_file_log_example_prelude_source([first_path, second_path]),
                 max_response_bytes: 1_000_000,
                 max_tool_call_result_bytes: 600
               )

      assert step.return["sessions"] == [
               %{
                 "committed" => 4,
                 "correlation_id" => "session-a",
                 "driver" => "session",
                 "failed" => 0,
                 "tool_calls" => 2,
                 "turns" => 4
               },
               %{
                 "committed" => 2,
                 "correlation_id" => "session-b",
                 "driver" => "session",
                 "failed" => 0,
                 "tool_calls" => 0,
                 "turns" => 2
               },
               %{
                 "committed" => 1,
                 "correlation_id" => "session-c",
                 "driver" => "session",
                 "failed" => 0,
                 "tool_calls" => 3,
                 "turns" => 1
               }
             ]

      assert step.return["programs"] == [
               "(tool/servers)",
               ~S|(doc "observatory/list-traces")|,
               ~S|(tool/call 'observatory/list-traces {:limit 2})|,
               ~S|(tool/call 'observatory/get-trace {:id "t1"})|
             ]

      assert step.return["callTools"] == ["list-traces", "get-trace"]
      assert step.return["finalTurnsHasMore"] == true
      assert step.return["finalCallsHasMore"] == true
      assert step.return["chunkedCallTools"] == [["first", "second"], ["third"]]

      assert step.return["turnPage"] == [
               [3, ~S|(tool/call 'observatory/list-traces {:limit 2})|],
               [4, ~S|(tool/call 'observatory/get-trace {:id "t1"})|]
             ]

      assert step.return["emptyTurnPage"] == []

      assert length(step.tool_calls) > 4
      assert Enum.all?(step.tool_calls, &(&1[:name] == "call"))
    after
      Runtime.stop(runtime)
    end
  end

  @tag :e2e
  test "large-file log tool-call pages stop when the page is full" do
    path =
      write_jsonl_file!(
        "ptc_runner_large_file_tool_calls_bounded",
        [
          turn_event("sparse", 1, "(+ 1 1)", []),
          turn_event("bounded", 1, "(tool/call 'x/a {})", [
            %{"server" => "x", "tool" => "a", "outcome" => "ok"},
            %{"server" => "x", "tool" => "b", "outcome" => "ok"},
            %{"server" => "x", "tool" => "c", "outcome" => "ok"}
          ])
          | Enum.map(2..20, fn turn -> turn_event("bounded", turn, "(+ 1 1)", []) end)
        ]
      )

    {:ok, runtime} =
      Runtime.start_link(config: large_file_mcp_config(), catalog_snapshot_mode: :frozen)

    program = ~S"""
    (let [turn-page (log/turns "sparse" {:limit 1})
          page (log/tool-calls "bounded" {:limit 2})
          next-page (log/tool-calls "bounded" {:limit 1 :cursor (get page "next_cursor")})]
      {"tools" (map (fn [call] (get call "tool")) (get page "items"))
       "hasMore" (get page "has_more")
       "nextCursor" (get page "next_cursor")
       "nextTools" (map (fn [call] (get call "tool")) (get next-page "items"))
       "sparseTurns" (map (fn [turn] (get turn "turn")) (get turn-page "items"))
       "sparseHasMore" (get turn-page "has_more")
       "sparseNextCursor" (get turn-page "next_cursor")})
    """

    try do
      assert {:ok, step} =
               Eval.run_lisp(runtime, program,
                 prelude: large_file_log_example_prelude_source([path], lines_per_page: 1),
                 max_tool_calls: 12,
                 max_response_bytes: 1_000_000,
                 max_tool_call_result_bytes: 600
               )

      assert step.return == %{
               "tools" => ["a", "b"],
               "hasMore" => true,
               "nextCursor" => "0:0:0:2",
               "nextTools" => ["c"],
               "sparseTurns" => [1],
               "sparseHasMore" => true,
               "sparseNextCursor" => "0:1:0"
             }
    after
      Runtime.stop(runtime)
    end
  end

  @tag :e2e
  test "large-file log prelude can inspect realistic ptc-bench-comparison turn logs" do
    paths = realistic_bench_turn_log_paths()

    if paths == [] do
      IO.puts("Skipping local corpus smoke: #{@bench_planted_turn_log_dir} is unavailable")
    else
      events = Enum.flat_map(paths, &Analyzer.load/1)
      host_tools = Introspection.tools(events)
      expected_sessions = get_in(host_tools["log_sessions"].(%{}), ["items"])
      first_session_id = List.first(expected_sessions)["correlation_id"]

      expected_programs =
        get_in(host_tools["log_programs"].(%{"session-id" => first_session_id}), ["items"])

      expected_calls =
        get_in(host_tools["log_tool_calls"].(%{"session-id" => first_session_id}), ["items"])

      {:ok, runtime} =
        Runtime.start_link(config: large_file_mcp_config(), catalog_snapshot_mode: :frozen)

      program = """
      (let [sessions-page (log/sessions {:limit 20})
            sessions (get sessions-page "items")
            sid "#{first_session_id}"
            programs (log/programs-page sid 0 4)
            calls (log/tool-calls-page sid 0 6)]
        {"sessionCount" (count sessions)
         "firstSession" (first sessions)
         "programs" programs
         "callCount" (count calls)
         "callTools" (map (fn [call] (get call "tool")) calls)})
      """

      try do
        assert {:ok, step} =
                 Eval.run_lisp(runtime, program,
                   prelude: large_file_log_example_prelude_source(paths, lines_per_page: 5),
                   max_heap: 20_000_000,
                   max_response_bytes: 2_000_000,
                   max_tool_calls: 200,
                   max_tool_call_result_bytes: 250_000
                 )

        assert step.return["sessionCount"] > 0
        assert step.return["sessionCount"] <= min(length(expected_sessions), 20)
        assert is_map(step.return["firstSession"])
        assert is_binary(step.return["firstSession"]["correlation_id"])
        assert step.return["programs"] == Enum.take(expected_programs, 4)
        assert step.return["callCount"] > 0
        assert step.return["callCount"] <= min(length(expected_calls), 6)

        assert step.return["callTools"] ==
                 expected_calls
                 |> Enum.take(step.return["callCount"])
                 |> Enum.map(&Map.get(&1, "tool"))
      after
        Runtime.stop(runtime)
      end
    end
  end

  test "root runtime can call an MCP HTTP upstream" do
    {:ok, server} = start_mcp_http_fixture()

    config = %{
      "upstreams" => %{
        "fixture" => %{
          "transport" => "mcp_http",
          "url" => server.url,
          "allow_insecure_http" => true
        }
      }
    }

    {:ok, runtime} = Runtime.start_link(config: config)

    try do
      assert [%{"name" => "fixture", "tool_count" => 1}] = Runtime.catalog_snapshot(runtime)

      program = ~S|(tool/call 'fixture/echo {:message "hello"})|
      {{:ok, step}, records} = Eval.run_lisp_with_records(runtime, program)

      assert step.return == %{
               ok: true,
               value: %{"echo" => %{"message" => "hello"}},
               value_kind: :json
             }

      assert [%{"server" => "fixture", "tool" => "echo", "status" => "ok"}] = records

      assert_receive {:mcp_http_fixture_request, "initialize", _headers}, 1_000
      assert_receive {:mcp_http_fixture_request, "notifications/initialized", headers}, 1_000

      assert Enum.any?(headers, fn {key, value} ->
               String.downcase(key) == "mcp-session-id" and value == "root-test-session"
             end)

      assert_receive {:mcp_http_fixture_request, "tools/list", _headers}, 1_000
      assert_receive {:mcp_http_fixture_request, "tools/call", _headers}, 1_000
    after
      Runtime.stop(runtime)
    end
  end

  test "root MCP HTTP transport normalizes SSE tool responses" do
    {:ok, server} = start_mcp_http_fixture(sse?: true)

    config = %{
      "upstreams" => %{
        "fixture" => %{
          "transport" => "mcp_http",
          "url" => server.url,
          "allow_insecure_http" => true
        }
      }
    }

    {:ok, runtime} = Runtime.start_link(config: config)

    try do
      program = ~S|(tool/call 'fixture/echo {:message "hello"})|
      {{:ok, step}, records} = Eval.run_lisp_with_records(runtime, program)

      assert step.return == %{
               ok: true,
               value: %{"echo" => %{"message" => "hello"}},
               value_kind: :json
             }

      assert [%{"server" => "fixture", "tool" => "echo", "status" => "ok"}] = records
    after
      Runtime.stop(runtime)
    end
  end

  test "root MCP HTTP transport applies credential-backed auth headers" do
    {:ok, server} = start_mcp_http_fixture()

    config = %{
      "credentials" => %{
        "fixture-token" => %{
          "source" => "literal",
          "value" => "http-secret",
          "scheme_hint" => "bearer"
        }
      },
      "upstreams" => %{
        "fixture" => %{
          "transport" => "mcp_http",
          "url" => server.url,
          "allow_insecure_http" => true,
          "allow_insecure_auth" => true,
          "auth" => [%{"scheme" => "bearer", "binding" => "fixture-token"}]
        }
      }
    }

    {:ok, runtime} = Runtime.start_link(config: config)

    try do
      assert Runtime.scrub(runtime, "Authorization: Bearer http-secret") ==
               "Authorization: Bearer [REDACTED]"

      assert [%{"name" => "fixture", "catalog_loaded" => true}] =
               Runtime.catalog_snapshot(runtime)

      assert_receive {:mcp_http_fixture_request, "initialize", headers}, 1_000

      assert Enum.any?(headers, fn {key, value} ->
               String.downcase(key) == "authorization" and value == "Bearer http-secret"
             end)
    after
      Runtime.stop(runtime)
    end
  end

  test "root MCP HTTP transport surfaces isError tool results and redacts secrets in the message" do
    {:ok, server} =
      start_mcp_http_fixture(
        tool_call_response: fn socket, id, _args ->
          # A real MCP server signals tool-level failure with a successful
          # JSON-RPC envelope carrying isError: true. The error text echoes the
          # auth secret, which must be redacted before reaching the program.
          json_response(socket, id, %{
            "isError" => true,
            "content" => [%{"type" => "text", "text" => "denied mcp-secret"}]
          })
        end
      )

    config = %{
      "credentials" => %{
        "fixture-token" => %{
          "source" => "literal",
          "value" => "mcp-secret",
          "scheme_hint" => "bearer"
        }
      },
      "upstreams" => %{
        "fixture" => %{
          "transport" => "mcp_http",
          "url" => server.url,
          "allow_insecure_http" => true,
          "allow_insecure_auth" => true,
          "auth" => [%{"scheme" => "bearer", "binding" => "fixture-token"}]
        }
      }
    }

    {:ok, runtime} = Runtime.start_link(config: config)
    program = ~S|(tool/call 'fixture/echo {:message "hello"})|

    try do
      {{:ok, step}, records} = Eval.run_lisp_with_records(runtime, program)

      assert step.return == %{ok: false, reason: :tool_error, message: "denied [REDACTED]"}

      # The diagnostics record is a separate redaction surface from step.return;
      # assert the secret is scrubbed there too, not just in the program value.
      assert [
               %{
                 "server" => "fixture",
                 "tool" => "echo",
                 "status" => "error",
                 "reason" => "tool_error",
                 "error" => "denied [REDACTED]"
               }
             ] = records

      refute inspect(records) =~ "mcp-secret"
    after
      Runtime.stop(runtime)
    end
  end

  test "root MCP HTTP transport JSON-decodes a text-only content block into structured data" do
    {:ok, server} =
      start_mcp_http_fixture(
        tool_call_response: fn socket, id, _args ->
          # No structuredContent: the only payload is a JSON string inside a text
          # content block. It must be decoded into usable data, not left opaque.
          json_response(socket, id, %{
            "content" => [%{"type" => "text", "text" => ~s({"echo":{"message":"hello"}})}]
          })
        end
      )

    config = %{
      "upstreams" => %{
        "fixture" => %{
          "transport" => "mcp_http",
          "url" => server.url,
          "allow_insecure_http" => true
        }
      }
    }

    {:ok, runtime} = Runtime.start_link(config: config)
    program = ~S|(tool/call 'fixture/echo {:message "hello"})|

    try do
      {{:ok, step}, _records} = Eval.run_lisp_with_records(runtime, program)

      assert step.return == %{
               ok: true,
               value: %{"echo" => %{"message" => "hello"}},
               value_kind: :json
             }
    after
      Runtime.stop(runtime)
    end
  end

  test "root MCP HTTP transport selects the matching id from a batched SSE stream" do
    {:ok, server} =
      start_mcp_http_fixture(
        tool_call_response: fn socket, id, _args ->
          # SSE can interleave responses/notifications for other request ids.
          # Wrong ids share the real id's integer type, and the real message sits
          # in the MIDDLE of the batched array, so neither "take first/last
          # element" nor "take first integer id" passes — only true correlation
          # on the request id selects it.
          wrong_before = sse_envelope(id + 10, "wrong-before")
          wrong_after = sse_envelope(id + 20, "wrong-after")
          right = sse_envelope(id, "hello")

          body =
            "data: " <>
              Jason.encode!(wrong_before) <>
              "\n\n" <>
              "data: " <> Jason.encode!([wrong_before, right, wrong_after]) <> "\n\n"

          raw_sse_response(socket, body)
        end
      )

    config = %{
      "upstreams" => %{
        "fixture" => %{
          "transport" => "mcp_http",
          "url" => server.url,
          "allow_insecure_http" => true
        }
      }
    }

    {:ok, runtime} = Runtime.start_link(config: config)
    program = ~S|(tool/call 'fixture/echo {:message "hello"})|

    try do
      {{:ok, step}, _records} = Eval.run_lisp_with_records(runtime, program)

      assert step.return.ok == true
      assert get_in(step.return.value, ["echo", "message"]) == "hello"
      refute inspect(step.return.value) =~ "wrong"
    after
      Runtime.stop(runtime)
    end
  end

  test "root MCP HTTP transport prefers isError over a present structuredContent" do
    {:ok, server} =
      start_mcp_http_fixture(
        tool_call_response: fn socket, id, _args ->
          # isError must win even when structuredContent is also present, so a
          # failing call is never reported as a success carrying stale data.
          json_response(socket, id, %{
            "isError" => true,
            "structuredContent" => %{"echo" => %{"message" => "should-not-win"}},
            "content" => [%{"type" => "text", "text" => "boom"}]
          })
        end
      )

    config = %{
      "upstreams" => %{
        "fixture" => %{
          "transport" => "mcp_http",
          "url" => server.url,
          "allow_insecure_http" => true
        }
      }
    }

    {:ok, runtime} = Runtime.start_link(config: config)
    program = ~S|(tool/call 'fixture/echo {:message "hello"})|

    try do
      {{:ok, step}, _records} = Eval.run_lisp_with_records(runtime, program)

      assert step.return == %{ok: false, reason: :tool_error, message: "boom"}
      refute inspect(step.return) =~ "should-not-win"
    after
      Runtime.stop(runtime)
    end
  end

  test "root credential emitters support bearer, basic, and custom headers" do
    {:ok, credentials} =
      Credentials.new(%{
        "bearer" => %{"source" => "literal", "value" => "token"},
        "basic" => %{"source" => "literal", "value" => ~s({"user":"u","pass":"p"})},
        "custom" => %{"source" => "literal", "value" => "api-secret"}
      })

    assert {:ok,
            [
              {"authorization", "Bearer token"},
              {"authorization", "Basic dTpw"},
              {"X-Api-Token", "api-secret"}
            ]} =
             Credentials.headers(credentials, [
               %{"scheme" => "bearer", "binding" => "bearer"},
               %{"scheme" => "basic", "binding" => "basic"},
               %{"scheme" => "custom_header", "binding" => "custom", "header" => "X-Api-Token"}
             ])

    assert {:error, :upstream_unavailable, message} =
             Credentials.headers(credentials, [
               %{"scheme" => "custom_header", "binding" => "custom", "header" => "Authorization"}
             ])

    assert message =~ "invalid custom auth header"
  end

  test "old MCP transport names are rejected in root config" do
    assert {:error, {:upstream_unavailable, message}} =
             Runtime.start_link(config: %{"upstreams" => %{"fs" => %{"transport" => "stdio"}}})

    assert message =~ "use mcp_stdio or mcp_http"
  end

  test "root config rejects insecure URLs and reserved static headers" do
    assert {:error, {:upstream_unavailable, insecure_message}} =
             Runtime.start_link(
               config: %{
                 "upstreams" => %{
                   "remote" => %{"transport" => "mcp_http", "url" => "http://example.test/mcp"}
                 }
               }
             )

    assert insecure_message =~ "allow_insecure_http"

    assert {:error, {:upstream_unavailable, header_message}} =
             Runtime.start_link(
               config: %{
                 "upstreams" => %{
                   "remote" => %{
                     "transport" => "mcp_http",
                     "url" => "https://example.test/mcp",
                     "static_headers" => %{"Authorization" => "Bearer nope"}
                   }
                 }
               }
             )

    assert header_message =~ "reserved"
  end

  test "root OpenAPI config requires exactly one schema source" do
    assert {:error, {:upstream_unavailable, missing_message}} =
             Runtime.start_link(
               config: %{
                 "upstreams" => %{
                   "observatory" => %{
                     "transport" => "openapi",
                     "base_url" => "https://observatory.example",
                     "include_operations" => ["list_traces"]
                   }
                 }
               }
             )

    assert missing_message =~ "exactly one"

    assert {:error, {:upstream_unavailable, duplicate_message}} =
             Runtime.start_link(
               config: %{
                 "upstreams" => %{
                   "observatory" => %{
                     "transport" => "openapi",
                     "base_url" => "https://observatory.example",
                     "schema_file" => @schema,
                     "schema_url" => "https://observatory.example/openapi.json",
                     "include_operations" => ["list_traces"]
                   }
                 }
               }
             )

    assert duplicate_message =~ "exactly one"
  end

  test "root config validates auth binding references at load time" do
    assert {:error, {:upstream_unavailable, message}} =
             Runtime.start_link(
               config: %{
                 "upstreams" => %{
                   "remote" => %{
                     "transport" => "mcp_http",
                     "url" => "https://example.test/mcp",
                     "auth" => [%{"scheme" => "bearer", "binding" => "missing-token"}]
                   }
                 }
               }
             )

    assert message =~ "unknown credential binding missing-token"
  end

  test "run context close stops the collector" do
    {:ok, runtime} = Runtime.start_link(config: config())

    try do
      {:ok, context} = Eval.run_context(runtime)

      assert :ok = RunContext.ensure_open(context)
      assert :ok = RunContext.close(context)
      refute Process.alive?(context.collector.pid)
      assert :ok = RunContext.close(context)
      assert {:error, :run_context_closed} = RunContext.ensure_open(context)
    after
      Runtime.stop(runtime)
    end
  end

  test "stale upstream tool closures fail closed before dispatch" do
    {:ok, server} =
      start_http_fixture(%{
        "traces" => [
          %{"id" => "trace-1", "org_id" => "acme"}
        ]
      })

    {:ok, runtime} =
      Runtime.start_link(config: config(base_url: server.base_url, allow_insecure_http: true))

    try do
      {:ok, context} = Eval.run_context(runtime)
      call = Eval.eval_options(context)[:tools]["call"]

      assert :ok = RunContext.close(context)

      assert call.(%{server: "observatory", tool: "list-traces", args: %{org_id: "acme"}}) ==
               %{ok: false, reason: :run_context_closed, message: "run_context_closed"}

      refute_receive {:http_fixture_request, _request}, 100
      assert [] = RunContext.drain_calls(context)
    after
      Runtime.stop(runtime)
    end
  end

  test "stale upstream tool closures fail closed before argument validation" do
    {:ok, runtime} = Runtime.start_link(config: config())

    try do
      {:ok, context} = Eval.run_context(runtime)
      call = Eval.eval_options(context)[:tools]["call"]

      assert :ok = RunContext.close(context)

      assert call.(:not_a_map) ==
               %{ok: false, reason: :run_context_closed, message: "run_context_closed"}
    after
      Runtime.stop(runtime)
    end
  end

  test "stale upstream discovery closures fail closed" do
    {:ok, runtime} = Runtime.start_link(config: config())

    try do
      {:ok, context} = Eval.run_context(runtime)
      discovery_exec = Eval.eval_options(context)[:discovery_exec]

      assert :ok = RunContext.close(context)

      assert discovery_exec.(:servers, []) == {:world_fault, :run_context_closed}
    after
      Runtime.stop(runtime)
    end
  end

  test "with_run_context closes the collector when callback raises" do
    {:ok, runtime} = Runtime.start_link(config: config())
    parent = self()

    try do
      assert_raise RuntimeError, "boom", fn ->
        Eval.with_run_context(runtime, [], fn context ->
          send(parent, {:collector, context.collector.pid})
          raise "boom"
        end)
      end

      assert_receive {:collector, pid}
      refute Process.alive?(pid)
    after
      Runtime.stop(runtime)
    end
  end

  test "catalog text honors lazy exposure mode and diagnostics expose runtime facts" do
    {:ok, runtime} =
      Runtime.start_link(
        config: config(),
        catalog_exposure_mode: :lazy,
        catalog_snapshot_mode: :frozen
      )

    try do
      assert Runtime.catalog_text(runtime) == "observatory (2 tools)"

      assert %{
               upstreams: ["observatory"],
               catalog_exposure_mode: :lazy,
               catalog_snapshot_mode: :frozen,
               transports: %{"observatory" => :openapi}
             } = Runtime.diagnostics(runtime)
    after
      Runtime.stop(runtime)
    end
  end

  test "runtime redactor scope scrubs credential material from diagnostics terms" do
    {:ok, runtime} = Runtime.start_link(config: credential_config())

    try do
      secret = "root-runtime-secret"

      assert Runtime.scrub(runtime, "Bearer #{secret}") == "Bearer [REDACTED]"

      assert Runtime.scrub(runtime, %{
               "error" => "request included #{secret}",
               "nested" => ["token=#{secret}"]
             }) == %{
               "error" => "request included [REDACTED]",
               "nested" => ["token=[REDACTED]"]
             }
    after
      Runtime.stop(runtime)
    end
  end

  test "catalog and discovery outputs scrub credential material" do
    secret = "catalog-secret-token"

    {:ok, runtime} =
      Runtime.start_link(
        config:
          credential_config(secret)
          |> put_in(["upstreams", "observatory", "description"], "server #{secret}")
          |> put_in(["upstreams", "observatory", "operation_overrides"], %{})
          |> put_in(
            ["upstreams", "observatory", "operation_overrides", "list_traces"],
            %{"description" => "tool #{secret}"}
          )
      )

    try do
      catalog_text = Runtime.catalog_text(runtime)
      refute catalog_text =~ secret
      assert catalog_text =~ "[REDACTED]"

      assert {:ok, servers_step} = Eval.run_lisp(runtime, "(tool/servers)")
      refute inspect(servers_step.return) =~ secret

      assert {:ok, dir_step} = Eval.run_lisp(runtime, "(dir 'observatory)")
      refute inspect(dir_step.return) =~ secret

      assert {:ok, doc_step} = Eval.run_lisp(runtime, "(doc 'observatory/list-traces)")
      assert doc_step.return == nil
      refute Enum.join(doc_step.prints, "\n") =~ secret

      assert {:ok, meta_step} = Eval.run_lisp(runtime, "(meta 'observatory/list-traces)")
      refute inspect(meta_step.return) =~ secret
    after
      Runtime.stop(runtime)
    end
  end

  test "discovery results enforce max_catalog_result_bytes" do
    {:ok, runtime} = Runtime.start_link(config: config())

    try do
      assert {:ok, step} =
               Eval.run_lisp(runtime, "(dir 'observatory)", max_catalog_result_bytes: 10)

      assert step.return == nil

      assert [
               %{
                 operation: :dir,
                 outcome: :nil_world_fault,
                 reason: :catalog_result_too_large
               }
             ] = step.catalog_ops
    after
      Runtime.stop(runtime)
    end
  end

  test "live snapshot mode does not eagerly start unavailable MCP client upstreams" do
    config = %{
      "upstreams" => %{
        "missing" => %{
          "transport" => "mcp_stdio",
          "command" => "/definitely/not/a/real/command"
        }
      }
    }

    assert {:ok, runtime} = Runtime.start_link(config: config, catalog_snapshot_mode: :live)

    try do
      assert [
               %{
                 "name" => "missing",
                 "catalog_loaded" => false,
                 "tool_count" => 0,
                 "tools" => []
               }
             ] = Runtime.catalog_snapshot(runtime)
    after
      Runtime.stop(runtime)
    end
  end

  test "multiple root runtimes keep redaction scopes separate" do
    {:ok, runtime_a} = Runtime.start_link(config: credential_config("secret-a"))
    {:ok, runtime_b} = Runtime.start_link(config: credential_config("secret-b"))

    try do
      assert Runtime.scrub(runtime_a, "secret-a secret-b") == "[REDACTED] secret-b"
      assert Runtime.scrub(runtime_b, "secret-a secret-b") == "secret-a [REDACTED]"
    after
      Runtime.stop(runtime_a)
      Runtime.stop(runtime_b)
    end
  end

  # First line of a raw HTTP request (e.g. "GET /path?q=1 HTTP/1.1").
  defp request_line(request), do: request |> String.split("\r\n", parts: 2) |> List.first()

  defp config(opts \\ []) do
    %{
      "upstreams" => %{
        "observatory" => %{
          "transport" => "openapi",
          "base_url" => Keyword.get(opts, :base_url, "https://observatory.example"),
          "schema_file" => @schema,
          "include_operations" => Keyword.get(opts, :operations, ["list_traces", "get_trace"]),
          "allow_insecure_http" => Keyword.get(opts, :allow_insecure_http, false)
        }
      }
    }
  end

  defp credential_config(secret \\ "root-runtime-secret") do
    config()
    |> Map.put("credentials", %{
      "observatory-token" => %{
        "source" => "literal",
        "value" => secret,
        "scheme_hint" => "bearer"
      }
    })
    |> put_in(["upstreams", "observatory", "auth"], [
      %{"scheme" => "bearer", "binding" => "observatory-token"}
    ])
  end

  defp start_http_fixture(response_body, opts \\ []) do
    parent = self()
    response_json = Jason.encode!(response_body)
    status_line = Keyword.get(opts, :status, "200 OK")

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen_socket)

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, request} = :gen_tcp.recv(socket, 0, @fixture_recv_timeout_ms)
        send(parent, {:http_fixture_request, request})

        response = [
          "HTTP/1.1 #{status_line}\r\n",
          "content-type: application/json\r\n",
          "content-length: #{byte_size(response_json)}\r\n",
          "connection: close\r\n",
          "\r\n",
          response_json
        ]

        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
      end)

    {:ok, %{pid: pid, base_url: "http://127.0.0.1:#{port}"}}
  end

  defp write_stdio_fixture! do
    path =
      Path.join(
        System.tmp_dir!(),
        "ptc_runner_mcp_stdio_fixture_#{System.unique_integer([:positive])}.exs"
      )

    File.write!(path, ~S'''
    tools = [
      %{
        "name" => "echo",
        "description" => "Echo arguments",
        "inputSchema" => %{"type" => "object", "properties" => %{"message" => %{"type" => "string"}}}
      }
    ]

    for line <- IO.stream(:stdio, :line) do
      {:ok, frame} = Jason.decode(String.trim(line))
      id = frame["id"]

      response =
        case frame["method"] do
          "initialize" ->
            %{"jsonrpc" => "2.0", "id" => id, "result" => %{"capabilities" => %{}}}

          "notifications/initialized" ->
            nil

          "tools/list" ->
            %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => tools}}

          "tools/call" ->
            args = get_in(frame, ["params", "arguments"]) || %{}
            %{"jsonrpc" => "2.0", "id" => id, "result" => %{"structuredContent" => %{"echo" => args}}}
        end

      if response do
        IO.puts(Jason.encode!(response))
      end
    end
    ''')

    path
  end

  defp write_large_page_stdio_fixture! do
    path =
      Path.join(
        System.tmp_dir!(),
        "ptc_runner_mcp_large_page_fixture_#{System.unique_integer([:positive])}.exs"
      )

    File.write!(path, ~S'''
    tools = [
      %{
        "name" => "page",
        "description" => "Return one large numeric page",
        "inputSchema" => %{
          "type" => "object",
          "required" => ["page"],
          "properties" => %{"page" => %{"type" => "integer"}}
        }
      }
    ]

    page_rows = Enum.to_list(1..5_000)

    for line <- IO.stream(:stdio, :line) do
      {:ok, frame} = Jason.decode(String.trim(line))
      id = frame["id"]

      response =
        case frame["method"] do
          "initialize" ->
            %{"jsonrpc" => "2.0", "id" => id, "result" => %{"capabilities" => %{}}}

          "notifications/initialized" ->
            nil

          "tools/list" ->
            %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => tools}}

          "tools/call" ->
            %{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => %{"structuredContent" => %{"rows" => page_rows}}
            }
        end

      if response do
        IO.puts(Jason.encode!(response))
      end
    end
    ''')

    path
  end

  defp write_jsonl_file!(prefix, rows) do
    path = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}.jsonl")
    File.write!(path, Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n")
    path
  end

  defp turn_event(session_id, turn, program, tool_calls) do
    %{
      "event" => "turn",
      "driver" => "session",
      "session_id" => session_id,
      "turn" => turn,
      "attempt" => turn,
      "committed" => true,
      "status" => "ok",
      "data" => %{
        "program" => program,
        "result_preview" => "ok",
        "tool_calls" => tool_calls
      }
    }
  end

  defp large_file_mcp_config do
    %{
      "upstreams" => %{
        "logs" => %{
          "transport" => "mcp_stdio",
          "command" => System.find_executable("npx"),
          "args" => ["-y", "@willianpinho/large-file-mcp"],
          "env" => %{"OVERLAP_LINES" => "0", "CACHE_ENABLED" => "false"},
          "handshake_timeout_ms" => 60_000,
          "description" => "Large-file MCP server for paged JSONL log smoke tests"
        }
      }
    }
  end

  defp realistic_bench_turn_log_paths do
    Path.wildcard(Path.join(@bench_planted_turn_log_dir, "*.jsonl"))
    |> Enum.sort_by(fn path -> File.stat!(path).size end, :desc)
    |> Enum.take(6)
  end

  defp large_file_log_example_prelude_source(paths, opts \\ []) do
    paths_source = inspect(paths, charlists: :as_lists)
    lines_per_page = Keyword.get(opts, :lines_per_page, 2)

    Path.expand(
      "../../examples/large_file_log_introspection/large_file_log_introspection.clj",
      __DIR__
    )
    |> File.read!()
    |> String.replace(~S(["__REPLACE_WITH_ABSOLUTE_TURN_LOG_JSONL_PATH__"]), paths_source)
    |> String.replace("(def lines-per-page 500)", "(def lines-per-page #{lines_per_page})")
  end

  defp stdio_fixture_config(script) do
    # Derive Jason's ebin from the loaded module rather than hard-coding
    # `_build/test/lib/jason/ebin`, so the spawned `elixir` finds Jason even
    # under a custom MIX_BUILD_PATH (where deps compile outside `_build/test`).
    jason_ebin = Jason |> :code.which() |> to_string() |> Path.dirname()

    %{
      "upstreams" => %{
        "fixture" => %{
          "transport" => "mcp_stdio",
          "command" => System.find_executable("elixir"),
          "args" => ["-pa", jason_ebin, script],
          "cd" => File.cwd!()
        }
      }
    }
  end

  defp start_mcp_http_fixture(opts \\ []) do
    parent = self()

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen_socket)

    pid =
      spawn_link(fn ->
        serve_mcp_http(parent, listen_socket, 4, opts)
        :gen_tcp.close(listen_socket)
      end)

    {:ok, %{pid: pid, url: "http://127.0.0.1:#{port}/mcp"}}
  end

  defp serve_mcp_http(_parent, _listen_socket, 0, _opts), do: :ok

  defp serve_mcp_http(parent, listen_socket, remaining, opts) do
    {:ok, socket} = :gen_tcp.accept(listen_socket)
    {:ok, request} = read_http_request(socket)
    method = get_in(request, [:decoded, "method"])
    send(parent, {:mcp_http_fixture_request, method, request.headers})
    send_mcp_http_response(socket, request.decoded, opts)
    :gen_tcp.close(socket)
    serve_mcp_http(parent, listen_socket, remaining - 1, opts)
  end

  defp read_http_request(socket) do
    {:ok, head} = read_until(socket, "\r\n\r\n", "")
    [header_text, rest] = String.split(head, "\r\n\r\n", parts: 2)
    [_request_line | header_lines] = String.split(header_text, "\r\n")

    headers =
      Enum.map(header_lines, fn line ->
        [key, value] = String.split(line, ":", parts: 2)
        {String.trim(key), String.trim(value)}
      end)

    content_length =
      headers
      |> Enum.find_value("0", fn {key, value} ->
        if String.downcase(key) == "content-length", do: value
      end)
      |> String.to_integer()

    body = read_body(socket, rest, content_length)
    {:ok, %{headers: headers, body: body, decoded: Jason.decode!(body)}}
  end

  defp read_until(socket, marker, acc) do
    if String.contains?(acc, marker) do
      {:ok, acc}
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, @fixture_recv_timeout_ms)
      read_until(socket, marker, acc <> chunk)
    end
  end

  defp read_body(_socket, buffered, length) when byte_size(buffered) >= length do
    binary_part(buffered, 0, length)
  end

  defp read_body(socket, buffered, length) do
    {:ok, chunk} = :gen_tcp.recv(socket, length - byte_size(buffered), @fixture_recv_timeout_ms)
    read_body(socket, buffered <> chunk, length)
  end

  defp send_mcp_http_response(socket, %{"method" => "notifications/initialized"}, _opts) do
    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 202 Accepted\r\n",
        "mcp-session-id: root-test-session\r\n",
        "content-length: 0\r\n",
        "connection: close\r\n\r\n"
      ])
  end

  defp send_mcp_http_response(socket, %{"id" => id, "method" => "initialize"}, _opts) do
    json_response(socket, id, %{"protocolVersion" => "2025-06-18", "capabilities" => %{}},
      session?: true
    )
  end

  defp send_mcp_http_response(socket, %{"id" => id, "method" => "tools/list"}, _opts) do
    json_response(socket, id, %{
      "tools" => [
        %{
          "name" => "echo",
          "description" => "Echo arguments",
          "inputSchema" => %{"type" => "object"}
        }
      ]
    })
  end

  defp send_mcp_http_response(socket, %{"id" => id, "method" => "tools/call"} = frame, opts) do
    args = get_in(frame, ["params", "arguments"]) || %{}

    case Keyword.get(opts, :tool_call_response) do
      fun when is_function(fun, 3) ->
        fun.(socket, id, args)

      nil ->
        if Keyword.get(opts, :sse?, false) do
          sse_response(socket, id, %{"structuredContent" => %{"echo" => args}})
        else
          json_response(socket, id, %{"structuredContent" => %{"echo" => args}})
        end
    end
  end

  defp json_response(socket, id, result, opts \\ []) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

    session_header =
      if Keyword.get(opts, :session?, false),
        do: "mcp-session-id: root-test-session\r\n",
        else: ""

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\n",
        "content-type: application/json\r\n",
        session_header,
        "content-length: #{byte_size(body)}\r\n",
        "connection: close\r\n",
        "\r\n",
        body
      ])
  end

  defp sse_response(socket, id, result) do
    event =
      "data: " <> Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}) <> "\n\n"

    raw_sse_response(socket, event)
  end

  # A JSON-RPC tools/call success envelope tagged with `id`, echoing `message`.
  defp sse_envelope(id, message) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"structuredContent" => %{"echo" => %{"message" => message}}}
    }
  end

  # Send an already-encoded SSE body verbatim, so tests can craft multi-event
  # streams (e.g. wrong-id events, batched arrays) to exercise id correlation.
  defp raw_sse_response(socket, body) do
    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\n",
        "content-type: text/event-stream\r\n",
        "content-length: #{byte_size(body)}\r\n",
        "connection: close\r\n",
        "\r\n",
        body
      ])
  end
end
