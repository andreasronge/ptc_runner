defmodule PtcRunner.SubAgent.Loop.ResponseHandlerTruncationTest do
  @moduledoc """
  Tests for turn history result truncation in ResponseHandler.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent.Loop.ResponseHandler

  describe "truncate_for_history/2" do
    test "small values pass through unchanged" do
      assert ResponseHandler.truncate_for_history(42) == 42
      assert ResponseHandler.truncate_for_history("hello") == "hello"
      assert ResponseHandler.truncate_for_history([1, 2, 3]) == [1, 2, 3]
      assert ResponseHandler.truncate_for_history(%{a: 1, b: 2}) == %{a: 1, b: 2}
    end

    test "small nil passes through" do
      assert ResponseHandler.truncate_for_history(nil) == nil
    end

    test "large strings are truncated with ellipsis" do
      large_string = String.duplicate("x", 2000)
      result = ResponseHandler.truncate_for_history(large_string)

      assert is_binary(result)
      assert String.ends_with?(result, "...")
      # External size includes overhead, so we check actual byte_size
      assert byte_size(result) <= 1030
    end

    test "respects custom max_bytes option" do
      medium_string = String.duplicate("x", 200)
      result = ResponseHandler.truncate_for_history(medium_string, max_bytes: 100)

      assert is_binary(result)
      assert String.ends_with?(result, "...")
      # Should be truncated to ~100 bytes
      assert byte_size(result) <= 103
    end

    test "large lists are truncated to fit" do
      large_list = Enum.to_list(1..1000)
      result = ResponseHandler.truncate_for_history(large_list)

      assert is_list(result)
      assert length(result) < 1000
      # First elements should be preserved
      assert hd(result) == 1
    end

    test "large maps are truncated to fit" do
      large_map = Map.new(1..500, fn i -> {"key_#{i}", "value_#{i}"} end)
      result = ResponseHandler.truncate_for_history(large_map)

      assert is_map(result)
      assert map_size(result) < 500
    end

    test "nested structures are truncated recursively" do
      nested = %{
        large_string: String.duplicate("x", 2000),
        small_value: 42
      }

      result = ResponseHandler.truncate_for_history(nested)

      assert is_map(result)
      # The large_string should be truncated
      if Map.has_key?(result, :large_string) do
        assert String.ends_with?(result[:large_string], "...")
      end
    end

    test "preserves structure type" do
      assert is_list(ResponseHandler.truncate_for_history([1, 2, 3]))
      assert is_map(ResponseHandler.truncate_for_history(%{a: 1}))
      assert is_binary(ResponseHandler.truncate_for_history("hello"))
      assert is_number(ResponseHandler.truncate_for_history(42))
    end

    test "empty collections pass through" do
      assert ResponseHandler.truncate_for_history([]) == []
      assert ResponseHandler.truncate_for_history(%{}) == %{}
    end

    test "default limit is 1KB (1024 bytes)" do
      # Create something just under 1KB
      small = String.duplicate("x", 500)
      assert ResponseHandler.truncate_for_history(small) == small

      # Create something over 1KB
      large = String.duplicate("x", 2000)
      result = ResponseHandler.truncate_for_history(large)
      assert result != large
    end
  end
end
