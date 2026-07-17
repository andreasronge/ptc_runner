defmodule Mix.Tasks.Ptc.RunTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Ptc.Run
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.TraceLog

  @tag :tmp_dir
  test "runs the shared manifest path and accepts a confined mission override", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "main.lisp"),
      ~S|(ns main) (defn run [input] (return (get input "value")))|
    )

    File.write!(Path.join(dir, "override.json"), Jason.encode!(%{"value" => 42}))

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.lisp"}],
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
      Path.join(dir, "main.lisp"),
      ~S|(ns main) (defn run [input] (return 1))|
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.lisp"}],
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
      Path.join(dir, "main.lisp"),
      ~S|(ns main) (defn run [input] (return (get input "value")))|
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.lisp"}],
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
      Path.join(dir, "main.lisp"),
      ~S|(ns main) (defn run [input] (return (get input "value")))|
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.lisp"}],
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
end
