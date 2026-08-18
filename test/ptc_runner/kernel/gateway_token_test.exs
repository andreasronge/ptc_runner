defmodule PtcRunner.Kernel.GatewayTokenTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.GatewayToken

  @tag :tmp_dir
  test "loads a 0o600 file and strips one trailing newline", %{tmp_dir: tmp} do
    path = Path.join(tmp, "gateway.token")
    write_secret!(path, "gateway-token-fixture\n")
    assert {:ok, "gateway-token-fixture"} = GatewayToken.load(path)
  end

  @tag :tmp_dir
  test "loads an owner-readable 0o400 file", %{tmp_dir: tmp} do
    path = Path.join(tmp, "gateway.token")
    write_secret!(path, "gateway-token-fixture")
    File.chmod!(path, 0o400)
    assert {:ok, "gateway-token-fixture"} = GatewayToken.load(path)
  end

  @tag :tmp_dir
  test "refuses a chmod to group-readable during the open read", %{tmp_dir: tmp} do
    path = Path.join(tmp, "gateway.token")
    write_secret!(path, "gateway-token-fixture")
    File.chmod!(path, 0o400)

    assert {:error, :invalid_gateway_token} =
             GatewayToken.load(path, after_open: fn -> File.chmod!(path, 0o440) end)
  end

  @tag :tmp_dir
  test "refuses empty, oversized, group-readable, and group-writable ancestors", %{tmp_dir: tmp} do
    empty = Path.join(tmp, "empty.token")
    write_secret!(empty, "")
    assert {:error, :invalid_gateway_token} = GatewayToken.load(empty)

    missing = Path.join(tmp, "missing.token")
    assert {:error, :invalid_gateway_token} = GatewayToken.load(missing)

    readable = Path.join(tmp, "readable.token")
    write_secret!(readable, "gateway-token-fixture")
    File.chmod!(readable, 0o640)
    assert {:error, :invalid_gateway_token} = GatewayToken.load(readable)

    oversized = Path.join(tmp, "oversized.token")
    write_secret!(oversized, :binary.copy("a", 1_025))
    assert {:error, :invalid_gateway_token} = GatewayToken.load(oversized)

    unsafe = Path.join(tmp, "unsafe")
    File.mkdir_p!(unsafe)
    File.chmod!(unsafe, 0o777)
    nested = Path.join(unsafe, "gateway.token")
    write_secret!(nested, "gateway-token-fixture")
    assert {:error, :invalid_gateway_token} = GatewayToken.load(nested)
  end

  @tag :tmp_dir
  test "resolves a trusted symlink and re-validates the target", %{tmp_dir: tmp} do
    target = Path.join(tmp, "gateway.token")
    write_secret!(target, "gateway-token-fixture")
    link = Path.join(tmp, "gateway.token.link")
    File.ln_s!(target, link)
    assert {:ok, "gateway-token-fixture"} = GatewayToken.load(link)
  end

  defp write_secret!(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o600)
  end
end
