defmodule PtcRunner.Kernel.HostConfigEndpointMatrixTest do
  @endpoints [
               "https://mcp.example.com/v1",
               "https://mcp.example.com:8443/v1",
               "https://mcp.example.com",
               "https://a.b.example.com/p?x=1",
               "https://EXAMPLE.test/x",
               "HTTPS://a.test/x",
               "https://a.test:bad/x",
               "https://a.test::443/x",
               "https://a.test:bad:443/x",
               "https://[2001:db8::1]garbage:443/x",
               "https://[2001:db8::1]:443/x",
               "https://a.test:99999",
               "https://a.test:0",
               "https://user@a.test/x",
               "https://a.test/x#f",
               "not-a-url",
               "",
               "ftp://a.test",
               "//a.test",
               "https://a.test/x\r\nX: 1",
               "http://127.0.0.1:8055",
               "http://127.0.0.1",
               "http://[::1]:8055/mcp",
               "http://[::1]",
               "HTTP://127.0.0.1",
               "http://localhost:8055",
               "http://10.0.0.7:8055",
               "http://[::1]:bad",
               "http://127.0.0.1:0",
               "http://127.0.0.1:65535",
               "http://127.0.0.1:8055\n",
               "http://127.0.0.1@evil.test/",
               "http://0177.0.0.1:8055"
             ] ++
               for(
                 cp <- [
                   0x09,
                   0x0A,
                   0x0D,
                   0x20,
                   0x7F,
                   0x85,
                   0xA0,
                   0x1680,
                   0x2000,
                   0x200A,
                   0x2028,
                   0x2029,
                   0x202F,
                   0x205F,
                   0x3000,
                   0x200B,
                   0xFEFF,
                   0x61
                 ],
                 do: "https://a.test/x" <> <<cp::utf8>> <> "y"
               )

  use ExUnit.Case,
    async: true,
    parameterize:
      for(
        endpoint <- @endpoints,
        loopback <- if(String.starts_with?(endpoint, "http://"), do: [false, true], else: [false]),
        credential <-
          if(String.starts_with?(endpoint, "http://"),
            do: [:none, :empty_auth, :static_auth, :oauth],
            else: [:none]
          ),
        do: %{endpoint: endpoint, loopback: loopback, credential: credential}
      )

  import PtcRunner.TestSupport.HostConfigEndpointHelpers

  alias PtcRunner.Kernel.HostConfig

  @moduletag :tmp_dir

  setup_all do
    {:ok, root} = JSV.build(HostConfig.schema(), atoms: false, warnings: :silent)
    {:ok, mirror_schema: root}
  end

  test "the schema never rejects an endpoint the decoder accepts", %{
    tmp_dir: dir,
    mirror_schema: root,
    endpoint: endpoint,
    loopback: loopback,
    credential: credential
  } do
    credential =
      case credential do
        :none -> %{}
        :empty_auth -> %{"auth" => []}
        :static_auth -> %{"auth" => [%{"scheme" => "bearer", "binding" => "server_token"}]}
        :oauth -> %{"oauth" => oauth_block()}
      end

    document = config(endpoint, mirror_overrides(loopback, credential))

    if not match?({:ok, _validated}, JSV.validate(document, root, cast: false)) do
      assert endpoint_diagnostic?(dir, document)
    end
  end
end
