defmodule PtcRunner.Upstream.CredentialsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Upstream.Credentials

  # Pure (no env/file) Credentials behavior: literal source resolution, header
  # emission per auth scheme, and the scrub/redaction pass that keeps secrets
  # out of LLM-visible diagnostics. The env/file source branches live in the
  # async: false companion file (credentials_source_test.exs).

  defp literal(value, extra \\ %{}) do
    Map.merge(%{"source" => "literal", "value" => value}, extra)
  end

  defp creds(config) do
    {:ok, c} = Credentials.new(config)
    c
  end

  describe "new/1 source resolution" do
    test "literal source materializes the value and records it as a secret" do
      c = creds(%{"token" => literal("abc123")})

      assert Credentials.binding_names(c) == ["token"]
      assert Credentials.redaction_secrets(c) == ["abc123"]
    end

    test "an unrecognized binding spec is rejected" do
      assert {:error, :upstream_unavailable, msg} =
               Credentials.new(%{"token" => %{"source" => "telepathy"}})

      assert msg =~ "invalid credential binding"
      assert msg =~ "token"
    end
  end

  describe "headers/2 scheme emission" do
    test "bearer scheme emits an Authorization: Bearer header" do
      c = creds(%{"token" => literal("abc123")})

      assert {:ok, [{"authorization", "Bearer abc123"}]} =
               Credentials.headers(c, [%{"scheme" => "bearer", "binding" => "token"}])
    end

    test "api_key scheme emits the raw value under the configured header" do
      c = creds(%{"key" => literal("k-1")})

      assert {:ok, [{"X-Api-Key", "k-1"}]} =
               Credentials.headers(c, [
                 %{"scheme" => "api_key", "binding" => "key", "header" => "X-Api-Key"}
               ])
    end

    test "basic scheme accepts JSON {user, pass} form" do
      c = creds(%{"login" => literal(~s({"user":"alice","pass":"wonder"}))})

      assert {:ok, [{"authorization", "Basic " <> encoded}]} =
               Credentials.headers(c, [%{"scheme" => "basic", "binding" => "login"}])

      assert Base.decode64!(encoded) == "alice:wonder"
    end

    test "basic scheme accepts user:pass colon form" do
      c = creds(%{"login" => literal("bob:hunter2")})

      assert {:ok, [{"authorization", "Basic " <> encoded}]} =
               Credentials.headers(c, [%{"scheme" => "basic", "binding" => "login"}])

      assert Base.decode64!(encoded) == "bob:hunter2"
    end

    test "basic scheme rejects malformed (non-JSON, no colon) value" do
      c = creds(%{"login" => literal("plainstring")})

      assert {:error, :upstream_unavailable, msg} =
               Credentials.headers(c, [%{"scheme" => "basic", "binding" => "login"}])

      assert msg =~ "must be user:pass"
    end

    test "basic scheme rejects JSON object missing user/pass" do
      c = creds(%{"login" => literal(~s({"user":"alice"}))})

      assert {:error, :upstream_unavailable, msg} =
               Credentials.headers(c, [%{"scheme" => "basic", "binding" => "login"}])

      assert msg =~ "must contain user and pass"
    end

    test "custom_header with a reserved header name is rejected at emit time" do
      c = creds(%{"token" => literal("v")})

      assert {:error, :upstream_unavailable, msg} =
               Credentials.headers(c, [
                 %{"scheme" => "custom_header", "binding" => "token", "header" => "Cookie"}
               ])

      assert msg =~ "invalid custom auth header"
    end

    test "emitter binding that does not exist is rejected" do
      c = creds(%{"token" => literal("v")})

      assert {:error, :upstream_unavailable, msg} =
               Credentials.headers(c, [%{"scheme" => "bearer", "binding" => "ghost"}])

      assert msg =~ "unknown credential binding ghost"
    end
  end

  describe "scrub/2 redaction" do
    test "redacts a literal secret inside a string" do
      c = creds(%{"token" => literal("s3cr3t")})

      assert Credentials.scrub(c, "auth=s3cr3t end") == "auth=[REDACTED] end"
    end

    test "redacts secrets nested in lists and maps, including map keys" do
      c = creds(%{"token" => literal("s3cr3t")})

      input = %{"s3cr3t" => ["leading s3cr3t", %{"inner" => "x s3cr3t y"}]}
      out = Credentials.scrub(c, input)

      assert out == %{
               "[REDACTED]" => ["leading [REDACTED]", %{"inner" => "x [REDACTED] y"}]
             }
    end

    test "leaves non-binary terms untouched" do
      c = creds(%{"token" => literal("s3cr3t")})

      assert Credentials.scrub(c, 42) == 42
      assert Credentials.scrub(c, :atom) == :atom
    end

    test "empty-secret bindings do not corrupt unrelated text" do
      c = creds(%{"token" => literal("")})

      # An empty secret is filtered out of redaction (would otherwise match
      # everywhere); the text passes through unchanged.
      assert Credentials.scrub(c, "untouched") == "untouched"
    end
  end
end
