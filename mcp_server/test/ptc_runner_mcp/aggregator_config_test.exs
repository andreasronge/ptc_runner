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
end
