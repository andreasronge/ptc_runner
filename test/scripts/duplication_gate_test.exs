defmodule PtcRunner.Scripts.DuplicationGateTest do
  use ExUnit.Case, async: true

  @gate Path.expand("../../scripts/duplication_gate.py", __DIR__)

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "ptc-duplication-gate-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok,
     report_path: Path.join(root, "report.json"), baseline_path: Path.join(root, "baseline.json")}
  end

  test "line movement leaves a known clone stable", context do
    clone = clone(:type_i, 40, [{"lib/a.ex", 10, "same"}, {"lib/b.ex", 20, "same"}])
    bless(context, [clone])

    moved = clone(:type_i, 40, [{"lib/a.ex", 110, "same"}, {"lib/b.ex", 220, "same"}])

    assert {output, 0} = check(context, [moved])
    assert output =~ "new=0"
  end

  test "whitespace inside a literal cannot collide with a known clone", context do
    old = ~S(def value, do: "a b")
    changed = ~S(def value, do: "a  b")
    bless(context, [clone(:type_i, 40, [{"lib/a.ex", 1, old}, {"lib/b.ex", 1, old}])])

    assert {output, 1} =
             check(context, [
               clone(:type_i, 40, [{"lib/a.ex", 1, changed}, {"lib/b.ex", 1, changed}])
             ])

    assert output =~ "NEW"
  end

  test "adding another occurrence is duplication growth", context do
    old = clone(:type_i, 40, [{"lib/a.ex", 1, "same"}, {"lib/a.ex", 20, "same"}])
    bless(context, [old])

    grown =
      clone(:type_i, 40, [
        {"lib/a.ex", 1, "same"},
        {"lib/a.ex", 20, "same"},
        {"lib/a.ex", 40, "same"}
      ])

    assert {output, 1} = check(context, [grown])
    assert output =~ "NEW"
  end

  test "one resolved clone cannot exempt two replacements", context do
    old = clone(:type_i, 40, [{"lib/a.ex", 1, "same"}, {"lib/b.ex", 1, "same"}])
    bless(context, [old])

    replacements = [
      clone(:type_ii, 39, [{"lib/a.ex", 1, "same"}, {"lib/b.ex", 1, "first"}]),
      clone(:type_ii, 38, [{"lib/a.ex", 1, "second"}, {"lib/b.ex", 1, "same"}])
    ]

    assert {output, 1} = check(context, replacements)
    assert output =~ "new=1"
    assert output =~ "shrunk=1"
  end

  test "a smaller, less exact remnant with an unchanged occurrence passes", context do
    old =
      clone(:type_i, 40, [
        {"lib/a.ex", 1, "same"},
        {"lib/b.ex", 1, "same"},
        {"lib/c.ex", 1, "same"}
      ])

    bless(context, [old])

    remnant =
      clone(:type_ii, 35, [{"lib/a.ex", 1, "same"}, {"lib/b.ex", 1, "changed"}])

    assert {output, 0} = check(context, [remnant])
    assert output =~ "shrunk=1"
    assert output =~ "new=0"
  end

  test "unrelated smaller duplication in the same files fails", context do
    old = clone(:type_i, 40, [{"lib/a.ex", 1, "old"}, {"lib/b.ex", 1, "old"}])
    bless(context, [old])

    unrelated = clone(:type_ii, 30, [{"lib/a.ex", 1, "new"}, {"lib/b.ex", 1, "new"}])

    assert {output, 1} = check(context, [unrelated])
    assert output =~ "NEW"
  end

  defp bless(context, clones) do
    write_report(context.report_path, clones)
    assert {_output, 0} = run_gate("bless", context)
  end

  defp check(context, clones) do
    write_report(context.report_path, clones)
    run_gate("check", context)
  end

  defp run_gate(mode, context) do
    System.cmd(
      "python3",
      [@gate, mode, context.report_path, context.baseline_path],
      stderr_to_stdout: true
    )
  end

  defp write_report(path, clones), do: File.write!(path, Jason.encode!(%{"clones" => clones}))

  defp clone(type, mass, occurrences) do
    %{
      "type" => Atom.to_string(type),
      "mass" => mass,
      "fragments" =>
        Enum.map(occurrences, fn {file, line, _snippet} ->
          %{"file" => file, "line" => line, "mass" => mass}
        end),
      "snippets" => Enum.map(occurrences, &elem(&1, 2))
    }
  end
end
