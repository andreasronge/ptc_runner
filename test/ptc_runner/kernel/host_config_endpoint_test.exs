defmodule PtcRunner.Kernel.HostConfigEndpointTest do
  use ExUnit.Case, async: true

  # Regression coverage for #1422. Every one of these documents used to load,
  # pass `validate` and passive `doctor`, and only fail later as an
  # occurrence-attributed `provider_unavailable` — the same code an unreachable
  # server produces. They are static facts about the document, so they are
  # settled before anything is contacted.

  alias PtcRunner.Kernel.CommandAcquisition
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.MCPSource

  describe "endpoints refused at load time" do
    @tag :tmp_dir
    test "a string that is not a URL never reaches a connectivity check", %{tmp_dir: dir} do
      assert_refused(dir, "not-a-url")
    end

    @tag :tmp_dir
    test "plain http is refused without the allowance", %{tmp_dir: dir} do
      assert_refused(dir, "http://127.0.0.1:8055")
    end

    @tag :tmp_dir
    test "a name that merely resolves to loopback is not a loopback address", %{tmp_dir: dir} do
      assert_refused(dir, "http://localhost:8055", %{"allow_insecure_loopback" => true})
    end

    @tag :tmp_dir
    test "a routable address is refused even with the allowance", %{tmp_dir: dir} do
      assert_refused(dir, "http://10.0.0.7:8055", %{"allow_insecure_loopback" => true})
    end

    @tag :tmp_dir
    test "the allowance against an https endpoint is stale, not redundant", %{tmp_dir: dir} do
      assert_refused(dir, "https://mcp.example.test/mcp", %{"allow_insecure_loopback" => true})
    end

    @tag :tmp_dir
    test "control characters are refused before they reach the request target", %{tmp_dir: dir} do
      # `URI.parse/1` puts what it cannot place into the path, so a CRLF passes
      # every scheme, host, userinfo, and fragment check. Mint then refuses the
      # request target, which turned a static configuration fault into a
      # transport failure — the exact confusion #1422 is about.
      assert_refused(dir, "https://mcp.example.test/x\r\nX-Injected: 1")
      assert_refused(dir, "https://mcp.example.test/x y")
      assert_refused(dir, "http://127.0.0.1:8055\n", %{"allow_insecure_loopback" => true})

      assert_refused(
        dir,
        "http://127.0.0.1:8055/x\r\nX-Injected: 1",
        %{"allow_insecure_loopback" => true}
      )
    end

    @tag :tmp_dir
    test "a port that does not round-trip is refused rather than silently defaulted",
         %{tmp_dir: dir} do
      # `URI.parse/1` answers with the scheme default when it cannot read the
      # written port, so these used to connect to 443 and 80 respectively while
      # the operator believed otherwise.
      assert_refused(dir, "https://mcp.example.test:bad/mcp")
      assert_refused(dir, "https://mcp.example.test:99999/mcp")
      assert_refused(dir, "http://[::1]:bad", %{"allow_insecure_loopback" => true})
      assert_refused(dir, "http://127.0.0.1:0", %{"allow_insecure_loopback" => true})
    end

    @tag :tmp_dir
    test "userinfo and fragments are refused on both schemes", %{tmp_dir: dir} do
      assert_refused(dir, "https://user:pw@mcp.example.test/mcp")
      assert_refused(dir, "https://mcp.example.test/mcp#frag")

      assert_refused(dir, "http://user@127.0.0.1:8055", %{"allow_insecure_loopback" => true})
      assert_refused(dir, "http://127.0.0.1:8055#frag", %{"allow_insecure_loopback" => true})
    end
  end

  describe "the allowance is credential-free" do
    @tag :tmp_dir
    test "a static auth binding may not cross a plaintext socket", %{tmp_dir: dir} do
      assert_refused(
        dir,
        "http://127.0.0.1:8055",
        %{
          "allow_insecure_loopback" => true,
          "auth" => [%{"scheme" => "bearer", "binding" => "server_token"}]
        }
      )
    end

    @tag :tmp_dir
    test "an OAuth authority may not cross a plaintext socket", %{tmp_dir: dir} do
      assert_refused(
        dir,
        "http://127.0.0.1:8055",
        %{"allow_insecure_loopback" => true, "oauth" => oauth_block()}
      )
    end

    @tag :tmp_dir
    test "an explicitly empty auth list is not a credential", %{tmp_dir: dir} do
      assert {:ok, host} =
               dir
               |> write(
                 config("http://127.0.0.1:8055", %{
                   "allow_insecure_loopback" => true,
                   "auth" => []
                 })
               )
               |> HostConfig.load()

      assert host.install["workspace"].transport.allow_insecure_loopback
      assert host.install["workspace"].transport.auth == []
    end
  end

  describe "endpoints admitted at load time" do
    @tag :tmp_dir
    test "https carries no allowance", %{tmp_dir: dir} do
      assert {:ok, host} =
               dir |> write(config("https://mcp.example.test/mcp")) |> HostConfig.load()

      refute host.install["workspace"].transport.allow_insecure_loopback
    end

    @tag :tmp_dir
    test "the literal loopback addresses are reachable with the allowance", %{tmp_dir: dir} do
      for endpoint <- ["http://127.0.0.1:8055", "http://[::1]:8055/mcp", "http://127.0.0.1"] do
        assert {:ok, host} =
                 dir
                 |> write(
                   config(endpoint, %{"allow_insecure_loopback" => true}),
                   unique_name()
                 )
                 |> HostConfig.load()

        assert host.install["workspace"].transport.endpoint == endpoint
        assert host.install["workspace"].transport.allow_insecure_loopback
      end
    end
  end

  describe "the schema mirrors the decoder" do
    test "the schema never rejects an endpoint the decoder accepts" do
      # The mirror is one-directional. Schema-stricter is a correctness bug: a
      # valid document would fail as a generic schema fault at `/install`
      # instead of the endpoint diagnostic. Schema-lenient is harmless, because
      # decoding is authoritative and refuses it anyway.
      {:ok, root} = JSV.build(HostConfig.schema(), atoms: false, warnings: :silent)

      endpoints =
        [
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
          for cp <- [
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

      # The credential axis matters as much as the endpoint one, because the
      # loopback allowance is defined in terms of it. These are the well-formed
      # shapes; a malformed credential block is its own schema fault and is
      # covered separately below.
      credentials = [
        %{},
        %{"auth" => []},
        %{"auth" => [%{"scheme" => "bearer", "binding" => "server_token"}]},
        %{"oauth" => oauth_block()}
      ]

      # Stated in observable terms: in this corpus the only thing that can make
      # the schema reject is the endpoint or its credential shape, so every
      # rejection must arrive as the endpoint diagnostic. A document the schema
      # refuses but the endpoint rule admits falls through to the generic
      # `/install` schema fault instead, which is exactly the drift to catch.
      divergent =
        for endpoint <- endpoints,
            loopback <- [false, true],
            credential <- credentials,
            overrides = mirror_overrides(loopback, credential),
            document = config(endpoint, overrides),
            not match?({:ok, _validated}, JSV.validate(document, root, cast: false)),
            not endpoint_diagnostic?(document),
            do: {endpoint, overrides}

      assert divergent == []
    end

    @tag :tmp_dir
    test "an explicit null oauth key is refused by decoder and schema alike", %{tmp_dir: dir} do
      # JSON Schema counts a present key regardless of its value, so reading
      # `"oauth": null` as "absent" would have let decoding admit a transport
      # the schema refuses.
      {:ok, root} = JSV.build(HostConfig.schema(), atoms: false, warnings: :silent)

      for overrides <- [
            %{"oauth" => nil},
            %{"allow_insecure_loopback" => true, "oauth" => nil}
          ] do
        endpoint =
          if overrides["allow_insecure_loopback"],
            do: "http://127.0.0.1:8055",
            else: "https://mcp.example.test/mcp"

        document = config(endpoint, overrides)

        assert {:error, :invalid_host_config} =
                 dir |> write(document, unique_name()) |> HostConfig.load()

        assert {:error, _details} = JSV.validate(document, root, cast: false)
      end
    end
  end

  describe "the command path names the installation" do
    @tag :tmp_dir
    test "endpoint diagnostics identify the rejected admissibility clause", %{tmp_dir: dir} do
      cases = [
        {"http://127.0.0.1:8055", %{}, :installation_endpoint_insecure_loopback_required,
         "a plain-http MCP endpoint requires allow_insecure_loopback"},
        {"http://localhost:8055", %{"allow_insecure_loopback" => true},
         :installation_endpoint_literal_loopback_required,
         "allow_insecure_loopback requires a literal 127.0.0.1 or [::1] address"},
        {"https://mcp.example.test/mcp", %{"allow_insecure_loopback" => true},
         :installation_endpoint_insecure_loopback_forbidden,
         "allow_insecure_loopback is not permitted on an https endpoint; remove it"},
        {"http://127.0.0.1:8055", %{"allow_insecure_loopback" => true, "oauth" => oauth_block()},
         :installation_endpoint_credentials_require_https,
         "configured MCP credentials require an https endpoint"}
      ]

      for {endpoint, overrides, expected_code, expected_message} <- cases do
        path = write(dir, config(endpoint, overrides), unique_name())

        assert {:error, %CommandDiagnostic{} = diagnostic} = CommandAcquisition.catalog(path)
        assert diagnostic.phase == :host
        assert diagnostic.code == expected_code
        assert diagnostic.message == expected_message
        assert diagnostic.subject.name == "workspace"
        assert diagnostic.path == nil
        assert diagnostic.source == nil
      end
    end

    @tag :tmp_dir
    test "a refused endpoint is a host diagnostic naming its alias", %{tmp_dir: dir} do
      path = write(dir, config("not-a-url"))

      assert {:error, %CommandDiagnostic{} = diagnostic} = CommandAcquisition.catalog(path)
      assert diagnostic.phase == :host
      assert diagnostic.code == :installation_endpoint_invalid
      assert diagnostic.subject.name == "workspace"
      assert diagnostic.subject.operation == :declaration
      assert diagnostic.path == nil
    end

    @tag :tmp_dir
    test "the endpoint diagnostic is reserved for MCP installations", %{tmp_dir: dir} do
      # A non-MCP installation carrying a stray streamable_http-shaped transport
      # is a plain schema fault, not an endpoint one.
      llm = %{
        "install" => %{
          "brain" => %{
            "source" => "llm",
            "installation_revision" => "brain-v1",
            "model" => "openrouter:some/model",
            "credential" => "api_key",
            "transport" => %{"type" => "streamable_http", "endpoint" => "not-a-url"}
          }
        },
        "credentials" => %{"api_key" => %{"env" => "API_KEY"}}
      }

      path = write(dir, llm)

      assert {:error, %CommandDiagnostic{} = diagnostic} = CommandAcquisition.catalog(path)
      assert diagnostic.code == :host_schema_invalid
    end

    @tag :tmp_dir
    test "an admitted loopback endpoint builds a catalog", %{tmp_dir: dir} do
      path = write(dir, config("http://127.0.0.1:8055", %{"allow_insecure_loopback" => true}))

      assert {:ok, _host, _catalog} = CommandAcquisition.catalog(path)
    end
  end

  describe "the in-process API applies the same rule" do
    test "localhost is not admitted as a loopback address" do
      assert_raise ArgumentError, fn ->
        MCPSource.builder(
          transport:
            {:streamable_http, endpoint: "http://localhost:8055", allow_insecure_loopback: true},
          tools: mappings()
        )
      end
    end

    test "the allowance against an https endpoint is refused" do
      assert_raise ArgumentError, fn ->
        MCPSource.builder(
          transport:
            {:streamable_http,
             endpoint: "https://mcp.example.test/mcp", allow_insecure_loopback: true},
          tools: mappings()
        )
      end
    end

    test "the literal loopback addresses remain admitted" do
      for endpoint <- ["http://127.0.0.1:8055", "http://[::1]:8055/mcp"] do
        assert {:staged, builder, nil} =
                 MCPSource.builder(
                   transport:
                     {:streamable_http, endpoint: endpoint, allow_insecure_loopback: true},
                   tools: mappings()
                 )

        assert is_function(builder, 2)
      end
    end
  end

  defp assert_refused(dir, endpoint, overrides \\ %{}) do
    path = write(dir, config(endpoint, overrides), unique_name())

    assert {:error, :invalid_host_config} = HostConfig.load(path)

    assert {:error, {:installation_endpoint_invalid, "workspace", _reason}} =
             HostConfig.load_command(path)
  end

  defp config(endpoint, overrides \\ %{}) do
    transport =
      %{"type" => "streamable_http", "endpoint" => endpoint} |> Map.merge(overrides)

    %{
      "credentials" => %{"server_token" => %{"env" => "SERVER_TOKEN"}},
      "install" => %{
        "workspace" => %{
          "source" => "mcp",
          "installation_revision" => "workspace-v1",
          "transport" => transport,
          "tools" => %{"echo" => %{"as" => "workspace.echo", "effect" => "read"}}
        }
      }
    }
  end

  defp oauth_block do
    %{
      "installation_id" => "workspace",
      "issuer" => "https://issuer.example.test",
      "scope_ceiling" => ["read"],
      "client" => %{
        "registration" => "pre_registered",
        "client_id" => "client",
        "token_endpoint_auth_method" => "none",
        "grant_types" => ["authorization_code"],
        "loopback_redirect" => %{"host" => "127.0.0.1", "path" => "/callback"}
      }
    }
  end

  defp mirror_overrides(loopback, credential) do
    if loopback,
      do: Map.put(credential, "allow_insecure_loopback", true),
      else: credential
  end

  defp endpoint_diagnostic?(document) do
    dir = Path.join(System.tmp_dir!(), "ptc-mirror-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      path = write(dir, document, "host.json")

      match?(
        {:error, {:installation_endpoint_invalid, _name, _reason}},
        HostConfig.load_command(path)
      )
    after
      File.rm_rf!(dir)
    end
  end

  defp mappings, do: %{"echo" => %{as: "workspace.echo", effect: :read}}

  defp write(dir, config, name \\ "host.json") do
    path = Path.join(dir, name)
    File.write!(path, Jason.encode!(config))
    path
  end

  defp unique_name,
    do: "host-#{System.unique_integer([:positive, :monotonic])}.json"
end
