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
end
