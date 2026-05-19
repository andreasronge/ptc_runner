defmodule PtcRunnerMcp.AgenticPayloadMetricsTest do
  @moduledoc """
  Phase B′ + Phase B (agentic side): `ptc_metrics` on the `ptc_task`
  envelope, including the `server_side_llm` planner-cost line item.

  See `Plans/ptc-runner-mcp-payload-reduction.md` §4.3 / §4.1 / §7.
  Uses both a stub *planner module* (no provider tokens →
  `provider_reported: false`) and the real `Planner` with a stubbed
  LLM adapter that reports `usage` (→ `provider_reported: true`).
  """
  use ExUnit.Case, async: false

  import PtcRunnerMcp.McpTestHelpers, only: [stop_existing_registry: 1]

  alias PtcRunnerMcp.Agentic.Planner
  alias PtcRunnerMcp.{AgenticConfig, AggregatorConfig, Limits, Tools}
  alias PtcRunnerMcp.Upstream.Catalog
  alias PtcRunnerMcp.Upstream.Registry

  @registry_name PtcRunnerMcp.Upstream.Registry

  # A planner module (bypasses `Planner.call/3`) that returns a program
  # fetching from an upstream then returning a JSON answer. Its meta
  # carries NO `"tokens"` slot → the metrics block must report
  # `provider_reported: false` and fall back to byte estimates.
  defmodule NoTokensPlanner do
    def call(_model, _prompt, _opts) do
      {:ok,
       ~S|(let [r (tool/mcp-call {:server "alpha" :tool "fetch" :args {}})] (return {:count (count (:value r))}))|,
       %{
         "model" => "stub:model",
         "duration_ms" => 1,
         "prompt_bytes" => 1234,
         "completion_bytes" => 77,
         "output_bytes" => 77
       }}
    end
  end

  # Pure-compute planner (no upstream call) — the metrics block is
  # still attached (the planner ran) but with `upstream_result_bytes:
  # 0` and `payload_reduction_ratio: null`.
  defmodule PureComputePlanner do
    def call(_model, _prompt, _opts) do
      {:ok, ~S|(return {:n 42})|,
       %{
         "model" => "stub:model",
         "prompt_bytes" => 10,
         "completion_bytes" => 5,
         "output_bytes" => 5
       }}
    end
  end

  # Fetches from an upstream then `(fail ...)` → error envelope. The
  # bytes fetched before the failure are still tallied; the answer
  # subset is empty so `final_result_bytes` is 0.
  defmodule FailAfterFetchPlanner do
    def call(_model, _prompt, _opts) do
      {:ok, ~S|(do (tool/mcp-call {:server "alpha" :tool "ok" :args {}}) (fail {:reason :bad}))|,
       %{
         "model" => "stub:model",
         "prompt_bytes" => 50,
         "completion_bytes" => 12,
         "output_bytes" => 12
       }}
    end
  end

  # Fetches from an upstream whose envelope is `isError: true` (a
  # tool-level error — the JSON-RPC call succeeded). The program reads
  # the world-fault tag and returns a fallback, so the envelope is a
  # success — but those bytes must land in `upstream_error_bytes`.
  defmodule IsErrorFetchPlanner do
    def call(_model, _prompt, _opts) do
      {:ok,
       ~S|(let [r (tool/mcp-call {:server "alpha" :tool "err" :args {}})] (return {:fallback (:reason r)}))|,
       %{
         "model" => "stub:model",
         "prompt_bytes" => 30,
         "completion_bytes" => 9,
         "output_bytes" => 9
       }}
    end
  end

  # An LLM adapter that records the request it received and reports
  # provider `usage`. Drives the *real* `Planner.call/3` so
  # `prompt_bytes` is computed from the actual system+prompt content.
  defmodule UsageReportingAdapter do
    def call(_model, req) do
      send(Application.fetch_env!(:ptc_runner_mcp, :agentic_test_pid), {:llm_req, req})
      {:ok, %{content: "(return {\"v\" 7})", tokens: %{input: 321, output: 88}}}
    end
  end

  # Same as above but reports no usage (`tokens: %{}`) — exercises the
  # `provider_reported: false` branch through the real planner.
  defmodule NoUsageAdapter do
    def call(_model, req) do
      send(Application.fetch_env!(:ptc_runner_mcp, :agentic_test_pid), {:llm_req, req})
      {:ok, %{content: "(return {\"v\" 9})", tokens: %{}}}
    end
  end

  setup do
    stop_existing_registry(@registry_name)
    Catalog.clear_frozen()
    AgenticConfig.set(AgenticConfig.defaults())
    AggregatorConfig.set(AggregatorConfig.defaults())
    Limits.set(Limits.defaults())
    original_planner = Application.get_env(:ptc_runner_mcp, :agentic_planner)
    original_test_pid = Application.get_env(:ptc_runner_mcp, :agentic_test_pid)
    original_llm_adapter = Application.get_env(:ptc_runner, :llm_adapter)

    on_exit(fn ->
      stop_existing_registry(@registry_name)
      Catalog.clear_frozen()
      AgenticConfig.set(AgenticConfig.defaults())
      AggregatorConfig.set(AggregatorConfig.defaults())
      Limits.set(Limits.defaults())
      restore(:ptc_runner_mcp, :agentic_planner, original_planner)
      restore(:ptc_runner_mcp, :agentic_test_pid, original_test_pid)
      restore(:ptc_runner, :llm_adapter, original_llm_adapter)
    end)

    {:ok, _pid} = Registry.start_link(name: @registry_name)
    # At least one configured upstream so `configured_aggregator_mode?/0`
    # is true and `ptc_task` is advertised. Individual tests override
    # this with their own `put_fake/2` when they need a real tool.
    :ok = Registry.put_fake("alpha", %{tools: %{}}, @registry_name)
    :ok = Catalog.freeze("alpha:\n  (unavailable at startup)")
    :ok = AgenticConfig.set(%{enabled: true, model: "stub:model"})
    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp tools_config(tools) do
    %{tools: Map.new(tools, fn {n, fun} -> {n, {%{name: n, input_schema: %{}}, fun}} end)}
  end

  defp put_fake(name, tools), do: Registry.put_fake(name, tools_config(tools), @registry_name)

  defp call_task(task), do: Tools.call(%{"name" => "ptc_task", "arguments" => %{"task" => task}})

  defp metrics(env), do: env["structuredContent"]["ptc_metrics"]

  # ============================================================
  # Stub-planner path — provider_reported: false
  # ============================================================

  test "ptc_task envelope carries ptc_metrics with the upstream byte tally" do
    upstream_value = Enum.to_list(1..40)
    upstream_size = byte_size(Jason.encode!(upstream_value))
    :ok = put_fake("alpha", %{"fetch" => fn _, _ -> {:ok, upstream_value} end})
    :ok = AggregatorConfig.set(%{read_only: true})
    Application.put_env(:ptc_runner_mcp, :agentic_planner, NoTokensPlanner)

    env = call_task("fetch and count")
    assert env["isError"] == false
    sc = env["structuredContent"]
    m = metrics(env)

    assert m["schema_version"] == 1
    assert m["upstream_call_count"] == 1
    assert m["upstream_ok_count"] == 1
    assert m["upstream_result_bytes"] == upstream_size
    # final_result_bytes == JSON bytes of {answer, structured_result} (§4.3 / §7 #9).
    expected_final =
      byte_size(
        Jason.encode!(%{
          "answer" => sc["answer"],
          "structured_result" => sc["structured_result"]
        })
      )

    assert m["final_result_bytes"] == expected_final
    assert is_number(m["payload_reduction_ratio"])
    assert m["payload_reduction_ratio"] > 1.0

    # server_side_llm: no provider tokens → byte estimates only.
    ssl = m["server_side_llm"]
    assert ssl["provider_reported"] == false
    assert ssl["prompt_tokens"] == nil
    assert ssl["completion_tokens"] == nil
    assert ssl["total_tokens"] == nil
    assert ssl["prompt_bytes"] == 1234
    assert ssl["completion_bytes"] == 77
    assert ssl["estimated_prompt_tokens"] == ceil_div(1234, 4)
    assert ssl["estimated_completion_tokens"] == ceil_div(77, 4)
    assert ssl["estimate_method"] == "utf8_bytes_div_4"
    assert ssl["planner_calls"] == 1

    assert m["efficiency_note"] =~ "answer/result-payload reduction only"
    assert m["baseline"]["optimistic"]["available"] == false
  end

  test "a pure-compute ptc_task still attaches ptc_metrics with a null ratio" do
    Application.put_env(:ptc_runner_mcp, :agentic_planner, PureComputePlanner)

    env = call_task("just compute")
    assert env["isError"] == false
    m = metrics(env)
    assert m["upstream_call_count"] == 0
    assert m["upstream_result_bytes"] == 0
    assert m["payload_reduction_ratio"] == nil
    # The planner ran, so server_side_llm is still present.
    assert is_map(m["server_side_llm"])
  end

  test "an errored ptc_task envelope carries ptc_metrics with final_result_bytes 0 and null ratio" do
    :ok =
      put_fake("alpha", %{"ok" => fn _, _ -> {:ok, %{"big" => String.duplicate("z", 2_000)}} end})

    :ok = AggregatorConfig.set(%{read_only: true})
    Application.put_env(:ptc_runner_mcp, :agentic_planner, FailAfterFetchPlanner)

    env = call_task("fetch then fail")
    assert env["isError"] == true
    m = metrics(env)
    assert m["final_result_bytes"] == 0
    assert m["payload_reduction_ratio"] == nil
    # The bytes fetched before the failure are still reported.
    assert m["upstream_result_bytes"] ==
             byte_size(Jason.encode!(%{"big" => String.duplicate("z", 2_000)}))

    assert is_map(m["server_side_llm"])
  end

  # Regression for codex review round 1 [P2]: a tool-level `isError`
  # upstream envelope's bytes must land in `upstream_error_bytes` (the
  # program received the full payload) — not be dropped to `null`,
  # which would underreport errored tool payloads relative to the
  # `ptc_lisp_execute` aggregator path.
  test "ptc_task counts isError upstream envelope bytes in upstream_error_bytes" do
    is_error_envelope = %{
      "isError" => true,
      "content" => [%{"type" => "text", "text" => String.duplicate("E", 1_500)}]
    }

    encoded_size = byte_size(Jason.encode!(is_error_envelope))
    :ok = put_fake("alpha", %{"err" => fn _, _ -> {:ok, is_error_envelope} end})
    :ok = AggregatorConfig.set(%{read_only: true})
    Application.put_env(:ptc_runner_mcp, :agentic_planner, IsErrorFetchPlanner)

    env = call_task("fetch from a failing tool")
    assert env["isError"] == false
    sc = env["structuredContent"]
    # The ledger entry is `status: "error"` with the byte count.
    [entry] = sc["upstream_calls"]
    assert entry["status"] == "error"
    assert entry["reason"] == "tool_error"
    assert entry["result_bytes"] == encoded_size
    assert entry["oversize"] == false

    m = metrics(env)
    assert m["upstream_error_count"] == 1
    assert m["upstream_ok_count"] == 0
    assert m["upstream_error_bytes"] == encoded_size
    # Those bytes do NOT count toward useful payload reduction.
    assert m["upstream_result_bytes"] == 0
    assert m["payload_reduction_ratio"] == nil
  end

  # ============================================================
  # Real Planner path — provider_reported: true / false
  # ============================================================

  test "real planner with a usage-reporting adapter → provider_reported: true with real counts" do
    Application.put_env(:ptc_runner_mcp, :agentic_test_pid, self())
    Application.put_env(:ptc_runner, :llm_adapter, UsageReportingAdapter)
    # Default agentic_planner is `Planner` (no app-env override).
    Application.delete_env(:ptc_runner_mcp, :agentic_planner)
    :ok = AgenticConfig.set(%{enabled: true, model: "ollama:metrics-test"})

    env = call_task("answer please")
    assert env["isError"] == false
    assert_receive {:llm_req, req}

    m = metrics(env)
    ssl = m["server_side_llm"]
    assert ssl["provider_reported"] == true
    assert ssl["prompt_tokens"] == 321
    assert ssl["completion_tokens"] == 88
    assert ssl["total_tokens"] == 321 + 88
    # `prompt_bytes` includes the FIXED system message, not just the
    # built prompt (§4.3). Reconstruct what Planner.call/3 sent.
    [%{content: user_prompt}] = req.messages
    assert req.system == Planner.system_message()
    assert ssl["prompt_bytes"] == byte_size(Planner.system_message()) + byte_size(user_prompt)
    assert ssl["prompt_bytes"] > byte_size(user_prompt)
    assert ssl["completion_bytes"] == byte_size("(return {\"v\" 7})")
    assert ssl["estimated_prompt_tokens"] == ceil_div(ssl["prompt_bytes"], 4)
    assert ssl["planner_calls"] == 1
  end

  test "real planner with a no-usage adapter → provider_reported: false, byte estimates present" do
    Application.put_env(:ptc_runner_mcp, :agentic_test_pid, self())
    Application.put_env(:ptc_runner, :llm_adapter, NoUsageAdapter)
    Application.delete_env(:ptc_runner_mcp, :agentic_planner)
    :ok = AgenticConfig.set(%{enabled: true, model: "ollama:metrics-test"})

    env = call_task("answer please")
    assert env["isError"] == false
    assert_receive {:llm_req, req}

    m = metrics(env)
    ssl = m["server_side_llm"]
    assert ssl["provider_reported"] == false
    assert ssl["prompt_tokens"] == nil
    assert ssl["completion_tokens"] == nil
    assert ssl["total_tokens"] == nil
    [%{content: user_prompt}] = req.messages
    assert ssl["prompt_bytes"] == byte_size(Planner.system_message()) + byte_size(user_prompt)
    assert ssl["estimated_prompt_tokens"] == ceil_div(ssl["prompt_bytes"], 4)
    assert ssl["estimated_completion_tokens"] > 0
  end

  defp ceil_div(n, d), do: div(n + d - 1, d)
end
