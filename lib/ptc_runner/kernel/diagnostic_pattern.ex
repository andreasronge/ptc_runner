defmodule PtcRunner.Kernel.DiagnosticPattern do
  @moduledoc false

  # A template is a list of literal segments and named typed slots:
  # {:slot, name, :integer | :text, ecma262_pattern}. Rendered text, parser
  # captures, and schema patterns all come from these same segments. Callers
  # keep domain checks (relationships, canonical lists, and disclosure policy)
  # in their builders and pass those builders to valid_template?/3.
  @type segment ::
          {:literal, binary()} | {:slot, atom(), :integer | :text, binary()}
  @type template :: [segment()]

  @doc "Renders trusted, already domain-validated values through a template."
  @spec render(template(), map()) :: binary()
  def render(parts, values) do
    Enum.map_join(parts, fn
      {:literal, text} -> text
      {:slot, name, :integer, _pattern} -> Integer.to_string(Map.fetch!(values, name))
      {:slot, name, :text, _pattern} -> Map.fetch!(values, name)
    end)
  end

  @doc "Derives the unanchored ECMA-262 pattern from a template."
  @spec body(template()) :: binary()
  def body(parts) do
    Enum.map_join(parts, fn
      {:literal, text} -> escape(text)
      {:slot, _name, _type, pattern} -> pattern
    end)
  end

  @doc """
  Parses bounded slot syntax, retaining canonical integer spelling.

  Pass `"u"` for codecs whose pattern widths count Unicode codepoints.
  The default retains byte-oriented parsing for ASCII diagnostic grammars.
  """
  @spec parse(template(), term(), binary()) :: {:ok, map()} | :error
  def parse(parts, message, regex_options \\ "")

  def parse(parts, message, regex_options) when is_binary(message) do
    source =
      Enum.map_join(parts, fn
        {:literal, text} -> escape(text)
        {:slot, name, _type, pattern} -> "(?<#{name}>#{pattern})"
      end)

    case Regex.named_captures(Regex.compile!(exact(source), regex_options), message) do
      nil -> :error
      captures -> decode_slots(parts, captures)
    end
  end

  def parse(_parts, _message, _regex_options), do: :error

  @doc "Validates syntax and canonical output using the domain builder."
  @spec valid_template?(template(), term(), (map() -> {:ok, binary()} | :error)) :: boolean()
  def valid_template?(parts, message, builder) do
    case parse(parts, message) do
      {:ok, values} -> builder.(values) == {:ok, message}
      :error -> false
    end
  end

  defp decode_slots(parts, captures) do
    Enum.reduce_while(parts, {:ok, %{}}, fn
      {:literal, _text}, result ->
        {:cont, result}

      {:slot, name, type, _pattern}, {:ok, values} ->
        text = Map.fetch!(captures, Atom.to_string(name))

        case decode_slot(type, text) do
          {:ok, value} -> {:cont, {:ok, Map.put(values, name, value)}}
          :error -> {:halt, :error}
        end
    end)
  end

  defp decode_slot(:text, text), do: {:ok, text}

  defp decode_slot(:integer, text) do
    case Integer.parse(text) do
      {value, ""} -> if Integer.to_string(value) == text, do: {:ok, value}, else: :error
      _invalid -> :error
    end
  end

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

  @doc """
  Publishes one bounded message as an exact JSON Schema string branch.

  `parts` is the same typed template used by the renderer and parser.
  Only literal segments are escaped. Slot patterns describe syntax; domain
  relationships are enforced by the builder during admission.
  """
  @spec exact_message_schema(pos_integer(), template()) :: map()
  def exact_message_schema(maximum_bytes, parts)
      when is_integer(maximum_bytes) and maximum_bytes > 0 and is_list(parts) do
    %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => maximum_bytes,
      "pattern" => exact(body(parts))
    }
  end
end
