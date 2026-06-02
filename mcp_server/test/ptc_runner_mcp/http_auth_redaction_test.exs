defmodule PtcRunnerMcp.HttpAuthRedactionTest do
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Credentials
  alias PtcRunnerMcp.Credentials.Redactor
  alias PtcRunnerMcp.Http.SessionRegistry

  @token "test-bearer-token-" <> String.duplicate("x", 32)

  setup do
    start_supervised!({Credentials, [bindings: %{}]})
    :ok
  end

  defp unique_registry_name do
    :"registry_#{:erlang.unique_integer([:positive])}"
  end

  defp minimal_http_config(token) do
    %{
      auth_token: token,
      session_ttl_ms: 3_600_000,
      session_idle_timeout_ms: 900_000,
      max_sessions: 256,
      max_sessions_per_owner: 32,
      max_in_flight_per_session: 4,
      instance_label: "test"
    }
  end

  test "HTTP bearer token is redacted after session registry starts" do
    start_supervised!(
      {SessionRegistry, [name: unique_registry_name(), config: minimal_http_config(@token)]}
    )

    assert Redactor.scrub("Authorization: Bearer #{@token}") ==
             "Authorization: Bearer [REDACTED]"
  end

  test "redaction handles nil auth_token (auth disabled)" do
    start_supervised!(
      {SessionRegistry, [name: unique_registry_name(), config: minimal_http_config(nil)]}
    )

    assert Redactor.scrub("no token here") == "no token here"
  end
end
