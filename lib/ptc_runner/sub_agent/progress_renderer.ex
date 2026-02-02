defmodule PtcRunner.SubAgent.ProgressRenderer do
  @moduledoc """
  Renders a markdown checklist from plan steps and summaries.

  Used to show the LLM its progress through a plan as user feedback messages.

  ## Rendering

  Steps are checked off only when `step-done` has been called with the
  matching ID. The journal (task cache) is not consulted — caching and
  progress tracking are independent concerns.

  ## Visibility

  `TurnFeedback.format/3` merges the current turn's summaries before
  rendering, so `step-done` calls appear in the checklist on the
  *next* turn's prompt (i.e., the feedback message for the current turn).
  If the current turn errors, its summaries are discarded by the loop
  and never reach the renderer.
  See `PtcRunner.SubAgent.Loop.TurnFeedback` for the call site.

  Step-done entries whose IDs don't appear in the plan are collected
  under an "Out-of-Plan Steps" section.
  """

  @doc """
  Render a progress checklist.

  ## Parameters

  - `plan` - Normalized plan list of `{id, description}` tuples
  - `summaries` - Summaries map from step-done calls

  ## Returns

  A markdown string with the progress checklist, or empty string if no plan.
  """
  @spec render([{String.t(), String.t()}], map()) :: String.t()
  def render(plan, summaries)

  def render([], _summaries), do: ""

  def render(plan, summaries) when is_list(plan) do
    summaries = summaries || %{}

    plan_ids = MapSet.new(plan, fn {id, _} -> id end)

    plan_lines =
      Enum.map(plan, fn {id, description} ->
        render_plan_step(id, description, summaries)
      end)

    # Out-of-plan step-done entries
    extra_lines =
      summaries
      |> Enum.reject(fn {id, _} -> MapSet.member?(plan_ids, id) end)
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.map(fn {id, summary} ->
        "- [x] #{id}: #{summary}"
      end)

    sections = [
      "## Progress\n",
      "Batch independent steps in the same turn. Use `(step-done \"id\" \"summary\")` for each completed step.\n\n",
      Enum.join(plan_lines, "\n")
    ]

    sections =
      if extra_lines != [] do
        sections ++ ["\n\n### Out-of-Plan Steps\n", Enum.join(extra_lines, "\n")]
      else
        sections
      end

    Enum.join(sections)
  end

  defp render_plan_step(id, description, summaries) do
    if Map.has_key?(summaries, id) do
      "- [x] **#{id}.** #{description} — #{summaries[id]}"
    else
      "- [ ] **#{id}.** #{description}"
    end
  end
end
