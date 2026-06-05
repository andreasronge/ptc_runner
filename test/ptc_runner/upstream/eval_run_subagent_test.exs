defmodule PtcRunner.Upstream.EvalRunSubagentTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The core SubAgent↔upstream bridge: `Upstream.Eval.run_subagent/3`.

  Covers the two goals and the three Phase-1 correctness requirements from
  `private/Plans/subagent-upstream-runtime-integration.md`:

    * the bridge owns one RunContext, enriches the agent with the upstream
      `"call"` tool, threads the runtime, and round-trips end-to-end;
    * prelude `requires` validates fail-closed on the multi-turn loop path
      (§3.3); a missing backing is a HARD STOP, not a recoverable retry turn
      (§3.5 #2);
    * collision policy reserves `"call"` (§3.4).

  The single-shot fast-path fix (§3.5 #1) and child upstream-blindness (§3.5 #3)
  live in their own tests below.
  """

  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.SubAgent
  alias PtcRunner.Upstream.Eval
  alias PtcRunner.Upstream.Runtime

  @schema Path.expand(
            "../../../mcp_server/test/fixtures/openapi/observatory.openapi.json",
            __DIR__
          )
  @fixture_recv_timeout_ms 15_000

  # ------------------------------------------------------------------
  # Bridge lifecycle + round-trip
  # ------------------------------------------------------------------

  describe "round-trip through the bridge against a reachable upstream" do
    test "enriches the agent with the upstream call, validates requires, and round-trips" do
      {:ok, server} = start_http_fixture(%{"traces" => [%{"id" => "t-1", "org_id" => "acme"}]})
      {:ok, runtime} = Runtime.start_link(config: config(base_url: server.base_url))

      agent =
        SubAgent.new(
          prompt: "List traces.",
          runtime_prelude: direct_prelude(),
          output: :ptc_lisp,
          max_turns: 1
        )

      try do
        {result, records} =
          Eval.run_subagent(runtime, agent, llm: stub_llm(~S|(api/list-traces "acme")|))

        assert {:ok, step} = result

        # SubAgent normalizes return-map keys to strings (KeyNormalizer); the
        # recoverable result map round-trips with string keys on this path.
        assert step.return == %{
                 "ok" => true,
                 "value" => %{"traces" => [%{"id" => "t-1", "org_id" => "acme"}]},
                 "value_kind" => :json
               }

        # One RunContext spanned the run and drained the single upstream call.
        assert [%{"server" => "observatory", "tool" => "list-traces", "status" => "ok"}] = records

        # It genuinely hit HTTP through the bridge-enriched "call" tool.
        assert_receive {:http_fixture_request, request}, 1_000
        assert request =~ "org_id=acme"
      after
        Runtime.stop(runtime)
      end
    end
  end

  # ------------------------------------------------------------------
  # Prelude requires — fail closed on the multi-turn loop path (§3.3 + §3.5 #2)
  # ------------------------------------------------------------------

  describe "prelude requires validation on the multi-turn SubAgent path" do
    setup do
      {:ok, runtime} = Runtime.start_link(config: config())
      on_exit(fn -> Runtime.stop(runtime) end)
      %{runtime: runtime}
    end

    test "an unsatisfied requires fails closed before any user code AND hard-stops the loop",
         %{runtime: runtime} do
      # crm/get_user is NOT configured on this observatory-only runtime.
      prelude = literal_prelude("crm", "get_user")
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      agent =
        SubAgent.new(
          prompt: "Do the thing.",
          runtime_prelude: prelude,
          output: :ptc_lisp,
          # 3 turns: a recoverable error would retry up to here; a hard stop runs once.
          max_turns: 3
        )

      {result, _records} =
        Eval.run_subagent(runtime, agent,
          llm: counting_llm(counter, ~S|(crm/list-traces "o")|),
          collect_messages: true
        )

      assert {:error, step} = result
      assert step.fail.reason == :prelude_attach_failed
      assert step.fail.message =~ "upstream:crm/get_user"

      # Hard stop (§3.5 #2): the loop did not feed the attach failure back as a
      # retry turn — the planner was consulted exactly once and one turn ran.
      assert Agent.get(counter, & &1) == 1
      assert length(step.turns) == 1

      # Observability parity: the assistant response that triggered the failure
      # is preserved under collect_messages.
      assert Enum.any?(step.messages, &(&1.role == :assistant))
    end

    test "fails closed and hard-stops on the :tool_call transport too", %{runtime: runtime} do
      # Codex [P2]: the :tool_call transport has its own Lisp error handler; the
      # hard stop must apply there as well, not only on :content.
      prelude = literal_prelude("crm", "get_user")
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      agent =
        SubAgent.new(
          prompt: "Do the thing.",
          runtime_prelude: prelude,
          output: :ptc_lisp,
          ptc_transport: :tool_call,
          max_turns: 3
        )

      {result, _records} =
        Eval.run_subagent(runtime, agent,
          llm: counting_tool_call_llm(counter, ~S|(crm/list-traces "o")|)
        )

      assert {:error, step} = result
      assert step.fail.reason == :prelude_attach_failed
      assert Agent.get(counter, & &1) == 1
    end

    test "fails closed and hard-stops in combined text mode too", %{runtime: runtime} do
      # output: :text + ptc_transport: :tool_call is combined mode, which has its
      # OWN lisp_eval error handler (text_mode.ex) that otherwise renders a
      # recoverable tool error and retries.
      prelude = literal_prelude("crm", "get_user")
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      agent =
        SubAgent.new(
          prompt: "Do the thing.",
          runtime_prelude: prelude,
          output: :text,
          ptc_transport: :tool_call,
          max_turns: 3
        )

      {result, _records} =
        Eval.run_subagent(runtime, agent,
          llm: counting_tool_call_llm(counter, ~S|(crm/list-traces "o")|),
          collect_messages: true
        )

      assert {:error, step} = result
      assert step.fail.reason == :prelude_attach_failed
      assert Agent.get(counter, & &1) == 1

      # Observability parity: the halting turn is preserved (not an empty trace),
      # carries the failure reason (so error-breakdown metrics count it), and the
      # assistant tool call survives under collect_messages.
      assert [turn] = step.turns
      refute turn.success?
      assert turn.result == step.fail
      assert Enum.any?(step.messages, &(&1.role == :assistant))
    end

    test "a satisfied requires does not block (validation passes)", %{runtime: runtime} do
      prelude = literal_prelude("observatory", "list-traces")

      agent =
        SubAgent.new(
          prompt: "List.",
          runtime_prelude: prelude,
          output: :ptc_lisp,
          max_turns: 1
        )

      # observatory.example is unreachable, so the call itself may error — but
      # that is a runtime tool error, NOT a prelude attach failure.
      {result, _records} =
        Eval.run_subagent(runtime, agent, llm: stub_llm(~S|(crm/list-traces "o")|))

      case result do
        {:ok, _step} -> :ok
        {:error, step} -> refute step.fail.reason == :prelude_attach_failed
      end
    end
  end

  # ------------------------------------------------------------------
  # Collision policy (§3.4)
  # ------------------------------------------------------------------

  describe "collision policy reserves the upstream \"call\" tool" do
    setup do
      {:ok, runtime} = Runtime.start_link(config: config())
      on_exit(fn -> Runtime.stop(runtime) end)
      %{runtime: runtime}
    end

    test "a local \"call\" tool plus a runtime raises by default", %{runtime: runtime} do
      agent =
        SubAgent.new(
          prompt: "x",
          tools: %{"call" => fn _args -> %{ok: true, value: "local"} end},
          output: :ptc_lisp,
          max_turns: 1
        )

      assert_raise ArgumentError, ~r/local "call" tool/, fn ->
        Eval.run_subagent(runtime, agent, llm: stub_llm("1"))
      end
    end

    test "allow_call_override: true keeps the local tool instead of raising", %{runtime: runtime} do
      agent =
        SubAgent.new(
          prompt: "x",
          tools: %{"call" => fn _args -> %{ok: true, value: "local"} end},
          output: :ptc_lisp,
          max_turns: 1
        )

      {result, _records} =
        Eval.run_subagent(runtime, agent,
          llm: stub_llm(~S|(tool/call {:server "s" :tool "t" :args {}})|),
          allow_call_override: true
        )

      assert {:ok, step} = result
      assert step.return == %{"ok" => true, "value" => "local"}
    end
  end

  # ------------------------------------------------------------------
  # §3.5 #1 — single-shot path must not skip requires validation
  # ------------------------------------------------------------------

  describe "single-shot fast path and prelude requires (§3.5 #1)" do
    setup do
      {:ok, runtime} = Runtime.start_link(config: config())
      on_exit(fn -> Runtime.stop(runtime) end)
      %{runtime: runtime}
    end

    test "a requires-backed prelude with no literal tool/call still validates against a runtime",
         %{runtime: runtime} do
      # requires != [] (explicit metadata) but tool_refs == [] (no literal
      # (tool/call ...) in the body) — the exact divergence that left this on the
      # single-shot path, which threads no :runtime and skips validation.
      prelude = requires_only_prelude("crm", "do_write")
      [export] = prelude.exports
      assert export.requires == ["upstream:crm/do_write"]
      assert export.tool_refs == []

      agent =
        SubAgent.new(
          prompt: "x",
          runtime_prelude: prelude,
          output: :ptc_lisp,
          max_turns: 1,
          retry_turns: 0
        )

      # Facade form: pass the runtime directly. The fix routes this off the
      # fast path into Loop.run, where the runtime reaches prelude attach.
      assert {:error, step} = SubAgent.run(agent, llm: stub_llm("1"), runtime: runtime)
      assert step.fail.reason == :prelude_attach_failed
      assert step.fail.message =~ "upstream:crm/do_write"
    end

    test "a pure prelude (no requires, no tool_refs) still uses the single-shot fast path" do
      {:ok, prelude} =
        Compiler.compile("""
        (ns util "Pure helpers." {:visibility :prompt})
        (defn add-one [x] (+ x 1))
        """)

      agent =
        SubAgent.new(
          prompt: "x",
          runtime_prelude: prelude,
          output: :ptc_lisp,
          max_turns: 1,
          retry_turns: 0
        )

      assert {:ok, step} = SubAgent.run(agent, llm: stub_llm(~S|(util/add-one 41)|))
      assert step.return == 42
    end
  end

  # ------------------------------------------------------------------
  # §3.5 #3 — child agents are upstream-blind (no runtime inheritance)
  # ------------------------------------------------------------------

  describe "child agents do not inherit the parent runtime (§3.5 #3)" do
    test "a child's own requires-backed prelude is not validated against the parent runtime" do
      {:ok, runtime} = Runtime.start_link(config: config())

      # The child requires crm/do_write (unconfigured). Its body is the constant
      # 777, but prelude attach runs per-turn before user code regardless. If the
      # child INHERITED the parent's runtime, that attach would fail closed
      # (:prelude_attach_failed); because children are upstream-blind, the child
      # has no runtime, attach skips validation, the child returns 777, and the
      # parent's (child) call yields it.
      child =
        SubAgent.new(
          prompt: "CHILD_MARKER",
          runtime_prelude: requires_only_prelude("crm", "do_write"),
          output: :ptc_lisp,
          max_turns: 1,
          signature: "() -> :int",
          description: "Child that returns a number."
        )

      parent =
        SubAgent.new(
          prompt: "PARENT_MARKER",
          tools: %{"child" => SubAgent.as_tool(child)},
          output: :ptc_lisp,
          max_turns: 1
        )

      llm = routing_llm([{"CHILD_MARKER", "777"}, {"PARENT_MARKER", "(tool/child {})"}])

      try do
        {result, _records} = Eval.run_subagent(runtime, parent, llm: llm)

        assert {:ok, step} = result
        assert step.return == 777
      after
        Runtime.stop(runtime)
      end
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp stub_llm(program) do
    fn _input -> {:ok, "```clojure\n#{program}\n```"} end
  end

  defp counting_llm(counter, program) do
    fn _input ->
      Agent.update(counter, &(&1 + 1))
      {:ok, "```clojure\n#{program}\n```"}
    end
  end

  # Native tool-call transport: the LLM returns a `lisp_eval` tool call rather
  # than a fenced content block.
  defp counting_tool_call_llm(counter, program) do
    fn _input ->
      Agent.update(counter, &(&1 + 1))

      {:ok,
       %{
         content: nil,
         tool_calls: [%{id: "c1", name: "lisp_eval", args: %{"program" => program}}],
         tokens: %{input: 0, output: 0}
       }}
    end
  end

  # Returns different programs per caller, keyed by a marker substring present in
  # the LLM input (each agent's prompt). Lets a parent call a child while the
  # child returns its own program.
  defp routing_llm(routes) do
    fn input ->
      text = inspect(input, limit: :infinity)

      program =
        Enum.find_value(routes, "nil", fn {marker, prog} ->
          if String.contains?(text, marker), do: prog
        end)

      {:ok, "```clojure\n#{program}\n```"}
    end
  end

  # Literal upstream tool/call: the compiler INFERS requires from the body.
  defp literal_prelude(server, tool) do
    {:ok, prelude} =
      Compiler.compile("""
      (ns crm "CRM helpers." {:visibility :prompt})

      (defn list-traces "doc" [org-id]
        (tool/call {:server "#{server}" :tool "#{tool}" :args {:org_id org-id}}))
      """)

    prelude
  end

  # A reachable observatory export (literal), used for the round-trip.
  defp direct_prelude do
    {:ok, prelude} =
      Compiler.compile("""
      (ns api "Observatory API." {:visibility :prompt})

      (defn list-traces "List traces for an org." [org-id]
        (tool/call {:server "observatory" :tool "list-traces"
                    :args {:org_id org-id :limit 1}}))
      """)

    prelude
  end

  # Explicit :requires metadata with NO literal (tool/call ...) in the body, so
  # requires != [] but tool_refs == [] (the §3.5 #1 divergence).
  defp requires_only_prelude(server, tool) do
    {:ok, prelude} =
      Compiler.compile("""
      (ns crm "CRM helpers." {:visibility :prompt})

      (defn do-write
        "Perform a write."
        {:provider-ref "upstream:#{server}/#{tool}" :effect :write
         :requires ["upstream:#{server}/#{tool}"]}
        []
        42)
      """)

    prelude
  end

  defp config(opts \\ []) do
    base_url = Keyword.get(opts, :base_url, "https://observatory.example")

    %{
      "upstreams" => %{
        "observatory" => %{
          "transport" => "openapi",
          "base_url" => base_url,
          "schema_file" => @schema,
          "include_operations" => ["list_traces", "get_trace"],
          "allow_insecure_http" => true
        }
      }
    }
  end

  # Ephemeral one-shot HTTP server (mirrors upstream_roundtrip_test.exs).
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
