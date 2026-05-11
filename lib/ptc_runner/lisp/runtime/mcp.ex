defmodule PtcRunner.Lisp.Runtime.Mcp do
  @moduledoc """
  MCP result-envelope unwrap helpers for PTC-Lisp.

  Implements `(mcp/text r)` and `(mcp/json r)` — small, total functions
  that traverse the well-known MCP tool-result envelope shape and return
  the unwrapped value, or `nil` for anything that doesn't fit. Helpers
  are unconditional in `:ptc_runner`'s `Env.initial/0`: they live here
  rather than in `:ptc_runner_mcp` because the module has no MCP-protocol
  dependency (only shape inspection), and putting it in the MCP package
  would invert the `:ptc_runner_mcp -> :ptc_runner` dependency direction
  (see `Plans/json-support.md` §5.5).

  Both functions follow the DIV-* convention: they **never raise**.
  Failures surface as `nil` so PTC-Lisp programs without `try/catch`
  can guard cleanly.

  See `Plans/json-support.md` §5 for the full spec, including the
  `:json-null` propagation table (§6.2) — top-level JSON null collapses
  to `nil`, sub-field JSON null in `structuredContent` is preserved as
  `:json-null`.
  """

  alias PtcRunner.Lisp.Runtime.Json

  @doc """
  Extract the first text item's `text` from an MCP tool-result envelope.

  Returns `result["content"][0]["text"]` when:

    * `result` is a map,
    * `result["content"]` is a list,
    * the first item is a map with `"type" == "text"`,
    * the first item has a binary `"text"` field.

  Returns `nil` for any non-conforming input — including the
  `:json-null` sentinel (a keyword, not a map). Index 0 only:
  programs that need later items use `get-in` directly (see §5.1.1).

  ## Examples

      iex> PtcRunner.Lisp.Runtime.Mcp.text(%{"content" => [%{"type" => "text", "text" => "hello"}]})
      "hello"

      iex> PtcRunner.Lisp.Runtime.Mcp.text(%{"content" => [%{"type" => "image"}]})
      nil

      iex> PtcRunner.Lisp.Runtime.Mcp.text(:"json-null")
      nil

      iex> PtcRunner.Lisp.Runtime.Mcp.text(nil)
      nil

      iex> PtcRunner.Lisp.Runtime.Mcp.text(%{"content" => []})
      nil
  """
  @spec text(term()) :: String.t() | nil
  def text(result) when is_map(result) do
    case result do
      %{"content" => [%{"type" => "text", "text" => text} | _]} when is_binary(text) -> text
      _ -> nil
    end
  end

  def text(_), do: nil

  @doc """
  Extract typed JSON from an MCP tool-result envelope.

  Precedence (§5.2):

    1. If `result` is a map and `result["structuredContent"]` is
       non-`nil`, return it verbatim — including the `:json-null`
       sentinel (truthy in PTC-Lisp), which short-circuits the
       fallback so sub-field JSON null is preserved (§6.2).
    2. Otherwise, parse `result["content"][0]["text"]` as JSON and
       return the parsed value.

  Returns `nil` when both paths fail (no `structuredContent`, no
  parseable text).

  ## Examples

      iex> PtcRunner.Lisp.Runtime.Mcp.json(%{"structuredContent" => %{"a" => 1}})
      %{"a" => 1}

      iex> PtcRunner.Lisp.Runtime.Mcp.json(%{"content" => [%{"type" => "text", "text" => ~S|{"x":2}|}]})
      %{"x" => 2}

      iex> PtcRunner.Lisp.Runtime.Mcp.json(%{"structuredContent" => :"json-null"})
      :"json-null"

      iex> PtcRunner.Lisp.Runtime.Mcp.json(:"json-null")
      nil

      iex> PtcRunner.Lisp.Runtime.Mcp.json(%{})
      nil

      iex> PtcRunner.Lisp.Runtime.Mcp.json(nil)
      nil
  """
  @spec json(term()) :: term() | nil
  def json(result) when is_map(result) do
    case Map.fetch(result, "structuredContent") do
      {:ok, nil} ->
        Json.parse_string(text(result))

      {:ok, %{"content" => content} = structured} when is_binary(content) ->
        if map_size(structured) == 1 and content == text(result),
          do: Json.parse_string(content),
          else: structured

      {:ok, value} ->
        value

      :error ->
        Json.parse_string(text(result))
    end
  end

  def json(_), do: nil
end
