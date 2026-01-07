defmodule PtcRunner.Lisp.SchemaTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Prompts

  describe "multi_turn prompt" do
    test "returns non-empty string" do
      prompt = Prompts.get(:multi_turn)
      assert is_binary(prompt)
      assert String.length(prompt) > 500
    end

    test "documents PTC extensions" do
      prompt = Prompts.get(:multi_turn)
      # Predicate builders
      assert prompt =~ "where"
      assert prompt =~ "all-of"
      assert prompt =~ "any-of"
      # Aggregation
      assert prompt =~ "sum-by"
      assert prompt =~ "min-by"
    end

    test "documents context access" do
      prompt = Prompts.get(:multi_turn)
      assert prompt =~ "ctx/"
    end

    test "documents restrictions" do
      prompt = Prompts.get(:multi_turn)
      # Key restrictions LLMs need to know
      assert prompt =~ "if" and prompt =~ "else"
      assert prompt =~ "range"
    end

    test "documents common mistakes" do
      prompt = Prompts.get(:multi_turn)
      # Table with wrong/right patterns
      assert prompt =~ "Wrong"
      assert prompt =~ "Right"
    end

    test "documents state persistence for multi-turn" do
      prompt = Prompts.get(:multi_turn)
      assert prompt =~ "def"
      assert prompt =~ ~r/\*1|\*2|\*3/
    end
  end

  describe "single_shot prompt" do
    test "does not include multi-turn memory docs" do
      prompt = Prompts.get(:single_shot)
      refute prompt =~ "*1"
      refute prompt =~ "Previous turn"
    end
  end
end
