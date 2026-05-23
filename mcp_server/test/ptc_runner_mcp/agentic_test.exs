defmodule PtcRunnerMcp.AgenticTest do
  use ExUnit.Case, async: false

  import PtcRunnerMcp.McpTestHelpers, only: [stop_existing_registry: 1]
  import PtcRunnerMcp.TestSupport.WaitHelpers, only: [wait_for_files: 2]

  alias PtcRunnerMcp.{
    AgenticConfig,
    AggregatorConfig,
    JsonRpc,
    Limits,
    Tools,
    TraceConfig,
    TraceHandler
  }

  alias PtcRunnerMcp.Application, as: McpApplication
  alias PtcRunnerMcp.Upstream.Catalog
  alias PtcRunnerMcp.Upstream.Registry

  @registry_name PtcRunnerMcp.Upstream.Registry

  defmodule StubPlanner do
    def call(_model, _prompt, _opts) do
      {:ok,
       ~S|(return "{\"items\":[{\"id\":1,\"name\":\"one\",\"extra\":\"x\"},{\"id\":2,\"name\":\"two\",\"extra\":\"y\"}]}")|,
       %{"model" => "stub:model", "duration_ms" => 1, "prompt_bytes" => 10, "output_bytes" => 20}}
    end
  end

  defmodule FencedPlanner do
    def call(_model, _prompt, _opts),
      do: {:ok, "```clojure\n(return 42)\n```", %{"model" => "stub:model"}}
  end

  defmodule ExplanatoryPlanner do
    def call(_model, _prompt, _opts),
      do: {:ok, "Here is the program:\n(return 42)", %{"model" => "stub:model"}}
  end

  defmodule SignatureTextPlanner do
    def call(_model, _prompt, _opts),
      do: {:ok, ~S|(return "signature.txt")|, %{"model" => "stub:model"}}
  end

  defmodule BareExpressionPlanner do
    def call(_model, _prompt, _opts),
      do: {:ok, ~S|(+ 1 1)|, %{"model" => "stub:model"}}
  end

  defmodule RaisingPlanner do
    def call(_model, _prompt, _opts), do: raise("planner exploded")
  end

  defmodule UpstreamErrorPlanner do
    def call(_model, _prompt, _opts) do
      {:ok,
       ~S|(let [r (tool/mcp-call {:server "alpha" :tool "err" :args {}})] (if (:ok r) (return (:value r)) (return {:fallback (:reason r)})))|,
       %{"model" => "stub:model", "duration_ms" => 1, "prompt_bytes" => 10, "output_bytes" => 20}}
    end
  end

  defmodule RuntimeErrorAfterUpstreamPlanner do
    def call(_model, _prompt, _opts) do
      {:ok, ~S|(do (tool/mcp-call {:server "alpha" :tool "ok" :args {}}) (fail {:reason :bad}))|,
       %{"model" => "stub:model", "duration_ms" => 1, "prompt_bytes" => 10, "output_bytes" => 20}}
    end
  end

  defmodule SequencePlanner do
    def call(_model, _prompt, _opts) do
      sequence = Application.fetch_env!(:ptc_runner_mcp, :agentic_test_sequence)

      program =
        Agent.get_and_update(sequence, fn
          [program | rest] -> {program, rest}
          [] -> flunk("agentic test planner sequence exhausted")
        end)

      {:ok, program,
       %{"model" => "stub:model", "duration_ms" => 1, "prompt_bytes" => 10, "output_bytes" => 20}}
    end
  end

  defmodule CapturingAdapter do
    def call(model, req) do
      send(Application.fetch_env!(:ptc_runner_mcp, :agentic_test_pid), {:llm_call, model, req})
      {:ok, %{content: "(return 7)", tokens: %{input: 1, output: 1}}}
    end
  end

  setup do
    stop_existing_registry(@registry_name)
    Catalog.clear_frozen()
    AgenticConfig.set(AgenticConfig.defaults())
    AggregatorConfig.set(AggregatorConfig.defaults())
    original_planner = Elixir.Application.get_env(:ptc_runner_mcp, :agentic_planner)
    original_test_pid = Elixir.Application.get_env(:ptc_runner_mcp, :agentic_test_pid)
    original_test_sequence = Elixir.Application.get_env(:ptc_runner_mcp, :agentic_test_sequence)
    original_llm_adapter = Elixir.Application.get_env(:ptc_runner, :llm_adapter)
    original_trace = TraceConfig.get()

    on_exit(fn ->
      stop_existing_registry(@registry_name)
      Catalog.clear_frozen()
      AgenticConfig.set(AgenticConfig.defaults())
      AggregatorConfig.set(AggregatorConfig.defaults())
      Limits.set(Limits.defaults())
      TraceConfig.set(original_trace)
      TraceHandler.detach()
      restore_app_env(:agentic_planner, original_planner)
      restore_app_env(:agentic_test_pid, original_test_pid)
      restore_app_env(:agentic_test_sequence, original_test_sequence)
      restore_ptc_env(:llm_adapter, original_llm_adapter)
    end)

    :ok
  end

  describe "configuration" do
    test "defaults disable agentic mode and CLI overrides env" do
      System.put_env("PTC_RUNNER_MCP_AGENTIC", "false")
      System.put_env("PTC_RUNNER_MCP_AGENTIC_MODEL", "env-model")

      on_exit(fn ->
        System.delete_env("PTC_RUNNER_MCP_AGENTIC")
        System.delete_env("PTC_RUNNER_MCP_AGENTIC_MODEL")
      end)

      assert McpApplication.parse_args(["--agentic", "--agentic-model", "cli-model"]) == %{
               agentic: true,
               agentic_model: "cli-model"
             }

      assert :ok = McpApplication.apply_agentic_config(%{})
      refute AgenticConfig.enabled?()
      assert AgenticConfig.get().model == "env-model"

      args = McpApplication.parse_args(["--agentic", "--agentic-model", "cli-model"])
      assert :ok = McpApplication.apply_agentic_config(args)
      assert AgenticConfig.enabled?()
      assert AgenticConfig.get().model == "cli-model"
    end

    test "invalid integer env falls back to default" do
      System.put_env("PTC_RUNNER_MCP_AGENTIC_TASK_TIMEOUT_MS", "nope")

      on_exit(fn ->
        System.delete_env("PTC_RUNNER_MCP_AGENTIC_TASK_TIMEOUT_MS")
      end)

      assert :ok = McpApplication.apply_agentic_config(%{})
      assert AgenticConfig.get().task_timeout_ms == AgenticConfig.defaults().task_timeout_ms
    end

    test "default planner model alias resolves to OpenRouter Gemini Flash Lite" do
      assert PtcRunner.LLM.Registry.resolve!(AgenticConfig.defaults().model) ==
               "openrouter:google/gemini-3.1-flash-lite"
    end

    test "real planner path forwards timeout and max token caps to the LLM request" do
      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_test_pid, self())
      Elixir.Application.put_env(:ptc_runner, :llm_adapter, CapturingAdapter)

      {:ok, _pid} = Registry.start_link(name: @registry_name)
      :ok = Registry.put_fake("alpha", %{tools: %{}}, @registry_name)
      :ok = Catalog.freeze("alpha:\n  (unavailable at startup)")

      :ok =
        AgenticConfig.set(%{
          enabled: true,
          model: "ollama:agentic-test",
          planner_timeout_ms: 1234,
          max_output_tokens: 321
        })

      env = Tools.call(%{"name" => "lisp_task", "arguments" => %{"task" => "answer"}})

      assert env["isError"] == false
      assert_receive {:llm_call, "ollama:agentic-test", req}
      assert req.receive_timeout == 1234
      assert req.max_tokens == 321
      assert req.system == "You generate only PTC-Lisp programs."
    end
  end

  describe "tool advertisement" do
    test "lisp_task is hidden without upstreams or when disabled" do
      assert tool_names() == ["lisp_eval"]

      {:ok, _pid} = Registry.start_link(name: @registry_name)
      :ok = Registry.put_fake("alpha", %{tools: %{}}, @registry_name)
      :ok = Catalog.freeze("alpha:\n  (unavailable at startup)")

      assert tool_names() == ["lisp_eval"]
    end

    test "lisp_task is advertised only in agentic aggregator mode" do
      {:ok, _pid} = Registry.start_link(name: @registry_name)
      :ok = Registry.put_fake("alpha", %{tools: %{}}, @registry_name)
      :ok = Catalog.freeze("alpha:\n  (unavailable at startup)")
      :ok = AgenticConfig.set(%{enabled: true})

      assert tool_names() == ["lisp_eval", "lisp_task"]
      task = Enum.find(Tools.list()["tools"], &(&1["name"] == "lisp_task"))
      assert task["description"] =~ "plain-English tasks"
      refute task["description"] =~ "mcp/text"
    end
  end

  describe "lisp_task execution" do
    setup do
      {:ok, _pid} = Registry.start_link(name: @registry_name)
      :ok = Registry.put_fake("alpha", %{tools: %{}}, @registry_name)
      :ok = Catalog.freeze("alpha:\n  (unavailable at startup)")
      :ok = AgenticConfig.set(%{enabled: true, model: "stub:model"})
      :ok
    end

    test "stub planner output executes and renderer enforces constraints" do
      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_planner, StubPlanner)

      env =
        Tools.call(%{
          "name" => "lisp_task",
          "arguments" => %{
            "task" => "return items",
            "constraints" => %{
              "max_items" => 1,
              "preferred_fields" => ["id", "name"],
              "unknown" => true
            }
          }
        })

      assert env["isError"] == false
      sc = env["structuredContent"]
      assert sc["status"] == "ok"
      assert sc["structured_result"] == %{"items" => [%{"id" => 1, "name" => "one"}]}
      assert [%{"code" => "unsupported_constraint", "detail" => "unknown"}] = sc["warnings"]
      assert sc["program"] =~ "(return"
      assert sc["planner"]["model"] == "stub:model"
    end

    test "markdown fences are stripped before execution" do
      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_planner, FencedPlanner)

      env = Tools.call(%{"name" => "lisp_task", "arguments" => %{"task" => "answer"}})

      assert env["isError"] == false
      assert env["structuredContent"]["structured_result"] == 42
    end

    test "explanatory planner output fails the explicit SubAgent terminal contract" do
      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_planner, ExplanatoryPlanner)

      env = Tools.call(%{"name" => "lisp_task", "arguments" => %{"task" => "answer"}})

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "ptc_max_turns_exceeded"
    end

    test "retry budget exhaustion keeps a budget-specific reason" do
      :ok = AgenticConfig.set(%{enabled: true, model: "stub:model", max_turns: 1, retry_turns: 1})
      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_planner, ExplanatoryPlanner)

      env = Tools.call(%{"name" => "lisp_task", "arguments" => %{"task" => "answer"}})

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "ptc_budget_exhausted"
    end

    test "generated-code contract failures keep ptc-prefixed reasons" do
      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_planner, BareExpressionPlanner)

      env = Tools.call(%{"name" => "lisp_task", "arguments" => %{"task" => "answer"}})

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "ptc_must_return_missing"
    end

    test "valid programs may contain signature as ordinary data" do
      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_planner, SignatureTextPlanner)

      env =
        Tools.call(%{
          "name" => "lisp_task",
          "arguments" => %{"task" => "find signature.txt"}
        })

      assert env["isError"] == false
      assert env["structuredContent"]["structured_result"] == "signature.txt"
    end

    test "planner crashes are converted to planner_error envelopes" do
      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_planner, RaisingPlanner)

      env = Tools.call(%{"name" => "lisp_task", "arguments" => %{"task" => "answer"}})

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["reason"] == "planner_error"
      assert sc["message"] =~ "planner crashed"
    end

    test "handled upstream world faults can still return successful fallback results" do
      :ok = put_fake("alpha", %{"err" => fn _, _ -> {:error, :upstream_error, "404"} end})
      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_planner, UpstreamErrorPlanner)

      env = Tools.call(%{"name" => "lisp_task", "arguments" => %{"task" => "call upstream"}})

      assert env["isError"] == false
      sc = env["structuredContent"]
      assert sc["status"] == "ok"
      assert sc["structured_result"] == %{"fallback" => :upstream_error}

      assert [%{"status" => "error", "reason" => "upstream_error", "error" => "404"}] =
               sc["upstream_calls"]

      assert sc["program"] =~ "tool/mcp-call"
    end

    test "agent failures preserve upstream_calls recorded before the failure" do
      :ok = put_fake("alpha", %{"ok" => fn _, _ -> {:ok, "done"} end})

      Elixir.Application.put_env(
        :ptc_runner_mcp,
        :agentic_planner,
        RuntimeErrorAfterUpstreamPlanner
      )

      env = Tools.call(%{"name" => "lisp_task", "arguments" => %{"task" => "call then fail"}})

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["reason"] == "agent_failed"
      assert sc["planner"]["model"] == "stub:model"

      assert [
               %{
                 "server" => "alpha",
                 "tool" => "ok",
                 "status" => "ok"
               }
             ] = sc["upstream_calls"]

      assert sc["program"] =~ "(fail"
    end

    test "read-only multi-turn can recover from a missing terminal form and records actual turns" do
      :ok = AggregatorConfig.set(%{read_only: true})
      :ok = AgenticConfig.set(%{enabled: true, model: "stub:model", max_turns: 2})

      :ok =
        put_fake("alpha", %{
          "ok" => fn _, _ -> {:ok, %{"structuredContent" => %{"seen" => true}}} end
        })

      {:ok, sequence} =
        Agent.start_link(fn ->
          [
            ~S|(tool/mcp-call {:server "alpha" :tool "ok" :args {"turn" 1}})|,
            ~S|(return (tool/mcp-call {:server "alpha" :tool "ok" :args {"turn" 2}}))|
          ]
        end)

      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_test_sequence, sequence)
      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_planner, SequencePlanner)

      env = Tools.call(%{"name" => "lisp_task", "arguments" => %{"task" => "call twice"}})

      assert env["isError"] == false
      sc = env["structuredContent"]
      assert sc["execution"]["turn_count"] == 2

      assert sc["structured_result"] == %{
               "ok" => true,
               "value" => %{"seen" => true},
               "value_kind" => :json
             }

      assert [
               %{"status" => "ok", "turn" => 1},
               %{"status" => "ok", "turn" => 2}
             ] = sc["upstream_calls"]
    end

    test "read-only multi-turn can continue after parse feedback while budget allows" do
      :ok = AggregatorConfig.set(%{read_only: true})
      :ok = AgenticConfig.set(%{enabled: true, model: "stub:model", max_turns: 2})
      {:ok, sequence} = Agent.start_link(fn -> ["not ptc-lisp", ~S|(return 9)|] end)

      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_test_sequence, sequence)
      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_planner, SequencePlanner)

      env = Tools.call(%{"name" => "lisp_task", "arguments" => %{"task" => "recover"}})

      assert env["isError"] == false
      sc = env["structuredContent"]
      assert sc["execution"]["turn_count"] == 2
      assert sc["structured_result"] == 9
      assert sc["upstream_calls"] == []
    end

    test "read-only multi-turn can continue after runtime feedback while budget allows" do
      :ok = AggregatorConfig.set(%{read_only: true})
      :ok = AgenticConfig.set(%{enabled: true, model: "stub:model", max_turns: 2})
      {:ok, sequence} = Agent.start_link(fn -> [~S|(+ 1 "x")|, ~S|(return 11)|] end)

      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_test_sequence, sequence)
      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_planner, SequencePlanner)

      env =
        Tools.call(%{
          "name" => "lisp_task",
          "arguments" => %{"task" => "recover from runtime error"}
        })

      assert env["isError"] == false
      sc = env["structuredContent"]
      assert sc["execution"]["turn_count"] == 2
      assert sc["structured_result"] == 11
      assert sc["upstream_calls"] == []
    end

    test "write-effect non-terminal turn is blocked before continuation" do
      :ok = AggregatorConfig.set(%{read_only: false})

      :ok =
        AgenticConfig.set(%{enabled: true, model: "stub:model", max_turns: 2, allow_writes: true})

      :ok =
        put_fake("alpha", %{
          "write" =>
            {fn _, _ -> {:ok, %{"structuredContent" => %{"written" => true}}} end,
             %{"destructiveHint" => true}}
        })

      {:ok, _} = Registry.ensure_started("alpha", @registry_name)

      {:ok, sequence} =
        Agent.start_link(fn ->
          [
            ~S|(tool/mcp-call {:server "alpha" :tool "write" :args {}})|,
            ~S|(return :should-not-run)|
          ]
        end)

      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_test_sequence, sequence)
      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_planner, SequencePlanner)

      env =
        Tools.call(%{"name" => "lisp_task", "arguments" => %{"task" => "write then continue"}})

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["reason"] == "partial_side_effects"
      assert sc["message"] =~ "Continuation blocked"
      assert sc["execution"]["turn_count"] == 1

      assert [
               %{"status" => "ok", "effect" => "write", "turn" => 1}
             ] = sc["upstream_calls"]
    end

    test "unknown-effect non-terminal runtime error is blocked before continuation" do
      :ok = AggregatorConfig.set(%{read_only: false})

      :ok =
        AgenticConfig.set(%{enabled: true, model: "stub:model", max_turns: 2, allow_writes: true})

      :ok = put_fake("alpha", %{"unknown" => {fn _, _ -> {:ok, "done"} end, %{}}})

      {:ok, sequence} =
        Agent.start_link(fn ->
          [
            ~S|(do (tool/mcp-call {:server "alpha" :tool "unknown" :args {}}) (+ 1 "x"))|,
            ~S|(return :should-not-run)|
          ]
        end)

      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_test_sequence, sequence)
      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_planner, SequencePlanner)

      env =
        Tools.call(%{
          "name" => "lisp_task",
          "arguments" => %{"task" => "unknown side effect then runtime error"}
        })

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["reason"] == "partial_side_effects"
      assert sc["execution"]["turn_count"] == 1

      assert [
               %{"status" => "ok", "effect" => "unknown", "turn" => 1}
             ] = sc["upstream_calls"]
    end

    test "write-effect final missing terminal reports partial side effects" do
      :ok = AggregatorConfig.set(%{read_only: false})

      :ok =
        AgenticConfig.set(%{enabled: true, model: "stub:model", max_turns: 1, allow_writes: true})

      :ok =
        put_fake("alpha", %{
          "write" =>
            {fn _, _ -> {:ok, %{"structuredContent" => %{"written" => true}}} end,
             %{"destructiveHint" => true}}
        })

      {:ok, _} = Registry.ensure_started("alpha", @registry_name)

      {:ok, sequence} =
        Agent.start_link(fn ->
          [~S|(tool/mcp-call {:server "alpha" :tool "write" :args {}})|]
        end)

      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_test_sequence, sequence)
      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_planner, SequencePlanner)

      env =
        Tools.call(%{
          "name" => "lisp_task",
          "arguments" => %{"task" => "write on final turn without terminal form"}
        })

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["reason"] == "partial_side_effects"
      assert sc["execution"]["turn_count"] == 1

      assert [
               %{"status" => "ok", "effect" => "write", "turn" => 1}
             ] = sc["upstream_calls"]
    end

    test "write-effect turn may finish with return in the same turn" do
      :ok = AggregatorConfig.set(%{read_only: false})

      :ok =
        AgenticConfig.set(%{enabled: true, model: "stub:model", max_turns: 2, allow_writes: true})

      :ok =
        put_fake("alpha", %{
          "write" =>
            {fn _, _ -> {:ok, %{"structuredContent" => %{"written" => true}}} end,
             %{"destructiveHint" => true}}
        })

      {:ok, _} = Registry.ensure_started("alpha", @registry_name)

      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_planner, SequencePlanner)

      {:ok, sequence} =
        Agent.start_link(fn ->
          [~S|(return (tool/mcp-call {:server "alpha" :tool "write" :args {}}))|]
        end)

      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_test_sequence, sequence)

      env = Tools.call(%{"name" => "lisp_task", "arguments" => %{"task" => "write and return"}})

      assert env["isError"] == false
      sc = env["structuredContent"]

      assert sc["structured_result"] == %{
               "ok" => true,
               "value" => %{"written" => true},
               "value_kind" => :json
             }

      assert [
               %{"status" => "ok", "effect" => "write", "turn" => 1}
             ] = sc["upstream_calls"]
    end

    test "write-effect turn may finish with fail in the same turn" do
      :ok = AggregatorConfig.set(%{read_only: false})

      :ok =
        AgenticConfig.set(%{enabled: true, model: "stub:model", max_turns: 2, allow_writes: true})

      :ok =
        put_fake("alpha", %{
          "write" =>
            {fn _, _ -> {:ok, %{"structuredContent" => %{"written" => true}}} end,
             %{"destructiveHint" => true}}
        })

      {:ok, _} = Registry.ensure_started("alpha", @registry_name)

      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_planner, SequencePlanner)

      {:ok, sequence} =
        Agent.start_link(fn ->
          [
            ~S|(do (tool/mcp-call {:server "alpha" :tool "write" :args {}}) (fail {:reason :after-write}))|
          ]
        end)

      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_test_sequence, sequence)

      env = Tools.call(%{"name" => "lisp_task", "arguments" => %{"task" => "write and fail"}})

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["reason"] == "agent_failed"

      assert [
               %{"status" => "ok", "effect" => "write", "turn" => 1}
             ] = sc["upstream_calls"]
    end

    test "constraints are capped before prompt assembly" do
      Limits.set(Map.put(Limits.defaults(), :max_context_bytes, 32))
      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_planner, RaisingPlanner)

      env =
        Tools.call(%{
          "name" => "lisp_task",
          "arguments" => %{
            "task" => "answer",
            "constraints" => %{"preferred_fields" => [String.duplicate("x", 100)]}
          }
        })

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "args_error"
      assert env["structuredContent"]["message"] =~ "constraints"
    end
  end

  describe "lisp_task tracing" do
    setup do
      {:ok, _pid} = Registry.start_link(name: @registry_name)
      :ok = Registry.put_fake("alpha", %{tools: %{}}, @registry_name)
      :ok = Catalog.freeze("alpha:\n  (unavailable at startup)")
      :ok = AgenticConfig.set(%{enabled: true, model: "stub:model"})
      Elixir.Application.put_env(:ptc_runner_mcp, :agentic_planner, StubPlanner)
      :ok
    end

    test "JSONL traces include agentic task and planner spans" do
      with_trace_dir(fn dir ->
        reply = dispatch_task("agentic-trace", %{"task" => "return items"})
        assert reply["result"]["isError"] == false

        [file] = wait_for_files(dir, 1)
        events = read_jsonl(Path.join(dir, file))
        names = Enum.map(events, & &1["event"])

        assert "ptc_lisp.call.start" in names
        assert "ptc_lisp.agentic_task.start" in names
        assert "ptc_lisp.agentic_task.stop" in names
        assert "ptc_lisp.agentic_planner.start" in names
        assert "ptc_lisp.agentic_planner.stop" in names
        assert "ptc_runner.lisp.execute.start" in names
      end)
    end
  end

  defp tool_names do
    Tools.list()["tools"] |> Enum.map(& &1["name"])
  end

  defp tools_config(tools) do
    %{
      tools:
        Map.new(tools, fn
          {n, {fun, annotations}} ->
            {n, {%{name: n, input_schema: %{}, annotations: annotations}, fun}}

          {n, fun} ->
            {n, {%{name: n, input_schema: %{}}, fun}}
        end)
    }
  end

  defp put_fake(name, tools) do
    Registry.put_fake(name, tools_config(tools), @registry_name)
  end

  defp with_trace_dir(fun) do
    dir =
      Path.join(System.tmp_dir!(), "ptc_mcp_agentic_trace_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    :ok = TraceConfig.set(%{trace_dir: dir, trace_payloads: :summary, trace_max_files: 1000})
    :ok = TraceHandler.attach()

    fun.(dir)
  end

  defp dispatch_task(id, args) do
    frame = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => "lisp_task", "arguments" => args}
    }

    case JsonRpc.dispatch({:ok, frame}) do
      {:async_call, ^id, work_fn, _on_busy, _on_discard, _} ->
        envelope = work_fn.()
        %{"jsonrpc" => "2.0", "id" => id, "result" => envelope}

      {:reply, reply, _} ->
        reply
    end
  end

  defp read_jsonl(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp restore_app_env(key, nil), do: Elixir.Application.delete_env(:ptc_runner_mcp, key)
  defp restore_app_env(key, value), do: Elixir.Application.put_env(:ptc_runner_mcp, key, value)

  defp restore_ptc_env(key, nil), do: Elixir.Application.delete_env(:ptc_runner, key)
  defp restore_ptc_env(key, value), do: Elixir.Application.put_env(:ptc_runner, key, value)
end
