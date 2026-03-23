defmodule PtcRunner.Lisp.LanguageSpecTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.LanguageSpec

  doctest LanguageSpec

  # ============================================================================
  # Canonical compositions
  # ============================================================================

  describe "canonical compositions" do
    test ":single_shot contains single-shot behavior only" do
      prompt = LanguageSpec.get(:single_shot)
      assert is_binary(prompt)
      assert String.contains?(prompt, "<single_shot>")
      # No reference, no multi-turn content
      refute String.contains?(prompt, "<role>")
      refute String.contains?(prompt, "<state>")
      refute String.contains?(prompt, "<return_rules>")
    end

    test ":explicit_return contains multi-turn + explicit return" do
      prompt = LanguageSpec.get(:explicit_return)
      assert is_binary(prompt)
      assert String.contains?(prompt, "<multi_turn_rules>")
      assert String.contains?(prompt, "<state>")
      assert String.contains?(prompt, "<return_rules>")
      assert String.contains?(prompt, "(return answer)")
      # No reference, no auto-return, no journal
      refute String.contains?(prompt, "<role>")
      refute String.contains?(prompt, "exploration turn")
      refute String.contains?(prompt, "<journaled_tasks>")
    end

    test ":auto_return contains multi-turn + auto return" do
      prompt = LanguageSpec.get(:auto_return)
      assert is_binary(prompt)
      assert String.contains?(prompt, "<multi_turn_rules>")
      assert String.contains?(prompt, "<state>")
      assert String.contains?(prompt, "<return_rules>")
      assert String.contains?(prompt, "exploration turn")
      # No reference, no explicit return, no journal
      refute String.contains?(prompt, "<role>")
      refute String.contains?(prompt, "(return answer)")
      refute String.contains?(prompt, "<journaled_tasks>")
    end

    test ":explicit_journal contains multi-turn + explicit return + journal" do
      prompt = LanguageSpec.get(:explicit_journal)
      assert is_binary(prompt)
      assert String.contains?(prompt, "<state>")
      assert String.contains?(prompt, "(return answer)")
      assert String.contains?(prompt, "<journaled_tasks>")
      assert String.contains?(prompt, "<semantic_progress>")
      refute String.contains?(prompt, "<role>")
    end

    test ":minimal is standalone compact prompt" do
      prompt = LanguageSpec.get(:minimal)
      assert is_binary(prompt)
      assert String.contains?(prompt, "(return")
      refute String.contains?(prompt, "<role>")
      refute String.contains?(prompt, "<state>")
    end
  end

  # ============================================================================
  # Reference is opt-in (not included by default)
  # ============================================================================

  describe "default compositions omit reference" do
    test "canonical compositions do not include reference" do
      for key <- [:single_shot, :explicit_return, :auto_return, :explicit_journal] do
        prompt = LanguageSpec.get(key)
        refute String.contains?(prompt, "<role>"), "#{key} should not contain reference"
      end
    end

    test "reference can be added via profile" do
      result = LanguageSpec.resolve_profile({:profile, :explicit_return, reference: :full})
      assert String.contains?(result, "<role>")
      assert String.contains?(result, "(return answer)")
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
            :minimal
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
    test "single_shot equals behavior_single_shot" do
      assert LanguageSpec.get(:single_shot) == LanguageSpec.get(:behavior_single_shot)
    end

    test "explicit_return equals behavior_multi_turn + behavior_return_explicit" do
      mt = LanguageSpec.get(:behavior_multi_turn)
      ret = LanguageSpec.get(:behavior_return_explicit)
      expected = mt <> "\n\n" <> ret

      assert LanguageSpec.get(:explicit_return) == expected
    end

    test "explicit_journal includes three parts" do
      mt = LanguageSpec.get(:behavior_multi_turn)
      ret = LanguageSpec.get(:behavior_return_explicit)
      journal = LanguageSpec.get(:capability_journal)
      expected = mt <> "\n\n" <> ret <> "\n\n" <> journal

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

    test "short form defaults to reference: :none, journal: false" do
      short = LanguageSpec.resolve_profile({:profile, :explicit_return})

      explicit =
        LanguageSpec.resolve_profile(
          {:profile, :explicit_return, reference: :none, journal: false}
        )

      assert short == explicit
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

      for key <- [:single_shot, :explicit_return, :auto_return, :explicit_journal, :minimal] do
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
            :minimal
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
      ss_v = LanguageSpec.version(:behavior_single_shot)
      mt_v = LanguageSpec.version(:behavior_multi_turn)
      assert LanguageSpec.version(:single_shot) == ss_v
      assert LanguageSpec.version(:explicit_return) == mt_v
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
