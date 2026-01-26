defmodule PtcRunner.Chunker do
  @moduledoc """
  Text chunking utilities for RLM preprocessing.

  Splits text into chunks by lines, characters, or approximate tokens.
  Removes chunking logic from LLM-generated code, eliminating typos
  and enabling proper tokenization.

  ## Examples

      iex> PtcRunner.Chunker.by_lines("a\\nb\\nc\\nd", 2)
      ["a\\nb", "c\\nd"]

      iex> PtcRunner.Chunker.by_chars("hello world", 5)
      ["hello", " worl", "d"]

      iex> PtcRunner.Chunker.by_tokens("hello world test", 2)
      ["hello wo", "rld test"]

  ## Options

  All functions accept these options:

  - `:overlap` - sliding window overlap (default: 0)
  - `:metadata` - return maps with `%{text, index, lines, chars, tokens}` (default: false)

  `by_tokens/3` also accepts:

  - `:tokenizer` - `:simple` (4 chars/token) or a custom function (default: `:simple`)
  """

  @type chunk :: String.t()
  @type chunk_with_metadata :: %{
          text: String.t(),
          index: non_neg_integer(),
          lines: non_neg_integer(),
          chars: non_neg_integer(),
          tokens: non_neg_integer()
        }
  @type result :: [chunk()] | [chunk_with_metadata()]

  @type lines_opt :: {:overlap, non_neg_integer()} | {:metadata, boolean()}
  @type chars_opt :: {:overlap, non_neg_integer()} | {:metadata, boolean()}
  @type tokens_opt ::
          {:overlap, non_neg_integer()}
          | {:metadata, boolean()}
          | {:tokenizer, :simple | :cl100k | (String.t() -> non_neg_integer())}

  @doc """
  Splits text into chunks by line count.

  ## Examples

      iex> PtcRunner.Chunker.by_lines("a\\nb\\nc\\nd\\ne", 2)
      ["a\\nb", "c\\nd", "e"]

      iex> PtcRunner.Chunker.by_lines("a\\nb\\nc\\nd", 2, overlap: 1)
      ["a\\nb", "b\\nc", "c\\nd"]

      iex> PtcRunner.Chunker.by_lines(nil, 10)
      []

      iex> PtcRunner.Chunker.by_lines("", 10)
      []

      iex> PtcRunner.Chunker.by_lines("short", 100)
      ["short"]

  """
  @spec by_lines(String.t() | nil, pos_integer()) :: result()
  @spec by_lines(String.t() | nil, pos_integer(), [lines_opt()]) :: result()
  def by_lines(text, n, opts \\ [])

  def by_lines(nil, _n, _opts), do: []
  def by_lines("", _n, _opts), do: []

  def by_lines(text, n, opts) when is_binary(text) and is_integer(n) do
    validate_opts!(n, opts)

    overlap = Keyword.get(opts, :overlap, 0)
    metadata? = Keyword.get(opts, :metadata, false)
    step = n - overlap

    lines = String.split(text, ~r/\r?\n/)

    line_chunks =
      lines
      |> Enum.chunk_every(n, step, [])
      |> Enum.reject(&(&1 == []))
      |> drop_trailing_overlap_chunks(overlap)

    if metadata? do
      line_chunks
      |> Enum.with_index()
      |> Enum.map(fn {line_list, index} ->
        chunk_text = Enum.join(line_list, "\n")

        %{
          text: chunk_text,
          index: index,
          lines: length(line_list),
          chars: String.length(chunk_text),
          tokens: estimate_tokens(chunk_text, :simple)
        }
      end)
    else
      Enum.map(line_chunks, &Enum.join(&1, "\n"))
    end
  end

  @doc """
  Splits text into chunks by character count.

  Uses `String.graphemes/1` for unicode-safe splitting.

  ## Examples

      iex> PtcRunner.Chunker.by_chars("hello world", 5)
      ["hello", " worl", "d"]

      iex> PtcRunner.Chunker.by_chars("abcdef", 3, overlap: 1)
      ["abc", "cde", "ef"]

      iex> PtcRunner.Chunker.by_chars(nil, 10)
      []

      iex> PtcRunner.Chunker.by_chars("", 10)
      []

      iex> PtcRunner.Chunker.by_chars("hi", 100)
      ["hi"]

  """
  @spec by_chars(String.t() | nil, pos_integer()) :: result()
  @spec by_chars(String.t() | nil, pos_integer(), [chars_opt()]) :: result()
  def by_chars(text, n, opts \\ [])

  def by_chars(nil, _n, _opts), do: []
  def by_chars("", _n, _opts), do: []

  def by_chars(text, n, opts) when is_binary(text) and is_integer(n) do
    validate_opts!(n, opts)

    overlap = Keyword.get(opts, :overlap, 0)
    metadata? = Keyword.get(opts, :metadata, false)
    step = n - overlap

    graphemes = String.graphemes(text)

    char_chunks =
      graphemes
      |> Enum.chunk_every(n, step, [])
      |> Enum.reject(&(&1 == []))
      |> drop_trailing_overlap_chunks(overlap)

    if metadata? do
      char_chunks
      |> Enum.with_index()
      |> Enum.map(fn {grapheme_list, index} ->
        chunk_text = Enum.join(grapheme_list)

        %{
          text: chunk_text,
          index: index,
          lines: count_lines(chunk_text),
          chars: String.length(chunk_text),
          tokens: estimate_tokens(chunk_text, :simple)
        }
      end)
    else
      Enum.map(char_chunks, &Enum.join/1)
    end
  end

  @doc """
  Splits text into chunks by approximate token count.

  Uses a tokenizer to estimate token count. The default `:simple` tokenizer
  uses 4 characters per token heuristic.

  ## Examples

      iex> PtcRunner.Chunker.by_tokens("hello world test", 2)
      ["hello wo", "rld test"]

      iex> PtcRunner.Chunker.by_tokens("abcdefghijklmnop", 2, overlap: 1)
      ["abcdefgh", "efghijkl", "ijklmnop"]

      iex> PtcRunner.Chunker.by_tokens(nil, 10)
      []

      iex> PtcRunner.Chunker.by_tokens("", 10)
      []

      iex> PtcRunner.Chunker.by_tokens("hi", 100)
      ["hi"]

  Custom tokenizer example:

      iex> tokenizer = fn text -> div(String.length(text), 2) end
      iex> PtcRunner.Chunker.by_tokens("abcdefgh", 2, tokenizer: tokenizer)
      ["abcd", "efgh"]

  """
  @spec by_tokens(String.t() | nil, pos_integer()) :: result()
  @spec by_tokens(String.t() | nil, pos_integer(), [tokens_opt()]) :: result()
  def by_tokens(text, n, opts \\ [])

  def by_tokens(nil, _n, _opts), do: []
  def by_tokens("", _n, _opts), do: []

  def by_tokens(text, n, opts) when is_binary(text) and is_integer(n) do
    validate_opts!(n, opts)

    tokenizer = Keyword.get(opts, :tokenizer, :simple)
    overlap = Keyword.get(opts, :overlap, 0)
    metadata? = Keyword.get(opts, :metadata, false)

    {char_chunk_size, char_overlap} = tokens_to_chars(n, overlap, tokenizer)

    char_opts = [overlap: char_overlap, metadata: metadata?]

    if metadata? do
      # Re-estimate tokens with actual tokenizer for metadata
      by_chars(text, char_chunk_size, char_opts)
      |> Enum.map(fn chunk ->
        %{chunk | tokens: estimate_tokens(chunk.text, tokenizer)}
      end)
    else
      by_chars(text, char_chunk_size, char_opts)
    end
  end

  # Convert token counts to character counts based on tokenizer
  defp tokens_to_chars(token_count, token_overlap, :simple) do
    # Simple tokenizer: 4 chars per token
    {token_count * 4, token_overlap * 4}
  end

  defp tokens_to_chars(_token_count, _token_overlap, :cl100k) do
    raise ArgumentError,
          ":cl100k tokenizer not yet implemented, use :simple or provide custom function"
  end

  defp tokens_to_chars(token_count, token_overlap, tokenizer) when is_function(tokenizer, 1) do
    # Estimate chars-per-token by testing with a sample string (returns float)
    chars_per_token = estimate_chars_per_token(tokenizer)
    # Round to integers for chunk sizes
    {round(token_count * chars_per_token), round(token_overlap * chars_per_token)}
  end

  defp estimate_chars_per_token(tokenizer) do
    # Use a sample string to estimate the chars-per-token ratio
    # Returns float for precision
    sample = "The quick brown fox jumps over the lazy dog."
    sample_length = String.length(sample)
    token_count = tokenizer.(sample)

    if token_count > 0 do
      sample_length / token_count
    else
      # Fallback to simple heuristic
      4.0
    end
  end

  defp estimate_tokens(text, :simple) do
    # Simple: ~4 characters per token
    div(String.length(text), 4)
  end

  # Note: :cl100k raises in tokens_to_chars/3 before reaching here

  defp estimate_tokens(text, tokenizer) when is_function(tokenizer, 1) do
    result = tokenizer.(text)

    if is_integer(result) do
      result
    else
      # Ensure integer result
      ceil(result)
    end
  end

  defp count_lines(text) do
    text
    |> String.split(~r/\r?\n/)
    |> length()
  end

  # Drop trailing partial chunks that are entirely within the previous chunk.
  # A chunk with length <= overlap contains only data already in the previous chunk.
  # Never drop the first chunk (handles single-chunk case).
  defp drop_trailing_overlap_chunks(chunks, 0), do: chunks
  defp drop_trailing_overlap_chunks([], _overlap), do: []
  defp drop_trailing_overlap_chunks([first], _overlap), do: [first]

  defp drop_trailing_overlap_chunks([first | rest], overlap) do
    cleaned_rest =
      rest
      |> Enum.reverse()
      |> Enum.drop_while(&(length(&1) <= overlap))
      |> Enum.reverse()

    [first | cleaned_rest]
  end

  defp validate_opts!(chunk_size, opts) do
    if chunk_size <= 0 do
      raise ArgumentError, "chunk_size must be positive, got: #{chunk_size}"
    end

    overlap = Keyword.get(opts, :overlap, 0)

    if overlap < 0 do
      raise ArgumentError, "overlap must be non-negative, got: #{overlap}"
    end

    if overlap >= chunk_size do
      raise ArgumentError,
            "overlap must be less than chunk_size, got overlap: #{overlap}, chunk_size: #{chunk_size}"
    end

    :ok
  end
end
