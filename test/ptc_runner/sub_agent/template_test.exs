defmodule PtcRunner.SubAgent.TemplateTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent.Template

  doctest PtcRunner.SubAgent.Template

  describe "extract_placeholders/1" do
    test "extracts simple placeholders" do
      assert Template.extract_placeholders("Hello {{name}}") == [
               %{path: ["name"], type: :simple}
             ]
    end

    test "extracts nested placeholders with path" do
      assert Template.extract_placeholders("User {{user.name}}") == [
               %{path: ["user", "name"], type: :simple}
             ]
    end

    test "extracts multiple placeholders" do
      result = Template.extract_placeholders("Hello {{name}}, you have {{items.count}} items")

      assert result == [
               %{path: ["name"], type: :simple},
               %{path: ["items", "count"], type: :simple}
             ]
    end

    test "returns unique placeholders (no duplicates)" do
      assert Template.extract_placeholders("{{name}} and {{name}}") == [
               %{path: ["name"], type: :simple}
             ]
    end

    test "returns empty list for no placeholders" do
      assert Template.extract_placeholders("No placeholders here") == []
    end

    test "handles empty template" do
      assert Template.extract_placeholders("") == []
    end

    test "handles unclosed braces gracefully" do
      # Unclosed braces should be treated as literal text
      assert Template.extract_placeholders("{{name and {{other") == []
    end

    test "extracts deeply nested paths" do
      assert Template.extract_placeholders("{{a.b.c.d}}") == [
               %{path: ["a", "b", "c", "d"], type: :simple}
             ]
    end

    test "handles multiple nested placeholders" do
      result = Template.extract_placeholders("{{user.email}} {{user.profile.bio}}")

      assert result == [
               %{path: ["user", "email"], type: :simple},
               %{path: ["user", "profile", "bio"], type: :simple}
             ]
    end

    test "handles placeholder with underscores" do
      assert Template.extract_placeholders("{{user_name}} {{_private}}") == [
               %{path: ["user_name"], type: :simple},
               %{path: ["_private"], type: :simple}
             ]
    end
  end

  describe "expand/2" do
    test "expands simple placeholder" do
      assert Template.expand("Hello {{name}}", %{name: "Alice"}) == {:ok, "Hello Alice"}
    end

    test "expands nested placeholder" do
      assert Template.expand("User {{user.name}}", %{user: %{name: "Bob"}}) ==
               {:ok, "User Bob"}
    end

    test "expands multiple placeholders" do
      assert Template.expand("{{greeting}} {{name}}", %{greeting: "Hello", name: "Alice"}) ==
               {:ok, "Hello Alice"}
    end

    test "returns error for missing key" do
      assert Template.expand("Hello {{name}}", %{}) == {:error, {:missing_keys, ["name"]}}
    end

    test "reports all missing keys, not just first" do
      assert Template.expand("{{a}} and {{b}}", %{}) == {:error, {:missing_keys, ["a", "b"]}}
    end

    test "handles empty template" do
      assert Template.expand("", %{}) == {:ok, ""}
    end

    test "handles template with no placeholders" do
      assert Template.expand("No placeholders here", %{foo: "bar"}) ==
               {:ok, "No placeholders here"}
    end

    test "supports atom keys in context" do
      assert Template.expand("Hello {{name}}", %{name: "Alice"}) == {:ok, "Hello Alice"}
    end

    test "supports string keys in context" do
      assert Template.expand("Hello {{name}}", %{"name" => "Alice"}) == {:ok, "Hello Alice"}
    end

    test "handles deeply nested paths" do
      assert Template.expand("{{a.b.c.d}}", %{a: %{b: %{c: %{d: "deep"}}}}) == {:ok, "deep"}
    end

    test "converts values to strings" do
      assert Template.expand("Count: {{count}}", %{count: 42}) == {:ok, "Count: 42"}
      assert Template.expand("Float: {{value}}", %{value: 3.14}) == {:ok, "Float: 3.14"}
      assert Template.expand("Bool: {{flag}}", %{flag: true}) == {:ok, "Bool: true"}
    end

    test "returns error when nested key is missing" do
      assert Template.expand("{{user.name}}", %{user: %{}}) ==
               {:error, {:missing_keys, ["user.name"]}}
    end

    test "returns error when parent key is missing" do
      assert Template.expand("{{user.name}}", %{}) == {:error, {:missing_keys, ["user.name"]}}
    end

    test "handles mix of atom and string keys in nested maps" do
      context = %{
        user: %{"name" => "Alice"},
        profile: %{email: "alice@example.com"}
      }

      assert Template.expand("{{user.name}}", context) == {:ok, "Alice"}
      assert Template.expand("{{profile.email}}", context) == {:ok, "alice@example.com"}
    end

    test "expands duplicate placeholders correctly" do
      assert Template.expand("{{name}} and {{name}}", %{name: "Alice"}) ==
               {:ok, "Alice and Alice"}
    end

    test "handles placeholders with underscores" do
      assert Template.expand("{{user_name}}", %{user_name: "alice_123"}) ==
               {:ok, "alice_123"}
    end

    test "returns error when nested path points to non-map" do
      assert Template.expand("{{user.name}}", %{user: "not a map"}) ==
               {:error, {:missing_keys, ["user.name"]}}
    end
  end
end
