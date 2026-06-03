defmodule PtcRunner.Upstream.ResultTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Upstream.Result

  # Mirrors how production builds an upstream-call entry (see
  # PtcRunner.Upstream.RunContext.success_entry/4): a string-keyed map carrying
  # a "result_overview" produced by Result.result_overview/2.
  defp ok_entry(server, tool, value) do
    kind = Result.value_kind(value)

    %{
      "server" => server,
      "tool" => tool,
      "status" => "ok",
      "duration_ms" => 12,
      "result_bytes" => 99,
      "oversize" => false,
      "result_overview" => Result.result_overview(value, kind)
    }
  end

  # Mirrors PtcRunner.Upstream.RunContext.error_entry/6.
  defp error_entry(server, tool, reason, detail) do
    %{
      "server" => server,
      "tool" => tool,
      "status" => "error",
      "duration_ms" => 7,
      "reason" => Atom.to_string(reason),
      "error" => detail,
      "result_bytes" => 0,
      "oversize" => reason == :response_too_large
    }
  end

  describe "success/1 tags value by kind" do
    test "nil value is tagged :json" do
      assert Result.success(nil) == %{ok: true, value: nil, value_kind: :json}
    end

    test "binary value is tagged :text" do
      assert Result.success("hi") == %{ok: true, value: "hi", value_kind: :text}
    end

    test "boolean value is tagged :json" do
      assert Result.success(true) == %{ok: true, value: true, value_kind: :json}
      assert Result.success(false) == %{ok: true, value: false, value_kind: :json}
    end

    test "number value is tagged :json" do
      assert Result.success(42) == %{ok: true, value: 42, value_kind: :json}
      assert Result.success(3.5) == %{ok: true, value: 3.5, value_kind: :json}
    end

    test "list value is tagged :json" do
      assert Result.success([1, 2]) == %{ok: true, value: [1, 2], value_kind: :json}
    end

    test "map value is tagged :json" do
      assert Result.success(%{"a" => 1}) == %{ok: true, value: %{"a" => 1}, value_kind: :json}
    end

    test "non-json value (tuple) is tagged :none" do
      assert Result.success({:a, :b}) == %{ok: true, value: {:a, :b}, value_kind: :none}
    end
  end

  describe "error/2" do
    test "builds a recoverable failure shape" do
      assert Result.error(:timeout, "took too long") ==
               %{ok: false, reason: :timeout, message: "took too long"}
    end

    test "requires an atom reason and binary message via guard" do
      assert_raise FunctionClauseError, fn -> Result.error("timeout", "msg") end
      assert_raise FunctionClauseError, fn -> Result.error(:timeout, :not_a_string) end
    end
  end

  describe "value_kind/1" do
    test "nil maps to :json" do
      assert Result.value_kind(nil) == :json
    end

    test "binary maps to :text" do
      assert Result.value_kind("abc") == :text
      assert Result.value_kind("") == :text
    end

    test "boolean maps to :json (and wins over the catch-all)" do
      assert Result.value_kind(true) == :json
      assert Result.value_kind(false) == :json
    end

    test "numbers map to :json" do
      assert Result.value_kind(0) == :json
      assert Result.value_kind(-1.25) == :json
    end

    test "list and map map to :json" do
      assert Result.value_kind([]) == :json
      assert Result.value_kind(%{}) == :json
    end

    test "everything else maps to :none" do
      assert Result.value_kind({:tuple}) == :none
      assert Result.value_kind(:an_atom) == :none
      assert Result.value_kind(self()) == :none
    end
  end

  describe "result_overview/2 shape strings" do
    test "map: sorted keys (take 8) plus count" do
      value = %{"b" => 1, "a" => 2, "c" => 3}
      overview = Result.result_overview(value, :json)

      assert overview["value_kind"] == "json"
      assert overview["shape"] == ~s(map keys=["a", "b", "c"] count=3)
    end

    test "map with > 8 keys: shape truncates key list to 8 but counts all" do
      value = for n <- 1..12, into: %{}, do: {"k#{String.pad_leading("#{n}", 2, "0")}", n}
      overview = Result.result_overview(value, :json)

      assert overview["shape"] ==
               ~s(map keys=["k01", "k02", "k03", "k04", "k05", "k06", "k07", "k08"] count=12)
    end

    test "list shape" do
      assert Result.result_overview([1, 2, 3], :json)["shape"] == "list count=3"
    end

    test "string shape counts bytes" do
      assert Result.result_overview("héllo", :text)["shape"] == "string bytes=6"
    end

    test "integer shape" do
      assert Result.result_overview(7, :json)["shape"] == "integer"
    end

    test "float shape labelled number" do
      assert Result.result_overview(1.5, :json)["shape"] == "number"
    end

    test "boolean shape" do
      assert Result.result_overview(true, :json)["shape"] == "boolean"
      assert Result.result_overview(false, :json)["shape"] == "boolean"
    end

    test "nil shape" do
      assert Result.result_overview(nil, :json)["shape"] == "nil"
    end

    test "unknown shape for non-json terms" do
      assert Result.result_overview({:a, :b}, :none)["shape"] == "unknown"
    end
  end

  describe "result_overview/2 preview" do
    test "binary preview passes through untruncated when short" do
      assert Result.result_overview("short text", :text)["preview"] == "short text"
    end

    test "binary preview > 240 bytes is utf8-safe truncated with ellipsis" do
      long = String.duplicate("a", 300)
      preview = Result.result_overview(long, :text)["preview"]

      assert String.ends_with?(preview, "...")
      assert preview == String.duplicate("a", 240) <> "..."
    end

    test "binary preview never splits a multibyte codepoint at the boundary" do
      # 'é' is 2 bytes. Pad with one leading ASCII byte so the 240-byte cut
      # lands mid-codepoint and the truncator must back off to stay valid utf8.
      long = "a" <> String.duplicate("é", 200)
      preview = Result.result_overview(long, :text)["preview"]

      truncated = String.replace_suffix(preview, "...", "")
      assert String.valid?(truncated)
      assert byte_size(truncated) <= 240
      # Byte 240 = 1 ASCII + 239 of 'é' bytes lands mid-'é', so it backs off to 239.
      assert byte_size(truncated) == 239
    end

    test "map preview keeps sorted keys, takes 8, and tags nested children" do
      value = %{
        "z" => "v",
        "a" => %{"deep" => 1, "deeper" => 2},
        "m" => [10, 20, 30],
        "s" => String.duplicate("x", 200)
      }

      preview = Result.result_overview(value, :json)["preview"]
      decoded = Jason.decode!(preview)

      assert decoded["z"] == "v"
      assert decoded["a"] == %{"type" => "map", "keys" => ["deep", "deeper"]}
      assert decoded["m"] == %{"type" => "list", "count" => 3}
      # Long leaf string truncated to 120 bytes + "..."
      assert decoded["s"] == String.duplicate("x", 120) <> "..."
    end

    test "map preview with > 8 keys truncates to the 8 lexically-smallest" do
      value = for n <- 1..15, into: %{}, do: {"k#{String.pad_leading("#{n}", 2, "0")}", n}
      preview = Result.result_overview(value, :json)["preview"]
      decoded = Jason.decode!(preview)

      assert map_size(decoded) == 8
      assert Map.keys(decoded) |> Enum.sort() == ~w(k01 k02 k03 k04 k05 k06 k07 k08)
    end

    test "list preview truncates to first 5 and tags nested children" do
      value = [1, 2, 3, 4, 5, 6, 7]
      preview = Result.result_overview(value, :json)["preview"]
      assert Jason.decode!(preview) == [1, 2, 3, 4, 5]
    end

    test "list preview tags nested map/list leaves" do
      value = [%{"a" => 1, "b" => 2}, [9, 9, 9]]
      preview = Result.result_overview(value, :json)["preview"]

      assert Jason.decode!(preview) == [
               %{"type" => "map", "keys" => ["a", "b"]},
               %{"type" => "list", "count" => 3}
             ]
    end

    test "map leaf key list is sorted and capped at 8" do
      inner = for n <- 1..12, into: %{}, do: {"k#{String.pad_leading("#{n}", 2, "0")}", n}
      value = %{"nested" => inner}
      preview = Result.result_overview(value, :json)["preview"]
      decoded = Jason.decode!(preview)

      assert decoded["nested"] == %{
               "type" => "map",
               "keys" => ~w(k01 k02 k03 k04 k05 k06 k07 k08)
             }
    end

    test "non-json-encodable scalar preview falls back to inspect" do
      preview = Result.result_overview({:not, :json}, :none)["preview"]
      assert preview == inspect({:not, :json}, limit: 20, printable_limit: 200)
    end

    test "scalar number/bool/nil previews encode as JSON" do
      assert Result.result_overview(42, :json)["preview"] == "42"
      assert Result.result_overview(true, :json)["preview"] == "true"
      assert Result.result_overview(nil, :json)["preview"] == "null"
    end
  end

  describe "compact_result_entries/1" do
    test "ok entry merges its result_overview onto server/tool/status" do
      entry = ok_entry("weather", "forecast", %{"temp" => 21, "unit" => "C"})

      assert [compacted] = Result.compact_result_entries([entry])
      assert compacted["server"] == "weather"
      assert compacted["tool"] == "forecast"
      assert compacted["status"] == "ok"
      assert compacted["value_kind"] == "json"
      assert compacted["shape"] == ~s(map keys=["temp", "unit"] count=2)
      assert Jason.decode!(compacted["preview"]) == %{"temp" => 21, "unit" => "C"}
    end

    test "error entry keeps reason and error via maybe_put" do
      entry = error_entry("db", "query", :timeout, "connection timed out")

      assert [compacted] = Result.compact_result_entries([entry])

      assert compacted == %{
               "server" => "db",
               "tool" => "query",
               "status" => "error",
               "reason" => "timeout",
               "error" => "connection timed out"
             }
    end

    test "error entry drops nil and empty-string reason/error" do
      entry = %{
        "server" => "db",
        "tool" => "query",
        "status" => "error",
        "reason" => nil,
        "error" => ""
      }

      assert [compacted] = Result.compact_result_entries([entry])

      assert compacted == %{
               "server" => "db",
               "tool" => "query",
               "status" => "error"
             }

      refute Map.has_key?(compacted, "reason")
      refute Map.has_key?(compacted, "error")
    end

    test "ok entry without a map result_overview falls through and is dropped" do
      # status ok but no/invalid overview -> matches neither ok nor error clause.
      entry = %{"server" => "s", "tool" => "t", "status" => "ok"}
      assert Result.compact_result_entries([entry]) == []
    end

    test "entry with an unknown status is dropped" do
      entry = %{"server" => "s", "tool" => "t", "status" => "pending"}
      assert Result.compact_result_entries([entry]) == []
    end

    test "missing server/tool keys compact to nil values" do
      entry = %{"status" => "error", "reason" => "boom", "error" => "kaboom"}
      assert [compacted] = Result.compact_result_entries([entry])
      assert compacted["server"] == nil
      assert compacted["tool"] == nil
    end

    test "mixed list keeps ok+error and drops unmatched" do
      entries = [
        ok_entry("a", "x", [1, 2, 3]),
        %{"server" => "b", "tool" => "y", "status" => "weird"},
        error_entry("c", "z", :rate_limited, "slow down")
      ]

      compacted = Result.compact_result_entries(entries)
      assert length(compacted) == 2
      assert Enum.map(compacted, & &1["server"]) == ["a", "c"]
    end

    test "empty input yields empty list" do
      assert Result.compact_result_entries([]) == []
    end
  end

  describe "decorate_payload/2" do
    test "empty entries pass the payload through unchanged" do
      payload = %{"answer" => 1}
      assert Result.decorate_payload(payload, []) == payload
    end

    test "entries add upstream_calls (overview stripped) and upstream_results (compacted)" do
      entry = ok_entry("weather", "forecast", %{"temp" => 21})
      payload = %{"answer" => "42"}

      decorated = Result.decorate_payload(payload, [entry])

      assert decorated["answer"] == "42"

      # upstream_calls carries the raw entry minus the heavy result_overview.
      assert [call] = decorated["upstream_calls"]
      refute Map.has_key?(call, "result_overview")
      assert call["server"] == "weather"
      assert call["status"] == "ok"
      assert call["duration_ms"] == 12

      # upstream_results carries the compacted overview-merged summary.
      assert [summary] = decorated["upstream_results"]
      assert summary["server"] == "weather"
      assert summary["value_kind"] == "json"
    end

    test "when all entries compact to nothing, upstream_results is omitted" do
      # An entry that matches no compaction clause -> compact yields [].
      entry = %{"server" => "s", "tool" => "t", "status" => "skipped", "result_overview" => 7}
      payload = %{"answer" => 1}

      decorated = Result.decorate_payload(payload, [entry])

      # upstream_calls is still added (raw, minus result_overview)...
      assert [call] = decorated["upstream_calls"]
      refute Map.has_key?(call, "result_overview")
      # ...but the empty compaction means upstream_results is never added.
      refute Map.has_key?(decorated, "upstream_results")
    end

    test "decorate strips result_overview from every call regardless of status" do
      entries = [
        ok_entry("a", "x", "text result"),
        error_entry("b", "y", :upstream_error, "broke")
      ]

      decorated = Result.decorate_payload(%{"k" => "v"}, entries)

      assert Enum.all?(decorated["upstream_calls"], &(not Map.has_key?(&1, "result_overview")))
      assert length(decorated["upstream_results"]) == 2
    end
  end
end
