defmodule PtcRunner.Lisp.Runtime.RegexTest do
  use ExUnit.Case, async: true
  alias PtcRunner.Lisp.Runtime.Regex

  # Define a local version of Regex with low limits to verify error handling logic
  defmodule LowLimitRegex do
    @match_limit 1
    @recursion_limit 1_000

    def re_find({:re_mp, mp, _, _}, s) do
      run_safe(s, mp)
    end

    defp run_safe(input, mp) do
      opts = [
        :report_errors,
        {:match_limit, @match_limit},
        {:match_limit_recursion, @recursion_limit},
        {:capture, :all, :binary}
      ]

      case :re.run(input, mp, opts) do
        {:match, [full]} ->
          full

        {:match, matches} ->
          matches

        :nomatch ->
          nil

        {:error, :match_limit} ->
          raise RuntimeError, "Regex complexity limit exceeded (ReDoS protection)"

        {:error, reason} ->
          raise RuntimeError, "Regex execution error: #{inspect(reason)}"
      end
    end
  end

  describe "re_pattern/1" do
    test "compiles valid regex" do
      assert {:re_mp, _mp, _anchored, "abc"} = Regex.re_pattern("abc")
    end

    test "fails on invalid regex" do
      assert_raise ArgumentError, ~r/Invalid regex at position/, fn ->
        Regex.re_pattern("[")
      end
    end

    test "fails on too long pattern" do
      long_pattern = String.duplicate("a", 300)

      assert_raise ArgumentError, ~r/Regex pattern exceeds maximum length/, fn ->
        Regex.re_pattern(long_pattern)
      end
    end
  end

  describe "re_find/2" do
    test "finds first match without groups" do
      re = Regex.re_pattern("\\d+")
      assert "123" == Regex.re_find(re, "abc 123 def")
    end

    test "finds first match with groups" do
      re = Regex.re_pattern("(\\d+)-(\\d+)")
      assert ["10-20", "10", "20"] == Regex.re_find(re, "range: 10-20")
    end

    test "returns nil when no match" do
      re = Regex.re_pattern("xyz")
      assert nil == Regex.re_find(re, "abc")
    end
  end

  describe "re_matches/2" do
    test "matches entire string" do
      re = Regex.re_pattern("\\d+")
      assert "123" == Regex.re_matches(re, "123")
    end

    test "returns nil on partial match" do
      re = Regex.re_pattern("\\d+")
      assert nil == Regex.re_matches(re, "123abc")
    end

    test "matches with groups" do
      re = Regex.re_pattern("(\\d+):(\\d+)")
      assert ["10:20", "10", "20"] == Regex.re_matches(re, "10:20")
    end
  end

  describe "Safety Mechanisms" do
    test "LowLimitRegex aborts on match limit" do
      # Use the exact pattern and input that worked in re_test.exs
      re = Regex.re_pattern("a+b")
      input = "aaab"

      # With match_limit 1, "a+b" on "aaab" should hit the limit
      assert_raise RuntimeError, "Regex complexity limit exceeded (ReDoS protection)", fn ->
        LowLimitRegex.re_find(re, input)
      end
    end

    test "truncates long input by bytes" do
      re = Regex.re_pattern("last")
      # Max input is 32KB (32_768 bytes).
      # We create a string that is 32_768 bytes of 'a' followed by "last".
      # Since it's truncated at exactly 32_768, "last" will be cut off.
      long_input = String.duplicate("a", 32_768) <> "last"

      assert nil == Regex.re_find(re, long_input)
    end

    test "truncates correctly with multibyte characters" do
      # Each λ is 2 bytes. 16_383 λ = 32_766 bytes.
      # Plus one 'a' = 32_767 bytes.
      # Next λ would start at 32_767 but be cut in half.
      re = Regex.re_pattern("last")
      input = String.duplicate("λ", 16_383) <> "a" <> "last"

      assert nil == Regex.re_find(re, input)
    end
  end
end
