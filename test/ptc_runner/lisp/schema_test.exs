defmodule PtcRunner.Lisp.SchemaTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Prompts

  describe "to_prompt/0" do
    test "returns non-empty string" do
      prompt = Prompts.get(:multi_turn)
      assert is_binary(prompt)
      assert String.length(prompt) > 1000
    end

    test "contains language overview" do
      prompt = Prompts.get(:multi_turn)
      assert String.contains?(prompt, "PTC-Lisp")
      assert String.contains?(prompt, "single expressions")
    end

    test "contains data access section" do
      prompt = Prompts.get(:multi_turn)
      assert String.contains?(prompt, "Data Access")
      assert String.contains?(prompt, "ctx/products")
    end

    test "contains accessing data section" do
      prompt = Prompts.get(:multi_turn)
      assert String.contains?(prompt, "ctx/")
      assert String.contains?(prompt, "memory/")
    end

    test "contains unsupported features section" do
      prompt = Prompts.get(:multi_turn)
      assert String.contains?(prompt, "NOT Supported")
      assert String.contains?(prompt, "`if` without else")
    end

    test "contains threading macros" do
      prompt = Prompts.get(:multi_turn)
      assert String.contains?(prompt, "->>")
      assert String.contains?(prompt, "->")
    end

    test "contains predicate builders" do
      prompt = Prompts.get(:multi_turn)
      assert String.contains?(prompt, "where")
      assert String.contains?(prompt, "all-of")
      assert String.contains?(prompt, "any-of")
    end

    test "contains core functions" do
      prompt = Prompts.get(:multi_turn)
      assert String.contains?(prompt, "filter")
      assert String.contains?(prompt, "count")
      assert String.contains?(prompt, "sum-by")
    end

    test "contains common mistakes section" do
      prompt = Prompts.get(:multi_turn)
      assert String.contains?(prompt, "Common Mistakes")
      assert String.contains?(prompt, "Wrong")
      assert String.contains?(prompt, "Right")
    end

    test "contains memory section" do
      prompt = Prompts.get(:multi_turn)
      assert String.contains?(prompt, "Memory Storage Rules")
      assert String.contains?(prompt, "memory/")
    end
  end
end
