defmodule PtcRunner.Kernel.JSONSchemaAnnotationTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.JSONSchema

  # Mainstream MCP SDKs emit a root "$schema" dialect marker and "x-…" vendor
  # keys and standard "default" annotations by default (probed live against
  # DeepWiki, Cloudflare, Context7, and GitHub MCP Server).
  # "$schema" selects the dialect, so only explicitly supported dialect URIs
  # are accepted at the root; unknown, malformed, and nested markers are
  # rejected. Bounded "x-…" extension metadata and valid JSON "default"
  # annotations are discarded as a deliberate client policy. Semantic
  # keywords the profile does not implement stay rejected.

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

  test "accepts and drops default annotations without applying them" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "default" => "/"}
      }
    }

    assert {:ok, normalized, compiled} = JSONSchema.compile(schema)
    refute get_in(normalized, ["properties", "path"]) |> Map.has_key?("default")
    assert JSONSchema.valid?(compiled, %{})
    assert JSONSchema.valid?(compiled, %{"path" => "README.md"})
    refute JSONSchema.valid?(compiled, %{"path" => 42})

    invalid =
      put_in(schema, ["properties", "path", "default"], %{self() => "not JSON"})

    assert {:error, :invalid_schema} = JSONSchema.compile(invalid)
  end

  test "still rejects unsupported semantic keywords" do
    schema = %{
      "type" => "object",
      "properties" => %{"q" => %{"anyOf" => [%{"type" => "string"}]}}
    }

    assert {:error, :invalid_schema} = JSONSchema.compile(schema)
  end
end
