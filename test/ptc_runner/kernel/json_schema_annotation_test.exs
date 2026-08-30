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

    assert {:error, {:invalid_schema, %{rule: :unsupported_dialect, segments: segments}}} =
             JSONSchema.compile(unknown)

    assert segments == [property: "$schema"]

    malformed = %{"$schema" => 42, "type" => "object"}

    assert {:error, {:invalid_schema, %{rule: :unsupported_dialect}}} =
             JSONSchema.compile(malformed)

    nested = %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "$schema" => "https://json-schema.org/draft/2020-12/schema",
          "type" => "string"
        }
      }
    }

    assert {:error, {:invalid_schema, %{rule: :unsupported_keyword, segments: nested_segments}}} =
             JSONSchema.compile(nested)

    assert nested_segments == [property: "properties", property: "query", property: "$schema"]
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

    # `JSONValue.map?/1` proves the whole document is JSON before any keyword
    # is read, so a non-JSON annotation is refused as a document fault at the
    # root rather than located at the annotation it hides in.
    assert {:error, {:invalid_schema, %{rule: :not_a_schema_object, segments: []}}} =
             JSONSchema.compile(invalid)
  end

  test "supports only the bounded sha256 format" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "hash" => %{"type" => "string", "format" => "sha256"}
      },
      "required" => ["hash"]
    }

    assert {:ok, _normalized, compiled} = JSONSchema.compile(schema)

    assert JSONSchema.valid?(
             compiled,
             %{"hash" => "sha256:" <> String.duplicate("a", 64)}
           )

    refute JSONSchema.valid?(compiled, %{"hash" => String.duplicate("a", 71)})
    refute JSONSchema.valid?(compiled, %{"hash" => "sha256:" <> String.duplicate("A", 64)})

    assert {:error, {:invalid_schema, %{rule: :unsupported_format, segments: segments}}} =
             schema
             |> put_in(["properties", "hash", "format"], "regex")
             |> JSONSchema.compile()

    assert segments == [property: "properties", property: "hash", property: "format"]
  end

  test "still rejects unsupported semantic keywords" do
    schema = %{
      "type" => "object",
      "properties" => %{"q" => %{"anyOf" => [%{"type" => "string"}]}}
    }

    assert {:error, {:invalid_schema, %{rule: :unsupported_keyword, segments: segments}}} =
             JSONSchema.compile(schema)

    assert segments == [property: "properties", property: "q", property: "anyOf"]
  end

  test "accepts object property-count and property-name bounds" do
    schema = %{
      "type" => "object",
      "additionalProperties" => true,
      "maxProperties" => 2,
      "propertyNames" => %{"type" => "string", "maxLength" => 4}
    }

    assert {:ok, normalized, compiled} = JSONSchema.compile(schema)
    assert normalized["maxProperties"] == 2
    assert get_in(normalized, ["propertyNames", "maxLength"]) == 4

    assert JSONSchema.valid?(compiled, %{"ab" => 1, "cd" => 2})
    refute JSONSchema.valid?(compiled, %{"ab" => 1, "cd" => 2, "ef" => 3})
    refute JSONSchema.valid?(compiled, %{"abcde" => 1})

    assert {:error, {:invalid_schema, %{rule: :keyword_not_applicable}}} =
             JSONSchema.compile(%{
               "type" => "object",
               "properties" => %{"n" => %{"type" => "integer", "maxProperties" => 1}}
             })

    assert {:error, {:invalid_schema, %{rule: :invalid_keyword_value}}} =
             JSONSchema.compile(%{"type" => "object", "maxProperties" => -1})
  end
end
