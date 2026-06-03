defmodule PtcRunner.Upstream.ConfigTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Upstream.Config

  # Config.load/1 is the v1 trust boundary that turns untrusted upstream JSON
  # into validated transport configs. The error table below exercises the
  # rejection branches that guard header injection, auth/origin downgrade, and
  # type confusion. We use mcp_http/mcp_stdio entries because they validate
  # without touching the network (the openapi branch would call OpenAPI.load,
  # which reads a schema file/url).

  defp load(map), do: Config.load(config: map)

  defp http_upstream(extra) do
    %{
      "upstreams" => %{
        "svc" =>
          Map.merge(%{"transport" => "mcp_http", "url" => "https://svc.example.com"}, extra)
      }
    }
  end

  describe "static_headers rejection table" do
    test "reserved (denylisted) header is rejected" do
      assert {:error, :upstream_unavailable, msg} =
               load(http_upstream(%{"static_headers" => %{"Authorization" => "x"}}))

      assert msg =~ "is reserved"
      assert msg =~ "Authorization"
    end

    test "duplicate header (case-insensitive) is rejected" do
      assert {:error, :upstream_unavailable, msg} =
               load(http_upstream(%{"static_headers" => %{"X-Foo" => "a", "x-foo" => "b"}}))

      assert msg =~ "duplicate header"
    end

    test "non-string header value is rejected" do
      assert {:error, :upstream_unavailable, msg} =
               load(http_upstream(%{"static_headers" => %{"X-Foo" => 123}}))

      assert msg =~ "value must be a string"
    end

    test "invalid header name (token form) is rejected" do
      assert {:error, :upstream_unavailable, msg} =
               load(http_upstream(%{"static_headers" => %{"X Foo" => "a"}}))

      assert msg =~ "header"
      assert msg =~ "is invalid"
    end

    test "static_headers that is not an object is rejected" do
      assert {:error, :upstream_unavailable, msg} =
               load(http_upstream(%{"static_headers" => ["not", "a", "map"]}))

      assert msg =~ "static_headers must be an object"
    end

    test "a normal static header is accepted and lowercased" do
      assert {:ok, %{upstreams: [upstream]}} =
               load(http_upstream(%{"static_headers" => %{"X-Foo" => "bar"}}))

      assert upstream.config.static_headers == [{"x-foo", "bar"}]
    end
  end

  describe "auth / origin downgrade table" do
    defp creds_with_token do
      %{"token" => %{"source" => "literal", "value" => "s3cr3t"}}
    end

    test "auth bound to an unknown credential binding is rejected" do
      map = %{
        "credentials" => %{},
        "upstreams" => %{
          "svc" => %{
            "transport" => "mcp_http",
            "url" => "https://svc.example.com",
            "auth" => [%{"scheme" => "bearer", "binding" => "ghost"}]
          }
        }
      }

      assert {:error, :upstream_unavailable, msg} = load(map)
      assert msg =~ "unknown credential binding ghost"
    end

    test "auth header colliding with a static header is rejected" do
      map = %{
        "credentials" => creds_with_token(),
        "upstreams" => %{
          "svc" => %{
            "transport" => "mcp_http",
            "url" => "https://svc.example.com",
            "auth" => [
              %{"scheme" => "api_key", "binding" => "token", "header" => "X-Key"}
            ],
            "static_headers" => %{"X-Key" => "static"}
          }
        }
      }

      assert {:error, :upstream_unavailable, msg} = load(map)
      assert msg =~ "in both auth and static_headers"
    end

    test "insecure_auth_gate: http url with auth but no allow_insecure_auth is rejected" do
      map = %{
        "credentials" => creds_with_token(),
        "upstreams" => %{
          "svc" => %{
            "transport" => "mcp_http",
            "url" => "http://svc.example.com",
            "allow_insecure_http" => true,
            "auth" => [%{"scheme" => "bearer", "binding" => "token"}]
          }
        }
      }

      assert {:error, :upstream_unavailable, msg} = load(map)
      assert msg =~ "allow_insecure_auth is not true"
    end

    test "auth emitter referencing a reserved header is rejected" do
      map = %{
        "credentials" => creds_with_token(),
        "upstreams" => %{
          "svc" => %{
            "transport" => "mcp_http",
            "url" => "https://svc.example.com",
            "auth" => [
              %{"scheme" => "custom_header", "binding" => "token", "header" => "Cookie"}
            ]
          }
        }
      }

      assert {:error, :upstream_unavailable, msg} = load(map)
      assert msg =~ "is reserved"
    end

    test "http url without allow_insecure_http is rejected" do
      assert {:error, :upstream_unavailable, msg} =
               load(http_upstream(%{"url" => "http://svc.example.com"}))

      assert msg =~ "without allow_insecure_http"
    end

    test "valid bearer auth over https is accepted and bound" do
      map = %{
        "credentials" => creds_with_token(),
        "upstreams" => %{
          "svc" => %{
            "transport" => "mcp_http",
            "url" => "https://svc.example.com",
            "auth" => [%{"scheme" => "bearer", "binding" => "token"}]
          }
        }
      }

      assert {:ok, %{upstreams: [upstream]}} = load(map)
      assert upstream.config.auth == [%{"scheme" => "bearer", "binding" => "token"}]
    end
  end

  describe "transport-level validation" do
    test "old transport names give a migration hint" do
      assert {:error, :upstream_unavailable, msg} =
               load(%{"upstreams" => %{"svc" => %{"transport" => "stdio", "command" => "x"}}})

      assert msg =~ "old transport"
      assert msg =~ "mcp_stdio or mcp_http"
    end

    test "unsupported transport is rejected" do
      assert {:error, :upstream_unavailable, msg} =
               load(%{"upstreams" => %{"svc" => %{"transport" => "carrier-pigeon"}}})

      assert msg =~ "unsupported transport"
    end

    test "missing transport key is rejected" do
      assert {:error, :upstream_unavailable, msg} =
               load(%{"upstreams" => %{"svc" => %{"url" => "https://x.example.com"}}})

      assert msg =~ "requires explicit transport"
    end

    test "upstreams that is not an object is rejected" do
      assert {:error, :upstream_unavailable, msg} = load(%{"upstreams" => "nope"})
      assert msg =~ "upstreams must be an object"
    end
  end

  describe "mcp_stdio parsing" do
    test "type error in env (non-object) is rejected" do
      map = %{
        "upstreams" => %{
          "svc" => %{"transport" => "mcp_stdio", "command" => "run", "env" => ["bad"]}
        }
      }

      assert {:error, :upstream_unavailable, msg} = load(map)
      assert msg =~ "env must be an object"
    end

    test "type error in args (non-list-of-strings) is rejected" do
      map = %{
        "upstreams" => %{
          "svc" => %{"transport" => "mcp_stdio", "command" => "run", "args" => [1, 2]}
        }
      }

      assert {:error, :upstream_unavailable, msg} = load(map)
      assert msg =~ "args must be a list of strings"
    end

    test "missing command is rejected" do
      map = %{"upstreams" => %{"svc" => %{"transport" => "mcp_stdio"}}}

      assert {:error, :upstream_unavailable, msg} = load(map)
      assert msg =~ "requires command"
    end

    test "valid mcp_stdio config parses with coerced env/args and defaults" do
      map = %{
        "upstreams" => %{
          "svc" => %{
            "transport" => "mcp_stdio",
            "command" => "run",
            "args" => ["--flag", "value"],
            "env" => %{"KEY" => "VAL"},
            "cd" => "/tmp"
          }
        }
      }

      assert {:ok, %{upstreams: [upstream]}} = load(map)
      assert upstream.transport == :mcp_stdio
      assert upstream.config.command == "run"
      assert upstream.config.args == ["--flag", "value"]
      assert upstream.config.env == %{"KEY" => "VAL"}
      assert upstream.config.cd == "/tmp"
      assert upstream.config.handshake_timeout_ms == 10_000
    end
  end

  describe "raw_config decoding" do
    test "config_json must decode to a JSON object" do
      assert {:error, :upstream_unavailable, msg} = Config.load(config_json: "[1,2,3]")
      assert msg =~ "must be a JSON object"
    end

    test "malformed config_json reports a decode failure" do
      assert {:error, :upstream_unavailable, msg} = Config.load(config_json: "{not json")
      assert msg =~ "JSON decode failed"
    end

    test "no source yields an empty upstream set" do
      assert {:ok, %{upstreams: []}} = Config.load([])
    end
  end
end
