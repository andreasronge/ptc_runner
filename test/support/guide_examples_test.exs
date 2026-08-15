defmodule PtcRunner.TestSupport.GuideExamplesTest do
  use ExUnit.Case, async: false

  alias PtcRunner.TestSupport.GuideExamples

  test "returns command diagnostics when an asserted envelope is missing" do
    example = example("printf 'guide failed\\n' >&2; exit 23")

    result = GuideExamples.run(example, File.cwd!())

    assert result.status == 23
    assert result.stderr == "guide failed\n"
    assert result.stdout == ""
    assert result.envelope == nil
  end

  test "isolates concurrent guide runs in distinct temporary directories" do
    example =
      example("""
      printf '{"status":"ok","execution":{"usage":{"subordinate_evaluations":2,"capability_calls":{"workflow/llm-request":2}},"evaluation_memory":{"defined_count":1,"history_count":1}},"scratch":"%s"}\\n' "$PTC_ENVELOPE_FILE" > "$PTC_ENVELOPE_FILE"
      printf '{"ok":true}\\n'
      """)

    paths =
      1..32
      |> Task.async_stream(
        fn _index -> GuideExamples.run(example, File.cwd!()) end,
        max_concurrency: 32,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} ->
        assert result.status == 0
        assert result.stderr == ""
        assert GuideExamples.last_json!(result.stdout) == %{"ok" => true}
        assert GuideExamples.verify_assertion(example, result.envelope) == :ok

        result.envelope
        |> Map.fetch!("scratch")
        |> Path.dirname()
      end)

    assert length(Enum.uniq(paths)) == length(paths)
  end

  @tag :tmp_dir
  test "isolates project artifacts and injects credentials through the copied project", %{
    tmp_dir: directory
  } do
    variable = "PTC_GUIDE_TEST_PROJECT_KEY"
    previous = System.get_env(variable)
    System.put_env(variable, "temporary-secret")

    on_exit(fn ->
      if previous, do: System.put_env(variable, previous), else: System.delete_env(variable)
    end)

    project_path = Path.join(directory, "ptc-project.json")

    File.write!(
      project_path,
      Jason.encode!(%{
        "kind" => "ptc-project",
        "version" => 1,
        "application" => %{"path" => "ptc.json"},
        "host" => %{
          "path" => "ptc-host.json",
          "env_file" => %{"path" => ".env"}
        },
        "artifacts" => %{
          "root" => ".ptc",
          "trace" => true,
          "inspection" => false,
          "result" => false,
          "envelope" => true
        }
      })
    )

    File.write!(Path.join(directory, "ptc.json"), "{}")
    File.write!(Path.join(directory, "ptc-host.json"), "{}")

    command = """
    project=#{project_path}
    env_file="$(dirname "$project")/.env"
    artifact_root="$(dirname "$project")/.ptc"
    grep -q '^#{variable}=temporary-secret$' "$env_file"
    mkdir -p "$artifact_root/envelopes"
    printf '{"status":"ok","execution":{"usage":{"subordinate_evaluations":2,"capability_calls":{"workflow/llm-request":2}},"evaluation_memory":{"defined_count":1,"history_count":1}}}\n' > "$artifact_root/envelopes/run.json"
    printf '{"ok":true}\n'
    """

    example = %GuideExamples{
      assertion: "two-turn-agent",
      command: command,
      expected: %{"ok" => true},
      id: "project-example",
      line: 1,
      project: project_path,
      requires: variable
    }

    result = GuideExamples.run(example, File.cwd!())

    assert result.status == 0
    assert result.stderr == ""
    assert GuideExamples.last_json!(result.stdout) == %{"ok" => true}
    assert GuideExamples.verify_assertion(example, result.envelope) == :ok
    refute File.exists?(Path.join(directory, ".env"))
    refute File.exists?(Path.join(directory, ".ptc"))
  end

  @tag :tmp_dir
  test "rejects non-canonical executable-guide registry entries", %{tmp_dir: dir} do
    registry = Path.join(dir, "executable-guides.txt")

    for entry <- ["  docs/guides/quickstart.md  ", "./docs/guides/quickstart.md"] do
      File.write!(registry, entry <> "\n")

      assert_raise ArgumentError, ~r/must be canonical and repository-relative/, fn ->
        GuideExamples.parse_registry!(registry, File.cwd!())
      end
    end
  end

  defp example(command) do
    %GuideExamples{
      assertion: "two-turn-agent",
      command: command,
      expected: %{"ok" => true},
      id: "test-example",
      line: 1,
      requires: nil
    }
  end
end
