defmodule PtcRunnerMcp.Http.HostTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias PtcRunnerMcp.Http.Host

  # cfg with a loopback bind — triggers host_without_port/1 parsing
  @loopback_cfg %{host: "127.0.0.1"}
  # cfg with a non-loopback bind — Host check is skipped entirely
  @nonloopback_cfg %{host: "0.0.0.0"}

  defp conn_with_host(host), do: %{conn(:get, "/") | host: host}

  describe "host_without_port/1 via allowed?/2 (loopback bind)" do
    test "IPv6 with port [::1]:7332 strips port and recognises loopback" do
      assert Host.allowed?(conn_with_host("[::1]:7332"), @loopback_cfg)
    end

    test "IPv4 with port 127.0.0.1:7332 strips port and recognises loopback" do
      assert Host.allowed?(conn_with_host("127.0.0.1:7332"), @loopback_cfg)
    end

    test "bare hostname localhost is recognised as loopback" do
      assert Host.allowed?(conn_with_host("localhost"), @loopback_cfg)
    end

    test "bare IP 127.0.0.1 is recognised as loopback" do
      assert Host.allowed?(conn_with_host("127.0.0.1"), @loopback_cfg)
    end

    test "non-loopback host is rejected" do
      refute Host.allowed?(conn_with_host("attacker.example"), @loopback_cfg)
    end
  end

  describe "allowed?/2 with non-loopback bind" do
    test "any host is allowed when the server is not loopback-bound" do
      assert Host.allowed?(conn_with_host("attacker.example"), @nonloopback_cfg)
    end
  end
end
