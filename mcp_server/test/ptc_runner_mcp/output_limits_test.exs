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

  test "zero validated cap still records validated byte size when exact value is omitted" do
    shaped =
      %{"status" => "ok", "validated" => ["alpha", "beta"]}
      |> OutputLimits.shape_lisp_payload(:ok, :slim)

    refute Map.has_key?(shaped, "validated")
    assert shaped["validated_bytes"] == byte_size(Jason.encode!(["alpha", "beta"]))
    assert is_binary(shaped["validated_preview"])
    assert shaped["output_truncated"] == true
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
