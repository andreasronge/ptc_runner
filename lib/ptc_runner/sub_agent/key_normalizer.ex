defmodule PtcRunner.SubAgent.KeyNormalizer do
  @moduledoc """
  Normalizes map keys at the tool boundary.

  Two related concerns live here:

  1. **Hyphen → underscore key normalization** (`normalize_keys/1`,
     `normalize_key/1`). PTC-Lisp uses Clojure conventions where LLMs
     naturally write hyphenated keywords (e.g., `:was-improved`).
     Elixir/JSON conventions use underscores. This is a one-way conversion
     applied at the LLM-output boundary.

  2. **Canonical cache key construction** (`canonical_cache_key/2`).
     A deterministic, layer-agnostic cache key so native app-tool calls and
     PTC-Lisp `(tool/...)` calls share cache entries regardless of how the
     args arrived. See the function docstring for the full rule list.
  """

  @doc """
  Recursively normalize map keys from hyphens to underscores.

  Converts Clojure-style `:was-improved` to Elixir-style `"was_improved"`.
  Works recursively on nested maps and lists.

  ## Examples

      iex> PtcRunner.SubAgent.KeyNormalizer.normalize_keys(%{"was-improved" => true})
      %{"was_improved" => true}

      iex> PtcRunner.SubAgent.KeyNormalizer.normalize_keys(%{nested: %{"foo-bar" => 1}})
      %{"nested" => %{"foo_bar" => 1}}

      iex> PtcRunner.SubAgent.KeyNormalizer.normalize_keys([%{"list-item" => 1}])
      [%{"list_item" => 1}]

  """
  @spec normalize_keys(term()) :: term()
  def normalize_keys(%_{} = value), do: value

  def normalize_keys(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {normalize_key(k), normalize_keys(v)} end)
  end

  def normalize_keys(value) when is_list(value) do
    Enum.map(value, &normalize_keys/1)
  end

  def normalize_keys(value), do: value

  @doc """
  Normalize a single key from hyphen to underscore format.

  ## Examples

      iex> PtcRunner.SubAgent.KeyNormalizer.normalize_key(:"was-improved")
      "was_improved"

      iex> PtcRunner.SubAgent.KeyNormalizer.normalize_key("foo-bar")
      "foo_bar"

      iex> PtcRunner.SubAgent.KeyNormalizer.normalize_key(:no_hyphens)
      "no_hyphens"

  """
  @spec normalize_key(atom() | binary() | term()) :: binary() | term()
  def normalize_key(k) when is_atom(k), do: k |> Atom.to_string() |> String.replace("-", "_")
  def normalize_key(k) when is_binary(k), do: String.replace(k, "-", "_")
  def normalize_key(k), do: k

  @doc """
  Build a deterministic cache key shared between native app-tool calls and
  PTC-Lisp `(tool/...)` calls.

  Returns `{tool_name, normalized_args}` where `normalized_args` is the
  recursive canonical form of `args`. Two semantically equivalent inputs
  (different insertion order, atom vs string keys, integer-equal floats vs
  integers) produce keys that compare equal with `==`.

  This function intentionally widens equivalence classes vs naive
  `{tool_name, args}` keying. It is the single source of truth for cache
  identity across Tier 2b native calls and PTC-Lisp's `(tool/...)` cache
  path; both layers reach the same cache entry whenever the call is
  semantically identical.

  ## Normalization rules

  Applied recursively to every value in `args`:

  1. **Map keys** — converted to strings (`:foo` → `"foo"`). Atom keys and
     string keys collapse to the same canonical form.
  2. **Maps** — Elixir maps are structurally compared regardless of
     insertion order, so two maps with the same string-keyed entries
     produced from differently-ordered inputs are `==`.
  3. **Numbers** — integer-equal floats collapse to integers
     (`1.0` → `1`, `2.0e0` → `2`, `0.0` → `0`). Non-integer floats stay
     floats (`1.5` stays `1.5`). NaN and infinity are out of scope: they
     pass through unchanged because `trunc/1` raises on them; do not pass
     them in via tool args.
  4. **Lists** — recurse into elements; order is preserved.
  5. **Tuples** — recurse into elements; order is preserved. Tuples don't
     normally appear in JSON-decoded args but PTC-Lisp call paths may
     produce them.
  6. **Strings, booleans, `nil`, atoms (other than nil/true/false)** —
     unchanged for values. Atom-keyed maps are converted by rule 1; atom
     **values** stay atoms.

  ## Examples

      iex> PtcRunner.SubAgent.KeyNormalizer.canonical_cache_key("search", %{q: "x"})
      {"search", %{"q" => "x"}}

      # Atom and string keys converge.
      iex> a = PtcRunner.SubAgent.KeyNormalizer.canonical_cache_key("t", %{foo: 1})
      iex> b = PtcRunner.SubAgent.KeyNormalizer.canonical_cache_key("t", %{"foo" => 1})
      iex> a == b
      true

      # Integer-equal floats collapse to integers.
      iex> PtcRunner.SubAgent.KeyNormalizer.canonical_cache_key("t", %{n: 1.0})
      {"t", %{"n" => 1}}

      # Non-integer floats stay floats.
      iex> PtcRunner.SubAgent.KeyNormalizer.canonical_cache_key("t", %{n: 1.5})
      {"t", %{"n" => 1.5}}

      # Nested maps and lists recurse.
      iex> PtcRunner.SubAgent.KeyNormalizer.canonical_cache_key("t", %{xs: [%{a: 1.0}, %{a: 2.0}]})
      {"t", %{"xs" => [%{"a" => 1}, %{"a" => 2}]}}

  """
  @spec canonical_cache_key(String.t(), map()) :: {String.t(), map()}
  def canonical_cache_key(tool_name, args) when is_binary(tool_name) and is_map(args) do
    {tool_name, canonicalize(args)}
  end

  # Maps: stringify keys, recurse into values. Insertion order is irrelevant
  # for Elixir map equality, so no explicit sort is needed at the value level.
  defp canonicalize(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {k, v} -> {stringify_key(k), canonicalize(v)} end)
  end

  defp canonicalize(value) when is_list(value) do
    Enum.map(value, &canonicalize/1)
  end

  defp canonicalize(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&canonicalize/1)
    |> List.to_tuple()
  end

  # Float collapse: integer-equal floats become integers. BEAM does not
  # natively produce NaN or infinity floats from ordinary arithmetic
  # (those operations raise `ArithmeticError`), so any float that reaches
  # this function is finite and `trunc/1` is safe. We still defensively
  # rescue in case a foreign-source float (e.g. decoded from a NIF) sneaks
  # in — pass it through unchanged rather than crash the cache layer.
  defp canonicalize(value) when is_float(value) do
    if trunc(value) == value, do: trunc(value), else: value
  rescue
    ArithmeticError -> value
  end

  defp canonicalize(value), do: value

  defp stringify_key(k) when is_binary(k), do: k
  defp stringify_key(k) when is_atom(k), do: Atom.to_string(k)
  defp stringify_key(k), do: k
end
