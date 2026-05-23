defmodule PtcRunnerMcp.UpstreamResultFeedbackTest do
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.{UpstreamCalls, UpstreamResultFeedback}

  describe "render/1" do
    test "renders projected upstream_results as a compact untrusted summary" do
      text =
        UpstreamResultFeedback.render([
          %{
            "server" => "filesystem",
            "tool" => "list_directory",
            "status" => "ok",
            "shape" => "map keys=[\"content\"] count=1",
            "preview" => %{"content" => "[FILE] README.md\n[DIR] docs"} |> inspect()
          }
        ])

      assert text =~ "source=\"upstream-tool-results\""
      assert text =~ "Tool results before error"
      assert text =~ "filesystem.list_directory ok"
      assert text =~ "map keys=[\"content\"]"
      assert text =~ "[FILE] README.md"
    end

    test "normalizes raw lisp_eval upstream entries before rendering" do
      entry =
        UpstreamCalls.success_entry("alpha", "get", 3,
          result_bytes: 42,
          result_overview: UpstreamCalls.result_overview(%{"content" => "hello"}, :json)
        )

      text = UpstreamResultFeedback.render([entry])

      assert text =~ "alpha.get ok"
      assert text =~ "map keys=[\"content\"]"
      assert text =~ "\"content\""
    end

    test "normalizes raw lisp_task ledger entries before rendering" do
      text =
        UpstreamResultFeedback.render([
          %{
            server: "alpha",
            tool: "get",
            status: :ok,
            effect: :read,
            turn: 1,
            args_hash: "abc",
            result_overview: %{
              "value_kind" => "json",
              "shape" => "map keys=[\"content\"] count=1",
              "preview" => "{\"content\":\"hello\"}"
            }
          }
        ])

      assert text =~ "alpha.get ok"
      assert text =~ "map keys=[\"content\"]"
      assert text =~ "hello"
    end

    test "caps entries and total feedback size" do
      entries =
        for n <- 1..8 do
          %{
            "server" => "s#{n}",
            "tool" => "t",
            "status" => "ok",
            "shape" => "string bytes=1000",
            "preview" => String.duplicate("x", 1000)
          }
        end

      text = UpstreamResultFeedback.render(entries)

      assert text =~ "s1.t ok"
      assert text =~ "s3.t ok"
      refute text =~ "s4.t ok"
      assert byte_size(text) < 900
    end
  end

  describe "append_to_feedback/2" do
    test "appends to existing feedback" do
      payload =
        UpstreamResultFeedback.append_to_feedback(
          %{"feedback" => "type_error: bad value"},
          [
            %{
              "server" => "alpha",
              "tool" => "get",
              "status" => "error",
              "reason" => "upstream_error",
              "error" => "boom"
            }
          ]
        )

      assert payload["feedback"] =~ "type_error: bad value"
      assert payload["feedback"] =~ "alpha.get error"
      assert payload["feedback"] =~ "upstream_error boom"
    end
  end
end
