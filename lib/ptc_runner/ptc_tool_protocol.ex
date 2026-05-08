defmodule PtcRunner.PtcToolProtocol do
  @moduledoc """
  Wire-format source of truth for the `ptc_lisp_execute` tool surface.

  Owns the canonical tool description (per capability profile) and the
  shared response-payload renderers (`render_success/2`,
  `render_error/3`) used across:

    * **In-process v1 PTC `:tool_call`** — `output: :ptc_lisp,
      ptc_transport: :tool_call` agents that expose `ptc_lisp_execute`
      as the only provider-native tool. Profile:
      `:in_process_with_app_tools`.
    * **In-process text-mode (combined mode)** — `output: :text,
      ptc_transport: :tool_call` agents that expose `ptc_lisp_execute`
      alongside `:both`-tagged app tools. Profile:
      `:in_process_text_mode`.
    * **MCP server** — standalone JSON-RPC server that advertises
      `ptc_lisp_execute` with no app tools available inside programs.
      Profile: `:mcp_no_tools`.

  The three feature plans share four conventions; this module is where
  all four are pinned (see "Coupling Points" in
  `Plans/text-mode-ptc-compute-tool.md`):

    1. **Profile-string convention.** Each profile is one canonical
       string constant. `tool_description/1` returns it directly — no
       runtime concatenation of base + capability note. If the
       representation ever changes (e.g., to a structured map), all
       three profiles change together.
    2. **`error_reason()` is a closed union.** Adding a new reason
       requires updating the `@type` and `render_error/3`'s reason
       handling in lockstep. `render_error/3` MUST handle every member
       without crashing.
    3. **Renderer signatures are keyword-driven.** `render_success/2`
       and `render_error/3` take a keyword list for any non-essential
       parameter so future additions are non-breaking. Unknown opts are
       silently ignored, not rejected.
    4. **`tool_description/1` carries capability statements only.**
       Cache-reuse guidance, prompt cards, and other workflow guidance
       live in plan-specific surfaces (system prompt, `cache_hint`, MCP
       server documentation), not here.

  See `Plans/text-mode-ptc-compute-tool.md` § "Prerequisite: Shared
  Protocol Module" and `Plans/ptc-runner-mcp-server.md` § "Tool
  Description Capability Profiles" for the spec.
  """

  alias PtcRunner.Lisp
  alias PtcRunner.SubAgent.Definition
  alias PtcRunner.SubAgent.Loop.JsonHandler
  alias PtcRunner.SubAgent.Loop.TurnFeedback
  alias PtcRunner.SubAgent.Signature

  # ----------------------------------------------------------------
  # Capability-profile description constants
  # ----------------------------------------------------------------
  #
  # Per Addendum #10 (text-mode plan): the `:in_process_with_app_tools`
  # string is locked to the existing v1 wording. Per Addendum #11: each
  # profile is one canonical constant; `tool_description/1` returns it
  # directly with no runtime concatenation. New profiles must extend
  # this list and add a substring-pinning test.

  @in_process_with_app_tools_description "Execute a PTC-Lisp program in PtcRunner's sandbox. Use this for deterministic computation and tool orchestration. Call app tools as `(tool/name ...)` from inside the program — do not attempt to call app tools as native function calls; only `ptc_lisp_execute` is available natively."

  @in_process_text_mode_description "Execute a PTC-Lisp program in PtcRunner's sandbox. Use this for deterministic computation, filtering, aggregation, or multi-step data transformation. Call `:both`-exposed app tools as `(tool/name ...)` from inside the program. The same tools are also callable natively in this assistant turn, but not in the same turn as `ptc_lisp_execute`."

  @mcp_no_tools_description "Execute a PTC-Lisp program in PtcRunner's sandbox. Use this for deterministic computation, filtering, aggregation, or multi-step data transformation. No app tools are available inside the program. Pass external data via the `context` argument; each invocation is independent — there is no memory of prior calls."

  @typedoc """
  Closed union of error reasons surfaced through `render_error/3`.

  Members:

    * `:parse_error`        — PTC-Lisp source failed to parse.
    * `:runtime_error`      — runtime evaluation error inside a program
      (also covers return-validation errors against the agent's
      signature).
    * `:timeout`            — sandbox timeout exceeded.
    * `:memory_limit`       — sandbox memory cap exceeded.
    * `:args_error`         — tool arguments malformed (missing
      `program`, non-string, wrong shape, oversized). Emitted only by
      MCP v1; in-process surfaces never construct it (Addendum #25).
    * `:fail`               — program called `(fail v)` to terminate
      with an error value. Only reason carrying a `result` payload
      (Addendum #4).
    * `:validation_error`   — return-value signature mismatch.
      Reserved for MCP v1; no in-process surface emits it today
      (Tier 0 scope expansion).
  """
  @type error_reason ::
          :parse_error
          | :runtime_error
          | :timeout
          | :memory_limit
          | :args_error
          | :fail
          | :validation_error

  @doc """
  Capability profile for the `ptc_lisp_execute` tool description.

  Returns the canonical description string for the requested profile.
  Per Addendum #11, each profile is one constant returned directly —
  no runtime concatenation. The `:in_process_with_app_tools` string is
  byte-for-byte locked to the existing v1 wording (Addendum #10).
  """
  @spec tool_description(:in_process_with_app_tools | :in_process_text_mode | :mcp_no_tools) ::
          String.t()
  def tool_description(:in_process_with_app_tools), do: @in_process_with_app_tools_description
  def tool_description(:in_process_text_mode), do: @in_process_text_mode_description
  def tool_description(:mcp_no_tools), do: @mcp_no_tools_description

  # ----------------------------------------------------------------
  # Response-payload renderers
  # ----------------------------------------------------------------

  @doc """
  Render a successful `ptc_lisp_execute` invocation as JSON.

  Success payload shape: `status`, optional `result`, `prints`,
  `feedback`, top-level `truncated`, and (when `include_memory: true`,
  the default) `memory.{changed,stored_keys,truncated}`. One-shot
  callers omit memory by passing `include_memory: false` or by going
  through `render_success_from_step/2` which sets it for them.

  ## Required input shape

  `lisp_step` is the `Step.t()` result of `Lisp.run/2`. Only the
  `:return` field is consulted directly (to decide whether to drop the
  `"result"` field when nil).

  ## Recognized opts

    * `:execution` — required for v1 callers. A
      `TurnFeedback.execution_feedback/3` result map carrying
      `:result`, `:prints`, `:feedback`, `:memory.{changed,stored_keys,truncated}`,
      and `:truncated`. The renderer reads these directly. Future
      callers (MCP server, text-mode) MAY pass their own equivalent
      map.
    * `:validated` — JSON-encodable value. When present, included as
      a top-level `"validated"` field. Used by MCP v1 to surface
      schema-validated return values.
    * `:include_memory` — boolean (default `true`). When `false`, the
      `"memory"` key is omitted entirely from the payload. One-shot
      callers (MCP server) set this to `false` because state never
      persists across calls (issue #879). Multi-turn `SubAgent` loops
      keep the default since `defn`'d names DO persist across turns.

  Unknown opts are ignored (Addendum #12).

  ## Result-field elision

  Matches the v1 invariant: when both `execution.result` and
  `lisp_step.return` are `nil`, the `"result"` field is dropped from
  the JSON. Any other combination keeps the field (even when the
  rendered value is `null`).
  """
  @spec render_success(map(), keyword()) :: String.t()
  def render_success(lisp_step, opts \\ []) do
    execution = Keyword.fetch!(opts, :execution)
    include_memory = Keyword.get(opts, :include_memory, true)

    payload = %{
      "status" => "ok",
      "result" => execution.result,
      "prints" => execution.prints,
      "feedback" => execution.feedback,
      "truncated" => execution.truncated
    }

    payload =
      if include_memory do
        Map.put(payload, "memory", %{
          "changed" => execution.memory.changed,
          "stored_keys" => execution.memory.stored_keys,
          "truncated" => execution.memory.truncated
        })
      else
        payload
      end

    payload =
      if is_nil(payload["result"]) and is_nil(Map.get(lisp_step, :return)) do
        Map.delete(payload, "result")
      else
        payload
      end

    payload =
      case Keyword.fetch(opts, :validated) do
        {:ok, value} -> Map.put(payload, "validated", value)
        :error -> payload
      end

    Jason.encode!(payload)
  end

  @doc """
  Render a successful `ptc_lisp_execute` invocation directly from a `Lisp.run/2` result.

  High-level convenience wrapper over `render_success/2`. Builds the
  `:execution` map internally via
  `PtcRunner.SubAgent.Loop.TurnFeedback.execution_feedback/3` so callers
  outside `:ptc_runner` (e.g. `:ptc_runner_mcp`) never have to reach
  into `TurnFeedback` themselves. Per § 13.1 of
  `Plans/ptc-runner-mcp-server.md`, this is the only canonical way for
  out-of-tree callers to render an R22 success payload.

  ## Required input shape

  `lisp_step` is a `PtcRunner.Step.t()` (the success-branch result of
  `PtcRunner.Lisp.run/2`). Only the structured fields the renderer
  consults — `:return`, `:prints`, `:memory` — need to be populated.

  ## Recognized opts

    * `:validated` — JSON-encodable value forwarded into
      `render_success/2` and surfaced as the top-level `"validated"`
      field. Only meaningful when the caller validated the program's
      return value against a signature.

  Unknown opts are silently ignored, matching `render_success/2`.

  ## One-shot semantics — no `memory` field

  This wrapper is the canonical path for one-shot callers (MCP server,
  text-mode rendering of single programs). One-shot calls never see
  state across invocations, so the response omits the `memory` field
  entirely (issue #879). Multi-turn callers — `SubAgent` loops where
  `defn`'d names persist across turns — should call `render_success/2`
  directly with the default `include_memory: true`.

  ## Example

      iex> {:ok, step} = PtcRunner.Lisp.run("(+ 1 2)")
      iex> json = PtcRunner.PtcToolProtocol.render_success_from_step(step)
      iex> %{"status" => "ok", "result" => "user=> 3"} = Jason.decode!(json)
      iex> json |> Jason.decode!() |> Map.fetch!("status")
      "ok"
  """
  @spec render_success_from_step(map(), keyword()) :: String.t()
  def render_success_from_step(lisp_step, opts \\ []) do
    agent = mcp_render_agent()
    state = %{memory: %{}}
    execution = TurnFeedback.execution_feedback(agent, state, lisp_step)

    forwarded_opts =
      [{:execution, execution}, {:include_memory, false} | Keyword.take(opts, [:validated])]

    render_success(lisp_step, forwarded_opts)
  end

  # Synthetic minimum agent for `render_success_from_step/2`.
  #
  # `TurnFeedback.execution_feedback/3` reads `agent.format_options`
  # and `agent.max_turns` only. We use the default format options and
  # pin `max_turns: 1`, which makes the human-feedback string apply
  # the single-shot suppression rules (no result-preview line, no
  # "Stored:" hint when nothing changed). The structured `:result`
  # and `:memory.changed` fields are populated unconditionally per
  # `execution_feedback/3`'s contract, so this mirrors the MCP v1
  # request semantics: each call is single-shot and stateless.
  defp mcp_render_agent do
    %Definition{
      format_options: Definition.default_format_options(),
      max_turns: 1
    }
  end

  @doc """
  Render an error `ptc_lisp_execute` response as JSON.

  Every member of `error_reason()` is handled. Output payload keys:

    * `"status"` — always `"error"`.
    * `"reason"` — `Atom.to_string/1` of the reason atom.
    * `"message"` — the supplied human-readable message.
    * `"feedback"` — defaults to `message`; overridden via
      `feedback:` opt.
    * `"result"` — present **only when** `reason == :fail`. The value
      is taken from the `result:` opt (Addendum #4: `:fail` is the
      only reason that carries a value).

  ## Recognized opts

    * `:result`   — only meaningful for `reason: :fail`. Encoded as
      the top-level `"result"` field (typically a string preview of
      the failed value). Ignored for any other reason.
    * `:feedback` — string. Defaults to `message` when not provided.

  Unknown opts are ignored (Addendum #12).
  """
  @spec render_error(error_reason(), String.t(), keyword()) :: String.t()
  def render_error(reason, message, opts \\ []) when is_atom(reason) and is_binary(message) do
    feedback = Keyword.get(opts, :feedback, message)

    base = %{
      "status" => "error",
      "reason" => Atom.to_string(reason),
      "message" => message,
      "feedback" => feedback
    }

    payload =
      case reason do
        :fail -> Map.put(base, "result", Keyword.get(opts, :result))
        _ -> base
      end

    Jason.encode!(payload)
  end

  # ----------------------------------------------------------------
  # Re-exports
  # ----------------------------------------------------------------
  #
  # Thin wrappers so future `Loop.TextMode` (and the MCP server tier)
  # do not have to reach into v1 internals (`Loop.JsonHandler`, etc.)
  # directly. Bodies are pure delegation; no behavior change.

  @doc """
  Delegates to `PtcRunner.Lisp.run/2`.

  Re-exported here so non-v1 callers (text-mode combined loop, MCP
  server) can drive PTC-Lisp programs through the protocol module
  without depending on the v1 loop's transitive aliases.
  """
  @spec lisp_run(String.t(), keyword()) ::
          {:ok, PtcRunner.Step.t()} | {:error, PtcRunner.Step.t()}
  def lisp_run(source, opts \\ []), do: Lisp.run(source, opts)

  @doc """
  Delegates to `PtcRunner.SubAgent.Loop.JsonHandler.atomize_value/2`.

  Used by surfaces that need to coerce a raw JSON value into the
  shape implied by a parsed signature before validation.
  """
  @spec atomize_value(term(), term()) :: term()
  def atomize_value(value, type), do: JsonHandler.atomize_value(value, type)

  @doc """
  Delegates to `PtcRunner.SubAgent.Loop.JsonHandler.validate_return/2`.

  Used by surfaces that need to validate a return value against an
  agent's parsed signature.
  """
  @spec validate_return(map(), term()) :: :ok | {:error, list()}
  def validate_return(definition, value), do: JsonHandler.validate_return(definition, value)

  @doc """
  Parse a PTC signature string for use by out-of-tree callers.

  Thin wrapper over `PtcRunner.SubAgent.Signature.parse/1`. Per § 13.1
  of `Plans/ptc-runner-mcp-server.md`, `:ptc_runner_mcp` consumes
  signatures exclusively through this function so the parser can
  later move out of the `SubAgent` namespace without breaking the MCP
  package.

  ## Examples

      iex> PtcRunner.PtcToolProtocol.parse_signature("() -> {count :int}")
      {:ok, {:signature, [], {:map, [{"count", :int}]}}}

      iex> {:error, _reason} = PtcRunner.PtcToolProtocol.parse_signature("not a signature")
  """
  @spec parse_signature(String.t()) ::
          {:ok, Signature.signature()} | {:error, String.t()}
  def parse_signature(signature_string) when is_binary(signature_string) do
    Signature.parse(signature_string)
  end

  # ----------------------------------------------------------------
  # JSON normalization for `validated` (§ 13)
  # ----------------------------------------------------------------

  @doc """
  Convert a typed Elixir term into a JSON-encodable value.

  Used by surfaces that surface signature-validated return values as
  structured JSON (currently only the MCP server's `validated` field;
  see § 13 of `Plans/ptc-runner-mcp-server.md`). This is the inverse
  direction of `atomize_value/2`, which goes JSON → typed Elixir.

  ## Conversion rules

  | Elixir term | JSON form |
  |---|---|
  | Integer | number |
  | Float | number |
  | Binary (string) | string |
  | Boolean | boolean |
  | `nil` | null |
  | Map with binary or atom keys | object with string keys |
  | List | array |
  | Atom (non-key) | string (`:foo` → `"foo"`, no leading colon) |
  | Tuple | array |
  | `%DateTime{}` | ISO-8601 string |
  | `%Date{}`, `%Time{}` | ISO-8601 string |
  | Anything else | `{:error, "non-JSON-encodable value at <path>"}` |

  Errors propagate the path to the offending sub-value. Map-key path
  segments are dot-joined; list/tuple indices use `[<index>]`.

  ## Examples

      iex> PtcRunner.PtcToolProtocol.to_json_value(42)
      {:ok, 42}

      iex> PtcRunner.PtcToolProtocol.to_json_value(1.5)
      {:ok, 1.5}

      iex> PtcRunner.PtcToolProtocol.to_json_value(:foo)
      {:ok, "foo"}

      iex> PtcRunner.PtcToolProtocol.to_json_value({1, :ok, "a"})
      {:ok, [1, "ok", "a"]}

      iex> {:ok, dt, _} = DateTime.from_iso8601("2026-05-07T12:00:00Z")
      iex> PtcRunner.PtcToolProtocol.to_json_value(dt)
      {:ok, "2026-05-07T12:00:00Z"}

      iex> PtcRunner.PtcToolProtocol.to_json_value(%{count: 2, items: [:a, :b]})
      {:ok, %{"count" => 2, "items" => ["a", "b"]}}

      iex> PtcRunner.PtcToolProtocol.to_json_value(%{rows: [%{ts: make_ref()}]})
      {:error, "non-JSON-encodable value at rows[0].ts"}
  """
  @spec to_json_value(term()) :: {:ok, term()} | {:error, String.t()}
  def to_json_value(value) do
    case do_to_json(value, []) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, path} -> {:error, "non-JSON-encodable value at #{render_path(path)}"}
    end
  end

  # Scalars that pass through unchanged.
  defp do_to_json(value, _path) when is_integer(value), do: {:ok, value}
  defp do_to_json(value, _path) when is_float(value), do: {:ok, value}
  defp do_to_json(value, _path) when is_binary(value), do: {:ok, value}
  defp do_to_json(value, _path) when is_boolean(value), do: {:ok, value}
  defp do_to_json(nil, _path), do: {:ok, nil}

  # Date/Time structs as ISO-8601 strings.
  defp do_to_json(%DateTime{} = dt, _path), do: {:ok, DateTime.to_iso8601(dt)}
  defp do_to_json(%Date{} = d, _path), do: {:ok, Date.to_iso8601(d)}
  defp do_to_json(%Time{} = t, _path), do: {:ok, Time.to_iso8601(t)}

  # Atoms that aren't already covered (true/false/nil handled above) →
  # stringify without the leading colon.
  defp do_to_json(value, _path) when is_atom(value), do: {:ok, Atom.to_string(value)}

  # Maps: stringify keys, recursively encode values. Reject struct types
  # we did not whitelist above.
  defp do_to_json(%_struct{} = value, path), do: {:error, build_path(path, struct_tag(value))}

  defp do_to_json(value, path) when is_map(value) do
    value
    |> Enum.reduce_while({:ok, %{}}, fn {k, v}, {:ok, acc} ->
      with {:ok, key_str} <- map_key_to_string(k, path),
           {:ok, encoded_v} <- do_to_json(v, [key_str | path]) do
        {:cont, {:ok, Map.put(acc, key_str, encoded_v)}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # Lists: encode elements, propagate path with `[index]`.
  defp do_to_json(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {elem, idx}, {:ok, acc} ->
      case do_to_json(elem, [{:index, idx} | path]) do
        {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      err -> err
    end
  end

  # Tuples: encode as JSON array.
  defp do_to_json(value, path) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {elem, idx}, {:ok, acc} ->
      case do_to_json(elem, [{:index, idx} | path]) do
        {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      err -> err
    end
  end

  # Anything else (PIDs, references, functions, ports, unknown structs).
  defp do_to_json(_other, path), do: {:error, path}

  defp map_key_to_string(k, _path) when is_binary(k), do: {:ok, k}
  defp map_key_to_string(k, _path) when is_atom(k), do: {:ok, Atom.to_string(k)}
  # § 13: only binary or atom keys are encodable. Integer keys are
  # rejected (rather than stringified) because stringifying can collide
  # with an existing string key — `%{1 => "a", "1" => "b"}` would lose
  # data on the round-trip. Surface as `validation_error`.
  defp map_key_to_string(_k, path), do: {:error, path}

  defp struct_tag(%mod{}), do: "<#{inspect(mod)}>"

  # Build a path string for an unencodable map value at `key`.
  defp build_path(path, key) do
    [key | path]
  end

  # Render a reverse-order path (top-of-stack is most-recent segment) as
  # a human-readable string. Map keys join with `.`; list/tuple indices
  # use `[N]` and attach to the previous segment.
  defp render_path(reverse_path) do
    reverse_path
    |> Enum.reverse()
    |> Enum.reduce("", fn
      {:index, i}, acc -> acc <> "[" <> Integer.to_string(i) <> "]"
      key, "" -> to_string(key)
      key, acc -> acc <> "." <> to_string(key)
    end)
    |> case do
      "" -> "<root>"
      s -> s
    end
  end
end
