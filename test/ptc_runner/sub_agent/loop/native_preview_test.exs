defmodule PtcRunner.SubAgent.Loop.NativePreviewTest do
  @moduledoc """
  Tier 2b unit tests for `PtcRunner.SubAgent.Loop.NativePreview`.

  Pins:

    * Default metadata preview shape per every row of the inference table
      in the plan doc's "Default Metadata Preview — Inference Rules."
    * Schema-level truncation flag placement at `schema.truncated`, not
      preview top-level.
    * `:rows` preview honoring `limit:`.
    * Custom preview function — success, raise, non-map, non-encodable
      (each fallback emits `Logger.warning/1` with the failure category).
    * `cache_hint` rendering for simple/nested/escaped/list/integer-equal-float
      inputs (Addendum #14, #26).
    * "Consistent keys" detection per Addendum #5 (first vs next 4 that
      exist; mismatch in element 3 → not consistent).
    * `:erlang.external_size/1` available for `retained_bytes` computation
      at cache-write time (Addendum #6) — the wiring test lives in
      `text_mode_combined_test.exs`; this file pins the primitive used.
  """
  # async: false because the custom-preview-fallback tests temporarily lift
  # the OTP primary logger level to :warning so `capture_log/1` can observe
  # `Logger.warning/1` output. test_helper.exs pins the primary level at
  # :critical to silence sandbox crash reports; the lift is restored via
  # on_exit but must not race with parallel tests that depend on silence.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PtcRunner.SubAgent.Loop.NativePreview
  alias PtcRunner.Tool

  setup do
    previous = :logger.get_primary_config()
    :logger.set_primary_config(:level, :warning)
    on_exit(fn -> :logger.set_primary_config(:level, previous.level) end)
    :ok
  end

  defp tool(name, opts \\ []) do
    %Tool{
      name: name,
      function: fn _ -> nil end,
      type: :native,
      cache: Keyword.get(opts, :cache, true),
      expose: Keyword.get(opts, :expose, :both),
      native_result: Keyword.get(opts, :native_result)
    }
  end

  # ---------------------------------------------------------------------------
  # Default metadata preview — inference table rows
  # ---------------------------------------------------------------------------

  describe "default metadata preview" do
    test "list of maps with consistent keys → result_count, schema with properties, sample_keys" do
      result = [
        %{"id" => 1, "msg" => "a"},
        %{"id" => 2, "msg" => "b"},
        %{"id" => 3, "msg" => "c"}
      ]

      {:ok, preview} = NativePreview.build(tool("t"), result, %{"q" => "x"})

      assert preview["result_count"] == 3

      assert preview["schema"] == %{
               "type" => "array",
               "items" => %{
                 "type" => "object",
                 "properties" => %{"id" => "integer", "msg" => "string"}
               }
             }

      assert preview["sample_keys"] == ["id", "msg"]
      assert preview["status"] == "ok"
      assert preview["full_result_cached"] == true
      assert is_binary(preview["cache_hint"])
    end

    test "list of maps with mixed keys → result_count, schema items=:object only, NO sample_keys" do
      result = [%{"a" => 1}, %{"b" => 2}, %{"c" => 3}]
      {:ok, preview} = NativePreview.build(tool("t"), result, %{})

      assert preview["result_count"] == 3
      assert preview["schema"] == %{"type" => "array", "items" => %{"type" => "object"}}
      refute Map.has_key?(preview, "sample_keys")
    end

    test "list of homogeneous scalars → result_count, schema with inferred item type, NO sample_keys" do
      {:ok, preview} = NativePreview.build(tool("t"), [1, 2, 3], %{})

      assert preview["result_count"] == 3
      assert preview["schema"] == %{"type" => "array", "items" => %{"type" => "integer"}}
      refute Map.has_key?(preview, "sample_keys")
    end

    test ~s|list of mixed scalars → schema items={"type":"any"}| do
      {:ok, preview} = NativePreview.build(tool("t"), [1, "two", true], %{})

      assert preview["result_count"] == 3
      assert preview["schema"]["items"] == %{"type" => "any"}
    end

    test "empty list → result_count: 0, schema items={}, NO sample_keys" do
      {:ok, preview} = NativePreview.build(tool("t"), [], %{})

      assert preview["result_count"] == 0
      assert preview["schema"] == %{"type" => "array", "items" => %{}}
      refute Map.has_key?(preview, "sample_keys")
    end

    test "non-empty map → schema with properties + sample_keys, NO result_count" do
      result = %{"name" => "Alice", "age" => 30}
      {:ok, preview} = NativePreview.build(tool("t"), result, %{})

      refute Map.has_key?(preview, "result_count")

      assert preview["schema"] == %{
               "type" => "object",
               "properties" => %{"age" => "integer", "name" => "string"}
             }

      assert preview["sample_keys"] == ["age", "name"]
    end

    test ~s|empty map → schema={"type":"object"}, sample_keys: []| do
      {:ok, preview} = NativePreview.build(tool("t"), %{}, %{})

      refute Map.has_key?(preview, "result_count")
      assert preview["schema"] == %{"type" => "object"}
      assert preview["sample_keys"] == []
    end

    test ~s|scalar → schema={"type":"<kind>"}, NO result_count, NO sample_keys| do
      {:ok, preview} = NativePreview.build(tool("t"), 42, %{})

      refute Map.has_key?(preview, "result_count")
      refute Map.has_key?(preview, "sample_keys")
      assert preview["schema"] == %{"type" => "integer"}
    end
  end

  # ---------------------------------------------------------------------------
  # Schema-level truncation (>20 keys) — placement at `schema.truncated`
  # ---------------------------------------------------------------------------

  describe "schema truncation (>20 properties)" do
    test "truncated flag lives INSIDE the schema, not at preview top level" do
      wide = for i <- 1..30, into: %{}, do: {"k#{i}", i}
      result = [wide]

      {:ok, preview} = NativePreview.build(tool("t"), result, %{})

      schema_items = preview["schema"]["items"]
      assert schema_items["truncated"] == true
      assert map_size(schema_items["properties"]) == 20

      # Top-level preview MUST NOT carry `truncated` — that field is
      # reserved for other semantics (Addendum / plan note).
      refute Map.has_key?(preview, "truncated")
    end

    test "sample_keys is also capped at 20 to match properties" do
      wide = for i <- 1..30, into: %{}, do: {"k#{i}", i}
      result = [wide]

      {:ok, preview} = NativePreview.build(tool("t"), result, %{})
      assert length(preview["sample_keys"]) == 20
    end

    test "map preview with >20 keys also truncates inside schema" do
      wide = for i <- 1..30, into: %{}, do: {"k#{i}", i}

      {:ok, preview} = NativePreview.build(tool("t"), wide, %{})

      assert preview["schema"]["truncated"] == true
      assert map_size(preview["schema"]["properties"]) == 20
      assert length(preview["sample_keys"]) == 20
      refute Map.has_key?(preview, "truncated")
    end
  end

  # ---------------------------------------------------------------------------
  # :rows preview
  # ---------------------------------------------------------------------------

  describe ":rows preview" do
    test "honors limit:, returns rows verbatim and full result_count" do
      rows = for i <- 1..50, do: %{"id" => i}

      {:ok, preview} =
        NativePreview.build(
          tool("t", native_result: [preview: :rows, limit: 5]),
          rows,
          %{}
        )

      assert preview["result_count"] == 50
      assert length(preview["rows"]) == 5

      assert preview["rows"] == [
               %{"id" => 1},
               %{"id" => 2},
               %{"id" => 3},
               %{"id" => 4},
               %{"id" => 5}
             ]

      assert preview["full_result_cached"] == true
    end

    test "default limit is 20 when :rows is configured without explicit limit" do
      rows = for i <- 1..30, do: %{"id" => i}

      {:ok, preview} =
        NativePreview.build(tool("t", native_result: [preview: :rows]), rows, %{})

      assert length(preview["rows"]) == 20
    end

    # Tier 3.5 Fix 6: rows containing temporal structs (DateTime, Date,
    # Time, NaiveDateTime) must be normalized via PtcRunner.Temporal.walk/1
    # before reaching Jason — those structs have no Jason encoder and
    # would otherwise crash the preview builder.
    test "rows with %DateTime{} and %Date{} values: temporal structs become ISO 8601 strings" do
      {:ok, dt, 0} = DateTime.from_iso8601("2026-05-06T12:00:00Z")
      d = ~D[2026-05-06]

      rows = [
        %{"id" => 1, "created_at" => dt, "due" => d},
        %{"id" => 2, "created_at" => dt, "due" => d}
      ]

      {:ok, preview} =
        NativePreview.build(tool("t", native_result: [preview: :rows, limit: 5]), rows, %{})

      # Encodable: no Jason crash.
      assert is_binary(Jason.encode!(preview))

      [first_row | _] = preview["rows"]
      assert first_row["created_at"] == "2026-05-06T12:00:00Z"
      assert first_row["due"] == "2026-05-06"
      assert first_row["id"] == 1
    end

    test "rows with %NaiveDateTime{} and %Time{} values: also normalize to ISO 8601" do
      ndt = ~N[2026-05-06 12:00:00]
      t = ~T[12:00:00]

      rows = [%{"started_at" => ndt, "open_at" => t}]

      {:ok, preview} =
        NativePreview.build(tool("t", native_result: [preview: :rows]), rows, %{})

      assert is_binary(Jason.encode!(preview))
      [first_row | _] = preview["rows"]
      assert first_row["started_at"] == "2026-05-06T12:00:00"
      assert first_row["open_at"] == "12:00:00"
    end
  end

  # ---------------------------------------------------------------------------
  # Custom preview function
  # ---------------------------------------------------------------------------

  describe "custom preview function" do
    test "success: returned map is merged with cache fields and used as preview" do
      fun = fn full_result -> %{"summary" => "got #{length(full_result)}", "extra" => 1} end

      {:ok, preview} =
        NativePreview.build(
          tool("t", native_result: [preview: fun]),
          [1, 2, 3],
          %{}
        )

      assert preview["summary"] == "got 3"
      assert preview["extra"] == 1
      # Cache fields are always merged
      assert preview["status"] == "ok"
      assert preview["full_result_cached"] == true
      assert is_binary(preview["cache_hint"])
    end

    test "raises → fallback to metadata preview, warns category=raised" do
      fun = fn _ -> raise "boom" end

      log =
        capture_log(fn ->
          {:fallback, preview} =
            NativePreview.build(
              tool("t", native_result: [preview: fun]),
              [1, 2, 3],
              %{}
            )

          # Fallback returned the metadata-only shape
          assert preview["result_count"] == 3
          assert preview["schema"]["type"] == "array"
        end)

      assert log =~ "category=raised"
      assert log =~ ~s|tool "t"|
    end

    test "returns non-map → fallback + warns category=non_map" do
      fun = fn _ -> "just a string" end

      log =
        capture_log(fn ->
          {:fallback, preview} =
            NativePreview.build(
              tool("t", native_result: [preview: fun]),
              [1, 2],
              %{}
            )

          assert preview["result_count"] == 2
        end)

      assert log =~ "category=non_map"
    end

    test "returns non-Jason-encodable map → fallback + warns category=non_encodable" do
      fun = fn _ -> %{"pid" => self()} end

      log =
        capture_log(fn ->
          {:fallback, preview} =
            NativePreview.build(
              tool("t", native_result: [preview: fun]),
              [1, 2, 3],
              %{}
            )

          assert preview["result_count"] == 3
        end)

      assert log =~ "category=non_encodable"
    end
  end

  # ---------------------------------------------------------------------------
  # cache_hint rendering (Addenda #14, #26)
  # ---------------------------------------------------------------------------

  describe "cache_hint rendering" do
    test "simple string args render as Clojure-style :keyword \"value\"" do
      hint = NativePreview.cache_hint("search_logs", %{"query" => "error code 42"})

      assert hint ==
               ~s|Call ptc_lisp_execute and then call (tool/search_logs {:query "error code 42"}) to process the full cached result.|
    end

    test "nested maps render with proper nesting" do
      hint = NativePreview.cache_hint("query", %{"filter" => %{"name" => "alice"}})
      assert hint =~ ~s|(tool/query {:filter {:name "alice"}})|
    end

    test "strings with embedded double quotes are escaped" do
      hint = NativePreview.cache_hint("q", %{"text" => ~s|she said "hi"|})
      assert hint =~ ~s|(tool/q {:text "she said \\"hi\\""})|
    end

    test "list values render as PTC-Lisp vectors" do
      hint = NativePreview.cache_hint("q", %{"ids" => [1, 2, 3]})
      assert hint =~ ~s|(tool/q {:ids [1 2 3]})|
    end

    test "integer-equal floats collapse to integers (canonical_cache_key already collapsed them)" do
      # canonical_cache_key/2 collapses 1.0 → 1; the cache_hint AST
      # converter must format the collapsed integer as an integer literal.
      hint = NativePreview.cache_hint("q", %{"n" => 1.0})
      assert hint =~ ~s|(tool/q {:n 1})|
      refute hint =~ "1.0"
    end

    test "atom-keyed args produce the same hint as string-keyed args" do
      atom_hint = NativePreview.cache_hint("q", %{q: "x"})
      str_hint = NativePreview.cache_hint("q", %{"q" => "x"})
      assert atom_hint == str_hint
    end

    test "keys are rendered in canonical sorted order regardless of insertion order" do
      h1 = NativePreview.cache_hint("q", %{"b" => 2, "a" => 1})
      h2 = NativePreview.cache_hint("q", %{"a" => 1, "b" => 2})
      assert h1 == h2
      # Sorted by string key — `a` first.
      assert h1 =~ ~s|{:a 1 :b 2}|
    end

    test "nil/boolean values render via Formatter passthrough" do
      assert NativePreview.cache_hint("q", %{"x" => nil}) =~ "{:x nil}"
      assert NativePreview.cache_hint("q", %{"x" => true}) =~ "{:x true}"
      assert NativePreview.cache_hint("q", %{"x" => false}) =~ "{:x false}"
    end
  end

  # ---------------------------------------------------------------------------
  # Consistent-keys detection (Addendum #5)
  # ---------------------------------------------------------------------------

  describe "consistent keys detection (Addendum #5)" do
    test "length-1 list is trivially consistent → schema has properties" do
      {:ok, preview} = NativePreview.build(tool("t"), [%{"a" => 1}], %{})
      assert preview["schema"]["items"]["properties"] == %{"a" => "integer"}
      assert preview["sample_keys"] == ["a"]
    end

    test "length-5 list, all same keys → consistent (uses first vs next 4)" do
      list = for i <- 1..5, do: %{"a" => i, "b" => i * 2}
      {:ok, preview} = NativePreview.build(tool("t"), list, %{})

      assert preview["sample_keys"] == ["a", "b"]
      assert preview["schema"]["items"]["properties"] == %{"a" => "integer", "b" => "integer"}
    end

    test "mismatch in element 3 → NOT consistent (compared against next 4)" do
      list = [
        %{"a" => 1, "b" => 1},
        %{"a" => 2, "b" => 2},
        # element index 2 (3rd) — drops "b"
        %{"a" => 3, "c" => 9},
        %{"a" => 4, "b" => 4},
        %{"a" => 5, "b" => 5}
      ]

      {:ok, preview} = NativePreview.build(tool("t"), list, %{})

      assert preview["schema"] == %{
               "type" => "array",
               "items" => %{"type" => "object"}
             }

      refute Map.has_key?(preview, "sample_keys")
    end
  end

  # ---------------------------------------------------------------------------
  # Addendum #6 — retained_bytes primitive
  # ---------------------------------------------------------------------------

  describe "retained_bytes primitive" do
    test ":erlang.external_size/1 computes byte size used for cache-write telemetry" do
      # Pinned for Addendum #6: native preview seeding uses
      # `:erlang.external_size(full_result)` at the point of cache write.
      # This is the primitive; the wiring test in
      # `text_mode_combined_test.exs` exercises it end-to-end.
      result = [%{"id" => 1, "msg" => "hello"}, %{"id" => 2, "msg" => "world"}]
      bytes = :erlang.external_size(result)
      assert is_integer(bytes)
      assert bytes > 0
    end
  end
end
