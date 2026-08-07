defmodule PtcRunner.Lisp.Runtime.Json do
  @moduledoc """
  JSON parsing and generation for PTC-Lisp.

  Implements `(json/parse-string s)`, `(json/parse-lines s)`, and
  `(json/generate-string v)` — Cheshire-shaped builtins.

  The two directions signal differently, following spec rule 4 (properties
  of input data may signal; properties of the program raise):

    * Parse helpers take **external** text and return `nil` on failure
      rather than raising (DIV-23) — bad input is a recoverable condition.
    * `generate-string` is handed a value the **program itself** built, so a
      value with no JSON encoding is a program fault. It returns a string or
      raises a named `type_error` locating the offending position (DIV-24).
      It never returns `nil`; a silent `nil` is indistinguishable from an
      empty encoding once `str` concatenates it (#1165).

  Generated JSON objects use string keys: keyword keys encode as their name
  and integer keys as their decimal text. Keyword *values*, sets, tuples, and
  non-finite floats have no JSON encoding and are refused.
  """

  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.Keyword, as: LispKeyword

  # `Eval.Apply` turns any RuntimeError raised by a builtin into a
  # `:type_error`, prefixing the rendered message itself — so the prefix is
  # deliberately absent here.
  @prefix "json/generate-string: "
  @keyword_hint "JSON has no keyword type — convert it first with (name x) or (str x)."

  # A refusal message locates the fault; it is not a rendering of the value.
  @max_path_steps 8
  @max_step_bytes 48

  @doc """
  Parse a JSON string into an Elixir value.

  Returns the parsed value on success; `nil` on any failure
  (invalid JSON, non-binary input, `nil` input). Map keys are
  decoded as **strings** (no atom keys) to avoid atom memory
  leaks on untrusted input.

  ## Examples

      iex> PtcRunner.Lisp.Runtime.Json.parse_string(~S|{"a": 1, "b": [2, 3]}|)
      %{"a" => 1, "b" => [2, 3]}

      iex> PtcRunner.Lisp.Runtime.Json.parse_string("[1, 2, 3]")
      [1, 2, 3]

      iex> PtcRunner.Lisp.Runtime.Json.parse_string("null")
      nil

      iex> PtcRunner.Lisp.Runtime.Json.parse_string("not json")
      nil

      iex> PtcRunner.Lisp.Runtime.Json.parse_string(nil)
      nil

      iex> PtcRunner.Lisp.Runtime.Json.parse_string(42)
      nil
  """
  @spec parse_string(term()) :: term() | nil
  def parse_string(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, value} -> value
      {:error, _} -> nil
    end
  rescue
    # Defensive: Jason.decode/1 should not raise on string input, but
    # the sandbox boundary requires a hard guarantee per DIV-23.
    _ -> nil
  end

  def parse_string(_), do: nil

  @doc """
  Parse line-delimited JSON into a list.

  Blank or whitespace-only lines are skipped. Each remaining line is
  parsed with `parse_string/1`, so malformed lines and valid JSON
  literal `null` lines both produce `nil`.

  ## Examples

      iex> PtcRunner.Lisp.Runtime.Json.parse_lines("{\\"a\\":1}\\n[2,3]\\n")
      [%{"a" => 1}, [2, 3]]

      iex> PtcRunner.Lisp.Runtime.Json.parse_lines("null\\nnot json\\n")
      [nil, nil]

      iex> PtcRunner.Lisp.Runtime.Json.parse_lines("  \\n{\\"ok\\":true}\\n")
      [%{"ok" => true}]

      iex> PtcRunner.Lisp.Runtime.Json.parse_lines(42)
      nil
  """
  @spec parse_lines(term()) :: [term()] | nil
  def parse_lines(s) when is_binary(s) do
    s
    |> String.split(~r/\r\n|\n|\r/)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.map(&parse_string/1)
  rescue
    _ -> nil
  end

  def parse_lines(_), do: nil

  @doc """
  Encode an Elixir value as a JSON string.

  Returns the encoded string, or raises a `type_error` naming the position
  that has no JSON encoding. It never returns `nil` — see the module doc.

  A conversion walk runs *before* `Jason.encode/1`, because `Jason` would
  otherwise coerce non-boolean atoms (e.g. the PTC-Lisp keyword `:fs`) into
  JSON strings on its own, eroding the wire-boundary type signal.

  Keys become JSON strings: a string key is used as-is, an integer key
  becomes its decimal text, and a keyword key becomes its name **verbatim**
  — no hyphen-to-underscore normalization, so `:max-turns` encodes as
  `"max-turns"` and never silently renames a key. Two keys that would encode
  to the same JSON key are refused rather than emitted as a duplicate.

  ## Examples

      iex> PtcRunner.Lisp.Runtime.Json.generate_string(nil)
      "null"

      iex> PtcRunner.Lisp.Runtime.Json.generate_string([1, 2, 3])
      "[1,2,3]"

      iex> PtcRunner.Lisp.Runtime.Json.generate_string("hello")
      "\\"hello\\""

      iex> PtcRunner.Lisp.Runtime.Json.generate_string(%{:server => "fs"})
      "{\\"server\\":\\"fs\\"}"

      iex> PtcRunner.Lisp.Runtime.Json.generate_string(%{1 => "a"})
      "{\\"1\\":\\"a\\"}"

      iex> PtcRunner.Lisp.Runtime.Json.generate_string(%{"server" => :fs})
      ** (RuntimeError) json/generate-string: cannot encode a keyword as a JSON value at ["server"]. JSON has no keyword type — convert it first with (name x) or (str x).
  """
  @spec generate_string(term()) :: String.t()
  def generate_string(value) do
    case encode(prepare(value, [])) do
      {:ok, json} -> json
      :error -> raise @prefix <> "the value has no JSON encoding."
    end
  end

  # Isolated so its rescue can only ever swallow a `Jason` fault — the
  # sandbox may not surface a foreign exception — and never a refusal
  # raised by `prepare/2`.
  defp encode(prepared) do
    case Jason.encode(prepared) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> :error
    end
  rescue
    # Defensive: `prepare/2` should rule out every Jason raise path.
    _ -> :error
  end

  # ----------------------------------------------------------------
  # Conversion walk
  #
  # Returns a Jason-ready value or raises. `path` accumulates the steps
  # taken to reach the current position, innermost first.
  #
  # Key handling is deliberately more permissive than value handling: a
  # JSON key is always a string, so stringifying a keyword key loses no
  # type signal JSON could have carried. A keyword *value* would lose one,
  # so it is refused.
  # ----------------------------------------------------------------

  defp prepare(value, path) when is_binary(value), do: valid_utf8!(value, path, "value")
  defp prepare(value, _path) when is_number(value), do: value
  defp prepare(value, _path) when is_boolean(value) or is_nil(value), do: value
  defp prepare(value, path) when is_atom(value), do: refuse_value(value, path)
  defp prepare(%LispKeyword{} = value, path), do: refuse_value(value, path)
  defp prepare(%MapSet{} = value, path), do: refuse_value(value, path)
  defp prepare(%_{} = value, path), do: refuse_value(value, path)

  defp prepare(value, path) when is_list(value), do: prepare_list(value, path, 0, [])

  defp prepare(value, path) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, item}, acc ->
      encoded_key = prepare_key(key, path)

      acc
      |> refuse_duplicate(encoded_key, path)
      |> Map.put(encoded_key, prepare(item, [key | path]))
    end)
  end

  defp prepare(value, path), do: refuse_value(value, path)

  defp prepare_list([], _path, _index, acc), do: Enum.reverse(acc)

  defp prepare_list([item | rest], path, index, acc),
    do: prepare_list(rest, path, index + 1, [prepare(item, [index | path]) | acc])

  # Only a host caller can hand us an improper list; PTC-Lisp cannot build one.
  # Walking it here rather than through `Enum` keeps it on the refusal path
  # instead of raising an unpositioned FunctionClauseError.
  defp prepare_list(tail, path, index, _acc) do
    raise @prefix <>
            "cannot encode an improper list#{position(path)}. A JSON array needs a " <>
            "proper list; the tail at index #{index} is #{kind(tail)}."
  end

  defp prepare_key(key, path) when is_binary(key), do: valid_utf8!(key, path, "object key")
  defp prepare_key(key, _path) when is_integer(key), do: Integer.to_string(key)
  defp prepare_key(key, path) when is_boolean(key) or is_nil(key), do: refuse_key(key, path)

  # `##Inf` / `##-Inf` / `##NaN` are numbers carried as bounded atoms. Without
  # this clause the keyword branch below would stringify `##Inf` to the key
  # "infinity" — a number silently becoming a word.
  defp prepare_key(key, path) when key in [:infinity, :negative_infinity, :nan] do
    raise @prefix <>
            "cannot encode #{special_float(key)} as a JSON object key#{position(path)}. " <>
            "JSON has no infinity or NaN literal."
  end

  defp prepare_key(key, _path) when is_atom(key), do: Atom.to_string(key)

  defp prepare_key(%LispKeyword{name: name} = key, path) do
    if LispKeyword.valid?(key), do: name, else: refuse_key(key, path)
  end

  defp prepare_key(key, path), do: refuse_key(key, path)

  # ----------------------------------------------------------------
  # Refusals
  # ----------------------------------------------------------------

  defp refuse_value(value, path) when value in [:infinity, :negative_infinity, :nan] do
    raise @prefix <>
            "cannot encode #{special_float(value)} as a JSON value#{position(path)}. " <>
            "JSON has no infinity or NaN literal."
  end

  defp refuse_value(value, path) do
    raise @prefix <>
            "cannot encode #{kind(value)} as a JSON value#{position(path)}. #{hint(value)}"
  end

  defp refuse_key(key, path) do
    raise @prefix <>
            "cannot encode #{kind(key)} as a JSON object key#{position(path)}. " <>
            "JSON object keys must be strings — use a string, an integer, or a keyword."
  end

  # Jason rejects invalid UTF-8 too, but only after the walk has finished and
  # the position is gone; catching it here keeps the refusal located.
  defp valid_utf8!(text, path, position_name) do
    if String.valid?(text) do
      text
    else
      raise @prefix <>
              "cannot encode a string with invalid UTF-8 as a JSON " <>
              "#{position_name}#{position(path)}. JSON strings must be valid UTF-8."
    end
  end

  defp refuse_duplicate(acc, encoded_key, path) do
    if Map.has_key?(acc, encoded_key) do
      raise @prefix <>
              "two keys#{position(path)} both encode to the JSON key " <>
              "#{inspect(clip(encoded_key))}, which would emit a duplicate JSON object key."
    end

    acc
  end

  defp special_float(:infinity), do: "##Inf"
  defp special_float(:negative_infinity), do: "##-Inf"
  defp special_float(:nan), do: "##NaN"

  defp kind(nil), do: "nil"
  defp kind(value) when is_boolean(value), do: "a boolean"
  defp kind(value) when is_atom(value), do: "a keyword"
  defp kind(value) when is_number(value), do: "a number"
  defp kind(value) when is_binary(value), do: "a string"
  # A PTC-Lisp closure is a tuple; so are several builtin-binding shapes.
  # `Helpers.describe_type/1` names the ones it knows, closures included.
  defp kind({:closure, _, _, _, _, _}), do: "a function"

  defp kind(value) when is_tuple(value) do
    case Helpers.describe_type(value) do
      "unknown" -> "a tuple"
      described -> "a #{described}"
    end
  end

  defp kind(value) when is_pid(value), do: "a pid"
  defp kind(value) when is_reference(value), do: "a reference"
  defp kind(value) when is_function(value), do: "a function"
  defp kind(%LispKeyword{}), do: "a keyword"
  defp kind(%MapSet{}), do: "a set"
  defp kind(%_{} = value), do: "a #{Helpers.describe_type(value)}"
  defp kind(value) when is_map(value), do: "a map"
  defp kind(value) when is_list(value), do: "a list"
  # A non-byte-aligned bitstring; the binary clause above took the rest.
  defp kind(value) when is_bitstring(value), do: "a bitstring"
  # With ports, these clauses cover every BEAM term — deliberately, and the
  # compiler checks it. An unnamed term would reach `refuse_value/2`, raise
  # FunctionClauseError, and lose the position the refusal exists to report.
  defp kind(value) when is_port(value), do: "a port"

  defp hint(%LispKeyword{}), do: @keyword_hint
  defp hint(value) when is_atom(value), do: @keyword_hint
  defp hint(%MapSet{}), do: "Convert it first with (vec x)."
  defp hint(_value), do: "It has no JSON representation."

  # ----------------------------------------------------------------
  # Position rendering
  #
  # Bounded in both depth and per-step width: a refusal message is
  # diagnostic text, not a rendering of the data that failed.
  # ----------------------------------------------------------------

  defp position([]), do: " at the top level"

  defp position(path) do
    steps = Enum.reverse(path)
    rendered = steps |> Enum.take(@max_path_steps) |> Enum.map_join(" ", &step/1)
    overflow = if length(steps) > @max_path_steps, do: " …", else: ""

    " at [" <> rendered <> overflow <> "]"
  end

  defp step(step) when is_binary(step), do: inspect(clip(step))
  # Clipped like every other step: a bignum key renders as many digits as it has.
  defp step(step) when is_integer(step), do: step |> Integer.to_string() |> clip()
  defp step(%LispKeyword{name: name}), do: ":" <> clip(name)
  defp step(step) when is_atom(step), do: clip(inspect(step))
  defp step(step), do: clip(inspect(step))

  # Bounded by BYTES, not graphemes. One base character followed by a run of
  # combining marks is a single grapheme of unbounded size, so a grapheme cap
  # would let a 200 KB key through and blow the message up with it.
  defp clip(text) when byte_size(text) > @max_step_bytes do
    text |> binary_part(0, @max_step_bytes) |> trim_to_valid() |> Kernel.<>("…")
  end

  defp clip(text), do: text

  # A byte-length cut can land inside a UTF-8 sequence; drop the partial tail
  # rather than put invalid bytes in a message. At most three steps.
  defp trim_to_valid(<<>>), do: <<>>

  defp trim_to_valid(prefix) do
    if String.valid?(prefix),
      do: prefix,
      else: trim_to_valid(binary_part(prefix, 0, byte_size(prefix) - 1))
  end
end
