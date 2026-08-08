defmodule PtcRunner.Utf8Test do
  use ExUnit.Case, async: true

  alias PtcRunner.Utf8

  test "truncates only at a valid UTF-8 boundary" do
    assert Utf8.truncate("aéz", 4) == "aéz"
    assert Utf8.truncate("aéz", 3) == "aé"
    assert Utf8.truncate("aéz", 2) == "a"
    assert Utf8.truncate("aéz", 0) == ""
  end

  test "copies truncated prefixes out of their parent binary" do
    source = String.duplicate("a", 128 * 1_024)
    truncated = Utf8.truncate(source, 32)

    assert truncated == String.duplicate("a", 32)
    assert :binary.referenced_byte_size(truncated) == byte_size(truncated)
  end

  test "does not reinterpret an untruncated binary as validation" do
    invalid = <<255>>

    assert Utf8.truncate(invalid, 1) == invalid
  end

  test "can sanitize an invalid binary when the caller requires valid UTF-8" do
    assert Utf8.truncate_valid(<<"valid", 255, "suffix">>, 64) == "valid"
  end
end
