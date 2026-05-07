defmodule PtcRunnerMcp.Lifecycle do
  @moduledoc """
  MCP handshake and lifecycle handlers.

  Implements `initialize`, `notifications/initialized`, `shutdown`,
  `exit`, and `notifications/cancelled`. See § 7.1, § 7.2, § 6.4 of
  `Plans/ptc-runner-mcp-server.md`.

  This module owns no process state; lifecycle transitions
  (drain/exit) are signaled by the caller (`PtcRunnerMcp.JsonRpc`).
  """

  alias PtcRunnerMcp.{Log, Version}

  @doc """
  Build the `initialize` reply per § 7.1.

  The reply mirrors the negotiated `protocolVersion`, advertises
  `tools.listChanged: false`, and intentionally omits `resources`,
  `prompts`, `experimental`, `elicitation`, and `sampling`.
  """
  @spec initialize_reply(map() | nil) :: map()
  def initialize_reply(params) do
    requested =
      case params do
        %{"protocolVersion" => v} when is_binary(v) -> v
        _ -> nil
      end

    %{
      "protocolVersion" => Version.negotiate(requested),
      "serverInfo" => %{
        "name" => "ptc_runner_mcp",
        "version" => Version.package_version()
      },
      "capabilities" => %{
        "tools" => %{"listChanged" => false}
      }
    }
  end

  @doc "Handle `notifications/initialized`. No reply; debug-level log only."
  @spec on_initialized() :: :ok
  def on_initialized do
    Log.log(:debug, "notifications_initialized")
    :ok
  end

  @doc """
  Handle `notifications/cancelled`.

  Phase 1 has no in-flight calls to cancel, so this records a debug
  log and returns. Phase 4 wires real cancellation.
  """
  @spec on_cancelled(map()) :: :ok
  def on_cancelled(params) do
    request_id =
      case params do
        %{"requestId" => id} -> id
        _ -> nil
      end

    Log.log(:debug, "notifications_cancelled", %{request_id: request_id})
    :ok
  end
end
