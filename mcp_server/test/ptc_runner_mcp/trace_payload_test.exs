defmodule PtcRunnerMcp.TracePayloadTest do
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.TracePayload

  describe "redact_program/2" do
    test ":full passthrough" do
      assert TracePayload.redact_program("(println :hi)", :full) == "(println :hi)"
    end

    test ":none has only sha256 and bytes" do
      result = TracePayload.redact_program("(println :hi)", :none)
      assert Map.keys(result) |> Enum.sort() == ["bytes", "sha256"]
      assert result["bytes"] == byte_size("(println :hi)")
      assert byte_size(result["sha256"]) == 64
      refute Map.has_key?(result, "preview")
    end

    test ":summary has sha256 + preview + bytes" do
      result = TracePayload.redact_program("(println :hi)", :summary)
      assert Map.keys(result) |> Enum.sort() == ["bytes", "preview", "sha256"]
      assert result["preview"] == "(println :hi)"
    end

    test ":summary truncates preview at 256 utf-8 chars" do
      long = String.duplicate("a", 1000)
      %{"preview" => preview} = TracePayload.redact_program(long, :summary)
      assert String.length(preview) == 256
    end

    test ":summary preview is utf-8 safe (multi-byte)" do
      # 1024 chars of "é" (2 bytes each) — preview should be 256 chars,
      # not a partial-byte slice that breaks utf-8.
      long = String.duplicate("é", 1024)
      %{"preview" => preview} = TracePayload.redact_program(long, :summary)
      assert String.valid?(preview)
      assert String.length(preview) == 256
    end
  end

  describe "redact_context/2" do
    test ":full passthrough" do
      ctx = %{"a" => 1, "b" => "hi"}
      assert TracePayload.redact_context(ctx, :full) == ctx
    end

    test ":none returns just byte size of encoded JSON" do
      ctx = %{"a" => 1}
      result = TracePayload.redact_context(ctx, :none)
      assert result == %{"<bytes>" => byte_size(Jason.encode!(ctx))}
    end

    test ":summary maps each top-level key to type+count" do
      ctx = %{
        "products" => [%{"id" => 1}, %{"id" => 2}, %{"id" => 3}],
        "name" => "alice",
        "limit" => 10,
        "config" => %{"a" => 1, "b" => 2},
        "active" => true,
        "missing" => nil
      }

      result = TracePayload.redact_context(ctx, :summary)

      assert result["products"] == %{"type" => "array", "count" => 3}
      assert result["name"] == %{"type" => "string", "count" => nil}
      assert result["limit"] == %{"type" => "number", "count" => nil}
      assert result["config"] == %{"type" => "object", "count" => 2}
      assert result["active"] == %{"type" => "boolean", "count" => nil}
      assert result["missing"] == %{"type" => "null", "count" => nil}
    end
  end

  describe "redact_validated/2" do
    test ":full passthrough" do
      v = %{"count" => 3}
      assert TracePayload.redact_validated(v, :full) == v
    end

    test ":summary on map → type + sorted keys" do
      v = %{"count" => 3, "name" => "x", "active" => true}
      result = TracePayload.redact_validated(v, :summary)
      assert result["type"] == "object"
      assert result["keys"] == ["active", "count", "name"]
    end

    test ":summary on array → type + length + element_type" do
      v = [1, 2, 3]
      result = TracePayload.redact_validated(v, :summary)
      assert result == %{"type" => "array", "length" => 3, "element_type" => "number"}
    end

    test ":summary on scalar → type only" do
      assert TracePayload.redact_validated(42, :summary) == %{"type" => "number"}
      assert TracePayload.redact_validated("hi", :summary) == %{"type" => "string"}
    end

    test ":none on map → no values" do
      v = %{"count" => 3, "name" => "x"}
      result = TracePayload.redact_validated(v, :none)
      assert result == %{"type" => "object", "keys" => ["count", "name"]}
    end
  end

  describe "redact_prints/2" do
    test ":full passthrough" do
      assert TracePayload.redact_prints(["a", "b"], :full) == ["a", "b"]
    end

    test ":none returns count only" do
      assert TracePayload.redact_prints(["a", "b", "c"], :none) == %{"count" => 3}
    end

    test ":summary truncates each print at 80 chars on first line" do
      prints = [
        "short",
        String.duplicate("x", 200),
        "first line\nsecond line shouldn't appear"
      ]

      result = TracePayload.redact_prints(prints, :summary)
      assert result["count"] == 3
      assert Enum.at(result["items"], 0) == "short"
      assert String.length(Enum.at(result["items"], 1)) == 80
      assert Enum.at(result["items"], 2) == "first line"
    end
  end

  describe "sha256_hex/1" do
    test "returns 64-char lowercase hex" do
      sha = TracePayload.sha256_hex("hello")
      assert byte_size(sha) == 64
      assert sha =~ ~r/^[0-9a-f]+$/
      # Known SHA-256 of "hello"
      assert sha == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    end
  end
end
