defmodule PtcRunnerMcp.Agentic.RendererTest do
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.Agentic.Renderer

  # Renderer is the pure core the agentic SubAgent handler calls AFTER eval:
  #   Renderer.render(%{"result" => step.return}, validated.constraints, cfg.max_result_bytes)
  #   Renderer.normalize_constraints(constraints)
  # These tests drive those public functions with the realistic execution payload
  # shapes the SubAgent produces (%{"result" => ...} / %{"validated" => ...}).

  describe "normalize_constraints/1" do
    test "nil yields empty constraints with no warnings" do
      assert Renderer.normalize_constraints(nil) == {:ok, %{}, []}
    end

    test "valid max_items (positive integer) is retained" do
      assert Renderer.normalize_constraints(%{"max_items" => 3}) == {:ok, %{"max_items" => 3}, []}
    end

    test "max_items of zero is treated as unsupported (not > 0)" do
      assert {:ok, known, [warning]} = Renderer.normalize_constraints(%{"max_items" => 0})
      assert known == %{}
      assert warning == %{"code" => "unsupported_constraint", "detail" => "max_items"}
    end

    test "max_items with non-integer value falls through to unsupported string key" do
      assert {:ok, %{}, [warning]} = Renderer.normalize_constraints(%{"max_items" => "5"})
      assert warning == %{"code" => "unsupported_constraint", "detail" => "max_items"}
    end

    test "preferred_fields list keeps only non-empty binaries" do
      constraints = %{"preferred_fields" => ["name", "", "age", 7, nil, "city"]}

      assert Renderer.normalize_constraints(constraints) ==
               {:ok, %{"preferred_fields" => ["name", "age", "city"]}, []}
    end

    test "preferred_fields that is not a list falls through to unsupported string key" do
      assert {:ok, %{}, [warning]} =
               Renderer.normalize_constraints(%{"preferred_fields" => "name"})

      assert warning == %{"code" => "unsupported_constraint", "detail" => "preferred_fields"}
    end

    test "unsupported string key produces a warning naming the key verbatim" do
      assert {:ok, %{}, [warning]} = Renderer.normalize_constraints(%{"sort_by" => "name"})
      assert warning == %{"code" => "unsupported_constraint", "detail" => "sort_by"}
    end

    test "unsupported non-string key is inspected in the warning detail" do
      assert {:ok, %{}, [warning]} = Renderer.normalize_constraints(%{42 => "x"})
      assert warning == %{"code" => "unsupported_constraint", "detail" => "42"}
    end

    test "unsupported atom key is inspected in the warning detail" do
      assert {:ok, %{}, [warning]} = Renderer.normalize_constraints(%{:weird => 1})
      assert warning == %{"code" => "unsupported_constraint", "detail" => ":weird"}
    end

    test "warnings preserve source order across multiple unsupported keys" do
      # ordered map literal -> reduce + reverse keeps insertion order deterministic here
      assert {:ok, _known, warnings} =
               Renderer.normalize_constraints(%{"a" => 1, "b" => 2})

      details = Enum.map(warnings, & &1["detail"])
      assert Enum.sort(details) == ["a", "b"]
    end

    test "valid and unsupported keys combine known map with warnings" do
      constraints = %{"max_items" => 2, "preferred_fields" => ["x"], "extra" => true}

      assert {:ok, known, [warning]} = Renderer.normalize_constraints(constraints)
      assert known == %{"max_items" => 2, "preferred_fields" => ["x"]}
      assert warning == %{"code" => "unsupported_constraint", "detail" => "extra"}
    end

    test "non-map boolean value is rejected with the boolean type label" do
      assert Renderer.normalize_constraints(true) ==
               {:error, "argument `constraints` must be a JSON object, got boolean"}
    end

    test "non-map list value is rejected with the array type label" do
      assert Renderer.normalize_constraints([1, 2]) ==
               {:error, "argument `constraints` must be a JSON object, got array"}
    end

    test "non-map integer value is rejected with the integer type label" do
      assert Renderer.normalize_constraints(5) ==
               {:error, "argument `constraints` must be a JSON object, got integer"}
    end

    test "non-map float value is rejected with the number type label" do
      assert Renderer.normalize_constraints(1.5) ==
               {:error, "argument `constraints` must be a JSON object, got number"}
    end

    test "non-map binary value is rejected with the unknown type label" do
      assert Renderer.normalize_constraints("nope") ==
               {:error, "argument `constraints` must be a JSON object, got unknown"}
    end
  end

  describe "render/3 structured value selection" do
    test "validated payload passes its value through untouched" do
      payload = %{"validated" => %{"items" => [1, 2, 3]}}

      assert {rendered, []} = Renderer.render(payload, %{}, 4096)
      assert rendered["structured_result"] == %{"items" => [1, 2, 3]}
    end

    test "validated value wins even when a result key is also present" do
      payload = %{"validated" => "kept", "result" => "ignored"}

      assert {rendered, []} = Renderer.render(payload, %{}, 4096)
      assert rendered["structured_result"] == "kept"
    end

    test "result string with REPL prefix is stripped, trimmed and JSON-decoded" do
      payload = %{"result" => ~s(user=> {"ok": true}  )}

      assert {rendered, []} = Renderer.render(payload, %{}, 4096)
      assert rendered["structured_result"] == %{"ok" => true}
    end

    test "double-encoded JSON string is unwrapped one extra level" do
      inner = Jason.encode!(%{"a" => 1})
      payload = %{"result" => Jason.encode!(inner)}

      assert {rendered, []} = Renderer.render(payload, %{}, 4096)
      assert rendered["structured_result"] == %{"a" => 1}
    end

    test "JSON string decoding to a plain (non-JSON) binary keeps the decoded binary" do
      payload = %{"result" => Jason.encode!("plain text")}

      assert {rendered, []} = Renderer.render(payload, %{}, 4096)
      assert rendered["structured_result"] == "plain text"
    end

    test "plain non-JSON result string is kept verbatim" do
      payload = %{"result" => "just words"}

      assert {rendered, []} = Renderer.render(payload, %{}, 4096)
      assert rendered["structured_result"] == "just words"
    end

    test "non-binary result value is kept as-is" do
      payload = %{"result" => %{"already" => "structured"}}

      assert {rendered, []} = Renderer.render(payload, %{}, 4096)
      assert rendered["structured_result"] == %{"already" => "structured"}
    end

    test "fallthrough payload drops prints, feedback and truncated keys" do
      payload = %{
        "prints" => ["log"],
        "feedback" => "noisy",
        "truncated" => true,
        "data" => [1, 2]
      }

      assert {rendered, []} = Renderer.render(payload, %{}, 4096)
      assert rendered["structured_result"] == %{"data" => [1, 2]}
    end
  end

  describe "render/3 enforce_max_items" do
    test "no max_items constraint leaves a list untouched" do
      payload = %{"validated" => [1, 2, 3, 4]}

      assert {rendered, []} = Renderer.render(payload, %{}, 4096)
      assert rendered["structured_result"] == [1, 2, 3, 4]
    end

    test "max_items truncates a top-level list" do
      payload = %{"validated" => [1, 2, 3, 4, 5]}

      assert {rendered, []} = Renderer.render(payload, %{"max_items" => 2}, 4096)
      assert rendered["structured_result"] == [1, 2]
    end

    test "max_items truncates the first list-valued field of a map" do
      payload = %{"validated" => %{"meta" => "x", "rows" => [10, 20, 30, 40]}}

      assert {rendered, []} = Renderer.render(payload, %{"max_items" => 2}, 4096)
      assert rendered["structured_result"]["rows"] == [10, 20]
      assert rendered["structured_result"]["meta"] == "x"
    end

    test "max_items on a map without any list field is a no-op" do
      payload = %{"validated" => %{"a" => 1, "b" => "two"}}

      assert {rendered, []} = Renderer.render(payload, %{"max_items" => 1}, 4096)
      assert rendered["structured_result"] == %{"a" => 1, "b" => "two"}
    end

    test "max_items on a scalar (non-list, non-map) value is a no-op" do
      payload = %{"validated" => "scalar"}

      assert {rendered, []} = Renderer.render(payload, %{"max_items" => 1}, 4096)
      assert rendered["structured_result"] == "scalar"
    end
  end

  describe "render/3 enforce_preferred_fields" do
    test "empty preferred_fields leaves the value untouched" do
      payload = %{"validated" => %{"a" => 1, "b" => 2}}

      assert {rendered, []} = Renderer.render(payload, %{"preferred_fields" => []}, 4096)
      assert rendered["structured_result"] == %{"a" => 1, "b" => 2}
    end

    test "list of maps with all preferred fields present is projected with Map.take" do
      payload = %{
        "validated" => [
          %{"name" => "a", "age" => 1, "secret" => "x"},
          %{"name" => "b", "age" => 2, "secret" => "y"}
        ]
      }

      assert {rendered, []} =
               Renderer.render(payload, %{"preferred_fields" => ["name", "age"]}, 4096)

      assert rendered["structured_result"] == [
               %{"name" => "a", "age" => 1},
               %{"name" => "b", "age" => 2}
             ]
    end

    test "map with all preferred fields present keeps only those fields" do
      payload = %{"validated" => %{"name" => "a", "age" => 1, "extra" => "drop"}}

      assert {rendered, []} =
               Renderer.render(payload, %{"preferred_fields" => ["name", "age"]}, 4096)

      assert rendered["structured_result"] == %{"name" => "a", "age" => 1}
    end

    test "map missing a preferred field recurses into its values" do
      # Top map lacks "name" -> recurse; the nested "user" map HAS all fields -> Map.take.
      payload = %{
        "validated" => %{
          "user" => %{"name" => "a", "age" => 1, "secret" => "x"},
          "count" => 2
        }
      }

      assert {rendered, []} =
               Renderer.render(payload, %{"preferred_fields" => ["name", "age"]}, 4096)

      assert rendered["structured_result"] == %{
               "user" => %{"name" => "a", "age" => 1},
               "count" => 2
             }
    end

    test "preferred_fields applied to a scalar value is a no-op" do
      payload = %{"validated" => "scalar"}

      assert {rendered, []} =
               Renderer.render(payload, %{"preferred_fields" => ["name"]}, 4096)

      assert rendered["structured_result"] == "scalar"
    end

    test "max_items and preferred_fields compose in order" do
      payload = %{
        "validated" => [
          %{"name" => "a", "drop" => 1},
          %{"name" => "b", "drop" => 2},
          %{"name" => "c", "drop" => 3}
        ]
      }

      assert {rendered, []} =
               Renderer.render(
                 payload,
                 %{"max_items" => 2, "preferred_fields" => ["name"]},
                 4096
               )

      assert rendered["structured_result"] == [%{"name" => "a"}, %{"name" => "b"}]
    end
  end

  describe "render/3 truncation and execution metadata" do
    test "result under the byte limit is not truncated and reports execution metadata" do
      payload = %{"validated" => %{"ok" => true}}

      assert {rendered, warnings} = Renderer.render(payload, %{}, 4096)
      assert warnings == []

      execution = rendered["execution"]
      assert execution["truncated"] == false
      assert execution["max_result_bytes"] == 4096

      expected_bytes =
        Jason.encode!(%{
          "answer" => rendered["answer"],
          "structured_result" => rendered["structured_result"]
        })
        |> byte_size()

      assert execution["result_bytes"] == expected_bytes
    end

    test "oversized result is truncated and emits a max_result_bytes warning" do
      big = String.duplicate("x", 50)
      payload = %{"validated" => big}

      # encoded_size(big) = 52 (50 chars + 2 quotes) > 20 -> truncate.
      assert {rendered, [warning]} = Renderer.render(payload, %{}, 20)

      assert warning == %{"code" => "max_result_bytes", "detail" => 20}
      assert rendered["execution"]["truncated"] == true
      assert rendered["execution"]["max_result_bytes"] == 20
      # compact_answer for a binary truncates the raw bytes to max_bytes.
      assert rendered["structured_result"] == String.duplicate("x", 20)
    end

    test "truncation is utf8-safe and never splits a multibyte character" do
      # 10 "é" chars = 20 bytes; a raw cut at 5 bytes lands mid-character,
      # so truncate_utf8 backs off to a 4-byte boundary yielding "éé".
      payload = %{"validated" => String.duplicate("é", 10)}

      assert {rendered, [warning]} = Renderer.render(payload, %{}, 5)

      assert warning == %{"code" => "max_result_bytes", "detail" => 5}
      assert rendered["structured_result"] == "éé"
      assert String.valid?(rendered["structured_result"])
      assert byte_size(rendered["structured_result"]) <= 5
    end

    test "max_result_bytes of effectively zero yields an empty truncated result" do
      payload = %{"validated" => "anything"}

      assert {rendered, [warning]} = Renderer.render(payload, %{}, 1)
      assert warning == %{"code" => "max_result_bytes", "detail" => 1}
      # binary_part_safe -> truncate_utf8 with max_bytes 1 on "anything"
      # ("a" is single-byte valid) keeps one byte; assert the boundary holds.
      assert byte_size(rendered["structured_result"]) <= 1
      assert rendered["execution"]["truncated"] == true
    end

    test "oversized non-binary structured result is JSON-encoded then byte-truncated" do
      payload = %{"validated" => %{"items" => Enum.to_list(1..100)}}

      assert {rendered, [warning]} = Renderer.render(payload, %{}, 16)
      assert warning == %{"code" => "max_result_bytes", "detail" => 16}
      assert rendered["execution"]["truncated"] == true
      # structured_result becomes a truncated encoded-JSON binary preview.
      assert is_binary(rendered["structured_result"])
      assert byte_size(rendered["structured_result"]) <= 16
    end

    test "render returns the canonical answer/structured_result/execution envelope keys" do
      assert {rendered, _} = Renderer.render(%{"validated" => %{"k" => "v"}}, %{}, 4096)
      assert Map.keys(rendered) |> Enum.sort() == ["answer", "execution", "structured_result"]

      assert Map.keys(rendered["execution"]) |> Enum.sort() ==
               ["max_result_bytes", "result_bytes", "truncated"]
    end
  end
end
