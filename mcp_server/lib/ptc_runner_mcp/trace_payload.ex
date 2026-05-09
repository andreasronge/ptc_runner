defmodule PtcRunnerMcp.TracePayload do
  @moduledoc """
  Payload redaction for per-call trace events.

  Per `Plans/ptc-runner-mcp-server.md` § 6.9, every program / context /
  validated value / print written to a trace file is redacted up-front
  according to the active `--trace-payloads` policy. This module owns
  the redaction; the trace handler (and `with_trace/2` header builder)
  delegate to it.

  Levels:

    * `:none`   — strongest redaction, counts only.
    * `:summary` — default; keys + counts + small previews, no values.
    * `:full`   — no redaction; full source, full JSON.

  **Error reasons and messages are NEVER redacted at any level**
  (debug requires them — § 6.9 last bullet).

  ## Credentials redaction

  In addition to the `--trace-payloads` policy redaction above, every
  string emitted by `redact_program/2`, `redact_context/2`,
  `redact_validated/2`, and `redact_prints/2` is finally passed
  through `PtcRunnerMcp.Credentials.Redactor.scrub/1` to substring-
  replace any registered binding plaintext (per
  `Plans/http-transport-credentials.md` §7.5.1).

  ### Why hook here, not in `TraceFile` or in `PtcRunner.TraceLog`?

  The actual JSONL encoding lives in `PtcRunner.TraceLog.Collector`
  (the parent `:ptc_runner` library), which has no dependency on
  `:ptc_runner_mcp` and cannot call `Redactor.scrub/1`. `TraceFile`
  only forwards header opts and never sees the per-event JSON
  payloads (they reach the collector via telemetry). So the cleanest
  hook is the **values produced by `TracePayload`** — those are
  exactly the strings that risk containing binding plaintext
  (`:full` and `:summary` previews of programs/contexts/prints can
  include literal secret bytes if a Lisp program embedded one).
  Telemetry handler-level metadata (request_id, status, etc.) does
  not flow through TracePayload but is structurally scalar and
  cannot carry secrets per §7.5.3 (a).
  """

  alias PtcRunnerMcp.Credentials.Redactor

  @preview_chars 256
  @print_preview_chars 80

  @typedoc "Redaction policy."
  @type level :: :none | :summary | :full

  # ----------------------------------------------------------------
  # Programs
  # ----------------------------------------------------------------

  @doc """
  Redact a PTC-Lisp program string per the active policy.

  Returns either the full source (`:full`) or a JSON-friendly map
  describing it without leaking content.

  ## Examples

      iex> alias PtcRunnerMcp.TracePayload
      iex> TracePayload.redact_program("(println :hi)", :full)
      "(println :hi)"
      iex> %{"sha256" => sha, "bytes" => 14} = TracePayload.redact_program("(println :hi)", :none)
      iex> byte_size(sha)
      64
  """
  @spec redact_program(String.t() | nil, level()) :: term()
  def redact_program(nil, _level), do: nil

  def redact_program(program, :full) when is_binary(program), do: scrub_strings(program)

  def redact_program(program, :none) when is_binary(program) do
    # `:none` mode emits only sha256 + byte_size — neither can carry
    # a registered plaintext, so we skip the scrub walk.
    %{
      "sha256" => sha256_hex(program),
      "bytes" => byte_size(program)
    }
  end

  def redact_program(program, :summary) when is_binary(program) do
    scrub_strings(%{
      "sha256" => sha256_hex(program),
      "preview" => utf8_preview(program, @preview_chars),
      "bytes" => byte_size(program)
    })
  end

  # ----------------------------------------------------------------
  # Context
  # ----------------------------------------------------------------

  @doc """
  Redact a `context` map per the active policy.

  - `:none`    — `{"<bytes>": <int>}`
  - `:summary` — per-top-level-key `{"type": ..., "count": ...}`
  - `:full`    — passthrough (caller supplies a JSON-encodable map)
  """
  @spec redact_context(map() | nil, level()) :: term()
  def redact_context(nil, _level), do: nil

  def redact_context(ctx, :full) when is_map(ctx), do: scrub_strings(ctx)

  def redact_context(ctx, :none) when is_map(ctx) do
    bytes =
      case Jason.encode(ctx) do
        {:ok, json} -> byte_size(json)
        _ -> 0
      end

    %{"<bytes>" => bytes}
  end

  def redact_context(ctx, :summary) when is_map(ctx) do
    # Top-level keys are stringified — they're operator-chosen names,
    # not values, but scrub them anyway as defense in depth.
    scrub_strings(
      Map.new(ctx, fn {k, v} ->
        {to_string(k), %{"type" => json_type(v), "count" => json_count(v)}}
      end)
    )
  end

  # ----------------------------------------------------------------
  # Validated value (signature-typed return)
  # ----------------------------------------------------------------

  @doc """
  Redact the `validated` field of an R22 success payload.

  - `:full`    — passthrough
  - `:summary` — shape + top-level types
  - `:none`    — shape only (no values, no types)
  """
  @spec redact_validated(term(), level()) :: term()
  def redact_validated(nil, _level), do: nil
  def redact_validated(value, :full), do: scrub_strings(value)

  def redact_validated(value, :summary) when is_map(value) and not is_struct(value) do
    scrub_strings(%{
      "type" => "object",
      "keys" => value |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    })
  end

  def redact_validated(value, :summary) when is_list(value) do
    element_type =
      case value do
        [] -> nil
        [first | _] -> json_type(first)
      end

    %{
      "type" => "array",
      "length" => length(value),
      "element_type" => element_type
    }
  end

  def redact_validated(value, :summary) do
    %{"type" => json_type(value)}
  end

  def redact_validated(value, :none) when is_map(value) and not is_struct(value) do
    scrub_strings(%{
      "type" => "object",
      "keys" => value |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    })
  end

  def redact_validated(value, :none) when is_list(value) do
    %{"type" => "array", "length" => length(value)}
  end

  def redact_validated(value, :none) do
    %{"type" => json_type(value)}
  end

  # ----------------------------------------------------------------
  # Prints
  # ----------------------------------------------------------------

  @doc """
  Redact the `prints` array per the policy.

  - `:full`    — passthrough
  - `:summary` — count + truncated first line per print
  - `:none`    — count only
  """
  @spec redact_prints([String.t()] | nil, level()) :: term()
  def redact_prints(nil, _level), do: nil

  def redact_prints(prints, :full) when is_list(prints), do: scrub_strings(prints)

  def redact_prints(prints, :none) when is_list(prints) do
    %{"count" => length(prints)}
  end

  def redact_prints(prints, :summary) when is_list(prints) do
    items =
      Enum.map(prints, fn p ->
        s = if is_binary(p), do: p, else: to_string(p)

        first_line =
          s
          |> String.split("\n", parts: 2)
          |> List.first()
          |> Kernel.||("")

        utf8_preview(first_line, @print_preview_chars)
      end)

    scrub_strings(%{"count" => length(prints), "items" => items})
  end

  # ----------------------------------------------------------------
  # Bytes counters
  # ----------------------------------------------------------------

  @doc "SHA-256 hex digest (lowercase)."
  @spec sha256_hex(binary()) :: String.t()
  def sha256_hex(bin) when is_binary(bin) do
    :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
  end

  @doc """
  Take the first `n` UTF-8 characters from `string` (returns the
  string unchanged when shorter).
  """
  @spec utf8_preview(String.t(), pos_integer()) :: String.t()
  def utf8_preview(string, n) when is_binary(string) and is_integer(n) and n > 0 do
    if String.length(string) <= n do
      string
    else
      String.slice(string, 0, n)
    end
  end

  # ----------------------------------------------------------------
  # JSON type helpers
  # ----------------------------------------------------------------

  @doc "Infer a JSON type name for a value."
  @spec json_type(term()) :: String.t()
  def json_type(nil), do: "null"
  def json_type(v) when is_boolean(v), do: "boolean"
  def json_type(v) when is_integer(v), do: "number"
  def json_type(v) when is_float(v), do: "number"
  def json_type(v) when is_binary(v), do: "string"
  def json_type(v) when is_list(v), do: "array"
  def json_type(v) when is_map(v) and not is_struct(v), do: "object"
  def json_type(v) when is_atom(v), do: "string"
  def json_type(_), do: "string"

  @doc "Element-count for arrays / objects (nil for scalars)."
  @spec json_count(term()) :: non_neg_integer() | nil
  def json_count(v) when is_list(v), do: length(v)
  def json_count(v) when is_map(v) and not is_struct(v), do: map_size(v)
  def json_count(_), do: nil

  # ----------------------------------------------------------------
  # Credentials redaction walk (§7.5.1)
  # ----------------------------------------------------------------

  # Recursively scrub every binary leaf in a redacted payload through
  # `Credentials.Redactor.scrub/1`. Maps, lists, atoms, and numbers
  # are walked but otherwise passed through. Structs are returned
  # unchanged (no current redacted shape produces a struct).
  @spec scrub_strings(term()) :: term()
  defp scrub_strings(value) when is_binary(value), do: Redactor.scrub(value)

  defp scrub_strings(value) when is_list(value) do
    Enum.map(value, &scrub_strings/1)
  end

  defp scrub_strings(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {k, v} -> {scrub_strings(k), scrub_strings(v)} end)
  end

  defp scrub_strings(value), do: value
end
