defmodule PtcRunner.Lisp.PromptsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Prompts

  doctest Prompts

  describe "get/1" do
    test "returns single_shot prompt (base + single_shot addon)" do
      prompt = Prompts.get(:single_shot)
      assert is_binary(prompt)
      assert String.contains?(prompt, "PTC-Lisp")
      assert String.contains?(prompt, "Single-Shot")
    end

    test "returns multi_turn prompt (base + multi_turn addon)" do
      prompt = Prompts.get(:multi_turn)
      assert is_binary(prompt)
      assert String.contains?(prompt, "PTC-Lisp")
      assert String.contains?(prompt, "Multi-Turn")
      # multi_turn is longer than single_shot
      assert String.length(prompt) > String.length(Prompts.get(:single_shot))
    end

    test "returns base snippet" do
      prompt = Prompts.get(:base)
      assert is_binary(prompt)
      assert String.contains?(prompt, "PTC-Lisp")
    end

    test "returns addon_single_shot snippet" do
      prompt = Prompts.get(:addon_single_shot)
      assert is_binary(prompt)
      assert String.contains?(prompt, "Single-Shot")
    end

    test "returns addon_multi_turn snippet" do
      prompt = Prompts.get(:addon_multi_turn)
      assert is_binary(prompt)
      assert String.contains?(prompt, "State Persistence")
    end

    test "returns nil for unknown prompt" do
      assert Prompts.get(:nonexistent) == nil
    end
  end

  describe "get!/1" do
    test "returns prompt for valid key" do
      prompt = Prompts.get!(:single_shot)
      assert is_binary(prompt)
    end

    test "raises for unknown prompt" do
      assert_raise ArgumentError, ~r/Unknown prompt: :nonexistent/, fn ->
        Prompts.get!(:nonexistent)
      end
    end
  end

  describe "compositions" do
    test "single_shot equals base + addon_single_shot" do
      base = Prompts.get(:base)
      addon = Prompts.get(:addon_single_shot)
      expected = base <> "\n\n" <> addon

      assert Prompts.get(:single_shot) == expected
    end

    test "multi_turn equals base + addon_multi_turn" do
      base = Prompts.get(:base)
      addon = Prompts.get(:addon_multi_turn)
      expected = base <> "\n\n" <> addon

      assert Prompts.get(:multi_turn) == expected
    end
  end

  describe "list/0" do
    test "returns list of available prompts" do
      keys = Prompts.list()
      assert :single_shot in keys
      assert :multi_turn in keys
      assert :base in keys
      assert :addon_single_shot in keys
      assert :addon_multi_turn in keys
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

      # Check compositions are included
      assert Enum.any?(items, fn {key, _} -> key == :single_shot end)
      assert Enum.any?(items, fn {key, _} -> key == :multi_turn end)
    end
  end

  describe "version/1" do
    test "returns a positive integer for base" do
      version = Prompts.version(:base)
      assert is_integer(version)
      assert version >= 1
    end

    test "compositions return the same version as their base snippet" do
      base_v = Prompts.version(:base)
      assert Prompts.version(:single_shot) == base_v
      assert Prompts.version(:multi_turn) == base_v
    end

    test "raises for unknown prompt" do
      assert_raise ArgumentError, ~r/Unknown prompt: :nonexistent/, fn ->
        Prompts.version(:nonexistent)
      end
    end
  end

  describe "metadata/1" do
    test "returns metadata for single_shot (from base)" do
      meta = Prompts.metadata(:single_shot)
      assert is_map(meta)
    end

    test "returns metadata for base" do
      meta = Prompts.metadata(:base)
      assert is_map(meta)
    end

    test "raises for unknown prompt" do
      assert_raise ArgumentError, ~r/Unknown prompt: :nonexistent/, fn ->
        Prompts.metadata(:nonexistent)
      end
    end
  end

  describe "archived?/1" do
    test "returns false for compositions" do
      refute Prompts.archived?(:single_shot)
      refute Prompts.archived?(:multi_turn)
    end

    test "returns false for current snippets" do
      refute Prompts.archived?(:base)
      refute Prompts.archived?(:addon_single_shot)
      refute Prompts.archived?(:addon_multi_turn)
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
      assert :single_shot in keys
      assert :multi_turn in keys
      assert :base in keys
      assert :addon_single_shot in keys
      assert :addon_multi_turn in keys
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
