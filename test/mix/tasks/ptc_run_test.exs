defmodule Mix.Tasks.Ptc.RunTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Ptc.Run
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.TraceLog

  @tag :tmp_dir
  test "runs the shared manifest path and accepts a confined mission override", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [input] (return (get input "value")))|
    )

    File.write!(Path.join(dir, "override.json"), Jason.encode!(%{"value" => 42}))

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{"value" => 1}}
    }

    path = Path.join(dir, "ptc.json")
    File.write!(path, Jason.encode!(manifest))

    output =
      capture_io(fn ->
        Mix.Task.reenable("ptc.run")
        Run.run([path, "--mission", "override.json"])
      end)

    assert %{"value" => 42} = Jason.decode!(output)
  end

  @tag :tmp_dir
  test "rejects an occupied inspection destination before execution", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [input] (return 1))|
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}}
    }

    path = Path.join(dir, "ptc.json")
    File.write!(path, Jason.encode!(manifest))

    occupied = Path.join(dir, "run.inspection.jsonl")
    File.write!(occupied, "occupied")

    Mix.Task.reenable("ptc.run")

    assert_raise Mix.Error, ~r/inspection_preflight_failed/, fn ->
      Run.run([path, "--inspect", occupied])
    end

    assert File.read!(occupied) == "occupied"
  end

  @tag :tmp_dir
  test "persists canonical run events when --trace is selected", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [input] (return (get input "value")))|
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{"value" => 42}},
      "labels" => %{"name" => "traceable-run"}
    }

    manifest_path = Path.join(dir, "ptc.json")
    trace_path = Path.join(dir, "run.jsonl")
    File.write!(manifest_path, Jason.encode!(manifest))

    output =
      capture_io(fn ->
        Mix.Task.reenable("ptc.run")
        Run.run([manifest_path, "--trace", trace_path])
      end)

    assert %{"value" => 42} = Jason.decode!(output)
    assert {:ok, trace_log} = TraceLog.new(source: {:file, trace_path})

    assert {:ok, %{"items" => [%{"complete" => true, "name" => name}]}} =
             TraceLog.query(trace_log, :list_runs, %{})

    assert name == SafeMetadata.fingerprint("traceable-run")
  end

  @tag :tmp_dir
  test "traces from separate runs remain a valid shared directory source", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [input] (return (get input "value")))|
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{"value" => 7}}
    }

    manifest_path = Path.join(dir, "ptc.json")
    File.write!(manifest_path, Jason.encode!(manifest))

    for name <- ["first", "second"] do
      capture_io(fn ->
        Mix.Task.reenable("ptc.run")
        Run.run([manifest_path, "--trace", Path.join(dir, "#{name}.jsonl")])
      end)
    end

    assert {:ok, trace_log} = TraceLog.new(source: {:directory, dir})
    assert {:ok, %{"items" => items}} = TraceLog.query(trace_log, :list_runs, %{})

    run_ids = Enum.map(items, & &1["run_id"])
    assert length(items) == 2
    assert Enum.uniq(run_ids) == run_ids
  end

  describe "result artifacts" do
    # The point of the artifact is that a later run consumes it directly, so
    # assert the round trip rather than only the bytes on disk.
    @tag :tmp_dir
    test "writes a value a later run consumes without scraping stdout", %{tmp_dir: dir} do
      manifest_path = write_manifest(dir, %{"value" => %{"value" => 42}})
      output = Path.join(dir, "candidate.json")

      terminal =
        capture_io(fn ->
          Mix.Task.reenable("ptc.run")
          Run.run([manifest_path, "--output", output])
        end)

      assert %{"value" => %{"value" => 42}} = Jason.decode!(terminal)
      assert %{"value" => 42} = output |> File.read!() |> Jason.decode!()

      # Feed the artifact straight back in as the next run's input.
      second =
        capture_io(fn ->
          Mix.Task.reenable("ptc.run")
          Run.run([manifest_path, "--mission", Path.basename(output)])
        end)

      assert %{"value" => 42} = Jason.decode!(second)
    end

    @tag :tmp_dir
    test "refuses to clobber an occupied destination", %{tmp_dir: dir} do
      manifest_path = write_manifest(dir, %{"value" => 1})
      output = Path.join(dir, "answer.json")
      File.write!(output, "occupied")

      Mix.Task.reenable("ptc.run")

      assert_raise Mix.Error, ~r/result_destination_exists/, fn ->
        Run.run([manifest_path, "--output", output])
      end

      assert File.read!(output) == "occupied"
    end

    @tag :tmp_dir
    test "rejects selecting both destinations", %{tmp_dir: dir} do
      manifest_path = write_manifest(dir, %{"value" => 1})

      Mix.Task.reenable("ptc.run")

      assert_raise Mix.Error, ~r/conflicting_result_destinations/, fn ->
        Run.run([
          manifest_path,
          "--output",
          Path.join(dir, "a.json"),
          "--private-output",
          Path.join(dir, "b.json")
        ])
      end

      refute File.exists?(Path.join(dir, "a.json"))
      refute File.exists?(Path.join(dir, "b.json"))
    end

    @tag :tmp_dir
    test "restricts a private artifact to 0600 and keeps the value off stdout",
         %{tmp_dir: dir} do
      manifest_path =
        write_manifest(dir, %{"value" => %{"secret" => "confidential"}}, private?: true)

      output = Path.join(dir, "answer.private.json")

      terminal =
        capture_io(fn ->
          Mix.Task.reenable("ptc.run")
          Run.run([manifest_path, "--private-output", output])
        end)

      refute terminal =~ "confidential"
      assert %{"class" => "private"} = Jason.decode!(terminal)
      assert %{"secret" => "confidential"} = output |> File.read!() |> Jason.decode!()

      assert {:ok, %File.Stat{mode: mode}} = File.stat(output)
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    @tag :tmp_dir
    test "refuses to publish a private value through --output", %{tmp_dir: dir} do
      manifest_path = write_manifest(dir, %{"value" => "confidential"}, private?: true)
      output = Path.join(dir, "answer.json")

      Mix.Task.reenable("ptc.run")

      assert_raise Mix.Error, ~r/private_result_requires_private_destination/, fn ->
        capture_io(fn -> Run.run([manifest_path, "--output", output]) end)
      end

      refute File.exists?(output)
    end

    @tag :tmp_dir
    test "a private run without a private destination keeps nothing", %{tmp_dir: dir} do
      manifest_path = write_manifest(dir, %{"value" => "confidential"}, private?: true)

      Mix.Task.reenable("ptc.run")

      assert_raise Mix.Error, ~r/requires --private-output/, fn ->
        capture_io(fn -> Run.run([manifest_path]) end)
      end
    end
  end

  defp write_manifest(dir, input, opts \\ []) do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [input] (return (get input "value")))|
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => input}
    }

    manifest =
      if Keyword.get(opts, :private?, false),
        do: Map.put(manifest, "events", %{"policy" => "private"}),
        else: manifest

    path = Path.join(dir, "ptc.json")
    File.write!(path, Jason.encode!(manifest))
    path
  end
end
