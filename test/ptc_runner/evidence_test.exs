defmodule PtcRunner.EvidenceTest do
  use ExUnit.Case, async: true

  alias PtcRunner.{Evidence, Lisp}
  alias PtcRunner.Evidence.{Bundle, ReadProjection}
  alias PtcRunner.Step
  alias PtcRunner.TraceLog.{Introspection, TurnEvent}

  @tag :tmp_dir
  test "serves visible fixture items and hides operator-only items", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "summary.md"), "observed facts\n")
    File.write!(Path.join(dir, "answer.json"), ~S({"expected":"secret"}))
    manifest_path = write_manifest!(dir, visible_fixture_manifest())

    tools = Evidence.tools(manifest_path)

    assert %{
             "bundle_id" => "demo/analyst",
             "bundle_checksum" => "sha256:" <> _,
             "items" => [%{"item_id" => "summary", "kind" => "markdown"}]
           } = tools["evidence_bundle"].(%{})

    assert %{
             "items" => [%{"bundle_id" => "demo/analyst", "item_id" => "summary"}],
             "next_cursor" => nil,
             "has_more" => false
           } = tools["evidence_page"].(%{})

    assert %{
             "bundle_id" => "demo/analyst",
             "item_id" => "summary",
             "source_ref" => "summary.md",
             "content" => "observed facts\n",
             "checksum" => "sha256:" <> _,
             "bytes" => 15,
             "truncated" => false
           } = tools["evidence_read"].(%{"id" => "summary"})

    refute inspect(tools["evidence_bundle"].(%{})) =~ "expected-layer"

    assert_raise ArgumentError, ~r/unknown evidence item "expected-layer"/, fn ->
      tools["evidence_read"].(%{"id" => "expected-layer"})
    end

    assert_raise ArgumentError, ~r/unknown evidence item "missing"/, fn ->
      tools["evidence_read"].(%{"id" => "missing"})
    end
  end

  @tag :tmp_dir
  test "bundle checksum excludes hidden items while manifest checksum tracks them", %{
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, "summary.md"), "same\n")
    File.write!(Path.join(dir, "answer.json"), ~S({"expected":"one"}))
    first = Bundle.load!(write_manifest!(dir, visible_fixture_manifest()))

    File.write!(Path.join(dir, "answer.json"), ~S({"expected":"two"}))
    second = Bundle.load!(write_manifest!(dir, visible_fixture_manifest()))

    assert first.bundle_checksum == second.bundle_checksum
    assert first.manifest_checksum != second.manifest_checksum
  end

  @tag :tmp_dir
  test "manifest checksum tracks hidden bytes beyond item byte caps", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "summary.md"), "same\n")
    File.write!(Path.join(dir, "answer.json"), "same-prefix-" <> String.duplicate("a", 128))

    manifest =
      visible_fixture_manifest()
      |> Map.put("max_item_bytes", 16)

    first = Bundle.load!(write_manifest!(dir, manifest))

    File.write!(Path.join(dir, "answer.json"), "same-prefix-" <> String.duplicate("b", 128))
    second = Bundle.load!(write_manifest!(dir, manifest))

    assert first.bundle_checksum == second.bundle_checksum
    assert first.manifest_checksum != second.manifest_checksum
    refute inspect(second) =~ "same-prefix-"
    refute inspect(second) =~ String.duplicate("b", 32)
  end

  @tag :tmp_dir
  test "refuses file path escapes and permits log sources only through allowed roots", %{
    tmp_dir: dir
  } do
    File.mkdir_p!(Path.join(dir, "bundle"))
    File.mkdir_p!(Path.join(dir, "logs"))
    File.write!(Path.join([dir, "logs", "turns.jsonl"]), "")

    File.write!(
      Path.join([dir, "bundle", "manifest.json"]),
      Jason.encode!(%{
        "schema_version" => 1,
        "bundle_id" => "demo/path",
        "items" => [
          %{
            "id" => "bad",
            "kind" => "markdown",
            "path" => "../secret.md",
            "model_visible" => true
          }
        ]
      })
    )

    assert_raise ArgumentError, ~r/may not contain \.\./, fn ->
      Bundle.load!(Path.join([dir, "bundle", "manifest.json"]))
    end

    File.ln_s!(Path.join(dir, "logs"), Path.join([dir, "bundle", "turn-logs"]))

    manifest =
      write_manifest!(Path.join(dir, "bundle"), %{
        "schema_version" => 1,
        "bundle_id" => "demo/logs",
        "items" => [
          %{
            "id" => "counters",
            "kind" => "log_counters",
            "log_source" => "turn-logs",
            "model_visible" => true
          }
        ]
      })

    assert_raise ArgumentError, ~r/escapes bundle root/, fn ->
      Bundle.load!(manifest)
    end

    assert %Bundle{} = Bundle.load!(manifest, allowed_log_roots: [Path.join(dir, "logs")])
  end

  @tag :tmp_dir
  test "projects log counters and safe log turns with canonical structured checksums", %{
    tmp_dir: dir
  } do
    log_dir = Path.join(dir, "turn-logs")
    File.mkdir_p!(log_dir)

    write_jsonl!(Path.join(log_dir, "a.jsonl"), [
      turn_event("reviewer", 1, %{"stage" => "reviewer"}, "(+ 1 2)", nil),
      turn_event("editor", 1, %{"stage" => "editor"}, "(def x 1)", nil),
      turn_event("editor", 2, %{"stage" => "editor"}, "(missing)", %{"reason" => "unbound_var"})
    ])

    manifest =
      write_manifest!(dir, %{
        "schema_version" => 1,
        "bundle_id" => "demo/logs",
        "items" => [
          %{
            "id" => "editor-counters",
            "kind" => "log_counters",
            "log_source" => "turn-logs",
            "filters" => %{"tags" => %{"stage" => "editor"}},
            "model_visible" => true
          },
          %{
            "id" => "editor-turns",
            "kind" => "log_turns",
            "log_source" => "turn-logs",
            "filters" => %{"tags" => %{"stage" => "editor"}},
            "fields" => [
              "turn",
              "attempt",
              "committed",
              "status",
              "tags",
              "catalog_ops_count",
              "fail.reason"
            ],
            "model_visible" => true
          }
        ]
      })

    tools = Evidence.tools(manifest)

    assert %{
             "kind" => "log_counters",
             "data" => %{
               "sessions" => 1,
               "attempts" => 2,
               "duration_ms" => 12,
               "input_tokens" => nil,
               "input_tokens_known_count" => 0
             },
             "checksum" => counters_checksum,
             "bytes" => counters_bytes
           } = tools["evidence_read"].(%{"id" => "editor-counters"})

    assert is_binary(counters_checksum)
    assert counters_bytes > 0

    assert %{
             "kind" => "log_turns",
             "data" => [
               %{
                 "turn" => 1,
                 "attempt" => 1,
                 "committed" => true,
                 "catalog_ops_count" => 0,
                 "fail" => %{"reason" => nil}
               },
               %{"turn" => 2, "attempt" => 2, "fail" => %{"reason" => "unbound_var"}}
             ]
           } = turns = tools["evidence_read"].(%{"id" => "editor-turns"})

    assert turns["bytes"] == byte_size(Bundle.canonical_json!(turns["data"]))
    assert turns["checksum"] == checksum_bytes(Bundle.canonical_json!(turns["data"]))

    refute inspect(turns) =~ "(def x 1)"
    refute inspect(turns) =~ "result_preview"

    assert %{"items" => [_], "has_more" => true, "next_cursor" => "1", "limit" => 1} =
             tools["evidence_page"].(%{"limit" => 1})
  end

  @tag :tmp_dir
  test "log counter evidence stays in parity with log introspection counters", %{tmp_dir: dir} do
    log_dir = Path.join(dir, "turn-logs")
    File.mkdir_p!(log_dir)

    events = [
      turn_event("editor", 1, %{"stage" => "editor"}, "(+ 1 2)", nil),
      turn_event("reviewer", 1, %{"stage" => "reviewer"}, "(+ 2 3)", nil)
    ]

    write_jsonl!(Path.join(log_dir, "a.jsonl"), events)

    manifest =
      write_manifest!(dir, %{
        "schema_version" => 1,
        "bundle_id" => "demo/log-parity",
        "items" => [
          %{
            "id" => "editor-counters",
            "kind" => "log_counters",
            "log_source" => "turn-logs",
            "filters" => %{"tags" => %{"stage" => "editor"}},
            "model_visible" => true
          }
        ]
      })

    evidence_counters = Bundle.load!(manifest) |> Bundle.read(%{"id" => "editor-counters"})

    log_counters =
      Introspection.tools(events)["log_counters"].(%{"tags" => %{"stage" => "editor"}})

    assert evidence_counters["data"] == log_counters
  end

  test "canonical JSON bytes recursively sort large nested maps" do
    wide =
      for index <- 34..0//-1, into: %{} do
        {"k" <> String.pad_leading(Integer.to_string(index), 2, "0"), index}
      end

    data = %{
      "z" => 1,
      "list" => [%{"b" => 2, "a" => 1}],
      "a" => Map.put(wide, "inner", %{"b" => 2, "a" => 1})
    }

    expected =
      ~S({"a":{"inner":{"a":1,"b":2},"k00":0,"k01":1,"k02":2,"k03":3,"k04":4,"k05":5,"k06":6,"k07":7,"k08":8,"k09":9,"k10":10,"k11":11,"k12":12,"k13":13,"k14":14,"k15":15,"k16":16,"k17":17,"k18":18,"k19":19,"k20":20,"k21":21,"k22":22,"k23":23,"k24":24,"k25":25,"k26":26,"k27":27,"k28":28,"k29":29,"k30":30,"k31":31,"k32":32,"k33":33,"k34":34},"list":[{"a":1,"b":2}],"z":1})

    assert Bundle.canonical_json!(data) == expected
  end

  @tag :tmp_dir
  test "rejects unsafe log_turns fields", %{tmp_dir: dir} do
    log_dir = Path.join(dir, "turn-logs")
    File.mkdir_p!(log_dir)
    write_jsonl!(Path.join(log_dir, "a.jsonl"), [])

    manifest =
      write_manifest!(dir, %{
        "schema_version" => 1,
        "bundle_id" => "demo/unsafe",
        "items" => [
          %{
            "id" => "turns",
            "kind" => "log_turns",
            "log_source" => "turn-logs",
            "fields" => ["program"],
            "model_visible" => true
          }
        ]
      })

    assert_raise ArgumentError, ~r/unsafe log_turns field/, fn -> Bundle.load!(manifest) end
  end

  @tag :tmp_dir
  test "rejects oversized structured log evidence", %{tmp_dir: dir} do
    log_dir = Path.join(dir, "turn-logs")
    File.mkdir_p!(log_dir)

    write_jsonl!(Path.join(log_dir, "a.jsonl"), [
      turn_event(
        "editor",
        1,
        %{"stage" => "editor", "long" => String.duplicate("x", 200)},
        "(+ 1 2)",
        nil
      )
    ])

    manifest =
      write_manifest!(dir, %{
        "schema_version" => 1,
        "bundle_id" => "demo/oversize",
        "max_item_bytes" => 64,
        "items" => [
          %{
            "id" => "turns",
            "kind" => "log_turns",
            "log_source" => "turn-logs",
            "fields" => ["turn", "tags"],
            "model_visible" => true
          }
        ]
      })

    assert_raise ArgumentError, ~r/exceeding max_item_bytes 64/, fn ->
      Bundle.load!(manifest)
    end
  end

  @tag :tmp_dir
  test "rejects log evidence when input JSONL bytes exceed max_item_bytes", %{tmp_dir: dir} do
    log_dir = Path.join(dir, "turn-logs")
    File.mkdir_p!(log_dir)

    write_jsonl!(Path.join(log_dir, "a.jsonl"), [
      turn_event("editor", 1, %{"stage" => String.duplicate("x", 80)}, "(+ 1 2)", nil)
    ])

    manifest =
      write_manifest!(dir, %{
        "schema_version" => 1,
        "bundle_id" => "demo/input-oversize",
        "max_item_bytes" => 64,
        "items" => [
          %{
            "id" => "counters",
            "kind" => "log_counters",
            "log_source" => "turn-logs",
            "model_visible" => true
          }
        ]
      })

    assert_raise ArgumentError, ~r/evidence log_source .* exceeding max_item_bytes 64/, fn ->
      Bundle.load!(manifest)
    end
  end

  @tag :tmp_dir
  test "rejects oversized prelude export evidence before serving it as complete", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "export.json"),
      Jason.encode!(%{"source" => String.duplicate("x", 200)})
    )

    manifest =
      write_manifest!(dir, %{
        "schema_version" => 1,
        "bundle_id" => "demo/prelude-export",
        "max_item_bytes" => 64,
        "items" => [
          %{
            "id" => "export",
            "kind" => "prelude_export",
            "path" => "export.json",
            "model_visible" => true
          }
        ]
      })

    assert_raise ArgumentError,
                 ~r/evidence prelude_export "export" .* exceeding max_item_bytes 64/,
                 fn ->
                   Bundle.load!(manifest)
                 end
  end

  @tag :tmp_dir
  test "visible file reads are bounded to served bytes", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "summary.md"), "abcdef")

    manifest =
      write_manifest!(dir, %{
        "schema_version" => 1,
        "bundle_id" => "demo/bounded-file",
        "max_item_bytes" => 3,
        "items" => [
          %{
            "id" => "summary",
            "kind" => "markdown",
            "path" => "summary.md",
            "model_visible" => true
          }
        ]
      })

    bundle = Bundle.load!(manifest)

    assert %{
             "content" => "abc",
             "bytes" => 3,
             "checksum" => checksum,
             "truncated" => true
           } = Bundle.read(bundle, %{"id" => "summary"})

    assert checksum ==
             :crypto.hash(:sha256, "abc")
             |> Base.encode16(case: :lower)
             |> then(&("sha256:" <> &1))
  end

  @tag :tmp_dir
  test "visible file truncation preserves valid UTF-8", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "summary.md"), "éclair")

    manifest =
      write_manifest!(dir, %{
        "schema_version" => 1,
        "bundle_id" => "demo/utf8-file",
        "max_item_bytes" => 1,
        "items" => [
          %{
            "id" => "summary",
            "kind" => "markdown",
            "path" => "summary.md",
            "model_visible" => true
          }
        ]
      })

    bundle = Bundle.load!(manifest)

    assert %{
             "content" => "",
             "bytes" => 0,
             "checksum" => checksum,
             "truncated" => true
           } = Bundle.read(bundle, %{"id" => "summary"})

    assert String.valid?(Bundle.read(bundle, %{"id" => "summary"})["content"])
    assert checksum == checksum_bytes("")
  end

  @tag :tmp_dir
  test "evidence pages are capped so turn-log audits keep item-level checksums", %{tmp_dir: dir} do
    items =
      for index <- 1..120 do
        id = "item-#{index}"
        File.write!(Path.join(dir, "#{id}.md"), "item #{index}")

        %{
          "id" => id,
          "kind" => "markdown",
          "path" => "#{id}.md",
          "model_visible" => true
        }
      end

    bundle =
      Bundle.load!(
        write_manifest!(dir, %{
          "schema_version" => 1,
          "bundle_id" => "demo/page-cap",
          "items" => items
        })
      )

    page = Bundle.page(bundle, %{"all" => true, "limit" => 500})

    assert length(page["items"]) == 100
    assert page["limit"] == 100
    assert page["has_more"] == true
    assert page["next_cursor"] == "100"

    turn =
      TurnEvent.build(%{
        driver: :session,
        evidence_reads: ReadProjection.from_result(page)
      })

    assert reads = get_in(turn, ["data", "evidence_reads"])
    assert is_list(reads)
    assert length(reads) == 100
    assert Enum.all?(reads, &match?(%{"item_id" => _, "checksum" => "sha256:" <> _}, &1))
  end

  @tag :tmp_dir
  test "evidence prelude reads through granted tools and fails closed without them", %{
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, "summary.md"), "hello")
    File.write!(Path.join(dir, "answer.json"), "{}")
    tools = Evidence.tools(write_manifest!(dir, visible_fixture_manifest()))

    assert {:ok, %Step{return: "hello"}} =
             Lisp.run(~S|(get (evidence/read "summary") "content")|,
               prelude: Evidence.prelude_source(),
               tools: tools
             )

    assert {:error, %Step{} = step} =
             Lisp.run(~S|(evidence/bundle)|, prelude: Evidence.prelude_source(), tools: %{})

    assert step.fail.reason == :prelude_attach_failed
    assert step.fail.message =~ "evidence_bundle"
  end

  defp visible_fixture_manifest do
    %{
      "schema_version" => 1,
      "bundle_id" => "demo/analyst",
      "description" => "Analyst evidence",
      "items" => [
        %{
          "id" => "summary",
          "kind" => "markdown",
          "path" => "summary.md",
          "model_visible" => true
        },
        %{
          "id" => "expected-layer",
          "kind" => "answer_key",
          "path" => "answer.json",
          "model_visible" => false
        }
      ]
    }
  end

  defp checksum_bytes(bytes) do
    bytes
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("sha256:" <> &1))
  end

  defp write_manifest!(dir, manifest) do
    path = Path.join(dir, "manifest.json")
    File.write!(path, Jason.encode!(manifest, pretty: true))
    path
  end

  defp write_jsonl!(path, events) do
    File.write!(path, Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n")
  end

  defp turn_event(session_id, turn, tags, program, fail) do
    %{
      "schema_version" => 2,
      "event" => "turn",
      "driver" => "session",
      "session_id" => session_id,
      "turn" => turn,
      "attempt" => turn,
      "committed" => is_nil(fail),
      "status" => if(is_nil(fail), do: "ok", else: "error"),
      "duration_ms" => 6,
      "tags" => tags,
      "data" => %{
        "program" => program,
        "result_preview" => "preview",
        "tool_calls" => [],
        "catalog_ops" => [],
        "fail" => fail
      }
    }
  end
end
