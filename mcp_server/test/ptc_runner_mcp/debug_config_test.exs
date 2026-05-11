defmodule PtcRunnerMcp.DebugConfigTest do
  @moduledoc """
  CLI > env > default precedence and ring-size clamping for the opt-in
  `ptc_debug` tool config. See `Plans/ptc-runner-mcp-debug-tool.md` § 4.
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.{Application, DebugConfig}

  setup do
    original = DebugConfig.get()

    on_exit(fn ->
      DebugConfig.set(original)
      System.delete_env("PTC_RUNNER_MCP_DEBUG_TOOL")
      System.delete_env("PTC_RUNNER_MCP_DEBUG_RING_SIZE")
      System.delete_env("PTC_RUNNER_MCP_MAX_DEBUG_RESPONSE_BYTES")
    end)

    System.delete_env("PTC_RUNNER_MCP_DEBUG_TOOL")
    System.delete_env("PTC_RUNNER_MCP_DEBUG_RING_SIZE")
    System.delete_env("PTC_RUNNER_MCP_MAX_DEBUG_RESPONSE_BYTES")
    :ok
  end

  test "defaults: disabled, ring 500, 64 KiB" do
    :ok = Application.apply_debug_config(%{})
    assert DebugConfig.enabled?() == false
    assert DebugConfig.ring_size() == 500
    assert DebugConfig.max_response_bytes() == 65_536
  end

  test "CLI flag enables the tool" do
    :ok = Application.apply_debug_config(%{debug_tool: true})
    assert DebugConfig.enabled?()
  end

  test "env var enables the tool when no CLI flag" do
    System.put_env("PTC_RUNNER_MCP_DEBUG_TOOL", "true")
    :ok = Application.apply_debug_config(%{})
    assert DebugConfig.enabled?()
  end

  test "CLI flag wins over env var" do
    System.put_env("PTC_RUNNER_MCP_DEBUG_RING_SIZE", "111")
    :ok = Application.apply_debug_config(%{debug_tool: true, debug_ring_size: 222})
    assert DebugConfig.ring_size() == 222
  end

  test "env var used when no CLI flag" do
    System.put_env("PTC_RUNNER_MCP_DEBUG_RING_SIZE", "111")
    System.put_env("PTC_RUNNER_MCP_MAX_DEBUG_RESPONSE_BYTES", "4096")
    :ok = Application.apply_debug_config(%{debug_tool: true})
    assert DebugConfig.ring_size() == 111
    assert DebugConfig.max_response_bytes() == 4096
  end

  test "ring size clamped to [10, 5000] (low)" do
    :ok = Application.apply_debug_config(%{debug_tool: true, debug_ring_size: 1})
    assert DebugConfig.ring_size() == 10
  end

  test "ring size clamped to [10, 5000] (high)" do
    :ok = Application.apply_debug_config(%{debug_tool: true, debug_ring_size: 999_999})
    assert DebugConfig.ring_size() == 5000
  end

  test "clamp_ring_size/1 reports whether it clamped" do
    assert DebugConfig.clamp_ring_size(500) == {500, false}
    assert DebugConfig.clamp_ring_size(5) == {10, true}
    assert DebugConfig.clamp_ring_size(99_999) == {5000, true}
  end

  test "max_debug_response_bytes raised to the floor when set lower" do
    :ok = Application.apply_debug_config(%{debug_tool: true, max_debug_response_bytes: 100})
    assert DebugConfig.max_response_bytes() == DebugConfig.max_response_bytes_min()
    assert DebugConfig.max_response_bytes() == 4_096
  end

  test "clamp_max_response_bytes/1 reports whether it clamped" do
    assert DebugConfig.clamp_max_response_bytes(65_536) == {65_536, false}
    assert DebugConfig.clamp_max_response_bytes(10) == {4_096, true}
  end

  test "parse_args recognizes the three debug flags" do
    args =
      Application.parse_args([
        "--debug-tool",
        "--debug-ring-size",
        "42",
        "--max-debug-response-bytes",
        "8192"
      ])

    assert args[:debug_tool] == true
    assert args[:debug_ring_size] == 42
    assert args[:max_debug_response_bytes] == 8192
  end
end
