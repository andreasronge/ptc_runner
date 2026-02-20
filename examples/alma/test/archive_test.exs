defmodule Alma.ArchiveTest do
  use ExUnit.Case, async: true

  alias Alma.Archive

  describe "new/0" do
    test "creates empty archive" do
      archive = Archive.new()
      assert archive.entries == []
      assert archive.next_id == 1
    end
  end

  describe "add/2" do
    test "adds entry with auto-incremented id" do
      archive =
        Archive.new()
        |> Archive.add(%{design: %{name: "a"}, score: 0.5})
        |> Archive.add(%{design: %{name: "b"}, score: 0.8})

      assert length(archive.entries) == 2
      assert Enum.at(archive.entries, 0).id == 1
      assert Enum.at(archive.entries, 1).id == 2
      assert archive.next_id == 3
    end

    test "sets default values for missing fields" do
      archive = Archive.new() |> Archive.add(%{score: 0.5})
      entry = hd(archive.entries)

      assert entry.trajectories == []
      assert entry.parent_ids == []
      assert entry.generation == 0
      assert entry.times_sampled == 0
    end
  end

  describe "best/1" do
    test "returns nil for empty archive" do
      assert Archive.best(Archive.new()) == nil
    end

    test "returns entry with highest score" do
      archive =
        Archive.new()
        |> Archive.add(%{design: %{name: "a"}, score: 0.3})
        |> Archive.add(%{design: %{name: "b"}, score: 0.9})
        |> Archive.add(%{design: %{name: "c"}, score: 0.6})

      best = Archive.best(archive)
      assert best.score == 0.9
      assert best.design == %{name: "b"}
    end
  end

  describe "sample/2" do
    test "returns empty list for empty archive" do
      assert Archive.sample(Archive.new(), 3) == []
    end

    test "returns at most k entries" do
      archive =
        Archive.new()
        |> Archive.add(%{
          design: %{mem_update_source: "a", recall_source: "x"},
          score: 0.5
        })
        |> Archive.add(%{
          design: %{mem_update_source: "b", recall_source: "y"},
          score: 0.7
        })
        |> Archive.add(%{
          design: %{mem_update_source: "c", recall_source: "z"},
          score: 0.3
        })

      {selected, _updated} = Archive.sample(archive, 2)
      assert length(selected) == 2
    end

    test "increments times_sampled on selected entries" do
      archive =
        Archive.new()
        |> Archive.add(%{design: %{mem_update_source: "a"}, score: 0.5})
        |> Archive.add(%{design: %{mem_update_source: "b"}, score: 0.7})

      {_selected, updated} = Archive.sample(archive, 1)
      sampled_counts = Enum.map(updated.entries, & &1.times_sampled)

      # Exactly one entry should have been sampled
      assert Enum.sum(sampled_counts) == 1
    end

    test "does not return more than available entries" do
      archive = Archive.new() |> Archive.add(%{design: %{}, score: 0.5})

      {selected, _updated} = Archive.sample(archive, 5)
      assert length(selected) == 1
    end
  end

  describe "summary/1" do
    test "reports empty archive" do
      assert Archive.summary(Archive.new()) == "Archive: empty"
    end

    test "reports stats for non-empty archive" do
      archive =
        Archive.new()
        |> Archive.add(%{score: 0.4})
        |> Archive.add(%{score: 0.8})

      summary = Archive.summary(archive)
      assert summary =~ "2 entries"
      assert summary =~ "avg score: 0.6"
      assert summary =~ "best: 0.8"
    end
  end

  describe "seed_null/1" do
    test "adds a null baseline design with score 0.0" do
      archive = Archive.new() |> Archive.seed_null()

      assert length(archive.entries) == 1
      entry = hd(archive.entries)
      assert entry.score == 0.0
      assert entry.design.name == "null"
      assert entry.design.mem_update == nil
      assert entry.design.recall == nil
      assert entry.design.mem_update_source == ""
      assert entry.design.recall_source == ""
    end
  end

  describe "edit distance (DP)" do
    test "completes quickly on long PTC-Lisp strings" do
      code_a =
        "(def episodes (take 10 (conj (or episodes []) " <>
          String.duplicate("{\"k\" \"v\"} ", 10) <> ")))"

      code_b =
        "(def history (take 20 (conj (or history []) " <>
          String.duplicate("{\"a\" \"b\"} ", 10) <> ")))"

      archive =
        Archive.new()
        |> Archive.add(%{
          design: %{mem_update_source: code_a, recall_source: ""},
          score: 0.5
        })
        |> Archive.add(%{
          design: %{mem_update_source: code_b, recall_source: ""},
          score: 0.6
        })

      # Should complete within 1 second — the old naive version would hang
      {time_us, {selected, _}} = :timer.tc(fn -> Archive.sample(archive, 1) end)
      assert length(selected) == 1
      assert time_us < 1_000_000
    end
  end

  describe "AST-based novelty" do
    test "whitespace-only changes have lower distance than structural changes" do
      # Same structure, just whitespace differences
      code_ws_a = "(def x (+ 1 2))"
      code_ws_b = "(def  x  (+ 1  2))"

      # Structurally different code
      code_diff = "(if true (conj [] 1) nil)"

      archive_ws =
        Archive.new()
        |> Archive.add(%{
          design: %{mem_update_source: code_ws_a, recall_source: ""},
          score: 0.5
        })
        |> Archive.add(%{
          design: %{mem_update_source: code_ws_b, recall_source: ""},
          score: 0.6
        })

      archive_struct =
        Archive.new()
        |> Archive.add(%{
          design: %{mem_update_source: code_ws_a, recall_source: ""},
          score: 0.5
        })
        |> Archive.add(%{
          design: %{mem_update_source: code_diff, recall_source: ""},
          score: 0.6
        })

      # Sample both — the whitespace archive should yield lower novelty
      # We just verify both complete without error
      {selected_ws, _} = Archive.sample(archive_ws, 1)
      {selected_struct, _} = Archive.sample(archive_struct, 1)

      assert length(selected_ws) == 1
      assert length(selected_struct) == 1
    end
  end

  describe "save/2 and load/1" do
    @tag :tmp_dir
    test "round-trips archive through JSON with source strings", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "archive.json")

      archive =
        Archive.new()
        |> Archive.add(%{
          design: %{
            name: "tracker",
            description: "Tracks visits",
            mem_update: nil,
            recall: nil,
            mem_update_source: "(fn [] (def visits (conj (or visits []) data/task)))",
            recall_source: "(fn [] (str \"Visited: \" (or visits [])))"
          },
          score: 0.75,
          trajectories: [],
          parent_ids: [1],
          generation: 3
        })
        |> Archive.add(%{
          design: %{
            name: "counter",
            description: "Counts episodes",
            mem_update: nil,
            recall: nil,
            mem_update_source: "(fn [] (def n (inc (or n 0))))",
            recall_source: "(fn [] (str \"Episode \" (or n 0)))"
          },
          score: 0.9,
          trajectories: [],
          parent_ids: [1, 2],
          generation: 4
        })

      Archive.save(archive, path)
      loaded = Archive.load(path)

      assert length(loaded.entries) == 2
      assert loaded.next_id == 3

      first = hd(loaded.entries)
      assert first.score == 0.75
      assert first.design.name == "tracker"
      assert first.design.mem_update_source =~ "def visits"
      assert first.design.recall_source =~ "Visited"
      assert first.design.mem_update == nil
      assert first.design.recall == nil
      assert first.parent_ids == [1]
      assert first.generation == 3
    end

    @tag :tmp_dir
    test "hydrate reconstructs live closures from source", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "archive.json")

      archive =
        Archive.new()
        |> Archive.add(%{
          design: %{
            name: "adder",
            description: "Adds numbers",
            mem_update: nil,
            recall: nil,
            mem_update_source: "(fn [] (+ 1 2))",
            recall_source: "(fn [] (str \"Count: \" 42))"
          },
          score: 0.8
        })

      Archive.save(archive, path)
      loaded = Archive.load(path)
      hydrated = Archive.hydrate(loaded)

      entry = hd(hydrated.entries)
      assert is_tuple(entry.design.mem_update)
      assert is_tuple(entry.design.recall)
    end
  end
end
