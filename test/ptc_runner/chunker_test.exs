defmodule PtcRunner.ChunkerTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Chunker

  doctest PtcRunner.Chunker

  describe "by_lines/2,3" do
    test "chunks text by line count" do
      text = "a\nb\nc\nd\ne"
      assert Chunker.by_lines(text, 2) == ["a\nb", "c\nd", "e"]
    end

    test "preserves partial last chunk" do
      # 2005 lines chunked by 2000 should produce 2 chunks, not 1
      text = String.duplicate("line\n", 2005) |> String.trim_trailing()
      chunks = Chunker.by_lines(text, 2000)
      assert length(chunks) == 2

      # Verify first chunk has 2000 lines, second has 5
      first_lines = chunks |> Enum.at(0) |> String.split("\n") |> length()
      second_lines = chunks |> Enum.at(1) |> String.split("\n") |> length()
      assert first_lines == 2000
      assert second_lines == 5
    end

    test "handles overlap" do
      text = "a\nb\nc\nd"
      assert Chunker.by_lines(text, 2, overlap: 1) == ["a\nb", "b\nc", "c\nd"]
    end

    test "preserves single chunk with overlap (no data loss)" do
      # Bug fix: single chunk should never be dropped even if length <= overlap
      assert Chunker.by_lines("a", 2, overlap: 1) == ["a"]
      assert Chunker.by_lines("a\nb", 3, overlap: 2) == ["a\nb"]
    end

    test "drops all redundant trailing chunks with large overlap" do
      # Bug fix: with overlap=2, multiple trailing chunks can be redundant
      text = "a\nb\nc\nd"
      # n=3, overlap=2, step=1 produces: [["a","b","c"], ["b","c","d"], ["c","d"], ["d"]]
      # Both ["c","d"] and ["d"] are redundant
      chunks = Chunker.by_lines(text, 3, overlap: 2)
      assert chunks == ["a\nb\nc", "b\nc\nd"]
    end

    test "returns empty list for nil" do
      assert Chunker.by_lines(nil, 10) == []
    end

    test "returns empty list for empty string" do
      assert Chunker.by_lines("", 10) == []
    end

    test "returns single chunk when input smaller than chunk size" do
      assert Chunker.by_lines("short", 100) == ["short"]
    end

    test "handles CRLF line endings" do
      text = "a\r\nb\r\nc\r\nd"
      assert Chunker.by_lines(text, 2) == ["a\nb", "c\nd"]
    end

    test "preserves empty lines in the middle" do
      text = "a\n\nb\nc"
      chunks = Chunker.by_lines(text, 2)
      assert chunks == ["a\n", "b\nc"]
    end

    test "returns metadata when requested" do
      text = "hello\nworld\ntest"
      [first, second] = Chunker.by_lines(text, 2, metadata: true)

      assert first == %{
               text: "hello\nworld",
               index: 0,
               lines: 2,
               chars: 11,
               tokens: 2
             }

      assert second == %{
               text: "test",
               index: 1,
               lines: 1,
               chars: 4,
               tokens: 1
             }
    end

    test "raises on invalid chunk_size" do
      assert_raise ArgumentError, ~r/chunk_size must be positive/, fn ->
        Chunker.by_lines("text", 0)
      end

      assert_raise ArgumentError, ~r/chunk_size must be positive/, fn ->
        Chunker.by_lines("text", -1)
      end
    end

    test "raises on invalid overlap" do
      assert_raise ArgumentError, ~r/overlap must be non-negative/, fn ->
        Chunker.by_lines("text", 2, overlap: -1)
      end

      assert_raise ArgumentError, ~r/overlap must be less than chunk_size/, fn ->
        Chunker.by_lines("text", 2, overlap: 2)
      end

      assert_raise ArgumentError, ~r/overlap must be less than chunk_size/, fn ->
        Chunker.by_lines("text", 2, overlap: 3)
      end
    end
  end

  describe "by_chars/2,3" do
    test "chunks text by character count" do
      text = "hello world"
      assert Chunker.by_chars(text, 5) == ["hello", " worl", "d"]
    end

    test "preserves partial last chunk" do
      text = "abcdefg"
      assert Chunker.by_chars(text, 3) == ["abc", "def", "g"]
    end

    test "handles overlap" do
      text = "abcdef"
      assert Chunker.by_chars(text, 3, overlap: 1) == ["abc", "cde", "ef"]
    end

    test "preserves single chunk with overlap (no data loss)" do
      # Bug fix: single chunk should never be dropped even if length <= overlap
      assert Chunker.by_chars("a", 2, overlap: 1) == ["a"]
      assert Chunker.by_chars("ab", 3, overlap: 2) == ["ab"]
    end

    test "drops all redundant trailing chunks with large overlap" do
      # Bug fix: with overlap=2, multiple trailing chunks can be redundant
      # "abcd" with n=3, overlap=2, step=1 produces:
      # [["a","b","c"], ["b","c","d"], ["c","d"], ["d"]]
      # Both ["c","d"] and ["d"] are redundant (fully contained in ["b","c","d"])
      chunks = Chunker.by_chars("abcd", 3, overlap: 2)
      assert chunks == ["abc", "bcd"]
    end

    test "returns empty list for nil" do
      assert Chunker.by_chars(nil, 10) == []
    end

    test "returns empty list for empty string" do
      assert Chunker.by_chars("", 10) == []
    end

    test "returns single chunk when input smaller than chunk size" do
      assert Chunker.by_chars("hi", 100) == ["hi"]
    end

    test "handles unicode correctly" do
      # Each emoji is one grapheme
      text = "🎉🎊🎁🎄🎅"
      chunks = Chunker.by_chars(text, 2)
      assert chunks == ["🎉🎊", "🎁🎄", "🎅"]
    end

    test "returns metadata when requested" do
      text = "hello\nworld"
      [first, second] = Chunker.by_chars(text, 6, metadata: true)

      assert first == %{
               text: "hello\n",
               index: 0,
               lines: 2,
               chars: 6,
               tokens: 1
             }

      assert second == %{
               text: "world",
               index: 1,
               lines: 1,
               chars: 5,
               tokens: 1
             }
    end

    test "raises on invalid chunk_size" do
      assert_raise ArgumentError, ~r/chunk_size must be positive/, fn ->
        Chunker.by_chars("text", 0)
      end
    end

    test "raises on invalid overlap" do
      assert_raise ArgumentError, ~r/overlap must be less than chunk_size/, fn ->
        Chunker.by_chars("text", 2, overlap: 2)
      end
    end
  end

  describe "by_tokens/2,3" do
    test "chunks text by approximate token count with simple tokenizer" do
      # Simple tokenizer: 4 chars per token
      # 2 tokens = 8 chars
      text = "hello world test"
      assert Chunker.by_tokens(text, 2) == ["hello wo", "rld test"]
    end

    test "preserves partial last chunk" do
      text = "abcdefghij"
      # 2 tokens = 8 chars, should get 2 chunks
      chunks = Chunker.by_tokens(text, 2)
      assert chunks == ["abcdefgh", "ij"]
    end

    test "scales overlap by same factor as chunk size" do
      # 2 tokens = 8 chars, overlap 1 token = 4 chars
      # step = 8 - 4 = 4 chars
      text = "abcdefghijklmnop"
      chunks = Chunker.by_tokens(text, 2, overlap: 1)
      # Chunks at positions 0-7, 4-11, 8-15
      assert chunks == ["abcdefgh", "efghijkl", "ijklmnop"]
    end

    test "returns empty list for nil" do
      assert Chunker.by_tokens(nil, 10) == []
    end

    test "returns empty list for empty string" do
      assert Chunker.by_tokens("", 10) == []
    end

    test "returns single chunk when input smaller than chunk size" do
      assert Chunker.by_tokens("hi", 100) == ["hi"]
    end

    test "supports custom tokenizer function" do
      # Custom tokenizer: 2 chars per token
      tokenizer = fn text -> div(String.length(text), 2) end
      text = "abcdefgh"
      # 2 tokens = 4 chars with this tokenizer
      chunks = Chunker.by_tokens(text, 2, tokenizer: tokenizer)
      assert chunks == ["abcd", "efgh"]
    end

    test "custom tokenizer with overlap" do
      tokenizer = fn text -> div(String.length(text), 2) end
      text = "abcdefgh"
      # Custom tokenizer: 2 chars = 1 token (chars_per_token = 2)
      # 2 tokens = 4 chars, overlap 1 token = 2 chars, step = 2 chars
      # Chunks: [0-3], [2-5], [4-7] → ["abcd", "cdef", "efgh"]
      chunks = Chunker.by_tokens(text, 2, tokenizer: tokenizer, overlap: 1)
      assert chunks == ["abcd", "cdef", "efgh"]
    end

    test "raises on :cl100k tokenizer" do
      assert_raise ArgumentError, ~r/:cl100k tokenizer not yet implemented/, fn ->
        Chunker.by_tokens("text", 10, tokenizer: :cl100k)
      end
    end

    test "returns metadata when requested" do
      text = "hello world test"
      [first, second] = Chunker.by_tokens(text, 2, metadata: true)

      assert first.text == "hello wo"
      assert first.index == 0
      assert first.chars == 8
      assert is_integer(first.tokens)
      assert is_integer(first.lines)

      assert second.text == "rld test"
      assert second.index == 1
    end

    test "metadata tokens are integers" do
      text = "hello world test again"
      chunks = Chunker.by_tokens(text, 2, metadata: true)

      for chunk <- chunks do
        assert is_integer(chunk.tokens)
      end
    end

    test "raises on invalid chunk_size" do
      assert_raise ArgumentError, ~r/chunk_size must be positive/, fn ->
        Chunker.by_tokens("text", 0)
      end
    end

    test "raises on invalid overlap" do
      assert_raise ArgumentError, ~r/overlap must be less than chunk_size/, fn ->
        Chunker.by_tokens("text", 2, overlap: 2)
      end
    end
  end

  describe "integration" do
    test "handles large corpus" do
      # Generate a large corpus
      corpus = Enum.map_join(1..10_000, "\n", &"line #{&1}")

      # Chunk by lines
      line_chunks = Chunker.by_lines(corpus, 1000)
      assert length(line_chunks) == 10

      # Chunk by chars with overlap
      char_chunks = Chunker.by_chars(corpus, 10_000, overlap: 1000)
      assert length(char_chunks) > 1

      # Chunk by tokens with metadata
      token_chunks = Chunker.by_tokens(corpus, 2500, metadata: true)
      assert length(token_chunks) > 1

      for chunk <- token_chunks do
        assert is_binary(chunk.text)
        assert is_integer(chunk.index)
        assert is_integer(chunk.lines)
        assert is_integer(chunk.chars)
        assert is_integer(chunk.tokens)
      end
    end

    test "all chunks together cover the full input for by_lines" do
      text = "a\nb\nc\nd\ne\nf\ng"
      chunks = Chunker.by_lines(text, 3)

      # Without overlap, joining chunks with \n should give original
      # But we lose the \n between chunks, so count lines instead
      all_lines =
        chunks
        |> Enum.flat_map(&String.split(&1, "\n"))
        |> length()

      original_lines = String.split(text, "\n") |> length()
      assert all_lines == original_lines
    end

    test "all chunks together cover the full input for by_chars" do
      text = "abcdefghij"
      chunks = Chunker.by_chars(text, 4)

      joined = Enum.join(chunks)
      assert joined == text
    end
  end
end
