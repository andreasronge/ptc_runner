defmodule PtcRunnerMcp.ApplicationPhase0Test do
  @moduledoc """
  Phase 0 acceptance tests for §9 / §11.6 CLI flags and env vars:
  `--program-timeout-ms` / `PTC_RUNNER_MCP_PROGRAM_TIMEOUT_MS` and
  `--program-memory-limit-bytes` / `PTC_RUNNER_MCP_PROGRAM_MEMORY_LIMIT_BYTES`.

  Precedence per §9: CLI > env > default.

  Spec: `Plans/ptc-runner-mcp-aggregator.md` §9, §11.6.
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.{Application, Limits}

  setup do
    # Snapshot env vars we touch so we can restore them.
    original = %{
      timeout: System.get_env("PTC_RUNNER_MCP_PROGRAM_TIMEOUT_MS"),
      memory: System.get_env("PTC_RUNNER_MCP_PROGRAM_MEMORY_LIMIT_BYTES")
    }

    on_exit(fn ->
      restore_env("PTC_RUNNER_MCP_PROGRAM_TIMEOUT_MS", original.timeout)
      restore_env("PTC_RUNNER_MCP_PROGRAM_MEMORY_LIMIT_BYTES", original.memory)
      Limits.set(Limits.defaults())
    end)

    System.delete_env("PTC_RUNNER_MCP_PROGRAM_TIMEOUT_MS")
    System.delete_env("PTC_RUNNER_MCP_PROGRAM_MEMORY_LIMIT_BYTES")
    :ok
  end

  # Restore env to its pre-test value. If the var was unset before
  # the test ran, **delete** it — `restore_env(_, nil) → :ok` (the
  # previous shape) leaked any value the test `put_env`'d into
  # VM-wide state and silently affected subsequent tests / suites.
  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  describe "parse_args/1 (§11.6)" do
    test "accepts --program-timeout-ms" do
      args = Application.parse_args(["--program-timeout-ms", "2500"])
      assert args[:program_timeout_ms] == 2500
    end

    test "accepts --program-memory-limit-bytes" do
      args = Application.parse_args(["--program-memory-limit-bytes", "20971520"])
      assert args[:program_memory_limit_bytes] == 20_971_520
    end

    test "ignores unrelated argv tokens" do
      args = Application.parse_args(["--program-timeout-ms", "1500", "--max-frame-bytes", "1024"])
      assert args[:program_timeout_ms] == 1500
      assert args[:max_frame_bytes] == 1024
    end
  end

  describe "apply_limits/1 precedence (§9)" do
    # `apply_limits/1` is private; exercise it via the public seam by
    # building the full args map and running the same path
    # `Application.start/2` runs (sans supervision tree). We rely on
    # Limits.* getters reflecting the configured values.

    test "default (no CLI, no env) yields v1 defaults" do
      assert :ok = run_apply_limits(%{})
      assert Limits.program_timeout_ms() == 1000
      assert Limits.program_memory_limit_bytes() == 10 * 1024 * 1024
    end

    test "env var alone is applied" do
      System.put_env("PTC_RUNNER_MCP_PROGRAM_TIMEOUT_MS", "7777")
      System.put_env("PTC_RUNNER_MCP_PROGRAM_MEMORY_LIMIT_BYTES", "33554432")
      assert :ok = run_apply_limits(%{})
      assert Limits.program_timeout_ms() == 7777
      assert Limits.program_memory_limit_bytes() == 33_554_432
    end

    test "CLI flag overrides env var" do
      System.put_env("PTC_RUNNER_MCP_PROGRAM_TIMEOUT_MS", "7777")
      args = Application.parse_args(["--program-timeout-ms", "1234"])
      assert :ok = run_apply_limits(args)
      assert Limits.program_timeout_ms() == 1234
    end

    test "CLI flag for memory overrides env var" do
      System.put_env("PTC_RUNNER_MCP_PROGRAM_MEMORY_LIMIT_BYTES", "33554432")
      args = Application.parse_args(["--program-memory-limit-bytes", "16777216"])
      assert :ok = run_apply_limits(args)
      assert Limits.program_memory_limit_bytes() == 16_777_216
    end
  end

  # Re-run the same apply path Application.start/2 uses. Phase 0
  # exposes `apply_limits/1` as a `@doc false` seam for this test.
  defp run_apply_limits(args), do: PtcRunnerMcp.Application.apply_limits(args)
end
