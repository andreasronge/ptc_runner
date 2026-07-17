defmodule PtcViewer.DialogueRenderTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Renders the frontend transcript over a real multi-turn agent run (canonical
  trace + pinned inspection artifact captured through the viewer HTTP API) and
  asserts the private joins: the model dialogue, generated program source,
  model feedback, source-hash verification, token spend, and the strict
  prelude dependency-graph contract with its chip fallback.
  """

  @fixtures Path.expand("../fixtures", __DIR__)

  setup_all do
    %{rendered: render_fixtures()}
  end

  defp render_fixtures(overrides \\ %{}) do
    paths =
      Map.new([:metadata, :turns, :inspection], fn kind ->
        default = Path.join(@fixtures, "dialogue_#{kind}.json")

        case Map.fetch(overrides, kind) do
          :error ->
            {kind, default}

          {:ok, transform} ->
            data = default |> File.read!() |> Jason.decode!() |> transform.()

            path =
              Path.join(
                System.tmp_dir!(),
                "dialogue-#{kind}-#{System.unique_integer([:positive])}.json"
              )

            File.write!(path, Jason.encode!(data))
            on_exit(fn -> File.rm(path) end)
            {kind, path}
        end
      end)

    {rendered, 0} =
      System.cmd(
        "node",
        [
          Path.expand("../render_viewer.mjs", __DIR__),
          paths.metadata,
          paths.turns,
          paths.inspection
        ],
        stderr_to_stdout: true
      )

    rendered
  end

  defp map_llm_outputs(inspection, fun) do
    update_in(inspection, ["records"], fn records ->
      records
      |> Enum.filter(fn record ->
        record["record_type"] == "capability-output" and
          record["payload"]["name"] == "llm-request"
      end)
      |> Enum.with_index()
      |> Enum.reduce(records, fn {record, index}, acc ->
        replaced = fun.(record, index)
        Enum.map(acc, fn candidate -> if candidate == record, do: replaced, else: candidate end)
      end)
    end)
  end

  defp group_digits(value) do
    value
    |> Integer.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  describe "model dialogue" do
    test "renders one dialogue turn per captured llm-request", %{rendered: rendered} do
      assert rendered =~ "Model dialogue"

      llm_calls =
        @fixtures
        |> Path.join("dialogue_inspection.json")
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("records")
        |> Enum.count(fn record ->
          record["record_type"] == "capability-input" and
            record["payload"]["name"] == "llm-request"
        end)

      assert llm_calls > 1

      for turn <- 1..llm_calls do
        assert rendered =~ "LLM call #{turn}"
      end

      refute rendered =~ "LLM call #{llm_calls + 1}"
    end

    test "shows generated programs and the feedback sent back to the model", %{
      rendered: rendered
    } do
      assert rendered =~ "generated program"
      assert rendered =~ "run_ptc_lisp"
      assert rendered =~ "tool · feedback"
      assert rendered =~ "The PTC-Lisp evaluation did not return successfully."
    end

    test "verifies captured source hashes against canonical evaluation events", %{
      rendered: rendered
    } do
      assert rendered =~ "source hash verified"
      refute rendered =~ "source hash mismatch"
      assert rendered =~ "Program source"
      refute rendered =~ "pairing is omitted"
    end

    test "pairs evaluations only on exact captured-source matches" do
      rendered =
        render_fixtures(%{
          inspection: fn inspection ->
            update_in(inspection, ["records"], fn records ->
              [first_source | _] =
                Enum.filter(records, &(&1["record_type"] == "evaluation-source"))

              Enum.map(records, fn record ->
                if record == first_source do
                  update_in(record, ["payload", "source"], &(&1 <> " "))
                else
                  record
                end
              end)
            end)
          end
        })

      assert rendered =~ "pairing is omitted rather than inferred"
    end

    test "marks private payload panels and keeps the sanitized-trace notice", %{
      rendered: rendered
    } do
      assert rendered =~ "kt-private-chip"
      assert rendered =~ "Sanitized trace."
      assert rendered =~ "Sensitive inspection data"
    end
  end

  describe "token spend" do
    test "reports totals and estimated input composition", %{rendered: rendered} do
      assert rendered =~ "LLM token spend"

      tokens =
        @fixtures
        |> Path.join("dialogue_inspection.json")
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("records")
        |> Enum.filter(fn record ->
          record["record_type"] == "capability-output" and
            record["payload"]["name"] == "llm-request"
        end)
        |> Enum.map(&get_in(&1, ["payload", "result", "value", "tokens"]))

      input_total = tokens |> Enum.map(& &1["input"]) |> Enum.sum() |> group_digits()
      output_total = tokens |> Enum.map(& &1["output"]) |> Enum.sum() |> group_digits()

      assert rendered =~ "<strong>#{input_total}</strong><span>input tokens</span>"
      assert rendered =~ "<strong>#{output_total}</strong><span>output tokens</span>"
      assert rendered =~ "reported cost"

      assert rendered =~ "Input composition (estimated)"
      assert rendered =~ "System · instructions"
      assert rendered =~ "System · mission inventory"
      assert rendered =~ "Tool feedback"
      assert rendered =~ "resent with every call"
      assert rendered =~ "apportion each call’s reported input tokens by character share"

      refute rendered =~ "partial"
      refute rendered =~ "totals exclude the unreported calls"
    end

    test "falls back to character proportions when no usage at all is reported" do
      rendered =
        render_fixtures(%{
          inspection: fn inspection ->
            map_llm_outputs(inspection, fn record, _index ->
              update_in(record, ["payload", "result", "value"], &Map.delete(&1, "tokens"))
            end)
          end
        })

      assert rendered =~ "Input composition (by characters)"
      assert rendered =~ "No input token counts were reported"
      refute rendered =~ "input tokens</span>"
    end

    test "keeps output/cache/cost visible when input counts are missing" do
      rendered =
        render_fixtures(%{
          inspection: fn inspection ->
            map_llm_outputs(inspection, fn record, _index ->
              update_in(
                record,
                ["payload", "result", "value", "tokens"],
                &(&1 |> Map.delete("input") |> Map.put("cache_creation", 7))
              )
            end)
          end
        })

      assert rendered =~ "output tokens</span>"
      assert rendered =~ "cache creation</span>"
      assert rendered =~ "<th>Cache creation</th>"
      refute rendered =~ "<th>Cache read</th>"
      assert rendered =~ "Input composition (by characters)"
    end

    test "labels totals when some calls lack reported usage" do
      rendered =
        render_fixtures(%{
          inspection: fn inspection ->
            map_llm_outputs(inspection, fn record, index ->
              if index == 0 do
                update_in(record, ["payload", "result", "value"], &Map.delete(&1, "tokens"))
              else
                record
              end
            end)
          end
        })

      assert rendered =~ "Provider usage was reported for 3 of 4 calls"
      assert rendered =~ "totals exclude the unreported calls"
      assert rendered =~ "—"
    end

    test "labels spend and dialogue as partial when more event pages exist" do
      rendered =
        render_fixtures(%{
          turns: fn turns -> Map.put(turns, "next_cursor", "opaque-cursor") end
        })

      assert rendered =~ "cover only the loaded events"
      assert rendered =~ "kt-partial-chip"
    end
  end

  describe "prelude dependency graph" do
    test "renders load-order chips with bundle hash by default", %{rendered: rendered} do
      assert rendered =~ "Workflow prelude"
      assert rendered =~ "kt-component-order"
      assert rendered =~ "Load order — dependencies before dependants."
      assert rendered =~ "agent.core"
      refute rendered =~ "kt-component-rows"
    end

    test "renders the compact dependency projection when valid" do
      rendered =
        render_fixtures(%{
          metadata: fn metadata ->
            Map.put(metadata, "workflow_prelude", %{
              "component_ids" => ["kernel", "llm", "agent.core"],
              "dependency_indices" => [[], [], [0, 1]],
              "hash" => "abc"
            })
          end
        })

      assert rendered =~ "kt-component-rows"
      assert rendered =~ "needs"
      assert rendered =~ "used by 1"
    end

    test "falls back to chips for every malformed dependency projection" do
      malformed = [
        # forward/self reference: index not < position
        [[0], [], []],
        # length mismatch
        :short,
        # descending (violates unique ascending)
        [[], [], [1, 0]],
        # non-integer index
        [[], [], ["0"]]
      ]

      for indices <- malformed do
        rendered =
          render_fixtures(%{
            metadata: fn metadata ->
              Map.put(metadata, "workflow_prelude", %{
                "component_ids" => ["kernel", "llm", "agent.core"],
                "dependency_indices" => if(indices == :short, do: [[], []], else: indices),
                "hash" => "abc"
              })
            end
          })

        refute rendered =~ "kt-component-rows"
        assert rendered =~ "kt-component-order"
        assert rendered =~ "agent.core"
      end
    end
  end
end
