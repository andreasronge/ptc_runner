defmodule PtcRunnerMcp.LimitsPhase1aTest do
  @moduledoc """
  Phase 1a tests for the three new aggregator-only limits and the
  aggregator-mode override of the v1 program limits.

  Spec: `Plans/ptc-runner-mcp-aggregator.md` §9, §11.6.

  Each non-default flag has a behavioral regression test (set the
  limit to a non-default value, exercise the system, observe the
  difference) — Phase 0's first codex finding was a flag persisted
  in `Limits` but never consumed at runtime. The same shape of bug
  here would make the aggregator limits a dead config knob.
  """
  use ExUnit.Case, async: false

  import PtcRunnerMcp.McpTestHelpers, only: [stop_existing_registry: 1]

  alias PtcRunnerMcp.{Application, Limits, Tools}
  alias PtcRunnerMcp.Upstream.Registry

  @registry_name PtcRunnerMcp.Upstream.Registry

  setup do
    # Reset env vars we touch.
    original = %{
      ucto: System.get_env("PTC_RUNNER_MCP_UPSTREAM_CALL_TIMEOUT_MS"),
      muxr: System.get_env("PTC_RUNNER_MCP_MAX_UPSTREAM_RESPONSE_BYTES"),
      muxc: System.get_env("PTC_RUNNER_MCP_MAX_UPSTREAM_CALLS_PER_PROGRAM"),
      timeout: System.get_env("PTC_RUNNER_MCP_PROGRAM_TIMEOUT_MS"),
      memory: System.get_env("PTC_RUNNER_MCP_PROGRAM_MEMORY_LIMIT_BYTES")
    }

    Enum.each(
      [
        "PTC_RUNNER_MCP_UPSTREAM_CALL_TIMEOUT_MS",
        "PTC_RUNNER_MCP_MAX_UPSTREAM_RESPONSE_BYTES",
        "PTC_RUNNER_MCP_MAX_UPSTREAM_CALLS_PER_PROGRAM",
        "PTC_RUNNER_MCP_PROGRAM_TIMEOUT_MS",
        "PTC_RUNNER_MCP_PROGRAM_MEMORY_LIMIT_BYTES"
      ],
      &System.delete_env/1
    )

    on_exit(fn ->
      restore_env("PTC_RUNNER_MCP_UPSTREAM_CALL_TIMEOUT_MS", original.ucto)
      restore_env("PTC_RUNNER_MCP_MAX_UPSTREAM_RESPONSE_BYTES", original.muxr)
      restore_env("PTC_RUNNER_MCP_MAX_UPSTREAM_CALLS_PER_PROGRAM", original.muxc)
      restore_env("PTC_RUNNER_MCP_PROGRAM_TIMEOUT_MS", original.timeout)
      restore_env("PTC_RUNNER_MCP_PROGRAM_MEMORY_LIMIT_BYTES", original.memory)
      Limits.set(Limits.defaults())
    end)

    Limits.set(Limits.defaults())
    :ok
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  describe "defaults (§9 third+ rows)" do
    test "upstream_call_timeout_ms default is 5000ms" do
      assert Limits.upstream_call_timeout_ms() == 5_000
    end

    test "max_upstream_response_bytes default is 2MB" do
      assert Limits.max_upstream_response_bytes() == 2 * 1024 * 1024
    end

    test "max_upstream_calls_per_program default is 50" do
      assert Limits.max_upstream_calls_per_program() == 50
    end

    test "aggregator_defaults/0 returns the §9 mode-default values" do
      defaults = Limits.aggregator_defaults()
      assert defaults.program_timeout_ms == 10_000
      assert defaults.program_memory_limit_bytes == 100 * 1024 * 1024
    end
  end

  describe "parse_args/1 accepts new flags" do
    test "--upstream-call-timeout-ms" do
      args = Application.parse_args(["--upstream-call-timeout-ms", "1234"])
      assert args[:upstream_call_timeout_ms] == 1234
    end

    test "--max-upstream-response-bytes" do
      args = Application.parse_args(["--max-upstream-response-bytes", "9000000"])
      assert args[:max_upstream_response_bytes] == 9_000_000
    end

    test "--max-upstream-calls-per-program" do
      args = Application.parse_args(["--max-upstream-calls-per-program", "7"])
      assert args[:max_upstream_calls_per_program] == 7
    end

    test "--upstreams-config" do
      args = Application.parse_args(["--upstreams-config", "/tmp/foo.json"])
      assert args[:upstreams_config] == "/tmp/foo.json"
    end
  end

  describe "apply_limits/2 precedence (§9, §11.6)" do
    test "CLI flag wins over env var (upstream-call-timeout-ms)" do
      System.put_env("PTC_RUNNER_MCP_UPSTREAM_CALL_TIMEOUT_MS", "9999")
      args = Application.parse_args(["--upstream-call-timeout-ms", "777"])

      assert :ok = Application.apply_limits(args)
      assert Limits.upstream_call_timeout_ms() == 777
    end

    test "env var alone is applied for max-upstream-response-bytes" do
      System.put_env("PTC_RUNNER_MCP_MAX_UPSTREAM_RESPONSE_BYTES", "8192")
      assert :ok = Application.apply_limits(%{})
      assert Limits.max_upstream_response_bytes() == 8192
    end

    test "default kicks in when nothing set" do
      assert :ok = Application.apply_limits(%{})
      assert Limits.max_upstream_calls_per_program() == 50
    end

    test "aggregator mode override applies when no explicit value provided (§11.6)" do
      assert :ok = Application.apply_limits(%{}, aggregator?: true)
      assert Limits.program_timeout_ms() == 10_000
      assert Limits.program_memory_limit_bytes() == 100 * 1024 * 1024
    end

    test "aggregator mode does NOT override an explicit CLI flag (§11.6)" do
      args = Application.parse_args(["--program-timeout-ms", "1000"])
      assert :ok = Application.apply_limits(args, aggregator?: true)
      # Explicit 1000 wins over the 10000 aggregator default.
      assert Limits.program_timeout_ms() == 1000
    end

    test "aggregator mode does NOT override an explicit env var (§11.6)" do
      System.put_env("PTC_RUNNER_MCP_PROGRAM_TIMEOUT_MS", "1500")
      assert :ok = Application.apply_limits(%{}, aggregator?: true)
      assert Limits.program_timeout_ms() == 1500
    end

    test "non-aggregator mode keeps the v1 defaults (1s / 10MB)" do
      assert :ok = Application.apply_limits(%{})
      assert Limits.program_timeout_ms() == 1000
      assert Limits.program_memory_limit_bytes() == 10 * 1024 * 1024
    end
  end

  # ----------------------------------------------------------------
  # Behavioral regressions: prove each new flag actually flows
  # through to runtime behavior. Phase 0's first codex finding was
  # exactly this shape — a persisted-but-never-consumed flag.
  # ----------------------------------------------------------------

  describe "upstream_call_timeout_ms is consumed by the executor" do
    setup do
      stop_existing_registry(@registry_name)
      {:ok, _pid} = Registry.start_link(name: @registry_name)
      on_exit(fn -> stop_existing_registry(@registry_name) end)
      :ok
    end

    test "non-default value (50ms) trips a 500ms call → :timeout entry" do
      Limits.set(Map.put(Limits.defaults(), :upstream_call_timeout_ms, 50))

      slow = fn _, _ ->
        :timer.sleep(500)
        {:ok, "should not arrive"}
      end

      :ok =
        Registry.put_fake(
          "alpha",
          %{tools: %{"slow" => {%{name: "slow", input_schema: %{}}, slow}}},
          @registry_name
        )

      env =
        Tools.call_with_gate(%{
          "program" => ~S|(tool/call {:server "alpha" :tool "slow" :args {}})|
        })

      assert env["isError"] == false
      [entry] = env["structuredContent"]["upstream_calls"]
      assert entry["reason"] == "timeout"
    end
  end

  describe "max_upstream_response_bytes is consumed by the executor" do
    setup do
      stop_existing_registry(@registry_name)
      {:ok, _pid} = Registry.start_link(name: @registry_name)
      on_exit(fn -> stop_existing_registry(@registry_name) end)
      :ok
    end

    test "non-default cap (100B) trips a 5KB response → :response_too_large" do
      Limits.set(Map.put(Limits.defaults(), :max_upstream_response_bytes, 100))

      payload = String.duplicate("y", 5_000)

      :ok =
        Registry.put_fake(
          "alpha",
          %{
            tools: %{
              "big" => {%{name: "big", input_schema: %{}}, fn _, _ -> {:ok, payload} end}
            }
          },
          @registry_name
        )

      env =
        Tools.call_with_gate(%{
          "program" => ~S|(tool/call {:server "alpha" :tool "big" :args {}})|
        })

      [entry] = env["structuredContent"]["upstream_calls"]
      assert entry["reason"] == "response_too_large"
    end
  end

  describe "max_upstream_calls_per_program is consumed by the executor" do
    setup do
      stop_existing_registry(@registry_name)
      {:ok, _pid} = Registry.start_link(name: @registry_name)
      on_exit(fn -> stop_existing_registry(@registry_name) end)
      :ok
    end

    test "cap=2: 4 sequential calls produce 2 ok + 2 cap_exhausted" do
      Limits.set(Map.put(Limits.defaults(), :max_upstream_calls_per_program, 2))

      :ok =
        Registry.put_fake(
          "alpha",
          %{
            tools: %{
              "x" => {%{name: "x", input_schema: %{}}, fn args, _ -> {:ok, args["i"]} end}
            }
          },
          @registry_name
        )

      env =
        Tools.call_with_gate(%{
          "program" => ~S|
            [(tool/call {:server "alpha" :tool "x" :args {:i 1}})
             (tool/call {:server "alpha" :tool "x" :args {:i 2}})
             (tool/call {:server "alpha" :tool "x" :args {:i 3}})
             (tool/call {:server "alpha" :tool "x" :args {:i 4}})]
          |
        })

      entries = env["structuredContent"]["upstream_calls"]
      assert length(entries) == 4

      ok_count = Enum.count(entries, &(&1["status"] == "ok"))
      cap_count = Enum.count(entries, &(&1["reason"] == "cap_exhausted"))

      assert ok_count == 2
      assert cap_count == 2
    end
  end
end
