defmodule PtcRunner.Scripts.GuideBudgetTest do
  use ExUnit.Case, async: true

  @gate Path.expand("../../scripts/guide_budget.py", __DIR__)

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "ptc-guide-budget-#{System.unique_integer([:positive, :monotonic])}"
      )

    guides = Path.join(root, "guides")
    File.mkdir_p!(guides)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root, guides: guides, baseline: Path.join(root, "baseline.json")}
  end

  test "a blessed guide passes unchanged", context do
    write(context, "a.md", short_guide())
    assert {_, 0} = run(context, "bless")
    assert {output, 0} = run(context, "check")
    assert output =~ "1 guides within budget"
  end

  test "prose added to a blessed guide fails and names the metric", context do
    write(context, "a.md", short_guide())
    assert {_, 0} = run(context, "bless")

    write(context, "a.md", short_guide() <> "\n" <> skip_blocker())
    assert {output, 1} = run(context, "check")
    assert output =~ "grew past its budget"
    assert output =~ "a.md: words"
    assert output =~ "a.md: blockers 1 exceeds baseline 0"
  end

  test "identifier density is spent by prose, not by fenced example code", context do
    # Both revisions carry the same word count, so only density can move. A
    # fenced block full of identifiers is example code a reader skips past;
    # the same identifiers in a sentence are reference detail in a guide.
    fenced =
      short_guide() <> "\n```json\n" <> Enum.map_join(1..30, " ", &"\"k#{&1}\"") <> "\n```\n"

    prose = short_guide() <> "\nSee " <> inline_identifiers(30) <> "\n"

    write(context, "a.md", fenced)
    assert {_, 0} = run(context, "bless")
    assert {output, 0} = run(context, "check")
    assert output =~ "1 guides within budget"

    write(context, "a.md", prose)
    assert {output, 1} = run(context, "check")
    assert output =~ "a.md: density"
    refute output =~ "a.md: words"
  end

  test "moving prose between guides cannot satisfy the budget", context do
    write(context, "a.md", short_guide() <> "\n" <> skip_blocker())
    write(context, "b.md", short_guide())
    assert {_, 0} = run(context, "bless")

    # Same total across the tier, but b.md now exceeds its own row.
    write(context, "a.md", short_guide())
    write(context, "b.md", short_guide() <> "\n" <> skip_blocker())

    assert {output, 1} = run(context, "check")
    assert output =~ "b.md"
    refute output =~ "a.md: words"
  end

  test "a shrunk guide passes and is reported as tightenable", context do
    write(context, "a.md", short_guide() <> "\n" <> skip_blocker())
    assert {_, 0} = run(context, "bless")

    write(context, "a.md", short_guide())
    assert {output, 0} = run(context, "check")
    assert output =~ "loose enough to tighten"
    assert output =~ "a.md"
  end

  test "a new guide with no baseline row is held to the new-guide caps", context do
    write(context, "a.md", short_guide())
    assert {_, 0} = run(context, "bless")

    write(context, "new.md", "# New\n\n" <> String.duplicate("Filler words here. ", 300))
    assert {output, 1} = run(context, "check")
    assert output =~ "new.md: words"
    assert output =~ "new-guide cap"
  end

  test "a removed guide leaves its stale baseline row inert", context do
    write(context, "a.md", short_guide())
    write(context, "b.md", short_guide())
    assert {_, 0} = run(context, "bless")

    File.rm!(Path.join(context.guides, "b.md"))
    assert {output, 0} = run(context, "check")
    assert output =~ "1 guides within budget"
  end

  defp short_guide do
    """
    # Do one thing

    Run the command. Read the result.

    ```console
    ptc run ptc-project.json
    ```
    """
  end

  # 3+ sentences and 55+ words with no list, fence, or table to break it up.
  defp skip_blocker do
    String.duplicate(
      "The owner holds the lease for the whole session and refuses a second claim. ",
      6
    )
  end

  defp inline_identifiers(count) do
    Enum.map_join(1..count, " ", &"`option_#{&1}`")
  end

  defp write(context, name, body) do
    File.write!(Path.join(context.guides, name), body)
  end

  defp run(context, mode) do
    System.cmd("python3", [@gate, mode, context.baseline],
      cd: context.root,
      env: [{"PTC_GUIDE_DIRS", "guides"}],
      stderr_to_stdout: true
    )
  end
end
