defmodule Mix.Tasks.Ptc.RunTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Ptc.Run

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
end
