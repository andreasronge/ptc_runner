defmodule PtcRunner.SubAgent.SigilsTest do
  use ExUnit.Case, async: true

  import PtcRunner.SubAgent.Sigils

  alias PtcRunner.Prompt
  alias PtcRunner.SubAgent.Template

  doctest PtcRunner.SubAgent.Sigils

  describe "~PROMPT sigil" do
    test "creates Prompt struct at compile time" do
      prompt = ~PROMPT"Hello {{name}}"

      assert %Prompt{} = prompt
      assert prompt.template == "Hello {{name}}"
      assert is_list(prompt.placeholders)
    end

    test "extracts simple placeholders into struct" do
      prompt = ~PROMPT"Hello {{name}}"

      assert prompt.placeholders == [%{path: ["name"], type: :simple}]
    end

    test "extracts nested placeholders" do
      prompt = ~PROMPT"User {{user.name}} has {{count}} items"

      assert prompt.placeholders == [
               %{path: ["user", "name"], type: :simple},
               %{path: ["count"], type: :simple}
             ]
    end

    test "works with template containing no placeholders" do
      prompt = ~PROMPT"No placeholders here"

      assert prompt.template == "No placeholders here"
      assert prompt.placeholders == []
    end

    test "works with empty template" do
      prompt = ~PROMPT""

      assert prompt.template == ""
      assert prompt.placeholders == []
    end

    test "works with heredoc syntax" do
      prompt = ~PROMPT"""
      Hello {{name}},

      You have {{items.count}} items.
      """

      assert prompt.template == "Hello {{name}},\n\nYou have {{items.count}} items.\n"

      assert prompt.placeholders == [
               %{path: ["name"], type: :simple},
               %{path: ["items", "count"], type: :simple}
             ]
    end

    test "template expansion with sigil" do
      prompt = ~PROMPT"Find emails for {{user}} from {{sender.name}}"

      assert prompt.template == "Find emails for {{user}} from {{sender.name}}"
      assert length(prompt.placeholders) == 2
      assert %{path: ["user"], type: :simple} in prompt.placeholders
      assert %{path: ["sender", "name"], type: :simple} in prompt.placeholders

      {:ok, expanded} =
        Template.expand(
          prompt.template,
          %{user: "alice", sender: %{name: "bob"}}
        )

      assert expanded == "Find emails for alice from bob"
    end

    test "sigil extracts unique placeholders" do
      prompt = ~PROMPT"{{name}} and {{name}} again"

      assert prompt.placeholders == [%{path: ["name"], type: :simple}]
    end

    test "sigil handles deeply nested placeholders" do
      prompt = ~PROMPT"Value: {{a.b.c.d}}"

      assert prompt.placeholders == [%{path: ["a", "b", "c", "d"], type: :simple}]
    end
  end
end
