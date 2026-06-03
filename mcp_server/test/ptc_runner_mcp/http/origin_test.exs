defmodule PtcRunnerMcp.Http.OriginTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias PtcRunnerMcp.Http.Origin

  # Loopback bind, no allowlist — loopback origins are permitted.
  @loopback_cfg %{host: "127.0.0.1", allowed_origins: []}
  # Non-loopback bind, no allowlist — fail closed for any present Origin.
  @nonloopback_cfg %{host: "0.0.0.0", allowed_origins: []}
  # Explicit allowlist — only listed origins are permitted, on any bind.
  @allowlist_cfg %{host: "0.0.0.0", allowed_origins: ["https://app.example.com"]}

  describe "allowed?/2 header extraction" do
    test "absent Origin header is allowed" do
      assert Origin.allowed?(conn(:get, "/mcp"), @nonloopback_cfg)
    end

    test "present Origin header is delegated to the policy" do
      conn = %{conn(:get, "/mcp") | req_headers: [{"origin", "http://attacker.example"}]}
      refute Origin.allowed?(conn, @loopback_cfg)
    end
  end

  describe "allowed_origin?/2 allowlist branch" do
    test "an explicitly allowed origin succeeds" do
      assert Origin.allowed_origin?("https://app.example.com", @allowlist_cfg)
    end

    test "an origin outside the allowlist is rejected" do
      refute Origin.allowed_origin?("https://attacker.example", @allowlist_cfg)
    end

    test "allowlist match normalises default ports and case" do
      assert Origin.allowed_origin?("HTTPS://App.Example.com:443", @allowlist_cfg)
    end
  end

  describe "allowed_origin?/2 null origin" do
    test "Origin: null is rejected on a loopback bind" do
      refute Origin.allowed_origin?("null", @loopback_cfg)
    end

    test "Origin: null is rejected even with an allowlist" do
      refute Origin.allowed_origin?("null", @allowlist_cfg)
    end
  end

  describe "allowed_origin?/2 fail-closed on non-loopback bind" do
    test "a present origin without an allowlist is rejected" do
      refute Origin.allowed_origin?("https://app.example.com", @nonloopback_cfg)
    end
  end

  describe "allowed_origin?/2 loopback bind without allowlist" do
    test "a loopback origin is permitted" do
      assert Origin.allowed_origin?("http://localhost:3000", @loopback_cfg)
    end

    test "a non-loopback origin is rejected" do
      refute Origin.allowed_origin?("https://attacker.example", @loopback_cfg)
    end
  end
end
