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

  @boot_id_key {__MODULE__, :boot_id}

  @doc """
  Return the server boot id for this BEAM application run.

  The id is generated lazily so lifecycle fields are usable from tests and
  helper processes that do not run `PtcRunnerMcp.Application.start/2`.
  """
  @spec boot_id() :: String.t()
  def boot_id do
    case :persistent_term.get(@boot_id_key, nil) do
      id when is_binary(id) ->
        id

      nil ->
        id = generate_boot_id()
        :persistent_term.put(@boot_id_key, id)
        id
    end
  end

  @doc false
  @spec reset_boot_id!() :: :ok
  def reset_boot_id! do
    :persistent_term.erase(@boot_id_key)
    :ok
  end

  @doc """
  Add process-level lifecycle correlation fields to an event payload.
  """
  @spec lifecycle_fields(map()) :: map()
  def lifecycle_fields(extra \\ %{}) when is_map(extra) do
    %{
      boot_id: boot_id(),
      os_pid: System.pid()
    }
    |> Map.merge(extra)
  end

  @doc """
  Build the `initialize` reply per § 7.1.

  The reply mirrors the negotiated `protocolVersion`, advertises
  `tools.listChanged: false`, and intentionally omits `resources`,
  `prompts`, `experimental`, `elicitation`, and `sampling`.
  """
  @spec initialize_reply(map() | nil, String.t()) :: map()
  def initialize_reply(_params, protocol_version) when is_binary(protocol_version) do
    %{
      "protocolVersion" => protocol_version,
      "serverInfo" => %{
        "name" => "ptc_lisp",
        "version" => Version.display_version(),
        "build" => Version.build_info()
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

  defp generate_boot_id do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic)
    suffix = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    "#{timestamp}-#{suffix}"
  end
end
