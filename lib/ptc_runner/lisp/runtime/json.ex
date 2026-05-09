defmodule PtcRunner.Lisp.Runtime.Json do
  @moduledoc """
  JSON parsing and generation for PTC-Lisp.

  Implements `(json/parse-string s)` and `(json/generate-string v)` —
  Cheshire-shaped builtins. Both functions return `nil` on failure
  rather than raising, matching the DIV-* convention (see
  `docs/clojure-conformance-gaps.md` DIV-23, DIV-24): no try/catch
  in the sandbox means raising = unrecoverable program crash.

  See `Plans/json-support.md` §4 for the full spec, including the
  string-keyed-only round-trip property and the integer-key /
  special-float carve-outs (§4.3).
  """

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
    # the sandbox boundary requires a hard guarantee per DIV-23 / §4.4.
    _ -> nil
  end

  def parse_string(_), do: nil

  @doc """
  Encode an Elixir value as a JSON string.

  Returns the encoded string on success; `nil` on any failure
  (non-encodable input). Encoder pre-validation (per spec §4.4) runs
  *before* `Jason.encode/1` is invoked — without it, `Jason` would
  silently coerce non-boolean atoms (e.g. PTC-Lisp keywords like
  `:fs`) into JSON strings, eroding the wire-boundary type signal.

  Map keys are restricted to strings and integers — atoms (including
  `true` / `false` / `nil`), floats, and other key types fail the
  walk and produce `nil` (§4.2 / §4.3).

  ## Examples

      iex> PtcRunner.Lisp.Runtime.Json.generate_string(nil)
      "null"

      iex> PtcRunner.Lisp.Runtime.Json.generate_string([1, 2, 3])
      "[1,2,3]"

      iex> PtcRunner.Lisp.Runtime.Json.generate_string("hello")
      "\\"hello\\""

      iex> PtcRunner.Lisp.Runtime.Json.generate_string(%{"server" => :fs})
      nil

      iex> PtcRunner.Lisp.Runtime.Json.generate_string(%{:server => "fs"})
      nil

      iex> PtcRunner.Lisp.Runtime.Json.generate_string({:ok, 1})
      nil

      iex> PtcRunner.Lisp.Runtime.Json.generate_string(%{1 => "a"})
      "{\\"1\\":\\"a\\"}"
  """
  @spec generate_string(term()) :: String.t() | nil
  def generate_string(v) do
    if encodable_value?(v) do
      case Jason.encode(v) do
        {:ok, str} -> str
        {:error, _} -> nil
      end
    else
      nil
    end
  rescue
    # Defensive: pre-validation should rule out every Jason raise path,
    # but the sandbox boundary demands a hard guarantee.
    _ -> nil
  end

  # ----------------------------------------------------------------
  # Pre-validation walk (§4.4)
  #
  # Map-key validation is STRICTER than value validation: JSON only
  # accepts string keys, so atoms (including true/false/nil), floats,
  # and tuples are rejected at the key position even though some are
  # acceptable as values.
  # ----------------------------------------------------------------

  defp encodable_value?(v) when is_atom(v), do: v in [true, false, nil]
  defp encodable_value?(v) when is_binary(v), do: true
  defp encodable_value?(v) when is_number(v), do: true
  defp encodable_value?(v) when is_list(v), do: Enum.all?(v, &encodable_value?/1)

  defp encodable_value?(v) when is_map(v) do
    Enum.all?(v, fn {k, val} ->
      encodable_key?(k) and encodable_value?(val)
    end)
  end

  defp encodable_value?(_), do: false

  defp encodable_key?(k) when is_binary(k), do: true
  defp encodable_key?(k) when is_integer(k), do: true
  defp encodable_key?(_), do: false
end
