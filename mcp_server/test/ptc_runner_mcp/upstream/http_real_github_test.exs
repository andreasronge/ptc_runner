defmodule PtcRunnerMcp.Upstream.HttpRealGithubTest do
  @moduledoc """
  Phase 4 (`Plans/http-transport-credentials.md` §12 Phase 4 / §13.4)
  opt-in integration test against the real GitHub MCP server.

  Gated on `MCP_REAL_REMOTE=1` AND `GITHUB_PAT` env var. Excluded from
  the default `mix test` run via the `:real_remote_upstream` ExUnit
  tag.

  ## Running

      MCP_REAL_REMOTE=1 GITHUB_PAT="ghp_…" \\
        mix test --only real_remote_upstream

  ## What this test asserts

  Drives `Upstream.Http` directly against
  `https://api.githubcopilot.com/mcp/` with a bearer auth emitter
  resolved from the `GITHUB_PAT` env binding. Verified facts (per
  https://github.com/github/github-mcp-server/blob/main/docs/remote-server.md
  fetched 2026-05-10):

    * URL: `https://api.githubcopilot.com/mcp/` (default toolset list)
    * Auth: `Authorization: Bearer <PAT>` — header set verbatim
    * Read-only: `X-MCP-Readonly: true` static header pins the
      surface to read-only tools so this test can never mutate
      account state even with a write-scope PAT
    * Server auto-filters tools by token scope via `X-OAuth-Scopes`
      discovery at boot (classic PATs only). Fine-grained PATs skip
      filtering; GitHub enforces at the API level.

  Test PAT scope: classic PAT with `read:user` is sufficient for
  `get_me`. Other read-only tools may require additional scopes
  (`read:org`, `repo` for public repo metadata, etc.). The PAT
  documented in the test setup MUST be read-only by design.

  ## Drift handling

  GitHub's MCP server has historically rev'd headers, scope
  expectations, and toolset names. If this test starts failing,
  refresh the verified facts above against the current docs before
  changing the assertions.

  Phase 4 explicitly accepts this drift cost: the spec §12 Phase 4
  exit gate is "live-endpoint validation" — drift is the price of
  validating against a moving target.
  """
  use ExUnit.Case, async: false

  @moduletag :real_remote_upstream

  alias PtcRunnerMcp.Credentials
  alias PtcRunnerMcp.Credentials.Binding
  alias PtcRunnerMcp.Upstream.Http

  @github_mcp_url "https://api.githubcopilot.com/mcp/"

  setup do
    pat = System.get_env("GITHUB_PAT")

    if pat in [nil, ""] do
      flunk("GITHUB_PAT env var is required for this test")
    end

    creds_name = :"creds_#{System.unique_integer([:positive])}"

    bindings = %{
      "github-pat" => %Binding{
        name: "github-pat",
        source: :literal,
        scheme_hint: :bearer,
        spec: %{value: pat}
      }
    }

    {:ok, creds_pid} =
      start_supervised({Credentials, [name: creds_name, bindings: bindings]})

    upstream_name = "github-#{System.unique_integer([:positive])}"

    config = %{
      url: @github_mcp_url,
      static_headers: [{"x-mcp-readonly", "true"}],
      auth: [
        %{scheme: :bearer, binding: "github-pat", header: nil}
      ],
      proxy: nil,
      handshake_timeout_ms: 15_000,
      request_timeout_ms: 30_000,
      connect_timeout_ms: 10_000,
      max_response_bytes: 2_097_152,
      pool_size: 2,
      backoff_initial_ms: 100,
      backoff_max_ms: 30_000,
      credentials: creds_name
    }

    on_exit(fn -> safe_stop(upstream_name) end)

    %{upstream_name: upstream_name, config: config, creds_pid: creds_pid}
  end

  describe "real GitHub MCP — happy path" do
    test "handshake completes and tools/list returns a non-empty toolset",
         %{upstream_name: name, config: config} do
      assert {:ok, _pid} = Http.start_link(name, config)
      assert {:ok, tools} = Http.list_tools(name)

      assert is_list(tools)
      assert tools != [], "expected non-empty toolset; got: #{inspect(tools)}"

      # `get_me` is one of the canonical context tools; if it's
      # missing, either the read-only mode filtered it out (it
      # shouldn't — get_me is read-only by definition) or the PAT
      # lacks a user-context scope.
      tool_names = Enum.map(tools, & &1["name"])

      assert "get_me" in tool_names,
             "expected `get_me` in toolset; got: #{inspect(tool_names)}. " <>
               "Verify PAT has read:user scope (classic) or User profile " <>
               "permission (fine-grained)."
    end

    test "tools/call get_me returns the authenticated user's profile",
         %{upstream_name: name, config: config} do
      {:ok, _pid} = Http.start_link(name, config)

      assert {:ok, result} = Http.call(name, "get_me", %{}, timeout: 30_000)

      # GitHub's `get_me` returns either the user object directly
      # or wraps it in a `content` array (MCP envelope). Either is
      # acceptable; what we're proving is that auth flowed end-to-end
      # and the upstream returned data.
      assert is_map(result), "expected map response, got: #{inspect(result)}"
    end
  end

  describe "real GitHub MCP — failure-mode probe (4D)" do
    @tag :real_remote_upstream
    test "401 with invalid PAT → :auth_failed exit reason", %{config: config} do
      bad_config =
        Map.update!(config, :credentials, fn _ ->
          :"bad_creds_#{System.unique_integer([:positive])}"
        end)

      bad_bindings = %{
        "github-pat" => %Binding{
          name: "github-pat",
          source: :literal,
          scheme_hint: :bearer,
          spec: %{value: "ghp_invalidtokenshouldreturn401aaaaaa"}
        }
      }

      {:ok, _} =
        start_supervised(
          {Credentials, [name: bad_config.credentials, bindings: bad_bindings]},
          id: :bad_creds
        )

      bad_name = "bad-github-#{System.unique_integer([:positive])}"

      # start_link/2 wraps init/1 failures and returns
      # `{:error, {:upstream_unavailable, detail}}`. With a 401 on
      # initialize the detail must mention auth_failed.
      result = Http.start_link(bad_name, bad_config)

      assert {:error, {:upstream_unavailable, detail}} = result
      assert detail =~ "auth_failed", "expected auth_failed mention; got: #{detail}"
    end
  end

  defp safe_stop(name) do
    case Http.stop(name) do
      :ok -> :ok
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end
end
