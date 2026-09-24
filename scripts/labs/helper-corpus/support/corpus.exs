defmodule PtcRunner.Labs.HelperCorpus do
  @moduledoc false
  alias PtcRunner.Labs.PreludeSearch

  @fixture "test/fixtures/prompts/agent-prompt-final-turn.txt"
  @legend "In map types, field? means the field may be omitted; type? means nil is allowed.\n\n"
  @corpus_id "ptc-shipped-helper-corpus"
  @subjects ~w(segments measure delta fold-pages)

  def generate(output) do
    if File.exists?(output) do
      index = Path.join(output, "index.json")

      unless File.lstat!(output).type == :directory and
               (File.ls!(output) == [] or recognized_index?(index)),
             do: raise("refusing to replace a directory that is not a helper corpus: #{output}")

      File.rm_rf!(output)
    end

    File.mkdir_p!(output)
    prompt = File.read!(@fixture)
    empty = prompt |> String.split("Available API\n", parts: 2) |> hd()

    empty =
      empty <> "Available API\n- No mission-specific data, functions, or tools are available.\n"

    result =
      prompt <>
        "\nApplication result contract\nThe host validates the exact value passed to (return value).\nType: :string\n"

    malformed = String.replace(prompt, @legend, "broken legend\n\n", global: false)

    prompts =
      [
        {prompt, "api-entries", "visible"},
        {empty, "api-empty", "visible"},
        {"not a rendering", "unrecognised-marker", "visible"},
        {result, "result-contract", "withheld"},
        {malformed, "unrecognised-boundary", "withheld"},
        {prompt <> "API notes\n", "unrecognised-duplicate-boundary", "withheld"}
      ] ++
        for n <- 1..4 do
          {String.replace(prompt, "- fixture: ", "- fixture-#{n}: ", global: false),
           "generated-entry-variation", if(rem(n, 2) == 0, do: "withheld", else: "visible")}
        end

    prompt_source = File.read!("priv/preludes/kernel/prompt.audit.clj")

    for {subject, call} <- [
          {"segments", "(segments (get input \"prompt\"))"},
          {"measure", "(measure (get input \"prompt\"))"}
        ] do
      source = prompt_source <> "\n(defn corpus [input] (return #{call}))\n"

      cases =
        Enum.map(prompts, fn {text, branch, split} ->
          case_row(%{"prompt" => text}, branch, split)
        end)

      PreludeSearch.capture_helper(
        output,
        subject,
        "prompt.audit",
        "prompt.audit/corpus",
        source,
        cases
      )
    end

    delta_cases =
      [
        case_row(%{"before" => prompt, "after" => prompt}, "same-labels", "visible"),
        case_row(%{"before" => empty, "after" => prompt}, "after-adds-labels", "visible"),
        case_row(%{"before" => prompt, "after" => empty}, "before-only-labels", "withheld"),
        case_row(
          %{"before" => malformed, "after" => result},
          "unrecognised-to-contract",
          "withheld"
        )
      ] ++
        for n <- 1..4 do
          case_row(
            %{"before" => prompt, "after" => prompt <> String.duplicate("x", n)},
            "generated-after-suffix",
            if(rem(n, 2) == 0, do: "withheld", else: "visible")
          )
        end

    delta_source =
      prompt_source <>
        "\n(defn corpus [input] (return (delta (get input \"before\") (get input \"after\"))))\n"

    PreludeSearch.capture_helper(
      output,
      "delta",
      "prompt.audit",
      "prompt.audit/corpus",
      delta_source,
      delta_cases
    )

    pages = %{
      "first" => %{"items" => [1, 2], "next_cursor" => "second", "snapshot_hash" => "sha256:same"},
      "second" => %{"items" => [3], "next_cursor" => nil, "snapshot_hash" => "sha256:same"}
    }

    fold_cases =
      [
        case_row(%{"pages" => pages, "opts" => %{"max_pages" => 2}}, "complete", "visible"),
        case_row(%{"pages" => pages, "opts" => %{"max_pages" => 1}}, "page-bound", "visible"),
        case_row(
          %{"pages" => pages, "opts" => %{"max_pages" => 0}},
          "invalid-max-pages",
          "visible"
        ),
        case_row(
          %{
            "pages" => pages,
            "opts" => %{"max_pages" => 2, "cursor" => "second", "snapshot_hash" => "sha256:same"}
          },
          "resume",
          "withheld"
        ),
        case_row(
          %{"pages" => pages, "opts" => %{"max_pages" => 2, "cursor" => "second"}},
          "missing-snapshot-hash",
          "withheld"
        ),
        case_row(
          %{
            "pages" => %{
              "first" => %{
                "items" => [],
                "next_cursor" => "first",
                "snapshot_hash" => "sha256:same"
              }
            },
            "opts" => %{"max_pages" => 3}
          },
          "cursor-cycle",
          "withheld"
        ),
        case_row(
          %{"pages" => %{"first" => %{"items" => []}}, "opts" => %{"max_pages" => 1}},
          "missing-page-hash",
          "withheld"
        )
      ] ++
        for n <- 1..4 do
          case_row(
            %{
              "pages" => %{
                "first" => %{
                  "items" => Enum.to_list(1..n),
                  "next_cursor" => nil,
                  "snapshot_hash" => "sha256:generated-#{n}"
                }
              },
              "opts" => %{"max_pages" => n}
            },
            "generated-complete",
            if(rem(n, 2) == 0, do: "withheld", else: "visible")
          )
        end

    cap_source =
      File.read!("priv/preludes/kernel/cap.clj") <>
        "\n" <>
        ~S"""
        (defn corpus [input]
          (return
            (fold-pages
              (fn [cursor] (get (get input "pages") (if (nil? cursor) "first" cursor)))
              + 0 (get input "opts"))))
        """

    PreludeSearch.capture_helper(
      output,
      "fold-pages",
      "cap",
      "cap/corpus",
      cap_source,
      fold_cases
    )

    index = %{
      "corpus_id" => @corpus_id,
      "version" => 1,
      "branch_labels_are" => "declared intent, not measured coverage",
      "measurement_boundary" =>
        "duration_ms measures execute_built through publication per invocation; kernel_usage is the aggregate Kernel.run snapshot; no helper-only attribution",
      "subjects" => @subjects,
      "unrepresented_arms" => %{
        "segments" => ["phase-return-contract", "api-notes-absent"],
        "measure" => ["phase-return-contract", "non-string"],
        "delta" => [],
        "fold-pages" => [
          "invalid-cursor",
          "invalid-items",
          "snapshot-changed",
          "missing-next-cursor",
          "invalid-next-cursor"
        ]
      }
    }

    File.write!(Path.join(output, "index.json"), Jason.encode!(index, pretty: true) <> "\n")

    for subject <- @subjects do
      rows = output |> Path.join(subject <> "/executions.json") |> File.read!() |> Jason.decode!()
      visible = MapSet.new(for row <- rows, row["split"] == "visible", do: row["input"])
      withheld = MapSet.new(for row <- rows, row["split"] == "withheld", do: row["input"])

      unless MapSet.disjoint?(visible, withheld),
        do: raise("overlapping input values: #{subject}")
    end
  end

  def replay(output) do
    index = Path.join(output, "index.json")
    unless recognized_index?(index), do: raise("invalid helper corpus index: #{index}")

    discovered =
      output
      |> Path.join("*/executions.json")
      |> Path.wildcard()
      |> Enum.map(&(Path.dirname(&1) |> Path.basename()))
      |> Enum.sort()

    unless discovered == Enum.sort(@subjects),
      do: raise("incomplete helper corpus: expected #{Enum.join(@subjects, ", ")}")

    PreludeSearch.replay(output)
  end

  defp recognized_index?(path) do
    File.regular?(path) and
      case Jason.decode(File.read!(path)) do
        {:ok, %{"corpus_id" => @corpus_id, "version" => 1, "subjects" => @subjects}} ->
          true

        _ ->
          false
      end
  end

  defp case_row(input, branch, split),
    do: %{"input" => input, "branch" => branch, "split" => split}
end
