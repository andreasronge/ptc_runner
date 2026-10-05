defmodule PtcGateway.StartupError do
  @moduledoc """
  Closed startup errors. CLI failures emit one JSON line on stderr, no stdout,
  and exit 78. Only a catalog code is exposed; paths, names and private causes
  are never included. Validation order is configuration, host, artifact root,
  tools in name order, audit, admission, warm capture/pins, then listener binding.
  """
  @codes ~w(config_unavailable duplicate_json_key config_invalid origin_invalid tool_name_duplicate
    audit_invalid host_invalid template_invalid catalog_too_large application_content_digest_mismatch write_forbidden
    audit_unavailable artifact_root_unavailable run_admission_unavailable credential_unavailable installation_pin_mismatch
    provider_pin_mismatch provider_pin_unavailable provider_admission_unavailable
    provider_runtime_unavailable provider_source_unsupported listener_unavailable internal_error)a

  @spec codes() :: [atom()]
  def codes, do: @codes
  @spec normalize(term()) :: atom()
  def normalize(:provider_runtime_unsupported), do: :provider_source_unsupported
  def normalize(code) when code in @codes, do: code
  def normalize(_), do: :internal_error
  @doc false
  def reason_class(reason) when reason in @codes, do: reason

  def reason_class(reason)
      when reason in [
             :provider_runtime_unsupported,
             :invalid_provider_runtime,
             :provider_cleanup_failed,
             :invalid_provider_runtime_services,
             :invalid_warm_provider_runtime,
             :provider_unavailable,
             :provider_acquisition_timeout,
             :provider_protocol_error,
             :provider_protocol_version_unsupported,
             :provider_tool_missing,
             :provider_policy_changed,
             :mcp_protocol_error,
             :mcp_transport_error,
             :mcp_timeout,
             :mcp_authentication_failed,
             :mcp_stdio_launcher_unavailable,
             :unsupported_mcp_stdio_platform
           ],
      do: reason

  def reason_class(_), do: :other
  @spec encode(term()) :: binary()
  def encode(code), do: Jason.encode!(%{error: normalize(code)})
  @spec exit_status() :: 78
  def exit_status, do: 78
end
