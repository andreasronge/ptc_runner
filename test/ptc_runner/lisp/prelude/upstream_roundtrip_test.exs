defmodule PtcRunner.Lisp.Prelude.UpstreamRoundtripTest do
  use ExUnit.Case, async: true

  @moduledoc """
  A tool-backed capability-prelude export executing END-TO-END against a
  reachable HTTP upstream.

  This closes a gap the existing suites leave open:

    * `attach_test.exs` validates `requires` against an UNREACHABLE upstream
      (`observatory.example`) — it proves the attach guard fails/passes, but the
      export is never actually executed.
    * `upstream_runtime_test.exs` executes a BARE `(tool/call ...)` against a
      reachable `start_http_fixture` server — but with no prelude in the path.

  This test combines them: a prelude export wrapping a literal `(tool/call ...)`
  runs through `Upstream.Eval.run_lisp` against a reachable local HTTP fixture,
  so attach-time `requires` validation passes AND the real round-trip returns
  the recoverable result map. It is the deterministic, no-LLM counterpart to the
  manual REPL check against `examples/ptc_repl_dummy_upstream`.
  """

  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Upstream.Eval
  alias PtcRunner.Upstream.Runtime

  @schema Path.expand(
            "../../../../mcp_server/test/fixtures/openapi/observatory.openapi.json",
            __DIR__
          )
  @fixture_recv_timeout_ms 15_000

  # A prelude whose PUBLIC export wraps a literal upstream `(tool/call ...)`, so
  # the compiler infers requires == ["upstream:observatory/list-traces"].
  defp direct_prelude do
    {:ok, prelude} =
      Compiler.compile("""
      (ns api "Observatory API." {:visibility :prompt})

      (defn list-traces
        "List traces for an org."
        [org-id]
        (tool/call {:server "observatory" :tool "list-traces"
                    :args {:org_id org-id :limit 1}}))
      """)

    prelude
  end

  # A prelude that reaches the upstream THROUGH a private helper, so `requires`
  # is inferred transitively — and must still execute end-to-end.
  defp transitive_prelude do
    {:ok, prelude} =
      Compiler.compile("""
      (ns api "Observatory API." {:visibility :prompt})

      (defn- fetch
        "Private upstream fetch."
        [org-id]
        (tool/call {:server "observatory" :tool "list-traces"
                    :args {:org_id org-id :limit 1}}))

      (defn list-traces
        "List traces for an org (via a private helper)."
        [org-id]
        (fetch org-id))
      """)

    prelude
  end

  describe "tool-backed prelude export against a reachable upstream" do
    test "attach validation passes and the export returns the recoverable result" do
      {:ok, server} = start_http_fixture(%{"traces" => [%{"id" => "t-1", "org_id" => "acme"}]})

      {:ok, runtime} =
        Runtime.start_link(config: config(base_url: server.base_url))

      try do
        {{:ok, step}, records} =
          Eval.run_lisp_with_records(runtime, ~S|(api/list-traces "acme")|,
            prelude: direct_prelude()
          )

        # The export's value IS the recoverable tool/call result map (branchable
        # by user code as (res :ok)/(res :value)).
        assert step.return == %{
                 ok: true,
                 value: %{"traces" => [%{"id" => "t-1", "org_id" => "acme"}]},
                 value_kind: :json
               }

        # It went through the existing upstream ledger exactly once.
        assert [%{"server" => "observatory", "tool" => "list-traces", "status" => "ok"}] = records

        # And it genuinely hit HTTP (not a stub): the request carried the arg.
        assert_receive {:http_fixture_request, request}, 1_000
        assert request =~ "GET /api/v1/traces?"
        assert request =~ "org_id=acme"
      after
        Runtime.stop(runtime)
      end
    end

    test "user code branches on the real recoverable result" do
      {:ok, server} = start_http_fixture(%{"traces" => []})

      {:ok, runtime} =
        Runtime.start_link(config: config(base_url: server.base_url))

      program = """
      (def res (api/list-traces "acme"))
      (if (res :ok)
        {:count (count (get (res :value) "traces"))}
        {:error (res :reason)})
      """

      try do
        {:ok, step} = Eval.run_lisp(runtime, program, prelude: direct_prelude())
        assert step.return == %{count: 0}
      after
        Runtime.stop(runtime)
      end
    end

    test "an export reaching the upstream through a private helper executes too" do
      {:ok, server} = start_http_fixture(%{"traces" => [%{"id" => "t-9"}]})

      {:ok, runtime} =
        Runtime.start_link(config: config(base_url: server.base_url))

      try do
        {:ok, step} =
          Eval.run_lisp(runtime, ~S|(api/list-traces "acme")|, prelude: transitive_prelude())

        # Transitive `requires` validated against the reachable runtime AND the
        # round-trip ran through the private helper.
        assert step.return.ok == true
        assert step.return.value == %{"traces" => [%{"id" => "t-9"}]}
      after
        Runtime.stop(runtime)
      end
    end
  end

  # ------------------------------------------------------------------
  # Fixtures (mirroring upstream_runtime_test.exs)
  # ------------------------------------------------------------------

  defp config(opts) do
    %{
      "upstreams" => %{
        "observatory" => %{
          "transport" => "openapi",
          "base_url" => Keyword.fetch!(opts, :base_url),
          "schema_file" => @schema,
          "include_operations" => ["list_traces", "get_trace"],
          "allow_insecure_http" => true
        }
      }
    }
  end

  # Ephemeral one-shot HTTP server: accepts a single request, replies with the
  # canned JSON body, and forwards the raw request to the test process.
  defp start_http_fixture(response_body) do
    parent = self()
    response_json = Jason.encode!(response_body)

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
          "HTTP/1.1 200 OK\r\n",
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
end
