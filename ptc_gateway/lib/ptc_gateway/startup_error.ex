defmodule PtcGateway.StartupError do
  @moduledoc """
  Closed startup errors. CLI failures emit one JSON line on stderr, no stdout,
  and exit 78. Only a catalog code is exposed; paths, names and private causes
  are never included. Validation order is configuration, host, tools in name
  order, audit, admission, warm capture/pins, then listener binding.
  """
  @codes ~w(config_unavailable duplicate_json_key config_invalid origin_invalid tool_name_duplicate
    audit_invalid host_invalid template_invalid catalog_too_large application_content_digest_mismatch write_forbidden
    audit_unavailable run_admission_unavailable credential_unavailable installation_pin_mismatch
    provider_pin_mismatch provider_pin_unavailable provider_admission_unavailable
    provider_runtime_unavailable listener_unavailable internal_error)a

  @spec codes() :: [atom()]
  def codes, do: @codes
  @spec normalize(term()) :: atom()
  def normalize(code) when code in @codes, do: code
  def normalize(_), do: :internal_error
  @spec encode(term()) :: binary()
  def encode(code), do: Jason.encode!(%{error: normalize(code)})
  @spec exit_status() :: 78
  def exit_status, do: 78
end
