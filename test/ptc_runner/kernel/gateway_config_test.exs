defmodule PtcRunner.Kernel.GatewayConfigTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.GatewayConfig

  @invalid_hosts [
    "http://example.com",
    "example.com:80",
    "example.com/x",
    "exam ple",
    "example.com\t",
    "example.com\n",
    "foo@bar",
    "foo?bar",
    "foo#bar",
    "foo\\bar"
  ]

  @tag :tmp_dir
  test "wildcard listen requires a host-only name", %{tmp_dir: tmp} do
    path = Path.join(tmp, "gateway.json")

    write_config!(path, tmp, %{"listen" => "0.0.0.0", "token_file" => "t", "port" => 0})
    assert {:error, :invalid_gateway_config} = GatewayConfig.load(path)

    Enum.each(@invalid_hosts, fn host ->
      write_config!(path, tmp, %{
        "listen" => "0.0.0.0",
        "host" => host,
        "token_file" => "t",
        "port" => 0
      })

      assert {:error, :invalid_gateway_config} = GatewayConfig.load(path)
    end)

    write_config!(path, tmp, %{
      "listen" => "0.0.0.0",
      "host" => "example.com",
      "token_file" => "t",
      "port" => 0
    })

    assert {:ok, config} = GatewayConfig.load(path)
    assert config.http.host == "example.com"
    assert config.http.listen == {0, 0, 0, 0}
  end

  defp write_config!(path, directory, http) do
    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "tools" => %{
          "echo" => %{
            "description" => "echo",
            "source" => %{"directory" => directory},
            "digests" => %{
              "application_content_digest" => String.duplicate("a", 64),
              "effective_application_digest" => "sha256:" <> String.duplicate("a", 64)
            }
          }
        },
        "http" => http
      })
    )
  end
end
