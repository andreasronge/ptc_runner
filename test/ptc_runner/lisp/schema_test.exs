defmodule PtcRunner.Lisp.SchemaTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Schema

  describe "to_prompt/0" do
    test "returns non-empty string" do
      prompt = Schema.to_prompt()
      assert is_binary(prompt)
      assert String.length(prompt) > 1000
    end

    test "contains language overview" do
      prompt = Schema.to_prompt()
      assert String.contains?(prompt, "PTC-Lisp")
      assert String.contains?(prompt, "single expressions")
    end

    test "contains data types section" do
      prompt = Schema.to_prompt()
      assert String.contains?(prompt, "Data Types")
      assert String.contains?(prompt, "nil true false")
      assert String.contains?(prompt, ":keyword")
    end

    test "contains accessing data section" do
      prompt = Schema.to_prompt()
      assert String.contains?(prompt, "ctx/")
      assert String.contains?(prompt, "memory/")
    end

    test "contains special forms section" do
      prompt = Schema.to_prompt()
      assert String.contains?(prompt, "let")
      assert String.contains?(prompt, "if cond then else")
      assert String.contains?(prompt, "fn")
    end

    test "contains threading macros" do
      prompt = Schema.to_prompt()
      assert String.contains?(prompt, "->>")
      assert String.contains?(prompt, "->")
    end

    test "contains predicate builders" do
      prompt = Schema.to_prompt()
      assert String.contains?(prompt, "where")
      assert String.contains?(prompt, "all-of")
      assert String.contains?(prompt, "any-of")
    end

    test "contains core functions" do
      prompt = Schema.to_prompt()
      assert String.contains?(prompt, "filter")
      assert String.contains?(prompt, "count")
      assert String.contains?(prompt, "sum-by")
    end

    test "contains common mistakes section" do
      prompt = Schema.to_prompt()
      assert String.contains?(prompt, "Common Mistakes")
      assert String.contains?(prompt, "Wrong")
      assert String.contains?(prompt, "Right")
    end

    test "contains memory result contract" do
      prompt = Schema.to_prompt()
      assert String.contains?(prompt, "Memory Result Contract")
      assert String.contains?(prompt, ":result")
    end
  end
end
