defmodule PtcRunner.Kernel.JSONSchemaAnnotationTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.JSONSchema

  # Mainstream MCP SDKs emit a root "$schema" dialect marker and "x-…" vendor
  # keys by default (probed live against DeepWiki, Cloudflare, and Context7).
  # "$schema" selects the dialect, so only explicitly supported dialect URIs
  # are accepted at the root; unknown, malformed, and nested markers are
  # rejected. Bounded "x-…" extension metadata is discarded as a deliberate
  # client policy. Semantic keywords the profile does not implement stay
  # rejected.

  test "accepts supported root dialects and drops vendor extension keys" do
    for dialect <- [
          "https://json-schema.org/draft/2020-12/schema",
          "http://json-schema.org/draft-07/schema#"
        ] do
      schema = %{
        "$schema" => dialect,
        "x-vendor-wrap" => true,
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "x-hint" => "free text"}
        },
        "required" => ["query"]
      }

      assert {:ok, normalized, compiled} = JSONSchema.compile(schema)

      encoded = Jason.encode!(normalized)
      refute encoded =~ "$schema"
      refute encoded =~ "x-vendor-wrap"
      refute encoded =~ "x-hint"

      assert JSONSchema.valid?(compiled, %{"query" => "text"})
      refute JSONSchema.valid?(compiled, %{"query" => 42})
      refute JSONSchema.valid?(compiled, %{})
    end
  end

  test "rejects unknown, malformed, and nested dialect markers" do
    unknown = %{"$schema" => "not-a-dialect-uri", "type" => "object"}
    assert {:error, :invalid_schema} = JSONSchema.compile(unknown)

    malformed = %{"$schema" => 42, "type" => "object"}
    assert {:error, :invalid_schema} = JSONSchema.compile(malformed)

    nested = %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "$schema" => "https://json-schema.org/draft/2020-12/schema",
          "type" => "string"
        }
      }
    }

    assert {:error, :invalid_schema} = JSONSchema.compile(nested)
  end

  test "still rejects unsupported semantic keywords" do
    for extra <- [
          %{"anyOf" => [%{"type" => "string"}]},
          %{"properties" => %{"q" => %{"type" => "string", "default" => "x"}}}
        ] do
      schema = Map.merge(%{"type" => "object"}, extra)
      assert {:error, :invalid_schema} = JSONSchema.compile(schema)
    end
  end
end
