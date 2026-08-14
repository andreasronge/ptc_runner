defmodule PtcRunner.TestSupport.GuideExamplesTest do
  use ExUnit.Case, async: true

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
