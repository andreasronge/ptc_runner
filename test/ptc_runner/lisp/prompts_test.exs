defmodule PtcRunner.Lisp.PromptsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Prompts

  doctest Prompts

  describe "get/1" do
    test "returns default prompt from Schema" do
      prompt = Prompts.get(:default)
      assert is_binary(prompt)
      assert String.contains?(prompt, "PTC-Lisp")
    end

    test "returns minimal prompt" do
      prompt = Prompts.get(:minimal)
      assert is_binary(prompt)
      assert String.contains?(prompt, "Quick Reference")
      refute String.contains?(prompt, "memory/")
    end

    test "returns single_shot prompt with examples" do
      prompt = Prompts.get(:single_shot)
      assert is_binary(prompt)
      assert String.contains?(prompt, "Single Query Mode")
      assert String.contains?(prompt, "Common Patterns")
    end

    test "returns multi_turn prompt with memory docs" do
      prompt = Prompts.get(:multi_turn)
      assert is_binary(prompt)
      assert String.contains?(prompt, "memory/")
      assert String.contains?(prompt, "Multi-Turn")
    end

    test "returns nil for unknown prompt" do
      assert Prompts.get(:nonexistent) == nil
    end
  end

  describe "get!/1" do
    test "returns prompt for valid key" do
      prompt = Prompts.get!(:minimal)
      assert is_binary(prompt)
    end

    test "raises for unknown prompt" do
      assert_raise ArgumentError, ~r/Unknown prompt: :nonexistent/, fn ->
        Prompts.get!(:nonexistent)
      end
    end
  end

  describe "list/0" do
    test "returns list of available prompts" do
      keys = Prompts.list()
      assert :default in keys
      assert :minimal in keys
      assert :single_shot in keys
      assert :multi_turn in keys
    end
  end

  describe "list_with_descriptions/0" do
    test "returns list of {key, description} tuples" do
      items = Prompts.list_with_descriptions()
      assert is_list(items)

      # Check structure
      for {key, desc} <- items do
        assert is_atom(key)
        assert is_binary(desc)
      end

      # Check default is included
      assert Enum.any?(items, fn {key, _} -> key == :default end)
    end
  end

  describe "version/1" do
    test "returns 1 for default prompt" do
      assert Prompts.version(:default) == 1
    end

    test "returns 1 for prompts without version metadata" do
      # Prompts without explicit version should default to 1
      assert Prompts.version(:minimal) == 1
    end

    test "raises for unknown prompt" do
      assert_raise ArgumentError, ~r/Unknown prompt: :nonexistent/, fn ->
        Prompts.version(:nonexistent)
      end
    end
  end

  describe "metadata/1" do
    test "returns version 1 map for default prompt" do
      meta = Prompts.metadata(:default)
      assert meta == %{version: 1}
    end

    test "returns parsed metadata for prompts with metadata" do
      # The minimal prompt now has version metadata
      meta = Prompts.metadata(:minimal)
      assert is_map(meta)
      assert meta[:version] == 1
      assert meta[:date] == "2025-01-02"
      assert meta[:changes] == "Initial minimal prompt for token-efficient queries"
    end

    test "raises for unknown prompt" do
      assert_raise ArgumentError, ~r/Unknown prompt: :nonexistent/, fn ->
        Prompts.metadata(:nonexistent)
      end
    end
  end

  describe "archived?/1" do
    test "returns false for default prompt" do
      refute Prompts.archived?(:default)
    end

    test "returns false for current prompts" do
      refute Prompts.archived?(:minimal)
      refute Prompts.archived?(:single_shot)
    end

    test "raises for unknown prompt" do
      assert_raise ArgumentError, ~r/Unknown prompt: :nonexistent/, fn ->
        Prompts.archived?(:nonexistent)
      end
    end
  end

  describe "list_current/0" do
    test "returns list of current (non-archived) prompts" do
      keys = Prompts.list_current()
      assert :default in keys
      assert :minimal in keys
      assert :single_shot in keys
      assert :multi_turn in keys
    end

    test "list_current is subset of list" do
      all_keys = Prompts.list()
      current_keys = Prompts.list_current()

      for key <- current_keys do
        assert key in all_keys
      end
    end
  end
end
