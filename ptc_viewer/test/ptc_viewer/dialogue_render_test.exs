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

    command_args = [
      Path.expand("../render_viewer.mjs", __DIR__),
      paths.metadata,
      paths.turns,
      paths.inspection
    ]

    command_args =
      case Map.fetch(overrides, :inspection_status) do
        :error ->
          command_args

        {:ok, status} ->
          path =
            Path.join(
              System.tmp_dir!(),
              "dialogue-inspection-status-#{System.unique_integer([:positive])}.json"
            )

          File.write!(path, Jason.encode!(status))
          on_exit(fn -> File.rm(path) end)
          command_args ++ [path]
      end

    {rendered, 0} =
      System.cmd(
        "node",
        command_args,
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

  defp map_llm_inputs(inspection, fun) do
    update_in(inspection, ["records"], fn records ->
      records
      |> Enum.filter(fn record ->
        record["record_type"] == "capability-input" and
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
      # Generated programs are syntax-highlighted PTC-Lisp, not flat text.
      assert rendered =~ ~r{kt-code kt-code-lisp">.*?class="hljs-}s
    end

    test "renders continued evaluations as successful" do
      rendered =
        render_fixtures(%{
          turns: fn turns ->
            update_in(turns, ["items"], fn items ->
              Enum.map(items, fn item ->
                if item["type"] == "evaluation-stopped" and
                     item["data"]["status"] == "returned" do
                  put_in(item, ["data", "status"], "continued")
                else
                  item
                end
              end)
            end)
          end
        })

      assert rendered =~ ~s|class="kt-status kt-status-success">continued</span>|
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

    test "renders captured prelude component source inside the matching card" do
      rendered =
        render_fixtures(%{
          inspection: fn inspection ->
            update_in(inspection, ["records"], fn records ->
              Enum.map(records, fn record ->
                if record["record_type"] == "prelude-source" and
                     record["correlation"]["component_id"] == "agent.core" and
                     record["payload"]["environment"] == "workflow" do
                  put_in(
                    record,
                    ["payload", "source"],
                    "(ns agent.core) (defn zzz-card-marker [task cfg] task)"
                  )
                else
                  record
                end
              end)
            end)
          end
        })

      assert rendered =~ "Component source"
      # The component source is syntax-highlighted, not dumped as raw text: the
      # defined name renders inside a highlight.js title span. (The raw record
      # text also appears in the inspection dump, so assert the highlighted form
      # specifically to pin the rendering.)
      assert rendered =~ ~s(hljs-title">zzz-card-marker</span>)
    end

    test "renders one complete-overlay notice with join counts", %{
      rendered: rendered
    } do
      assert rendered =~ "kt-private-chip"
      assert rendered =~ "Private inspection overlay loaded."
      assert rendered =~ "2/2 LLM calls joined"
      refute rendered =~ "Sanitized trace."
      refute rendered =~ "Sensitive inspection data."
      assert length(Regex.scan(~r/class="kt-provenance/, rendered)) == 1
    end

    test "keeps the captured prompt and raw request behind disclosures", %{
      rendered: rendered
    } do
      assert rendered =~ "Captured model request"
      assert rendered =~ "Raw captured request"
      assert rendered =~ "kt-prompt-version"
      assert rendered =~ "PTC_AGENT_PROMPT_V1"
      assert rendered =~ "Available API"
      assert rendered =~ "Exact captured prompt"
      refute rendered =~ "System prompt: same as LLM call 1."
      refute rendered =~ "Edited or unknown prompt format"
      refute rendered =~ "Exact request sent to the model"
    end

    test "reports a changed system prompt as a diff, not a second full copy", %{
      rendered: rendered
    } do
      assert rendered =~ "System prompt changed"
      assert rendered =~ "kt-prompt-diff"
      # The only substantive change between the two captured prompts is the
      # final-turn instruction, and it is marked as an addition.
      assert rendered =~
               ~r/kt-diff-add"><span class="kt-diff-marker"[^>]*>\+<\/span><span class="kt-diff-text">FINAL TURN: the next program must call/

      assert rendered =~ ~r/\+1 −0 lines vs LLM call 1/
      # Unchanged stretches are elided rather than reprinted.
      assert rendered =~ "unchanged lines"

      # The prompt body is rendered in full exactly once (for LLM call 1); the
      # second call contributes only the diff plus its collapsed exact copy.
      assert length(Regex.scan(~r/class="kt-prompt-section"/, rendered)) == 4
    end

    test "renders model prose next to the generated program, in both directions" do
      prose = "Trying parse-lines first; falling back to read-text if it is unbound."

      rendered =
        render_fixtures(%{
          inspection: fn inspection ->
            update_in(inspection, ["records"], fn records ->
              Enum.map(records, fn record ->
                cond do
                  # The provider response: prose alongside the tool call.
                  record["record_type"] == "capability-output" and
                      record["payload"]["name"] == "llm-request" ->
                    put_in(record, ["payload", "result", "value", "content"], prose)

                  # The same assistant turn replayed in the next request's history.
                  record["record_type"] == "capability-input" and
                      record["payload"]["name"] == "llm-request" ->
                    update_in(record, ["payload", "arguments", "messages"], fn messages ->
                      Enum.map(messages, fn message ->
                        if message["role"] == "assistant" and message["tool_calls"],
                          do: Map.put(message, "content", prose),
                          else: message
                      end)
                    end)

                  true ->
                    record
                end
              end)
            end)
          end
        })

      # Present as the model's own response...
      assert rendered =~ "kt-msg-reasoning"
      assert rendered =~ "assistant · prose"

      # ...and preserved when that turn is replayed as history. Before, an
      # assistant message carrying tool_calls rendered only its program and the
      # prose was dropped.
      assert rendered =~ "kt-msg-prose"

      # Prose and generated source are both shown, never one instead of the other.
      assert rendered =~ prose
      assert rendered =~ "generated program"
      assert length(Regex.scan(~r/#{Regex.escape(prose)}/, rendered)) >= 2
    end

    test "omits the prose block entirely when a response carries none", %{rendered: rendered} do
      refute rendered =~ "kt-msg-reasoning"
      refute rendered =~ "kt-msg-prose"
      assert rendered =~ "generated program"
    end

    test "falls back to exact opaque text for an edited prompt format" do
      rendered =
        render_fixtures(%{
          inspection: fn inspection ->
            update_in(inspection, ["records"], fn records ->
              Enum.map(records, fn record ->
                if record["record_type"] == "capability-input" and
                     record["payload"]["name"] == "llm-request" do
                  update_in(
                    record,
                    ["payload", "arguments", "system"],
                    &String.replace_prefix(&1, "PTC_AGENT_PROMPT_V1", "EDITED_PROMPT")
                  )
                else
                  record
                end
              end)
            end)
          end
        })

      assert rendered =~ "Edited or unknown prompt format"
      assert rendered =~ "EDITED_PROMPT"
    end

    test "keeps legacy mission-API prompts structured" do
      rendered =
        render_fixtures(%{
          inspection: fn inspection ->
            update_in(inspection, ["records"], fn records ->
              Enum.map(records, fn record ->
                if record["record_type"] == "capability-input" and
                     record["payload"]["name"] == "llm-request" do
                  update_in(
                    record,
                    ["payload", "arguments", "system"],
                    &String.replace(
                      &1,
                      "Available API",
                      "Mission API and limits (deterministic JSON)"
                    )
                  )
                else
                  record
                end
              end)
            end)
          end
        })

      assert rendered =~ "Mission API and limits (deterministic JSON)"
      refute rendered =~ "Edited or unknown prompt format"
    end

    test "keeps a canonical empty Available API section structured" do
      rendered =
        render_fixtures(%{
          inspection: fn inspection ->
            update_in(inspection, ["records"], fn records ->
              Enum.map(records, fn record ->
                if record["record_type"] == "capability-input" and
                     record["payload"]["name"] == "llm-request" do
                  update_in(
                    record,
                    ["payload", "arguments", "system"],
                    &String.replace(&1, ~r/Available API.*\z/s, "Available API\n")
                  )
                else
                  record
                end
              end)
            end)
          end
        })

      assert rendered =~ "Available API"
      refute rendered =~ "Edited or unknown prompt format"
    end

    test "moves exact private records behind one closed advanced disclosure", %{
      rendered: rendered
    } do
      assert rendered =~ ~r/<details class="inspection-panel inspection-advanced">/
      assert rendered =~ "Advanced/private records"
      refute rendered =~ ~r/<details class="inspection-panel inspection-advanced" open>/
    end

    test "renders canonical-only, zero-join, interrupted, and fetch-failure states" do
      canonical = render_fixtures(%{inspection: fn _inspection -> nil end})
      assert canonical =~ "Sanitized canonical trace."
      assert length(Regex.scan(~r/class="kt-provenance/, canonical)) == 1

      zero_join = render_fixtures(%{inspection: fn _inspection -> %{"records" => []} end})
      assert zero_join =~ "Private inspection overlay is incomplete: 0/2 LLM calls joined."

      interrupted =
        render_fixtures(%{
          inspection: fn inspection ->
            update_in(inspection, ["records"], fn records ->
              Enum.reject(records, fn record ->
                record["record_type"] == "capability-output" and
                  record["payload"]["name"] == "llm-request"
              end)
            end)
          end
        })

      assert interrupted =~ "0/2 LLM calls joined"
      assert interrupted =~ "2 interrupted"

      failed =
        render_fixtures(%{
          inspection: fn _inspection -> nil end,
          inspection_status: %{"state" => "error", "status" => 503, "reason" => "unavailable"}
        })

      assert failed =~ "Private inspection overlay could not be loaded"
      assert failed =~ "HTTP 503"
      assert length(Regex.scan(~r/class="kt-provenance/, failed)) == 1
    end

    test "preserves canonical LLM ordinals when an earlier private join is missing" do
      rendered =
        render_fixtures(%{
          inspection: fn inspection ->
            first_llm_id =
              Enum.find_value(inspection["records"], fn record ->
                if record["record_type"] == "capability-input" and
                     record["payload"]["name"] == "llm-request" do
                  record["correlation"]["capability_id"]
                end
              end)

            update_in(inspection, ["records"], fn records ->
              Enum.reject(
                records,
                &(&1["correlation"]["capability_id"] == first_llm_id)
              )
            end)
          end
        })

      assert rendered =~ "Private inspection overlay is incomplete: 1/2 LLM calls joined."
      assert rendered =~ "LLM call 2"
      assert rendered =~ "system prompt · LLM call 2"
      assert rendered =~ "Captured messages · previous request unavailable"
      refute rendered =~ "System prompt: same as LLM call 1."
      refute rendered =~ ~r/<strong>LLM call 1<\/strong>/
    end

    test "cannot claim a complete overlay when canonical evidence is incomplete" do
      for metadata_change <- [
            &Map.put(&1, "complete", false),
            &Map.put(&1, "truncated", true)
          ] do
        rendered = render_fixtures(%{metadata: metadata_change})
        assert rendered =~ "Private inspection overlay is incomplete"
        assert rendered =~ "Canonical evidence incomplete"
        refute rendered =~ "Private inspection overlay loaded."
      end

      paged = render_fixtures(%{turns: &Map.put(&1, "next_cursor", "remaining-events")})
      assert paged =~ "Private inspection overlay is incomplete"
      assert paged =~ "Canonical evidence incomplete"
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
      assert rendered =~ ~r/System · mission inventory<\/span>\s*<span[^>]*>≈[1-9]/
      assert rendered =~ "Tool feedback"
      assert rendered =~ "resent with every call"
      assert rendered =~ "apportion each call’s reported input tokens by character share"

      refute rendered =~ "partial"
      refute rendered =~ "totals exclude the unreported calls"
    end

    test "does not treat an inline Available API phrase as an inventory heading" do
      rendered =
        render_fixtures(%{
          inspection: fn inspection ->
            map_llm_inputs(inspection, fn record, _index ->
              put_in(
                record,
                ["payload", "arguments", "system"],
                "PTC_AGENT_PROMPT_V1\nInstructions\nOrdinary prose mentions Available API inline."
              )
            end)
          end
        })

      assert rendered =~ "System · instructions"
      refute rendered =~ "System · mission inventory"
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
                &(&1
                  |> Map.delete("input")
                  |> Map.delete("cache_read")
                  |> Map.put("cache_creation", 7))
              )
            end)
          end
        })

      assert rendered =~ "output tokens</span>"
      assert rendered =~ "cache creation</span>"
      assert rendered =~ "<th>Cache creation</th>"
      refute rendered =~ "<th>Cache read</th>"
      assert rendered =~ "Input composition (by characters)"

      # The never-reported input field renders as a gap, not a zero.
      assert rendered =~ "<strong>—</strong><span>input tokens</span>"
      refute rendered =~ "<strong>0</strong><span>input tokens</span>"
    end

    test "renders legitimately reported zero usage as zeros, not missing data" do
      rendered =
        render_fixtures(%{
          inspection: fn inspection ->
            map_llm_outputs(inspection, fn record, _index ->
              put_in(
                record,
                ["payload", "result", "value", "tokens"],
                %{"input" => 0, "output" => 0}
              )
            end)
          end
        })

      assert rendered =~ "<strong>0</strong><span>input tokens</span>"
      assert rendered =~ "<strong>0</strong><span>output tokens</span>"
      assert rendered =~ "Input token counts were reported as zero"
      refute rendered =~ "No input token counts were reported"
      refute rendered =~ "totals exclude the unreported calls"
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

      assert rendered =~ "Provider usage was reported for 1 of 2 calls"
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
    test "renders the current compact dependency projection by default", %{rendered: rendered} do
      assert rendered =~ "Workflow prelude"
      assert rendered =~ "kt-component-rows"
      assert rendered =~ "Load order — dependencies before dependants."
      assert rendered =~ "agent.core"
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

        assert rendered =~ "kt-component-order"
        assert rendered =~ "agent.core"
      end
    end
  end
end
