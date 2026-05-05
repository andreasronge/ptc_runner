defmodule PtcRunner.TemporalTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Temporal

  doctest PtcRunner.Temporal

  describe "iso8601/1" do
    test "DateTime -> ISO 8601 string" do
      assert Temporal.iso8601(~U[2026-05-03 09:14:00Z]) == "2026-05-03T09:14:00Z"
    end

    test "NaiveDateTime -> ISO 8601 string (no offset)" do
      assert Temporal.iso8601(~N[2026-05-03 09:14:00]) == "2026-05-03T09:14:00"
    end

    test "Date -> ISO 8601 string" do
      assert Temporal.iso8601(~D[2026-05-03]) == "2026-05-03"
    end

    test "Time -> ISO 8601 string" do
      assert Temporal.iso8601(~T[09:14:00]) == "09:14:00"
    end

    test "non-temporal values pass through unchanged" do
      assert Temporal.iso8601("hello") == "hello"
      assert Temporal.iso8601(42) == 42
      assert Temporal.iso8601(nil) == nil
      assert Temporal.iso8601(%{a: 1}) == %{a: 1}
      assert Temporal.iso8601([1, 2, 3]) == [1, 2, 3]
    end
  end

  describe "walk/1" do
    test "normalizes temporal structs nested inside maps" do
      input = %{when: ~U[2026-05-03 09:14:00Z], who: "alice"}
      assert Temporal.walk(input) == %{when: "2026-05-03T09:14:00Z", who: "alice"}
    end

    test "normalizes temporal structs inside lists" do
      assert Temporal.walk([~D[2026-05-03], ~T[09:14:00]]) == ["2026-05-03", "09:14:00"]
    end

    test "recurses through nested maps and lists" do
      input = %{
        events: [
          %{at: ~U[2026-05-03 09:14:00Z], type: "click"},
          %{at: ~U[2026-05-04 09:14:00Z], type: "view"}
        ]
      }

      assert Temporal.walk(input) == %{
               events: [
                 %{at: "2026-05-03T09:14:00Z", type: "click"},
                 %{at: "2026-05-04T09:14:00Z", type: "view"}
               ]
             }
    end

    test "leaves non-temporal structs untouched (their shape is the user's contract)" do
      mapset = MapSet.new([1, 2])
      assert Temporal.walk(%{set: mapset}) == %{set: mapset}
    end
  end
end
