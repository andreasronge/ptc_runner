defmodule PtcRunnerMcp.Http.SessionRoleCredentialTest do
  @moduledoc """
  `Http.Session` denies `tools/call` for role-blind tools (`lisp_eval` /
  `lisp_task`) when the HTTP owner carries trusted `AuthClaims` (i.e. a
  bearer token bound to a role via `--http-role-tokens`). Role grants are
  only enforced for `lisp_session_*` tools (`Sessions.prepare_start_opts/1`),
  so without this guard a role-token holder invoking either tool would run
  under full process-level authority instead of its bound role.
  """

  use ExUnit.Case, async: false

  alias PtcRunnerMcp.ConcurrencyGate
  alias PtcRunnerMcp.Http.AuthClaims
  alias PtcRunnerMcp.Http.Session
  alias PtcRunnerMcp.Version

  setup do
    ConcurrencyGate.init()
    ConcurrencyGate.reset()
    on_exit(fn -> ConcurrencyGate.reset() end)
    :ok
  end

  for tool_name <- ["lisp_task", "lisp_eval"] do
    test "denies #{tool_name} for a role-bound HTTP credential" do
      {:ok, session} = start_session(role_owner())

      reply = Session.request(session, tool_call_frame(unquote(tool_name), "deny-1"), [], 5_000)

      assert {:reply, %{"id" => "deny-1", "result" => result}} = reply
      assert result["isError"] == true
      assert result["structuredContent"]["reason"] == "role_credential_denied"
      assert result["structuredContent"]["message"] =~ unquote(tool_name)
    end
  end

  test "does not deny lisp_task for a plain bearer-token owner (no auth_claims)" do
    {:ok, session} = start_session(plain_owner())

    reply = Session.request(session, tool_call_frame("lisp_task", "plain-1"), [], 5_000)

    assert {:reply, %{"id" => "plain-1", "result" => result}} = reply
    # Falls through to the normal routing path: agentic isn't configured in
    # this test, so it's rejected as unknown_tool — a different reason than
    # the credential-scoped denial, proving the new guard didn't fire here.
    assert result["structuredContent"]["reason"] == "unknown_tool"
  end

  defp start_session(owner) do
    session =
      start_supervised!(
        {Session,
         [
           id: "sess_#{System.unique_integer([:positive])}",
           owner: owner,
           owner_hash: owner.hash,
           protocol_version: Version.primary(),
           max_in_flight: 4
         ]}
      )

    {:ok, session}
  end

  defp role_owner do
    claims = AuthClaims.new("analyst-subject", "subjecthash1234", ["analyst"])
    %{id: "role-owner", hash: claims.subject_hash, auth_claims: claims}
  end

  defp plain_owner do
    %{id: "plain-owner", hash: "plainhash1234", auth_claims: nil}
  end

  defp tool_call_frame(name, id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => %{}}
    }
  end
end
