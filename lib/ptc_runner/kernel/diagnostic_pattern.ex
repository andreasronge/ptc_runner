defmodule PtcRunner.Kernel.DiagnosticPattern do
  @moduledoc false

  # JSON Schema `pattern` is ECMA-262, not PCRE. `Regex.escape/1` escapes every
  # non-word character — spaces included — which PCRE accepts and a strict
  # ECMA-262 engine rejects, so a message built from prose needs an escaper that
  # touches only the metacharacters. Keeping it here means the diagnostic
  # modules that publish message patterns share one definition of "safe".

  @metacharacters ["\\", "^", "$", ".", "|", "?", "*", "+", "(", ")", "[", "]", "{", "}"]

  @doc "Escapes the ECMA-262 metacharacters in a literal message fragment."
  @spec escape(binary()) :: binary()
  def escape(text) when is_binary(text) do
    text
    |> String.graphemes()
    |> Enum.map_join(fn character ->
      if character in @metacharacters, do: "\\" <> character, else: character
    end)
  end

  @doc """
  Anchors a body so it matches one complete message and nothing longer.

  The trailing lookahead is what makes the anchor exact: `$` alone also matches
  before a final newline, which would admit a message carrying an appended line.
  """
  @spec exact(binary()) :: binary()
  def exact(body) when is_binary(body), do: "^" <> body <> "$(?![\\s\\S])"

  @doc false
  @spec valid_exact_integer_message?(
          binary(),
          binary(),
          binary(),
          pos_integer(),
          (integer() -> {:ok, binary()} | :error)
        ) :: boolean()
  def valid_exact_integer_message?(message, prefix, suffix, maximum_digits, builder)
      when is_binary(message) and is_binary(prefix) and is_binary(suffix) and
             is_integer(maximum_digits) and maximum_digits > 0 and is_function(builder, 1) do
    with true <- String.starts_with?(message, prefix),
         true <- String.ends_with?(message, suffix),
         digits_bytes <- byte_size(message) - byte_size(prefix) - byte_size(suffix),
         true <- digits_bytes in 1..maximum_digits,
         digits <- binary_part(message, byte_size(prefix), digits_bytes),
         {value, ""} <- Integer.parse(digits),
         true <- Integer.to_string(value) == digits,
         {:ok, expected} <- builder.(value) do
      message == expected
    else
      _invalid -> false
    end
  end

  def valid_exact_integer_message?(_message, _prefix, _suffix, _maximum_digits, _builder),
    do: false
end
