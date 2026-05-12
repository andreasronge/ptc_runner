defmodule PtcRunnerMcp.ResponseProfileTest do
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.{Application, DebugConfig, ResponseProfile}

  setup do
    old_debug = DebugConfig.get()
    old_env = System.get_env("PTC_RUNNER_MCP_RESPONSE_PROFILE")
    old_debug_env = System.get_env("PTC_RUNNER_MCP_DEBUG_TOOL")

    DebugConfig.set(DebugConfig.defaults())
    System.delete_env("PTC_RUNNER_MCP_RESPONSE_PROFILE")
    System.delete_env("PTC_RUNNER_MCP_DEBUG_TOOL")
    ResponseProfile.reset()

    on_exit(fn ->
      DebugConfig.set(old_debug)
      restore_env("PTC_RUNNER_MCP_RESPONSE_PROFILE", old_env)
      restore_env("PTC_RUNNER_MCP_DEBUG_TOOL", old_debug_env)
      ResponseProfile.set(:debug)
    end)

    :ok
  end

  test "defaults to slim" do
    assert ResponseProfile.resolve(%{}) == :slim
  end

  test "debug tool infers debug when no response profile is explicit" do
    assert ResponseProfile.resolve(%{debug_tool: true}) == :debug
  end

  test "env wins over debug-inferred profile" do
    System.put_env("PTC_RUNNER_MCP_RESPONSE_PROFILE", "structured")

    assert ResponseProfile.resolve(%{debug_tool: true}) == :structured
  end

  test "CLI wins over env" do
    System.put_env("PTC_RUNNER_MCP_RESPONSE_PROFILE", "debug")

    assert ResponseProfile.resolve(%{response_profile: "slim", debug_tool: true}) == :slim
  end

  test "application parser and applier wire the CLI flag" do
    args = Application.parse_args(["--response-profile", "structured"])

    assert args[:response_profile] == "structured"
    assert Application.apply_response_profile(args) == :ok
    assert ResponseProfile.current() == :structured
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
