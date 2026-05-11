defmodule PtcRunnerMcp.AgenticConfigTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PtcRunnerMcp.{AgenticConfig, AggregatorConfig, Application, Log}

  @env_vars ~w(
    PTC_RUNNER_MCP_AGENTIC
    PTC_RUNNER_MCP_AGENTIC_MAX_TURNS
    PTC_RUNNER_MCP_AGENTIC_RETRY_TURNS
    PTC_RUNNER_MCP_AGENTIC_ALLOW_WRITES
    PTC_RUNNER_MCP_AGENTIC_SUBAGENT_CONFIG
    PTC_RUNNER_MCP_AGENTIC_CAPABILITY_SUMMARY_MAX_BYTES
    PTC_RUNNER_MCP_AGENTIC_CAPABILITY_SUMMARY
  )

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_log_level = Log.level()
    tmp_dir = Path.join(System.tmp_dir!(), "agentic-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      Enum.each(original_env, fn {key, value} -> restore_env(key, value) end)
      File.rm_rf(tmp_dir)
      AgenticConfig.set(AgenticConfig.defaults())
      AggregatorConfig.set(AggregatorConfig.defaults())
      Log.set_level(original_log_level)
    end)

    Enum.each(@env_vars, &System.delete_env/1)
    AgenticConfig.set(AgenticConfig.defaults())
    AggregatorConfig.set(AggregatorConfig.defaults())
    Log.set_level(:info)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "CLI/env/config-file precedence" do
    test "parses Phase 2 agentic flags" do
      args =
        Application.parse_args([
          "--agentic-max-turns",
          "3",
          "--agentic-retry-turns",
          "1",
          "--agentic-allow-writes",
          "--agentic-subagent-config",
          "/tmp/agentic.json",
          "--agentic-capability-summary-max-bytes",
          "1200",
          "--agentic-capability-summary",
          "/tmp/summary.txt"
        ])

      assert args.agentic_max_turns == 3
      assert args.agentic_retry_turns == 1
      assert args.agentic_allow_writes
      assert args.agentic_subagent_config == "/tmp/agentic.json"
      assert args.agentic_capability_summary_max_bytes == 1200
      assert args.agentic_capability_summary == "/tmp/summary.txt"
    end

    test "config file overrides defaults and CLI/env override config file", %{tmp_dir: tmp_dir} do
      config_path =
        write_json!(tmp_dir, "agentic.json", %{
          "max_turns" => 2,
          "retry_turns" => 1,
          "system_prompt" => %{"prefix" => "ops prefix", "suffix" => "ops suffix"}
        })

      System.put_env("PTC_RUNNER_MCP_AGENTIC_RETRY_TURNS", "4")

      args =
        Application.parse_args([
          "--agentic-subagent-config",
          config_path,
          "--agentic-max-turns",
          "5"
        ])

      assert :ok = Application.apply_agentic_config(args)

      cfg = AgenticConfig.get()
      assert cfg.max_turns == 5
      assert cfg.retry_turns == 4
      assert cfg.system_prompt == %{prefix: "ops prefix", suffix: "ops suffix"}
      assert cfg.subagent_config_path == config_path
    end

    test "capability summary override is loaded verbatim and size checked", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "summary.txt")
      File.write!(path, "- alpha: search\n")

      args =
        Application.parse_args([
          "--agentic-capability-summary",
          path,
          "--agentic-capability-summary-max-bytes",
          "32"
        ])

      assert :ok = Application.apply_agentic_config(args)
      assert AgenticConfig.get().capability_summary_path == path
      assert AgenticConfig.get().capability_summary == "- alpha: search\n"

      oversize =
        Application.parse_args([
          "--agentic-capability-summary",
          path,
          "--agentic-capability-summary-max-bytes",
          "4"
        ])

      assert_raise ArgumentError, ~r/exceeding configured cap 4/, fn ->
        Application.apply_agentic_config(oversize)
      end
    end

    test "boot log reports sources and prompt byte counts without prompt text", %{
      tmp_dir: tmp_dir
    } do
      config_path =
        write_json!(tmp_dir, "agentic-log.json", %{
          "max_turns" => 3,
          "system_prompt" => %{"prefix" => "secret operator text"}
        })

      log =
        capture_io(:stderr, fn ->
          assert :ok =
                   Application.apply_agentic_config(%{
                     agentic: true,
                     agentic_subagent_config: config_path
                   })
        end)

      refute log =~ "secret operator text"
      decoded = log |> String.trim() |> Jason.decode!()
      fields = decoded["fields"]
      assert fields["applied"]["max_turns"] == %{"source" => "config_file", "value" => 3}

      assert fields["applied"]["system_prompt_prefix_bytes"] == %{
               "source" => "config_file",
               "value" => 20
             }

      assert fields["defaulted"]["retry_turns"] == 0
      assert fields["defaulted"]["system_prompt_suffix_bytes"] == 0
    end
  end

  describe "SubAgent JSON allowlist" do
    test "unreadable and malformed config files fail boot clearly", %{tmp_dir: tmp_dir} do
      missing = Path.join(tmp_dir, "missing.json")

      assert_raise ArgumentError, ~r/cannot read #{Regex.escape(missing)}/, fn ->
        Application.apply_agentic_config(%{agentic_subagent_config: missing})
      end

      malformed = Path.join(tmp_dir, "malformed.json")
      File.write!(malformed, "{")

      assert_raise ArgumentError, ~r/malformed JSON/, fn ->
        Application.apply_agentic_config(%{agentic_subagent_config: malformed})
      end
    end

    test "reserved top-level keys are rejected with allowed-key details", %{tmp_dir: tmp_dir} do
      path = write_json!(tmp_dir, "reserved.json", %{"tools" => %{}})

      assert_raise ArgumentError,
                   ~r/reserved key\(s\): tools.*Allowed keys: max_turns, retry_turns, system_prompt/s,
                   fn ->
                     Application.apply_agentic_config(%{agentic_subagent_config: path})
                   end
    end

    test "unknown and deferred top-level keys are rejected", %{tmp_dir: tmp_dir} do
      for key <- ["cache", "thinking", "mission_timeout_ms", "other"] do
        path = write_json!(tmp_dir, "#{key}.json", %{key => true})

        assert_raise ArgumentError, ~r/unknown key\(s\): #{Regex.escape(key)}/, fn ->
          Application.apply_agentic_config(%{agentic_subagent_config: path})
        end
      end
    end

    test "system_prompt rejects MCP-controlled and unknown slots", %{tmp_dir: tmp_dir} do
      path =
        write_json!(tmp_dir, "prompt.json", %{
          "system_prompt" => %{"language_spec" => "nope"}
        })

      assert_raise ArgumentError, ~r/unknown system_prompt key\(s\): language_spec/, fn ->
        Application.apply_agentic_config(%{agentic_subagent_config: path})
      end
    end

    test "prompt slots are capped at 4096 bytes", %{tmp_dir: tmp_dir} do
      path =
        write_json!(tmp_dir, "prompt-big.json", %{
          "system_prompt" => %{"prefix" => String.duplicate("x", 4097)}
        })

      assert_raise ArgumentError, ~r/system_prompt.prefix is 4097 bytes/, fn ->
        Application.apply_agentic_config(%{agentic_subagent_config: path})
      end
    end
  end

  describe "boot validation" do
    test "agentic with upstreams requires read-only assertion or allow_writes" do
      capture_io(:stderr, fn ->
        assert :ok = Application.apply_agentic_config(%{agentic: true})
      end)

      assert_raise RuntimeError, ~r/configured upstream access is not asserted read-only/, fn ->
        Application.validate_agentic_boot!([%{name: "alpha"}])
      end

      AggregatorConfig.set(%{read_only: true})
      assert :ok = Application.validate_agentic_boot!([%{name: "alpha"}])
    end

    test "allow_writes without agentic fails, but retry_turns remain allowed when enabled" do
      assert :ok = Application.apply_agentic_config(%{agentic_allow_writes: true})

      assert_raise RuntimeError, ~r/--agentic-allow-writes requires --agentic/, fn ->
        Application.validate_agentic_boot!([])
      end

      capture_io(:stderr, fn ->
        assert :ok =
                 Application.apply_agentic_config(%{
                   agentic: true,
                   agentic_allow_writes: true,
                   agentic_retry_turns: 2
                 })
      end)

      assert AgenticConfig.get().retry_turns == 2
      assert :ok = Application.validate_agentic_boot!([%{name: "alpha"}])
    end
  end

  defp write_json!(tmp_dir, filename, value) do
    path = Path.join(tmp_dir, filename)
    File.write!(path, Jason.encode!(value))
    path
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
