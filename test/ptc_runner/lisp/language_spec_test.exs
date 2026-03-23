defmodule PtcRunner.Lisp.LanguageSpecTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.LanguageSpec

  doctest LanguageSpec

  # ============================================================================
  # Canonical compositions
  # ============================================================================

  describe "canonical compositions" do
    test ":single_shot contains reference + single-shot, not multi-turn content" do
      prompt = LanguageSpec.get(:single_shot)
      assert is_binary(prompt)
      # Reference content
      assert String.contains?(prompt, "<role>")
      assert String.contains?(prompt, "<language_reference>")
      # Single-shot content
      assert String.contains?(prompt, "<single_shot>")
      # Must NOT contain multi-turn content
      refute String.contains?(prompt, "<state>")
      refute String.contains?(prompt, "<return_rules>")
      refute String.contains?(prompt, "<journaled_tasks>")
    end

    test ":explicit_return contains reference + multi-turn + explicit return" do
      prompt = LanguageSpec.get(:explicit_return)
      assert is_binary(prompt)
      # Reference content
      assert String.contains?(prompt, "<role>")
      # Multi-turn core
      assert String.contains?(prompt, "<multi_turn_rules>")
      assert String.contains?(prompt, "<state>")
      # Explicit return content
      assert String.contains?(prompt, "<return_rules>")
      assert String.contains?(prompt, "(return answer)")
      # Must NOT contain auto-return or journal content
      refute String.contains?(prompt, "exploration turn")
      refute String.contains?(prompt, "<journaled_tasks>")
    end

    test ":auto_return contains reference + multi-turn + auto return" do
      prompt = LanguageSpec.get(:auto_return)
      assert is_binary(prompt)
      # Reference content
      assert String.contains?(prompt, "<role>")
      # Multi-turn core
      assert String.contains?(prompt, "<multi_turn_rules>")
      assert String.contains?(prompt, "<state>")
      # Auto-return content
      assert String.contains?(prompt, "<return_rules>")
      assert String.contains?(prompt, "exploration turn")
      # Must NOT contain explicit return or journal content
      refute String.contains?(prompt, "(return answer)")
      refute String.contains?(prompt, "<journaled_tasks>")
    end

    test ":explicit_journal contains reference + multi-turn + explicit return + journal" do
      prompt = LanguageSpec.get(:explicit_journal)
      assert is_binary(prompt)
      assert String.contains?(prompt, "<role>")
      assert String.contains?(prompt, "<state>")
      assert String.contains?(prompt, "(return answer)")
      assert String.contains?(prompt, "<journaled_tasks>")
      assert String.contains?(prompt, "<semantic_progress>")
    end

    test ":repl is standalone (no reference, no multi-turn)" do
      prompt = LanguageSpec.get(:repl)
      assert is_binary(prompt)
      assert String.contains?(prompt, "REPL")
      refute String.contains?(prompt, "<role>")
      refute String.contains?(prompt, "<state>")
    end
  end

  # ============================================================================
  # Lite variants
  # ============================================================================

  describe "lite variants" do
    test ":single_shot_lite has no reference" do
      prompt = LanguageSpec.get(:single_shot_lite)
      assert String.contains?(prompt, "<single_shot>")
      refute String.contains?(prompt, "<role>")
    end

    test ":explicit_return_lite has no reference" do
      prompt = LanguageSpec.get(:explicit_return_lite)
      assert String.contains?(prompt, "<state>")
      assert String.contains?(prompt, "(return answer)")
      refute String.contains?(prompt, "<role>")
    end

    test ":auto_return_lite has no reference" do
      prompt = LanguageSpec.get(:auto_return_lite)
      assert String.contains?(prompt, "<state>")
      assert String.contains?(prompt, "exploration turn")
      refute String.contains?(prompt, "<role>")
    end
  end

  # ============================================================================
  # Snippet access
  # ============================================================================

  describe "snippet access" do
    test "all snippet keys return content" do
      for key <- [
            :reference,
            :behavior_single_shot,
            :behavior_multi_turn,
            :behavior_return_explicit,
            :behavior_return_auto,
            :capability_journal,
            :repl
          ] do
        content = LanguageSpec.get(key)
        assert is_binary(content), "Expected #{key} to return binary, got nil"
        assert String.length(content) > 0, "Expected #{key} to have content"
      end
    end

    test "returns nil for unknown prompt" do
      assert LanguageSpec.get(:nonexistent) == nil
    end
  end

  # ============================================================================
  # Compositions build correctly from parts
  # ============================================================================

  describe "composition structure" do
    test "single_shot equals reference + behavior_single_shot" do
      ref = LanguageSpec.get(:reference)
      behavior = LanguageSpec.get(:behavior_single_shot)
      expected = ref <> "\n\n" <> behavior

      assert LanguageSpec.get(:single_shot) == expected
    end

    test "explicit_return equals reference + behavior_multi_turn + behavior_return_explicit" do
      ref = LanguageSpec.get(:reference)
      mt = LanguageSpec.get(:behavior_multi_turn)
      ret = LanguageSpec.get(:behavior_return_explicit)
      expected = ref <> "\n\n" <> mt <> "\n\n" <> ret

      assert LanguageSpec.get(:explicit_return) == expected
    end

    test "explicit_journal includes all four parts" do
      ref = LanguageSpec.get(:reference)
      mt = LanguageSpec.get(:behavior_multi_turn)
      ret = LanguageSpec.get(:behavior_return_explicit)
      journal = LanguageSpec.get(:capability_journal)
      expected = ref <> "\n\n" <> mt <> "\n\n" <> ret <> "\n\n" <> journal

      assert LanguageSpec.get(:explicit_journal) == expected
    end
  end

  # ============================================================================
  # resolve_profile/1
  # ============================================================================

  describe "resolve_profile/1" do
    test "atom delegates to get!/1" do
      assert LanguageSpec.resolve_profile(:single_shot) == LanguageSpec.get!(:single_shot)
    end

    test "tuple with reference: :full includes reference" do
      result = LanguageSpec.resolve_profile({:profile, :explicit_return, reference: :full})
      assert String.contains?(result, "<role>")
      assert String.contains?(result, "(return answer)")
    end

    test "tuple with reference: :none omits reference" do
      result = LanguageSpec.resolve_profile({:profile, :explicit_return, reference: :none})
      refute String.contains?(result, "<role>")
      assert String.contains?(result, "(return answer)")
    end

    test "tuple with journal: true includes journal" do
      result = LanguageSpec.resolve_profile({:profile, :explicit_return, journal: true})
      assert String.contains?(result, "<journaled_tasks>")
    end

    test "short form defaults to reference: :full, journal: false" do
      short = LanguageSpec.resolve_profile({:profile, :explicit_return})

      full =
        LanguageSpec.resolve_profile(
          {:profile, :explicit_return, reference: :full, journal: false}
        )

      assert short == full
    end

    test "auto_return behavior uses auto-return content" do
      result = LanguageSpec.resolve_profile({:profile, :auto_return})
      assert String.contains?(result, "exploration turn")
      refute String.contains?(result, "(return answer)")
    end

    test "single_shot behavior uses single-shot content" do
      result = LanguageSpec.resolve_profile({:profile, :single_shot})
      assert String.contains?(result, "<single_shot>")
      refute String.contains?(result, "<state>")
    end

    test "rejects single_shot + journal" do
      assert_raise ArgumentError, ~r/journal: true is not compatible/, fn ->
        LanguageSpec.resolve_profile({:profile, :single_shot, journal: true})
      end
    end

    test "rejects unknown behavior" do
      assert_raise ArgumentError, ~r/Unknown behavior/, fn ->
        LanguageSpec.resolve_profile({:profile, :unknown_behavior})
      end
    end

    test "rejects invalid reference value" do
      assert_raise ArgumentError, ~r/Unknown reference/, fn ->
        LanguageSpec.resolve_profile({:profile, :explicit_return, reference: :invalid})
      end
    end

    test "rejects unknown option keys" do
      assert_raise ArgumentError, ~r/Unknown profile options/, fn ->
        LanguageSpec.resolve_profile({:profile, :explicit_return, unknown_key: true})
      end
    end
  end

  # ============================================================================
  # get!/1
  # ============================================================================

  describe "get!/1" do
    test "returns prompt for valid key" do
      prompt = LanguageSpec.get!(:single_shot)
      assert is_binary(prompt)
    end

    test "raises for unknown prompt" do
      assert_raise ArgumentError, ~r/Unknown prompt: :nonexistent/, fn ->
        LanguageSpec.get!(:nonexistent)
      end
    end
  end

  # ============================================================================
  # list/0 and list_with_descriptions/0
  # ============================================================================

  describe "list/0" do
    test "includes canonical compositions" do
      keys = LanguageSpec.list()

      for key <- [:single_shot, :explicit_return, :auto_return, :explicit_journal, :repl] do
        assert key in keys, "Expected #{key} in list"
      end
    end

    test "includes lite variants" do
      keys = LanguageSpec.list()

      for key <- [:single_shot_lite, :explicit_return_lite, :auto_return_lite] do
        assert key in keys, "Expected #{key} in list"
      end
    end

    test "includes snippet keys" do
      keys = LanguageSpec.list()

      for key <- [
            :reference,
            :behavior_single_shot,
            :behavior_multi_turn,
            :behavior_return_explicit,
            :behavior_return_auto,
            :capability_journal,
            :repl
          ] do
        assert key in keys, "Expected #{key} in list"
      end
    end
  end

  describe "list_with_descriptions/0" do
    test "returns list of {key, description} tuples" do
      items = LanguageSpec.list_with_descriptions()
      assert is_list(items)

      for {key, desc} <- items do
        assert is_atom(key)
        assert is_binary(desc)
      end

      assert Enum.any?(items, fn {key, _} -> key == :single_shot end)
      assert Enum.any?(items, fn {key, _} -> key == :explicit_return end)
    end
  end

  # ============================================================================
  # version/1 and metadata/1
  # ============================================================================

  describe "version/1" do
    test "returns a positive integer for reference" do
      version = LanguageSpec.version(:reference)
      assert is_integer(version)
      assert version >= 1
    end

    test "canonical compositions return version of their first component" do
      ref_v = LanguageSpec.version(:reference)
      assert LanguageSpec.version(:single_shot) == ref_v
      assert LanguageSpec.version(:explicit_return) == ref_v
    end

    test "raises for unknown prompt" do
      assert_raise ArgumentError, ~r/Unknown prompt: :nonexistent/, fn ->
        LanguageSpec.version(:nonexistent)
      end
    end
  end

  describe "metadata/1" do
    test "returns metadata for reference" do
      meta = LanguageSpec.metadata(:reference)
      assert is_map(meta)
    end

    test "raises for unknown prompt" do
      assert_raise ArgumentError, ~r/Unknown prompt: :nonexistent/, fn ->
        LanguageSpec.metadata(:nonexistent)
      end
    end
  end
end
