defmodule PtcRunnerMcp.AggregatorConfigTest do
  @moduledoc """
  Tests for non-limit aggregator configuration.
  """

  use ExUnit.Case, async: false

  alias PtcRunnerMcp.{AggregatorConfig, Application}

  setup do
    original = System.get_env("PTC_RUNNER_MCP_AGGREGATOR_READ_ONLY")
    System.delete_env("PTC_RUNNER_MCP_AGGREGATOR_READ_ONLY")
    AggregatorConfig.set(AggregatorConfig.defaults())

    on_exit(fn ->
      restore_env("PTC_RUNNER_MCP_AGGREGATOR_READ_ONLY", original)
      AggregatorConfig.set(AggregatorConfig.defaults())
    end)

    :ok
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  describe "parse_args/1" do
    test "accepts --aggregator-read-only" do
      args = Application.parse_args(["--aggregator-read-only"])
      assert args[:aggregator_read_only] == true
    end
  end

  describe "apply_aggregator_config/1 precedence" do
    test "default is conservative" do
      assert :ok = Application.apply_aggregator_config(%{})
      refute AggregatorConfig.read_only?()
    end

    test "env var alone enables read-only annotation mode" do
      System.put_env("PTC_RUNNER_MCP_AGGREGATOR_READ_ONLY", "true")
      assert :ok = Application.apply_aggregator_config(%{})
      assert AggregatorConfig.read_only?()
    end

    test "false env var disables read-only annotation mode" do
      System.put_env("PTC_RUNNER_MCP_AGGREGATOR_READ_ONLY", "false")
      assert :ok = Application.apply_aggregator_config(%{})
      refute AggregatorConfig.read_only?()
    end

    test "CLI flag wins over false env var" do
      System.put_env("PTC_RUNNER_MCP_AGGREGATOR_READ_ONLY", "false")
      args = Application.parse_args(["--aggregator-read-only"])

      assert :ok = Application.apply_aggregator_config(args)
      assert AggregatorConfig.read_only?()
    end
  end

  describe "raw envelope policy" do
    test "resolves tool, upstream, global, false precedence" do
      AggregatorConfig.set(%{
        raw_envelope_default: true,
        upstreams: %{
          "alpha" => %{
            raw_envelope: false,
            tools: %{"debug" => %{raw_envelope: true}}
          }
        }
      })

      assert AggregatorConfig.raw_envelope_enabled?("alpha", "debug")
      refute AggregatorConfig.raw_envelope_enabled?("alpha", "normal")
      assert AggregatorConfig.raw_envelope_enabled?("beta", "anything")

      AggregatorConfig.set(%{})
      refute AggregatorConfig.raw_envelope_enabled?("beta", "anything")
    end

    @tag :tmp_dir
    test "loads policy keys without leaving them in stdio transport config", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "upstreams.json")

      File.write!(
        path,
        Jason.encode!(%{
          "upstreams" => %{
            "alpha" => %{
              "command" => "echo",
              "raw_envelope" => true,
              "tools" => %{"read" => %{"raw_envelope" => false}}
            }
          }
        })
      )

      args = Application.parse_args(["--upstreams-config", path])

      assert %{upstreams: [%{config: %{command: "echo"}}]} =
               Application.load_aggregator_config(args)
    end
  end
end
