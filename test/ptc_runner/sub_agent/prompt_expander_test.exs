defmodule PtcRunner.SubAgent.PromptExpanderTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent.PromptExpander

  doctest PtcRunner.SubAgent.PromptExpander

  describe "extract_placeholders/1" do
    test "extracts simple placeholders" do
      assert PromptExpander.extract_placeholders("Hello {{name}}") == [
               %{path: ["name"], type: :simple}
             ]
    end

    test "extracts nested placeholders with path" do
      assert PromptExpander.extract_placeholders("User {{user.name}}") == [
               %{path: ["user", "name"], type: :simple}
             ]
    end

    test "extracts multiple placeholders" do
      result =
        PromptExpander.extract_placeholders("Hello {{name}}, you have {{items.count}} items")

      assert result == [
               %{path: ["name"], type: :simple},
               %{path: ["items", "count"], type: :simple}
             ]
    end

    test "returns unique placeholders (no duplicates)" do
      assert PromptExpander.extract_placeholders("{{name}} and {{name}}") == [
               %{path: ["name"], type: :simple}
             ]
    end

    test "returns empty list for no placeholders" do
      assert PromptExpander.extract_placeholders("No placeholders here") == []
    end

    test "handles empty template" do
      assert PromptExpander.extract_placeholders("") == []
    end

    test "handles unclosed braces gracefully" do
      # Unclosed braces should be treated as literal text
      assert PromptExpander.extract_placeholders("{{name and {{other") == []
    end

    test "extracts deeply nested paths" do
      assert PromptExpander.extract_placeholders("{{a.b.c.d}}") == [
               %{path: ["a", "b", "c", "d"], type: :simple}
             ]
    end

    test "handles multiple nested placeholders" do
      result = PromptExpander.extract_placeholders("{{user.email}} {{user.profile.bio}}")

      assert result == [
               %{path: ["user", "email"], type: :simple},
               %{path: ["user", "profile", "bio"], type: :simple}
             ]
    end

    test "handles placeholder with underscores" do
      assert PromptExpander.extract_placeholders("{{user_name}} {{_private}}") == [
               %{path: ["user_name"], type: :simple},
               %{path: ["_private"], type: :simple}
             ]
    end
  end

  describe "expand/2" do
    test "expands simple placeholder" do
      assert PromptExpander.expand("Hello {{name}}", %{name: "Alice"}) == {:ok, "Hello Alice"}
    end

    test "expands nested placeholder" do
      assert PromptExpander.expand("User {{user.name}}", %{user: %{name: "Bob"}}) ==
               {:ok, "User Bob"}
    end

    test "expands multiple placeholders" do
      assert PromptExpander.expand("{{greeting}} {{name}}", %{greeting: "Hello", name: "Alice"}) ==
               {:ok, "Hello Alice"}
    end

    test "returns error for missing key" do
      assert PromptExpander.expand("Hello {{name}}", %{}) == {:error, {:missing_keys, ["name"]}}
    end

    test "reports all missing keys, not just first" do
      assert PromptExpander.expand("{{a}} and {{b}}", %{}) ==
               {:error, {:missing_keys, ["a", "b"]}}
    end

    test "handles empty template" do
      assert PromptExpander.expand("", %{}) == {:ok, ""}
    end

    test "handles template with no placeholders" do
      assert PromptExpander.expand("No placeholders here", %{foo: "bar"}) ==
               {:ok, "No placeholders here"}
    end

    test "supports atom keys in context" do
      assert PromptExpander.expand("Hello {{name}}", %{name: "Alice"}) == {:ok, "Hello Alice"}
    end

    test "supports string keys in context" do
      assert PromptExpander.expand("Hello {{name}}", %{"name" => "Alice"}) ==
               {:ok, "Hello Alice"}
    end

    test "handles deeply nested paths" do
      assert PromptExpander.expand("{{a.b.c.d}}", %{a: %{b: %{c: %{d: "deep"}}}}) ==
               {:ok, "deep"}
    end

    test "converts values to strings" do
      assert PromptExpander.expand("Count: {{count}}", %{count: 42}) == {:ok, "Count: 42"}
      assert PromptExpander.expand("Float: {{value}}", %{value: 3.14}) == {:ok, "Float: 3.14"}
      assert PromptExpander.expand("Bool: {{flag}}", %{flag: true}) == {:ok, "Bool: true"}
    end

    test "returns error when nested key is missing" do
      assert PromptExpander.expand("{{user.name}}", %{user: %{}}) ==
               {:error, {:missing_keys, ["user.name"]}}
    end

    test "returns error when parent key is missing" do
      assert PromptExpander.expand("{{user.name}}", %{}) ==
               {:error, {:missing_keys, ["user.name"]}}
    end

    test "handles mix of atom and string keys in nested maps" do
      context = %{
        user: %{"name" => "Alice"},
        profile: %{email: "alice@example.com"}
      }

      assert PromptExpander.expand("{{user.name}}", context) == {:ok, "Alice"}
      assert PromptExpander.expand("{{profile.email}}", context) == {:ok, "alice@example.com"}
    end

    test "expands duplicate placeholders correctly" do
      assert PromptExpander.expand("{{name}} and {{name}}", %{name: "Alice"}) ==
               {:ok, "Alice and Alice"}
    end

    test "handles placeholders with underscores" do
      assert PromptExpander.expand("{{user_name}}", %{user_name: "alice_123"}) ==
               {:ok, "alice_123"}
    end

    test "returns error when nested path points to non-map" do
      assert PromptExpander.expand("{{user.name}}", %{user: "not a map"}) ==
               {:error, {:missing_keys, ["user.name"]}}
    end
  end

  describe "expand/3 with on_missing: :keep" do
    test "keeps missing placeholder unchanged" do
      assert PromptExpander.expand("{{missing}}", %{}, on_missing: :keep) == {:ok, "{{missing}}"}
    end

    test "expands available keys and keeps missing ones" do
      assert PromptExpander.expand("{{a}} and {{b}}", %{a: "1"}, on_missing: :keep) ==
               {:ok, "1 and {{b}}"}
    end

    test "expands all keys when all are present" do
      assert PromptExpander.expand("{{a}} and {{b}}", %{a: "1", b: "2"}, on_missing: :keep) ==
               {:ok, "1 and 2"}
    end

    test "keeps missing nested placeholder unchanged" do
      assert PromptExpander.expand("{{user.name}}", %{}, on_missing: :keep) ==
               {:ok, "{{user.name}}"}
    end

    test "expands partial nested path and keeps missing nested key" do
      assert PromptExpander.expand("{{user.name}}", %{user: %{}}, on_missing: :keep) ==
               {:ok, "{{user.name}}"}
    end

    test "handles template with no placeholders" do
      assert PromptExpander.expand("No placeholders", %{}, on_missing: :keep) ==
               {:ok, "No placeholders"}
    end

    test "handles empty template" do
      assert PromptExpander.expand("", %{}, on_missing: :keep) == {:ok, ""}
    end

    test "keeps multiple missing placeholders" do
      assert PromptExpander.expand("{{a}}, {{b}}, {{c}}", %{}, on_missing: :keep) ==
               {:ok, "{{a}}, {{b}}, {{c}}"}
    end

    test "expands some and keeps others" do
      assert PromptExpander.expand("{{a}}, {{b}}, {{c}}", %{b: "middle"}, on_missing: :keep) ==
               {:ok, "{{a}}, middle, {{c}}"}
    end

    test "expands variables and sections together" do
      context = %{
        topic: "quantum computing",
        articles: [%{id: 1, name: "Alpha"}, %{id: 2, name: "Beta"}]
      }

      template = """
      Topic: {{topic}}

      {{#articles}}
      - ID {{id}}: {{name}}
      {{/articles}}
      """

      {:ok, result} = PromptExpander.expand(template, context, on_missing: :keep)
      assert result =~ "Topic: quantum computing"
      assert result =~ "ID 1"
      assert result =~ "ID 2"
      assert result =~ "Alpha"
      refute result =~ "{{topic}}"
      refute result =~ "{{#articles}}"
    end
  end
end
