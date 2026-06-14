defmodule PtcRunnerMcp.ApplicationPhase0Test do
  @moduledoc """
  Phase 0 acceptance tests for §9 / §11.6 CLI flags and env vars:
  `--program-timeout-ms` / `PTC_RUNNER_MCP_PROGRAM_TIMEOUT_MS` and
  `--program-memory-limit-bytes` / `PTC_RUNNER_MCP_PROGRAM_MEMORY_LIMIT_BYTES`.

  Precedence per §9: CLI > env > default.

  Spec: `Plans/ptc-runner-mcp-aggregator.md` §9, §11.6.
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.{Application, Limits, TurnLogConfig}
  alias PtcRunnerMcp.Sessions.Config, as: SessionsConfig

  setup do
    # Snapshot env vars we touch so we can restore them.
    original = %{
      timeout: System.get_env("PTC_RUNNER_MCP_PROGRAM_TIMEOUT_MS"),
      memory: System.get_env("PTC_RUNNER_MCP_PROGRAM_MEMORY_LIMIT_BYTES"),
      max_sessions: System.get_env("PTC_RUNNER_MCP_MAX_SESSIONS"),
      max_session_preview_chars: System.get_env("PTC_RUNNER_MCP_MAX_SESSION_PREVIEW_CHARS"),
      max_upstream_response_bytes: System.get_env("PTC_RUNNER_MCP_MAX_UPSTREAM_RESPONSE_BYTES"),
      turn_log_dir: System.get_env("PTC_RUNNER_MCP_TURN_LOG_DIR"),
      prelude: System.get_env("PTC_RUNNER_MCP_PRELUDE")
    }

    on_exit(fn ->
      restore_env("PTC_RUNNER_MCP_PROGRAM_TIMEOUT_MS", original.timeout)
      restore_env("PTC_RUNNER_MCP_PROGRAM_MEMORY_LIMIT_BYTES", original.memory)
      restore_env("PTC_RUNNER_MCP_MAX_SESSIONS", original.max_sessions)
      restore_env("PTC_RUNNER_MCP_MAX_SESSION_PREVIEW_CHARS", original.max_session_preview_chars)

      restore_env(
        "PTC_RUNNER_MCP_MAX_UPSTREAM_RESPONSE_BYTES",
        original.max_upstream_response_bytes
      )

      restore_env("PTC_RUNNER_MCP_TURN_LOG_DIR", original.turn_log_dir)
      restore_env("PTC_RUNNER_MCP_PRELUDE", original.prelude)

      Limits.set(Limits.defaults())
      SessionsConfig.reset()
      TurnLogConfig.set(TurnLogConfig.defaults())
      TurnLogConfig.put_collector(nil)
    end)

    System.delete_env("PTC_RUNNER_MCP_PROGRAM_TIMEOUT_MS")
    System.delete_env("PTC_RUNNER_MCP_PROGRAM_MEMORY_LIMIT_BYTES")
    System.delete_env("PTC_RUNNER_MCP_MAX_SESSIONS")
    System.delete_env("PTC_RUNNER_MCP_MAX_SESSION_PREVIEW_CHARS")
    System.delete_env("PTC_RUNNER_MCP_MAX_UPSTREAM_RESPONSE_BYTES")
    System.delete_env("PTC_RUNNER_MCP_TURN_LOG_DIR")
    System.delete_env("PTC_RUNNER_MCP_PRELUDE")
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

    test "accepts --turn-log-dir" do
      args = Application.parse_args(["--turn-log-dir", "/tmp/ptc-turns"])
      assert args[:turn_log_dir] == "/tmp/ptc-turns"
    end

    test "accepts --prelude" do
      args = Application.parse_args(["--prelude", "/tmp/session-prelude.clj"])
      assert args[:prelude] == "/tmp/session-prelude.clj"
    end

    test "accepts --max-session-preview-chars" do
      args = Application.parse_args(["--max-session-preview-chars", "4096"])
      assert args[:max_session_preview_chars] == 4096
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

    test "rejects numeric-prefix garbage for integer config" do
      System.put_env("PTC_RUNNER_MCP_MAX_UPSTREAM_RESPONSE_BYTES", "64mb")

      assert_raise RuntimeError,
                   ~r/PTC_RUNNER_MCP_MAX_UPSTREAM_RESPONSE_BYTES must be a positive integer/,
                   fn ->
                     run_apply_limits(%{})
                   end
    end
  end

  describe "apply_sessions_config/1" do
    test "rejects invalid explicit integer config" do
      assert_raise RuntimeError, ~r/--max-sessions .* must be a positive integer/, fn ->
        Application.apply_sessions_config(%{max_sessions: 0})
      end
    end

    test "rejects invalid integer config supplied via env var" do
      System.put_env("PTC_RUNNER_MCP_MAX_SESSIONS", "not-a-number")

      assert_raise RuntimeError, ~r/PTC_RUNNER_MCP_MAX_SESSIONS must be a positive integer/, fn ->
        Application.apply_sessions_config(%{})
      end
    end

    test "rejects numeric-prefix garbage via shared session resolver" do
      System.put_env("PTC_RUNNER_MCP_MAX_SESSIONS", "64mb")

      assert_raise RuntimeError, ~r/PTC_RUNNER_MCP_MAX_SESSIONS must be a positive integer/, fn ->
        Application.apply_sessions_config(%{})
      end
    end

    test "max session preview chars defaults to the session projection preview cap" do
      assert :ok = Application.apply_sessions_config(%{})
      assert SessionsConfig.get().max_session_preview_chars == 512
    end

    test "max session preview chars follows env vars" do
      System.put_env("PTC_RUNNER_MCP_MAX_SESSION_PREVIEW_CHARS", "4096")

      assert :ok = Application.apply_sessions_config(%{})
      assert SessionsConfig.get().max_session_preview_chars == 4096
    end

    test "max session preview chars CLI flag overrides env var" do
      System.put_env("PTC_RUNNER_MCP_MAX_SESSION_PREVIEW_CHARS", "4096")

      assert :ok = Application.apply_sessions_config(%{max_session_preview_chars: 8192})
      assert SessionsConfig.get().max_session_preview_chars == 8192
    end

    test "rejects invalid max session preview chars" do
      assert_raise RuntimeError,
                   ~r/--max-session-preview-chars .* must be a positive integer/,
                   fn ->
                     Application.apply_sessions_config(%{max_session_preview_chars: 0})
                   end
    end

    test "loads prelude source from CLI path" do
      path = write_prelude!("cli")

      assert :ok = Application.apply_sessions_config(%{prelude: path})
      assert SessionsConfig.get().prelude_path == path
      assert SessionsConfig.prelude_source() =~ "(ns smoke"
    end

    test "prelude CLI path overrides env var" do
      env_path = write_prelude!("env")
      cli_path = write_prelude!("cli")
      System.put_env("PTC_RUNNER_MCP_PRELUDE", env_path)

      assert :ok = Application.apply_sessions_config(%{prelude: cli_path})
      assert SessionsConfig.get().prelude_path == cli_path
      assert SessionsConfig.prelude_source() =~ "cli"
    end

    test "manual config updates recompile runtime prelude from source" do
      assert :ok = Application.apply_sessions_config(%{prelude: write_prelude!("first")})
      first_hash = SessionsConfig.runtime_prelude().source_hash

      updated_source = prelude_source!("second")
      SessionsConfig.set(Map.put(SessionsConfig.get(), :prelude_source, updated_source))

      assert SessionsConfig.prelude_source() == updated_source
      assert SessionsConfig.runtime_prelude().source_hash != first_hash
      assert SessionsConfig.runtime_prelude().source_hash == source_hash(updated_source)
    end

    test "rejects unreadable prelude path" do
      missing = Path.join(System.tmp_dir!(), "ptc_runner_missing_prelude.clj")

      assert_raise RuntimeError, ~r/--prelude .* could not be read/, fn ->
        Application.apply_sessions_config(%{prelude: missing})
      end
    end
  end

  describe "apply_turn_log_config/1" do
    test "defaults to disabled" do
      assert :ok = Application.apply_turn_log_config(%{})
      assert TurnLogConfig.turn_log_dir() == nil
      refute TurnLogConfig.enabled?()
    end

    test "env var enables turn log dir" do
      System.put_env("PTC_RUNNER_MCP_TURN_LOG_DIR", "/tmp/from-env")

      assert :ok = Application.apply_turn_log_config(%{})
      assert TurnLogConfig.turn_log_dir() == "/tmp/from-env"
      assert TurnLogConfig.enabled?()
    end

    test "CLI flag overrides env var" do
      System.put_env("PTC_RUNNER_MCP_TURN_LOG_DIR", "/tmp/from-env")

      assert :ok =
               Application.apply_turn_log_config(%{
                 turn_log_dir: "/tmp/from-cli"
               })

      assert TurnLogConfig.turn_log_dir() == "/tmp/from-cli"
    end
  end

  # Re-run the same apply path Application.start/2 uses. Phase 0
  # exposes `apply_limits/1` as a `@doc false` seam for this test.
  defp run_apply_limits(args), do: PtcRunnerMcp.Application.apply_limits(args)

  defp write_prelude!(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ptc_runner_mcp_#{label}_#{System.unique_integer([:positive])}.clj"
      )

    File.write!(path, prelude_source!(label))

    path
  end

  defp prelude_source!(label) do
    """
    (ns smoke {:visibility :prompt})
    (defn label [] "#{label}")
    """
  end

  defp source_hash(source) do
    :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
  end
end
