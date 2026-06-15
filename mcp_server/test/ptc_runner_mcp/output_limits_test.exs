defmodule PtcRunnerMcp.OutputLimitsTest do
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.{Envelope, OutputLimits}

  test "debug profile preserves validated only while it is under the exactness cap" do
    small = %{"status" => "ok", "validated" => ["ok"]}
    assert OutputLimits.shape_lisp_payload(small, :ok, :debug) == small

    large = %{
      "status" => "ok",
      "validated" => Enum.map(1..2_000, fn _ -> String.duplicate("x", 80) end)
    }

    shaped = OutputLimits.shape_lisp_payload(large, :ok, :debug)

    refute Map.has_key?(shaped, "validated")
    assert is_binary(shaped["validated_preview"])
    assert shaped["validated_bytes"] > 128 * 1024
    assert shaped["output_truncated"] == true
  end

  test "slim omits the structured validated value but records its size and preview" do
    shaped =
      %{"status" => "ok", "validated" => ["alpha", "beta"]}
      |> OutputLimits.shape_lisp_payload(:ok, :slim)

    refute Map.has_key?(shaped, "validated")
    assert shaped["validated_bytes"] == byte_size(Jason.encode!(["alpha", "beta"]))
    assert is_binary(shaped["validated_preview"])
    # A small value fits entirely in the preview — replacing the structured
    # value with a string rendering is not truncation, so the shaped payload
    # must not claim it was.
    refute Map.has_key?(shaped, "truncated")
    refute Map.has_key?(shaped, "output_truncated")
    refute Map.has_key?(shaped, "validated_preview_truncated")
  end

  test "slim flags truncation only when the validated preview itself drops data" do
    big = Enum.map(1..2_000, fn _ -> String.duplicate("x", 80) end)

    shaped =
      %{"status" => "ok", "validated" => big}
      |> OutputLimits.shape_lisp_payload(:ok, :slim)

    refute Map.has_key?(shaped, "validated")
    assert is_binary(shaped["validated_preview"])
    assert shaped["validated_preview_truncated"] == true
    assert shaped["truncated"] == true
    assert shaped["output_truncated"] == true
  end

  test "slim preserves a doc-sized print that the result-channel preview would truncate (P1)" do
    # `(doc ...)` now routes its rendered text through the print channel (P1).
    # On the :slim profile the result preview is capped at 512 chars, but the
    # print channel allows 8KB — so a ~700-char doc survives intact in prints,
    # the exact case the old result-channel `doc` path truncated.
    doc_text = "observatory/list-traces\nDescription: " <> String.duplicate("detail ", 100)
    assert byte_size(doc_text) > 512
    assert byte_size(doc_text) < 8 * 1024

    shaped =
      %{"status" => "ok", "prints" => [doc_text]}
      |> OutputLimits.shape_lisp_payload(:ok, :slim)

    assert shaped["prints"] == [doc_text]
    refute Map.has_key?(shaped, "prints_truncated")

    # Contrast: the same text in the RESULT channel is preview-truncated to 512.
    result_shaped =
      %{"status" => "ok", "validated" => doc_text}
      |> OutputLimits.shape_lisp_payload(:ok, :slim)

    assert result_shaped["validated_preview_truncated"] == true
  end

  test "slim success text renders the validated preview when the structured value was shaped away" do
    # The post-shaping shape: `validated` removed, only the preview remains,
    # and no string `result` accompanies it. The renderer must surface the
    # preview rather than dropping the value.
    shaped = %{"status" => "ok", "validated_preview" => ~s(["alpha" "beta"])}

    assert Envelope.render_success_text(shaped) == ~s(["alpha" "beta"])
  end

  test "session success text renders a brief stored/upstream suffix" do
    text =
      Envelope.render_session_success_text(%{
        "status" => "ok",
        "result" => "42",
        "memory" => %{"changed_keys" => ["all", "by-day"]},
        "upstream_calls" => [%{"server" => "fs"}, %{"server" => "fs"}]
      })

    assert text == "42\n[stored: all, by-day; turn upstream calls: 2]"
    refute text =~ "lisp_debug"
  end

  test "structured session success keeps print-only nil results visible" do
    envelope =
      %{
        "status" => "ok",
        "prints" => ["(defn profile [source opts] ...)"],
        "feedback" => "",
        "session" => %{"session_id" => "s1", "turn" => 2}
      }
      |> Envelope.ptc_lisp_session_success(response_profile: :structured)

    assert envelope["structuredContent"]["prints"] == ["(defn profile [source opts] ...)"]

    assert get_in(envelope, ["content", Access.at(0), "text"]) =~
             "(defn profile [source opts] ...)"
  end

  test "session error text marks rollback and turn-local upstream calls" do
    text =
      Envelope.render_session_error_text(%{
        "status" => "error",
        "reason" => "runtime_error",
        "message" => "boom",
        "feedback" => "boom",
        "upstream_calls" => [%{"server" => "fs"}]
      })

    assert text == "runtime_error: boom\n[rolled back; turn upstream calls: 1]"
    refute text =~ "lisp_debug"
  end

  test "error text avoids duplicated reason prefixes and feedback" do
    text =
      Envelope.render_session_error_text(%{
        "status" => "error",
        "reason" => "type_error",
        "message" => "type_error: sort-by key function failed",
        "feedback" => "type_error: sort-by key function failed"
      })

    assert text == "type_error: sort-by key function failed\n[rolled back]"
  end

  test "prints are capped by encoded byte budget and the kept prefix stays within budget" do
    # 10 prints of ~2 KB each (~20 KB total) — under slim's 20-entry cap, so the
    # 8 KB byte budget is what fires.
    big_prints = Enum.map(1..10, fn i -> "#{i}-" <> String.duplicate("x", 2_000) end)

    shaped =
      %{"status" => "ok", "prints" => big_prints}
      |> OutputLimits.shape_lisp_payload(:ok, :slim)

    kept = shaped["prints"]
    assert length(kept) < length(big_prints)
    assert shaped["prints_truncated"] == true
    # The kept prefix must actually encode within the slim print budget...
    assert byte_size(Jason.encode!(kept)) <= OutputLimits.policy(:slim).max_print_bytes
    # ...and it must be a true prefix, in original order.
    assert kept == Enum.take(big_prints, length(kept))
  end

  test "prints under budget are kept whole without a truncation flag" do
    small = Enum.map(1..5, fn i -> "line #{i}" end)

    shaped =
      %{"status" => "ok", "prints" => small}
      |> OutputLimits.shape_lisp_payload(:ok, :debug)

    assert shaped["prints"] == small
    refute Map.has_key?(shaped, "prints_truncated")
    refute Map.has_key?(shaped, "truncated")
  end

  test "final envelope guard shrinks valid MCP output instead of truncating raw JSON" do
    envelope =
      %{
        "status" => "ok",
        "result" => String.duplicate("r", 100_000),
        "prints" => Enum.map(1..100, fn _ -> String.duplicate("p", 1_000) end),
        "feedback" => String.duplicate("f", 100_000),
        "validated_preview" => String.duplicate("v", 100_000)
      }
      |> Envelope.success()
      |> OutputLimits.limit_envelope(:slim)

    assert Jason.encode!(envelope) |> byte_size() <= OutputLimits.policy(:slim).max_envelope_bytes
    assert envelope["isError"] == false
    assert [%{"type" => "text", "text" => text}] = envelope["content"]
    assert text =~ "[truncated]"
    refute Map.has_key?(envelope, "structuredContent")
  end

  test "final envelope guard preserves minimal structuredContent outside slim profile" do
    envelope =
      %{
        "status" => "ok",
        "result" => String.duplicate("r", 100_000),
        "prints" => Enum.map(1..100, fn _ -> String.duplicate("p", 1_000) end),
        "feedback" => String.duplicate("f", 100_000),
        "validated_preview" => String.duplicate("v", 100_000),
        "validated_bytes" => 250_000
      }
      |> Envelope.success()
      |> OutputLimits.limit_envelope(:structured)

    assert Jason.encode!(envelope) |> byte_size() <=
             OutputLimits.policy(:structured).max_envelope_bytes

    assert envelope["isError"] == false

    assert envelope["structuredContent"] == %{
             "status" => "ok",
             "validated_bytes" => 250_000,
             "truncated" => true,
             "output_truncated" => true
           }

    assert hd(envelope["content"])["text"] =~ "[truncated]"
  end

  test "structured fallback caps huge error message in minimal structuredContent" do
    envelope =
      %{
        "status" => "error",
        "reason" => "runtime_error",
        "message" => String.duplicate("m", 200_000),
        "feedback" => String.duplicate("f", 100_000)
      }
      |> Envelope.error_envelope()
      |> OutputLimits.limit_envelope(:structured)

    assert Jason.encode!(envelope) |> byte_size() <=
             OutputLimits.policy(:structured).max_envelope_bytes

    assert envelope["isError"] == true
    assert envelope["structuredContent"]["status"] == "error"
    assert envelope["structuredContent"]["reason"] == "runtime_error"
    assert byte_size(envelope["structuredContent"]["message"]) < 5_000
    assert envelope["structuredContent"]["message"] =~ "[truncated]"
    assert envelope["structuredContent"]["output_truncated"] == true
  end
end
