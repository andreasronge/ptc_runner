defmodule PtcRunnerMcp.Envelope do
  @moduledoc """
  MCP `tools/call` result envelope.

  Per `Plans/ptc-runner-mcp-server.md` § 10.1, every tool result is
  returned as a JSON object with three keys:

    * `"isError"` — boolean, `true` for any R23 error including
      `(fail v)` (§ 10.5).
    * `"structuredContent"` — the parsed R22/R23 payload as an object.
    * `"content"` — a single-element array carrying the same payload
      as a `"text"` block, mirroring `structuredContent`.

  Phase 2 wires real `Lisp.run/2` results into the envelope. This
  module also owns `render_error/3` — the single entry point all MCP
  error rendering goes through. For the seven shared reasons it
  delegates to `PtcRunner.PtcToolProtocol.render_error/3`; for the
  two MCP-only reasons (`:busy`, `:unknown_tool`) it constructs the
  R23 payload locally per § 10.3.

  Per § 10.3, `:busy` and `:unknown_tool` are NOT in the shared
  `error_reason()` enum. `PtcRunner.PtcToolProtocol.render_error/3`
  is intentionally NOT widened to accept them; this package owns
  their rendering.
  """

  alias PtcRunner.PtcToolProtocol

  @shared_reasons [
    :parse_error,
    :runtime_error,
    :timeout,
    :memory_limit,
    :args_error,
    :fail,
    :validation_error
  ]

  @typedoc "MCP tool result envelope, ready for JSON-RPC serialization."
  @type t :: %{
          required(String.t()) => boolean() | map() | [map()]
        }

  @typedoc "Reasons accepted by `render_error/3`."
  @type reason ::
          :parse_error
          | :runtime_error
          | :timeout
          | :memory_limit
          | :args_error
          | :fail
          | :validation_error
          | :busy
          | :unknown_tool
          | :shutting_down
          | :cancelled

  @doc """
  Build the `unknown_tool` envelope for any `tools/call` whose
  `params.name` is not `"lisp_eval"`.

  Per § 7.4 D1, unknown tool names are surfaced as a tool result, not
  as JSON-RPC `-32602`. Delegates to `render_error/3` so all error
  rendering goes through one entry point.
  """
  @spec unknown_tool(String.t()) :: t()
  def unknown_tool(name) when is_binary(name) do
    render_error(:unknown_tool, "unknown tool: #{name}", tool_name: name)
  end

  @doc """
  Build a `busy` envelope when `:max_concurrent_calls` is exceeded.

  Profile-aware: routes through `ptc_lisp_error/1` so a busy rejection
  honors the active response profile (slim text vs. structured vs.
  debug) just like any other `lisp_eval` error.
  """
  @spec busy(pos_integer()) :: t()
  def busy(cap) when is_integer(cap) and cap > 0 do
    :busy
    |> render_error_payload("server busy: #{cap} concurrent calls in flight", cap: cap)
    |> ptc_lisp_error()
  end

  @doc """
  Build a `shutting_down` envelope for `tools/call` arriving after a
  `shutdown` request was accepted (§ 6.4 row 2).

  This is an MCP-only reason — it lives in `:ptc_runner_mcp` and is
  intentionally NOT added to `PtcRunner.PtcToolProtocol.error_reason()`.
  """
  @spec shutting_down() :: t()
  def shutting_down do
    render_error(
      :shutting_down,
      "server is draining after shutdown; new tool calls are rejected"
    )
  end

  @doc "Build a cancelled envelope for HTTP request cancellation."
  @spec cancelled(String.t()) :: t()
  def cancelled(message) when is_binary(message) do
    render_error(:cancelled, message)
  end

  @doc """
  Render an error tool-result envelope for any reason emitted by MCP v1.

  ## Reasons

    * Seven shared reasons (`:parse_error`, `:runtime_error`,
      `:timeout`, `:memory_limit`, `:args_error`, `:fail`,
      `:validation_error`) — delegated to
      `PtcRunner.PtcToolProtocol.render_error/3` and wrapped in the
      MCP envelope. Forwards `:result` and `:feedback` opts.
    * `:busy` — constructed locally with an MCP-owned feedback string.
      Accepts `:cap` for the in-flight cap.
    * `:unknown_tool` — constructed locally with an MCP-owned feedback
      string. Accepts `:tool_name` for the offending name.

  Both `:busy` and `:unknown_tool` produce R23 payloads with `status`,
  `reason`, `message`, and `feedback` only — never a `result` field
  (§ 10.3).
  """
  @spec render_error(reason(), String.t(), keyword()) :: t()
  def render_error(reason, message, opts \\ []) do
    reason
    |> render_error_payload(message, opts)
    |> error_envelope()
  end

  @doc """
  Render the **unwrapped** R23 structured payload for any reason.

  Phase 0 (`Plans/ptc-runner-mcp-aggregator.md` §11.3) seam: the
  request handler builds the v1 payload, may decorate it with
  `upstream_calls` (Phase 1a), and only then wraps it via
  `error_envelope/1`. Returning the bare map keeps the wrap step
  cleanly separable from the construction step.

  Same reason set and option semantics as `render_error/3`; this is
  exactly the function `render_error/3` delegates to.
  """
  @spec render_error_payload(reason(), String.t(), keyword()) :: map()
  def render_error_payload(reason, message, opts \\ [])

  def render_error_payload(reason, message, opts)
      when reason in @shared_reasons and is_binary(message) do
    reason
    |> PtcToolProtocol.render_error(message, opts)
    |> Jason.decode!()
  end

  def render_error_payload(:busy, message, opts) when is_binary(message) do
    cap = Keyword.get(opts, :cap)

    feedback =
      Keyword.get(opts, :feedback) ||
        "The MCP server is at its concurrent-call cap" <>
          if(is_integer(cap), do: " (#{cap})", else: "") <>
          ". The previous call has not finished. Wait briefly and retry the same `tools/call`."

    %{
      "status" => "error",
      "reason" => "busy",
      "message" => message,
      "feedback" => feedback
    }
  end

  def render_error_payload(:unknown_tool, message, opts) when is_binary(message) do
    name = Keyword.get(opts, :tool_name)

    feedback =
      Keyword.get(opts, :feedback) ||
        "The MCP server exposes exactly one tool: `lisp_eval`." <>
          if is_binary(name) and name != "" do
            " The requested tool `#{name}` is not registered."
          else
            " The requested tool name was missing or empty."
          end

    %{
      "status" => "error",
      "reason" => "unknown_tool",
      "message" => message,
      "feedback" => feedback
    }
  end

  def render_error_payload(:shutting_down, message, opts) when is_binary(message) do
    feedback =
      Keyword.get(opts, :feedback) ||
        "The MCP server received a `shutdown` request and is no " <>
          "longer accepting new tool calls. Open a fresh server " <>
          "process to retry."

    %{
      "status" => "error",
      "reason" => "shutting_down",
      "message" => message,
      "feedback" => feedback
    }
  end

  def render_error_payload(:cancelled, message, opts) when is_binary(message) do
    feedback =
      Keyword.get(opts, :feedback) ||
        "The request was cancelled before the tool call completed."

    %{
      "status" => "error",
      "reason" => "cancelled",
      "message" => message,
      "feedback" => feedback
    }
  end

  @doc "Wrap any structured payload as a successful MCP tool result."
  @spec success(map()) :: t()
  def success(structured) when is_map(structured) do
    %{
      "isError" => false,
      "structuredContent" => structured,
      "content" => [%{"type" => "text", "text" => Jason.encode!(structured)}]
    }
  end

  @doc "Wrap any structured payload as an error MCP tool result."
  @spec error_envelope(map()) :: t()
  def error_envelope(structured) when is_map(structured) do
    %{
      "isError" => true,
      "structuredContent" => structured,
      "content" => [%{"type" => "text", "text" => Jason.encode!(structured)}]
    }
  end

  @doc "Wrap a `lisp_eval` success according to the response profile."
  @spec ptc_lisp_success(map(), keyword()) :: t()
  def ptc_lisp_success(structured, opts \\ []) when is_map(structured) do
    case Keyword.get(opts, :response_profile, PtcRunnerMcp.ResponseProfile.current()) do
      :slim ->
        text_envelope(false, render_success_text(structured))

      :structured ->
        compact = compact_structured_success(structured)

        %{
          "isError" => false,
          "structuredContent" => compact,
          "content" => [%{"type" => "text", "text" => render_success_text(compact)}]
        }

      :debug ->
        success(structured)
    end
  end

  @doc "Wrap a `lisp_eval` error according to the response profile."
  @spec ptc_lisp_error(map(), keyword()) :: t()
  def ptc_lisp_error(structured, opts \\ []) when is_map(structured) do
    case Keyword.get(opts, :response_profile, PtcRunnerMcp.ResponseProfile.current()) do
      :slim ->
        text_envelope(true, render_error_text(structured))

      :structured ->
        compact = compact_structured_error(structured)

        %{
          "isError" => true,
          "structuredContent" => compact,
          "content" => [%{"type" => "text", "text" => render_error_text(compact)}]
        }

      :debug ->
        error_envelope(structured)
    end
  end

  @doc "Wrap a `lisp_session_eval` success according to the response profile."
  @spec ptc_lisp_session_success(map(), keyword()) :: t()
  def ptc_lisp_session_success(structured, opts \\ []) when is_map(structured) do
    case Keyword.get(opts, :response_profile, PtcRunnerMcp.ResponseProfile.current()) do
      :slim ->
        text_envelope(false, render_session_success_text(structured))

      :structured ->
        compact = compact_session_success(structured)

        %{
          "isError" => false,
          "structuredContent" => compact,
          "content" => [%{"type" => "text", "text" => render_session_success_text(compact)}]
        }

      :debug ->
        success(structured)
    end
  end

  @doc "Wrap a `lisp_session_eval` error according to the response profile."
  @spec ptc_lisp_session_error(map(), keyword()) :: t()
  def ptc_lisp_session_error(structured, opts \\ []) when is_map(structured) do
    case Keyword.get(opts, :response_profile, PtcRunnerMcp.ResponseProfile.current()) do
      :slim ->
        text_envelope(true, render_session_error_text(structured))

      :structured ->
        compact = compact_session_error(structured)

        %{
          "isError" => true,
          "structuredContent" => compact,
          "content" => [%{"type" => "text", "text" => render_session_error_text(compact)}]
        }

      :debug ->
        error_envelope(structured)
    end
  end

  @doc false
  @spec compact_structured_success(map()) :: map()
  def compact_structured_success(structured) do
    %{"status" => Map.get(structured, "status", "ok")}
    |> maybe_put("result", Map.get(structured, "result"))
    |> maybe_put("validated", Map.get(structured, "validated"), keep_nil?: false)
    |> maybe_put("validated_preview", Map.get(structured, "validated_preview"), keep_nil?: false)
    |> maybe_put_true(
      "validated_preview_truncated",
      Map.get(structured, "validated_preview_truncated")
    )
    |> maybe_put("validated_bytes", Map.get(structured, "validated_bytes"), keep_nil?: false)
    |> maybe_put("upstream_results", Map.get(structured, "upstream_results"), keep_nil?: false)
    |> maybe_put_true("truncated", Map.get(structured, "truncated"))
    |> maybe_put_true("output_truncated", Map.get(structured, "output_truncated"))
  end

  @doc false
  @spec compact_structured_error(map()) :: map()
  def compact_structured_error(structured) do
    %{"status" => Map.get(structured, "status", "error")}
    |> maybe_put("reason", Map.get(structured, "reason"))
    |> maybe_put("message", Map.get(structured, "message"))
    |> maybe_put("feedback", Map.get(structured, "feedback"))
    |> maybe_put("result", Map.get(structured, "result"))
    |> maybe_put_true("truncated", Map.get(structured, "truncated"))
    |> maybe_put_true("output_truncated", Map.get(structured, "output_truncated"))
    |> maybe_put_true("feedback_truncated", Map.get(structured, "feedback_truncated"))
    |> maybe_put("upstream_calls", compact_upstream_errors(Map.get(structured, "upstream_calls")),
      keep_nil?: false
    )
  end

  @doc false
  @spec compact_session_success(map()) :: map()
  def compact_session_success(structured) do
    %{"status" => Map.get(structured, "status", "ok")}
    |> maybe_put("result", Map.get(structured, "result"))
    |> maybe_put("validated", Map.get(structured, "validated"), keep_nil?: false)
    |> maybe_put("validated_preview", Map.get(structured, "validated_preview"), keep_nil?: false)
    |> maybe_put_true(
      "validated_preview_truncated",
      Map.get(structured, "validated_preview_truncated")
    )
    |> maybe_put("validated_bytes", Map.get(structured, "validated_bytes"), keep_nil?: false)
    |> maybe_put("session", Map.get(structured, "session"), keep_nil?: false)
    |> maybe_put("memory", compact_session_memory(Map.get(structured, "memory")),
      keep_nil?: false
    )
    |> maybe_put("history_notices", Map.get(structured, "history_notices"), keep_nil?: false)
    |> maybe_put_true("truncated", Map.get(structured, "truncated"))
    |> maybe_put_true("output_truncated", Map.get(structured, "output_truncated"))
  end

  @doc false
  @spec compact_session_error(map()) :: map()
  def compact_session_error(structured) do
    %{"status" => Map.get(structured, "status", "error")}
    |> maybe_put("reason", Map.get(structured, "reason"))
    |> maybe_put("message", Map.get(structured, "message"))
    |> maybe_put("feedback", Map.get(structured, "feedback"))
    |> maybe_put("result", Map.get(structured, "result"))
    |> maybe_put("session", Map.get(structured, "session"), keep_nil?: false)
    |> maybe_put("memory", compact_session_memory(Map.get(structured, "memory")),
      keep_nil?: false
    )
    |> maybe_put("history_notices", Map.get(structured, "history_notices"), keep_nil?: false)
    |> maybe_put(
      "upstream_errors",
      compact_upstream_errors(Map.get(structured, "upstream_calls")),
      keep_nil?: false
    )
    |> maybe_put_true("truncated", Map.get(structured, "truncated"))
    |> maybe_put_true("output_truncated", Map.get(structured, "output_truncated"))
    |> maybe_put_true("feedback_truncated", Map.get(structured, "feedback_truncated"))
  end

  @doc false
  @spec render_success_text(map()) :: String.t()
  def render_success_text(structured) do
    result =
      cond do
        is_binary(Map.get(structured, "result")) ->
          Map.fetch!(structured, "result")

        Map.has_key?(structured, "validated") ->
          preview(Map.get(structured, "validated"))

        # `validated` was shaped into a preview (slim, or a structured value
        # over budget) — render the preview so the value is never silently
        # dropped if no string `result` accompanies it.
        is_binary(Map.get(structured, "validated_preview")) ->
          Map.fetch!(structured, "validated_preview")

        true ->
          ""
      end

    text =
      case Map.get(structured, "prints") do
        prints when is_list(prints) and prints != [] ->
          "<prints>\n" <>
            Enum.map_join(prints, "\n", &to_string/1) <> "\n\n<result>\n" <> result

        _ ->
          result
      end

    if Map.get(structured, "truncated") == true do
      text <> "\n\n[truncated]"
    else
      text
    end
  end

  @doc false
  @spec render_session_success_text(map()) :: String.t()
  def render_session_success_text(structured) do
    structured
    |> render_success_text()
    |> append_session_suffix(structured)
  end

  @doc false
  @spec render_error_text(map()) :: String.t()
  def render_error_text(structured) do
    reason = Map.get(structured, "reason")
    message = Map.get(structured, "message")
    feedback = Map.get(structured, "feedback")

    base =
      cond do
        is_binary(reason) and is_binary(message) and message != "" -> reason <> ": " <> message
        is_binary(message) and message != "" -> message
        is_binary(reason) and reason != "" -> reason
        true -> "error"
      end

    base
    |> append_feedback(feedback)
    |> append_upstream_error(Map.get(structured, "upstream_calls"))
  end

  @doc false
  @spec render_session_error_text(map()) :: String.t()
  def render_session_error_text(structured) do
    structured
    |> render_error_text()
    |> append_session_suffix(structured)
  end

  defp text_envelope(is_error, text) do
    %{
      "isError" => is_error,
      "content" => [%{"type" => "text", "text" => text}]
    }
  end

  defp maybe_put(map, key, value, opts \\ [])

  defp maybe_put(map, _key, nil, opts) do
    if Keyword.get(opts, :keep_nil?, true), do: map, else: map
  end

  defp maybe_put(map, key, value, _opts) do
    if value in ["", [], %{}], do: map, else: Map.put(map, key, value)
  end

  defp maybe_put_true(map, key, true), do: Map.put(map, key, true)
  defp maybe_put_true(map, _key, _), do: map

  defp compact_session_memory(memory) when is_map(memory) do
    %{}
    |> maybe_put("changed_keys", Map.get(memory, "changed_keys"), keep_nil?: false)
    |> maybe_put("stored_keys", Map.get(memory, "stored_keys"), keep_nil?: false)
    |> maybe_put_true("truncated", Map.get(memory, "truncated"))
  end

  defp compact_session_memory(_), do: nil

  defp compact_upstream_errors(entries) when is_list(entries) do
    compacted =
      entries
      |> Enum.filter(&(Map.get(&1, "status") == "error"))
      |> Enum.map(fn entry ->
        %{
          "server" => Map.get(entry, "server"),
          "tool" => Map.get(entry, "tool"),
          "status" => "error"
        }
        |> maybe_put("reason", Map.get(entry, "reason"))
      end)

    if compacted == [], do: nil, else: compacted
  end

  defp compact_upstream_errors(_), do: nil

  defp append_feedback(text, feedback) when is_binary(feedback) and feedback != "" do
    text <> "\n" <> feedback
  end

  defp append_feedback(text, _), do: text

  defp append_upstream_error(text, entries) when is_list(entries) do
    case Enum.find(entries, &(Map.get(&1, "status") == "error")) do
      nil ->
        text

      entry ->
        server = Map.get(entry, "server", "?")
        tool = Map.get(entry, "tool", "?")
        reason = Map.get(entry, "reason") || Map.get(entry, "error") || "error"
        text <> "\nupstream #{server}.#{tool} failed: #{reason}"
    end
  end

  defp append_upstream_error(text, _), do: text

  defp append_session_suffix(text, structured) do
    suffix =
      [
        rollback_suffix(structured),
        stored_suffix(Map.get(structured, "memory")),
        upstream_suffix(Map.get(structured, "upstream_calls"))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("; ")

    if suffix == "", do: text, else: join_text(text, "[" <> suffix <> "]")
  end

  defp rollback_suffix(%{"status" => "error"}), do: "rolled back"
  defp rollback_suffix(_), do: nil

  defp stored_suffix(%{"changed_keys" => keys}) when is_list(keys) and keys != [] do
    "stored: " <> Enum.map_join(keys, ", ", &to_string/1)
  end

  defp stored_suffix(_), do: nil

  defp upstream_suffix(entries) when is_list(entries) and entries != [] do
    "turn upstream calls: #{length(entries)}"
  end

  defp upstream_suffix(_), do: nil

  defp join_text("", suffix), do: suffix
  defp join_text(text, suffix), do: text <> "\n" <> suffix

  defp preview(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value)
    end
  end
end
