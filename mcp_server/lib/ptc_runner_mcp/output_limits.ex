defmodule PtcRunnerMcp.OutputLimits do
  @moduledoc """
  Client-facing MCP output shaping.

  This module is deliberately policy-only: PTC-Lisp execution still produces
  the same payloads, then the MCP server trims fields that are expensive or
  unsafe to hand directly to an LLM client.
  """

  alias PtcRunner.Lisp.Format

  @type profile :: :slim | :structured | :debug
  @type kind :: :ok | :error

  @default_policies %{
    slim: %{
      max_print_entries: 20,
      max_print_bytes: 8 * 1024,
      max_feedback_bytes: 8 * 1024,
      max_validated_bytes: 0,
      validated_preview_chars: 512,
      max_envelope_bytes: 32 * 1024
    },
    structured: %{
      max_print_entries: 50,
      max_print_bytes: 16 * 1024,
      max_feedback_bytes: 16 * 1024,
      max_validated_bytes: 32 * 1024,
      validated_preview_chars: 1024,
      max_envelope_bytes: 96 * 1024
    },
    debug: %{
      max_print_entries: 200,
      max_print_bytes: 64 * 1024,
      max_feedback_bytes: 64 * 1024,
      max_validated_bytes: 128 * 1024,
      validated_preview_chars: 2048,
      max_envelope_bytes: 512 * 1024
    }
  }

  @doc "Return the client-output policy for a response profile."
  @spec policy(profile()) :: map()
  def policy(profile) when is_atom(profile), do: Map.fetch!(@default_policies, profile)

  @doc "Shape a stateless `lisp_eval` payload before it is wrapped as an MCP envelope."
  @spec shape_lisp_payload(map(), kind(), profile()) :: map()
  def shape_lisp_payload(payload, kind, profile)
      when is_map(payload) and kind in [:ok, :error] and is_atom(profile) do
    shape_common_payload(payload, profile)
  end

  @doc "Shape a stateful session payload before it is wrapped as an MCP envelope."
  @spec shape_session_payload(map(), kind(), profile()) :: map()
  def shape_session_payload(payload, kind, profile)
      when is_map(payload) and kind in [:ok, :error] and is_atom(profile) do
    shape_common_payload(payload, profile)
  end

  @doc """
  Final fully-serialized envelope guard.

  This is a last resort after payload shaping. It preserves valid JSON/MCP
  structure and drops heavy optional fields instead of slicing raw JSON bytes.
  """
  @spec limit_envelope(map(), profile()) :: map()
  def limit_envelope(envelope, profile) when is_map(envelope) and is_atom(profile) do
    limit = policy(profile).max_envelope_bytes

    if encoded_size(envelope) <= limit do
      envelope
    else
      envelope
      |> shrink_envelope()
      |> then(fn shrunk ->
        if encoded_size(shrunk) <= limit do
          shrunk
        else
          fallback_envelope(shrunk, profile, limit)
        end
      end)
    end
  end

  defp shape_common_payload(payload, profile) do
    limits = policy(profile)

    payload
    |> cap_prints(limits)
    |> cap_feedback(limits)
    |> cap_validated(limits)
  end

  defp cap_prints(%{"prints" => prints} = payload, limits) when is_list(prints) do
    {capped, truncated?} =
      cap_list_by_encoded_bytes(
        prints,
        limits.max_print_entries,
        limits.max_print_bytes
      )

    payload
    |> Map.put("prints", capped)
    |> mark_if(truncated?, "prints_truncated")
  end

  defp cap_prints(payload, _limits), do: payload

  defp cap_feedback(%{"feedback" => feedback} = payload, limits) when is_binary(feedback) do
    {capped, truncated?} = utf8_take(feedback, limits.max_feedback_bytes)

    payload
    |> Map.put("feedback", capped)
    |> mark_if(truncated?, "feedback_truncated")
  end

  defp cap_feedback(payload, _limits), do: payload

  # Slim policy (`max_validated_bytes: 0`): always replace the structured
  # `validated` value with a string preview, regardless of size. This is a
  # rendering choice, not a loss — `put_validated_preview/3` already flags
  # `truncated` (via `mark_if`) when the preview itself drops data, so we do
  # NOT mark truncated unconditionally here. Doing so falsely told clients a
  # complete small value had been truncated.
  defp cap_validated(%{"validated" => value} = payload, %{max_validated_bytes: 0} = limits) do
    payload
    |> Map.delete("validated")
    |> maybe_put_validated_bytes(value)
    |> put_validated_preview(value, limits)
  end

  defp cap_validated(%{"validated" => value} = payload, limits) do
    case Jason.encode(value) do
      {:ok, json} ->
        bytes = byte_size(json)

        if bytes <= limits.max_validated_bytes do
          payload
        else
          payload
          |> Map.delete("validated")
          |> Map.put("validated_bytes", bytes)
          |> put_validated_preview(value, limits)
          |> mark_truncated()
        end

      {:error, _reason} ->
        payload
        |> Map.delete("validated")
        |> put_validated_preview(value, limits)
        |> mark_truncated()
    end
  end

  defp cap_validated(payload, _limits), do: payload

  defp put_validated_preview(payload, value, limits) do
    {preview, preview_truncated?} =
      Format.to_clojure(value, limit: 20, printable_limit: limits.validated_preview_chars)

    payload
    |> Map.put("validated_preview", preview)
    |> mark_if(preview_truncated?, "validated_preview_truncated")
  end

  defp maybe_put_validated_bytes(payload, value) do
    case Jason.encode(value) do
      {:ok, json} -> Map.put(payload, "validated_bytes", byte_size(json))
      {:error, _reason} -> payload
    end
  end

  defp cap_list_by_encoded_bytes(items, max_entries, max_bytes) do
    limited = Enum.take(items, max_entries)

    {kept, _size} =
      Enum.reduce_while(limited, {[], 2}, fn item, {acc, _size} ->
        candidate = acc ++ [item]

        case Jason.encode(candidate) do
          {:ok, json} when byte_size(json) <= max_bytes ->
            {:cont, {candidate, byte_size(json)}}

          _ ->
            {:halt, {acc, encoded_size(acc)}}
        end
      end)

    truncated? = length(kept) < length(items)
    {kept, truncated?}
  end

  defp shrink_envelope(%{"structuredContent" => sc} = envelope) when is_map(sc) do
    shrunk_sc =
      sc
      |> Map.drop([
        "prints",
        "feedback",
        "validated_preview",
        "upstream_results",
        "upstream_calls",
        "ptc_metrics"
      ])
      |> mark_truncated()

    envelope
    |> Map.put("structuredContent", shrunk_sc)
    |> Map.put("content", [%{"type" => "text", "text" => fallback_text(shrunk_sc)}])
  end

  defp shrink_envelope(%{"content" => [%{"type" => "text", "text" => text} | _]} = envelope)
       when is_binary(text) do
    {capped, _truncated?} = utf8_take(text, 16 * 1024)
    Map.put(envelope, "content", [%{"type" => "text", "text" => capped <> "\n\n[truncated]"}])
  end

  defp shrink_envelope(envelope), do: envelope

  defp fallback_envelope(envelope, :slim, limit), do: text_only_fallback(envelope, limit)

  defp fallback_envelope(envelope, _profile, limit) do
    structured = minimal_structured_content(envelope, limit)
    text = fallback_text(structured)

    max_text =
      max(limit - encoded_size(%{"isError" => false, "structuredContent" => structured}) - 256, 0)

    {capped, truncated?} = utf8_take(text, max_text)

    %{
      "isError" => Map.get(envelope, "isError", false),
      "structuredContent" => structured,
      "content" => [
        %{
          "type" => "text",
          "text" => capped <> if(truncated?, do: "\n\n[truncated]", else: "")
        }
      ]
    }
  end

  defp text_only_fallback(envelope, limit) do
    text = fallback_text(Map.get(envelope, "structuredContent", %{}))
    max_text = max(limit - 512, 0)
    {capped, truncated?} = utf8_take(text, max_text)

    %{
      "isError" => Map.get(envelope, "isError", false),
      "content" => [
        %{
          "type" => "text",
          "text" => capped <> if(truncated?, do: "\n\n[truncated]", else: "")
        }
      ]
    }
  end

  defp fallback_text(%{"reason" => reason, "message" => message})
       when is_binary(reason) and is_binary(message),
       do: reason <> ": " <> message <> "\n\n[truncated]"

  defp fallback_text(%{"result" => result}) when is_binary(result),
    do: result <> "\n\n[truncated]"

  defp fallback_text(_), do: "MCP output exceeded response limit.\n\n[truncated]"

  defp minimal_structured_content(%{"structuredContent" => sc}, limit) when is_map(sc) do
    status =
      case Map.get(sc, "status") do
        status when status in ["ok", "error"] -> status
        _other -> "ok"
      end

    max_field_bytes = minimal_text_field_bytes(limit)

    %{"status" => status}
    |> maybe_put_capped_text("reason", Map.get(sc, "reason"), max_field_bytes)
    |> maybe_put_capped_text("message", Map.get(sc, "message"), max_field_bytes)
    |> maybe_put("validated_bytes", Map.get(sc, "validated_bytes"))
    |> mark_truncated()
  end

  defp minimal_structured_content(%{"isError" => true}, _limit),
    do: mark_truncated(%{"status" => "error"})

  defp minimal_structured_content(_envelope, _limit), do: mark_truncated(%{"status" => "ok"})

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_capped_text(map, _key, value, _max_bytes) when not is_binary(value), do: map

  defp maybe_put_capped_text(map, key, value, max_bytes) do
    {capped, truncated?} = utf8_take(value, max_bytes)

    text =
      if truncated? do
        capped <> "\n\n[truncated]"
      else
        capped
      end

    Map.put(map, key, text)
  end

  defp minimal_text_field_bytes(limit), do: min(4 * 1024, max(div(limit, 8), 256))

  defp mark_if(payload, true, key), do: payload |> Map.put(key, true) |> mark_truncated()
  defp mark_if(payload, _false, _key), do: payload

  defp mark_truncated(payload) do
    payload
    |> Map.put("truncated", true)
    |> Map.put("output_truncated", true)
  end

  defp utf8_take(text, max_bytes) when is_binary(text) and byte_size(text) <= max_bytes,
    do: {text, false}

  defp utf8_take(_text, max_bytes) when max_bytes <= 0, do: {"", true}

  defp utf8_take(text, max_bytes) when is_binary(text) do
    chunk = binary_part(text, 0, max_bytes)

    if String.valid?(chunk) do
      {chunk, true}
    else
      utf8_take(text, max_bytes - 1)
    end
  end

  defp encoded_size(value) do
    case Jason.encode(value) do
      {:ok, json} -> byte_size(json)
      {:error, _} -> value |> inspect(limit: 50, printable_limit: 500) |> byte_size()
    end
  end
end
