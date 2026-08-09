defmodule Mix.Tasks.Ptc.RunTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Ptc.Run
  alias PtcRunner.Dotenv
  alias PtcRunner.MixRunAdapter

  @tag :tmp_dir
  test "delegates the stable run grammar and renders its closed envelope", %{tmp_dir: dir} do
    manifest_path = write_manifest(dir, %{"value" => 1})
    input_path = Path.join(dir, "input.json")
    File.write!(input_path, Jason.encode!(%{"value" => 42}))

    envelope = run_envelope([manifest_path, "--input", Path.basename(input_path)])

    assert %{
             "schema_version" => 1,
             "command" => "run",
             "status" => "ok",
             "result" => %{"result_class" => "normal", "value" => 42},
             "execution" => %{"state" => "finished", "outcome" => "ok"}
           } = envelope
  end

  @tag :tmp_dir
  test "raises the same closed envelope for a shared command failure", %{tmp_dir: dir} do
    manifest_path = write_manifest(dir, %{"value" => 1})
    missing_host = Path.join(dir, "missing-host.json")

    envelope = failed_envelope([manifest_path, "--host-config", missing_host])

    assert envelope["status"] == "error"
    assert envelope["command"] == "run"
    assert envelope["error"]["phase"] == "host"
    assert envelope["error"]["code"] == "host_unavailable"
    assert envelope["error"]["provider_activity"] == false
    refute Jason.encode!(envelope) =~ dir
  end

  @tag :tmp_dir
  test "keeps a private input value out of the envelope and writes only its private artifact", %{
    tmp_dir: dir
  } do
    manifest_path = write_manifest(dir, %{"value" => 1})
    File.write!(Path.join(dir, "private.json"), Jason.encode!(%{"value" => "confidential"}))
    private_output = Path.join(dir, "answer.private.json")

    envelope =
      run_envelope([
        manifest_path,
        "--private-input",
        "private.json",
        "--private-output",
        private_output
      ])

    assert envelope["result"] == %{"result_class" => "private"}
    assert envelope["artifact_class"] == "private"
    assert envelope["artifact_state"]["result"] == "written"
    refute Jason.encode!(envelope) =~ "confidential"
    assert Jason.decode!(File.read!(private_output)) == "confidential"
  end

  @tag :tmp_dir
  test "uses the shared trace-directory publication contract", %{tmp_dir: dir} do
    manifest_path = write_manifest(dir, %{"value" => 1})
    trace_dir = Path.join(dir, "traces")
    File.mkdir!(trace_dir)

    envelope = run_envelope([manifest_path, "--trace-dir", trace_dir])

    assert envelope["artifact_state"]["trace"] == "written"
    assert File.exists?(Path.join(trace_dir, envelope["run_ref"] <> ".jsonl"))
  end

  @tag :tmp_dir
  test "rejects removed options and the removed check route in phase 1", %{tmp_dir: dir} do
    manifest_path = write_manifest(dir, %{"value" => 1})

    for removed <- [
          ["--mission", "input.json"],
          ["--private-mission", "input.json"],
          ["--trace", "run.jsonl"],
          ["--check"]
        ] do
      envelope = failed_envelope([manifest_path | removed])
      assert envelope["error"]["phase"] == "arguments"
      assert envelope["error"]["code"] == "invalid_arguments"
      assert envelope["error"]["provider_activity"] == false
      assert envelope["execution"] == %{"state" => "not_started"}
    end
  end

  test "rejects malformed and duplicate Mix authorization extensions through a closed envelope" do
    for args <- [
          ["ptc.json", "--authorize-mcp"],
          ["ptc.json", "--authorize-mcp", "workspace", "--authorize-mcp", "workspace"]
        ] do
      envelope = failed_envelope(args)
      assert envelope["error"]["phase"] == "arguments"
      assert envelope["error"]["code"] == "invalid_arguments"
      assert envelope["error"]["provider_activity"] == false
    end
  end

  test "bootstrap failures return a closed private-safe run outcome" do
    private_reason = "bootstrap-secret"

    assert {:error, outcome} =
             MixRunAdapter.dispatch(["private/application/ptc.json"], fn ->
               raise private_reason
             end)

    envelope = outcome.envelope
    encoded = Jason.encode!(envelope)

    assert envelope["status"] == "error"
    assert envelope["command"] == "run"
    assert envelope["error"]["phase"] == "internal"
    assert envelope["error"]["code"] == "internal_error"
    assert envelope["error"]["provider_activity"] == false
    assert envelope["execution"] == %{"state" => "not_started"}
    refute encoded =~ private_reason
    refute encoded =~ "private/application"
  end

  @tag :tmp_dir
  test "provider-free runs do not read an ambient dotenv file", %{tmp_dir: dir} do
    variable = "PTC_RUN_UNUSED_DOTENV_CREDENTIAL"
    reset_dotenv(variable)
    File.write!(Path.join(dir, ".env"), "#{variable}=must-not-load\n")
    manifest_path = write_manifest(dir, %{"value" => 1})

    File.cd!(dir, fn -> run_envelope([manifest_path]) end)

    assert System.get_env(variable) == nil
  end

  defp run_envelope(args) do
    output =
      capture_io(fn ->
        Mix.Task.reenable("ptc.run")
        Run.run(args)
      end)

    Jason.decode!(output)
  end

  defp failed_envelope(args) do
    Mix.Task.reenable("ptc.run")
    error = assert_raise Mix.Error, fn -> Run.run(args) end
    Jason.decode!(error.message)
  end

  defp write_manifest(dir, input) do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [input] (return (get input "value")))|
    )

    path = Path.join(dir, "ptc.json")

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "main", "path" => "main.clj"}],
          "entry" => "main/run"
        },
        "input" => %{"value" => input}
      })
    )

    path
  end

  defp reset_dotenv(variable) do
    previous_value = System.get_env(variable)
    key = {Dotenv, :dotenv_loaded}
    previous_state = :persistent_term.get(key, :missing)

    System.delete_env(variable)
    :persistent_term.erase(key)

    on_exit(fn ->
      if previous_value,
        do: System.put_env(variable, previous_value),
        else: System.delete_env(variable)

      case previous_state do
        :missing -> :persistent_term.erase(key)
        state -> :persistent_term.put(key, state)
      end
    end)
  end
end
