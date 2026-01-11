defmodule PtcRunner.SubAgent.SigilsTest do
  use ExUnit.Case, async: true

  # Exclude Kernel's ~T sigil to use our own
  import Kernel, except: [sigil_T: 2]
  import PtcRunner.SubAgent.Sigils

  alias PtcRunner.SubAgent.Template, as: TemplateExpander
  alias PtcRunner.Template

  # Note: doctest is not used because the ~T sigil conflicts with Elixir's built-in
  # Time sigil. The examples in the module doc are for reading, not testing.

  describe "~T sigil" do
    test "creates Template struct at compile time" do
      template = ~T"Hello {{name}}"

      assert %Template{} = template
      assert template.template == "Hello {{name}}"
      assert is_list(template.placeholders)
    end

    test "extracts simple placeholders into struct" do
      template = ~T"Hello {{name}}"

      assert template.placeholders == [%{path: ["name"], type: :simple}]
    end

    test "extracts nested placeholders" do
      template = ~T"User {{user.name}} has {{count}} items"

      assert template.placeholders == [
               %{path: ["user", "name"], type: :simple},
               %{path: ["count"], type: :simple}
             ]
    end

    test "works with template containing no placeholders" do
      template = ~T"No placeholders here"

      assert template.template == "No placeholders here"
      assert template.placeholders == []
    end

    test "works with empty template" do
      template = ~T""

      assert template.template == ""
      assert template.placeholders == []
    end

    test "works with heredoc syntax" do
      template = ~T"""
      Hello {{name}},

      You have {{items.count}} items.
      """

      assert template.template == "Hello {{name}},\n\nYou have {{items.count}} items.\n"

      assert template.placeholders == [
               %{path: ["name"], type: :simple},
               %{path: ["items", "count"], type: :simple}
             ]
    end

    test "template expansion with sigil" do
      template = ~T"Find emails for {{user}} from {{sender.name}}"

      assert template.template == "Find emails for {{user}} from {{sender.name}}"
      assert length(template.placeholders) == 2
      assert %{path: ["user"], type: :simple} in template.placeholders
      assert %{path: ["sender", "name"], type: :simple} in template.placeholders

      {:ok, expanded} =
        TemplateExpander.expand(
          template.template,
          %{user: "alice", sender: %{name: "bob"}}
        )

      assert expanded == "Find emails for alice from bob"
    end

    test "sigil extracts unique placeholders" do
      template = ~T"{{name}} and {{name}} again"

      assert template.placeholders == [%{path: ["name"], type: :simple}]
    end

    test "sigil handles deeply nested placeholders" do
      template = ~T"Value: {{a.b.c.d}}"

      assert template.placeholders == [%{path: ["a", "b", "c", "d"], type: :simple}]
    end
  end
end
