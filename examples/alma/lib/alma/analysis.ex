defmodule Alma.Analysis do
  @moduledoc """
  Computes metrics and compresses trajectories from evaluation results.

  This module is **domain-blind** — it operates on generic observation summaries
  provided by the Environment via `summarize_observation/2`. It does not know
  what "rooms", "tickers", or any domain concept means. It only aggregates
  `action_summary`, `state_identifier`, and `discovery` strings.
  """

  @doc """
  Computes aggregate metrics from evaluation results.

  The `env_module` must implement the `Alma.Environment` behaviour, providing
  `summarize_observation/2` for domain-specific interpretation.

  Returns a map with:
  - `success_rate` — fraction of successful episodes
  - `avg_steps` — average steps taken
  - `recall_provided` — fraction of episodes where non-empty recall advice was delivered
  - `avg_recall_length` — average character length of recall advice provided
  - `unique_states` — average distinct state identifiers per episode
  - `avg_discoveries` — average discovery events per episode
  """
  def analyze_results(results, tasks, env_module) do
    count = length(results)

    if count == 0 do
      %{
        success_rate: 0.0,
        avg_steps: 0.0,
        recall_provided: 0.0,
        avg_recall_length: 0.0,
        unique_states: 0.0,
        avg_discoveries: 0.0
      }
    else
      results_with_tasks = Enum.zip(results, tasks)
      successes = Enum.count(results, & &1.success?)
      total_steps = Enum.sum(Enum.map(results, & &1.steps))

      recall_advices =
        Enum.map(results, fn r -> Map.get(r, :recall_advice, "") || "" end)

      recall_provided_count =
        Enum.count(recall_advices, fn advice -> advice != "" end)

      total_recall_length =
        recall_advices |> Enum.map(&String.length/1) |> Enum.sum()

      {total_unique_states, total_discoveries} =
        Enum.reduce(results_with_tasks, {0, 0}, fn {r, t}, {states_acc, disc_acc} ->
          summaries = summarize_log(r.observation_log, t, env_module)

          unique =
            summaries
            |> Enum.map(& &1.state_identifier)
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()
            |> length()

          discoveries = Enum.count(summaries, & &1.discovery)

          {states_acc + unique, disc_acc + discoveries}
        end)

      %{
        success_rate: successes / count,
        avg_steps: total_steps / count,
        recall_provided: recall_provided_count / count,
        avg_recall_length: total_recall_length / count,
        unique_states: total_unique_states / count,
        avg_discoveries: total_discoveries / count
      }
    end
  end

  @doc """
  Produces compressed text summaries of selected episodes.

  Selects the best success (fewest steps) and worst failure (most steps)
  to provide the strongest positive/negative gradient for the MetaAgent.

  Options:
  - `max_episodes` — maximum episodes to include (default: 2)
  """
  def compress_trajectories(results, tasks, env_module, opts \\ []) do
    max_episodes = Keyword.get(opts, :max_episodes, 2)

    if results == [] do
      []
    else
      results_with_tasks = Enum.zip(results, tasks)
      selected = select_episodes(results_with_tasks, max_episodes)
      Enum.map(selected, fn rt -> format_episode(rt, env_module) end)
    end
  end

  @doc false
  def collapse_loops(actions) do
    actions
    |> collapse_subsequences(3)
    |> collapse_subsequences(2)
    |> collapse_subsequences(1)
  end

  # --- Private helpers ---

  defp summarize_log(observation_log, task, env_module) do
    goal = Map.get(task, :goal, %{})
    Enum.map(observation_log, fn obs -> env_module.summarize_observation(obs, goal) end)
  end

  defp select_episodes(results_with_tasks, max_episodes) do
    successes =
      results_with_tasks
      |> Enum.filter(fn {r, _t} -> r.success? end)
      |> Enum.sort_by(fn {r, _t} -> r.steps end, :asc)

    failures =
      results_with_tasks
      |> Enum.reject(fn {r, _t} -> r.success? end)
      |> Enum.sort_by(fn {r, _t} -> r.steps end, :desc)

    candidates = Enum.take(successes, 1) ++ Enum.take(failures, 1)

    remaining = max_episodes - length(candidates)

    if remaining > 0 do
      extra =
        (Enum.drop(successes, 1) ++ Enum.drop(failures, 1))
        |> Enum.take(remaining)

      candidates ++ extra
    else
      Enum.take(candidates, max_episodes)
    end
  end

  defp format_episode({result, task}, env_module) do
    status = if result.success?, do: "SUCCESS", else: "FAILED"
    goal_text = env_module.format_goal(task.goal)
    recall_advice = Map.get(result, :recall_advice, nil)

    summaries = summarize_log(result.observation_log, task, env_module)
    actions = format_summaries(summaries)
    actions = collapse_loops(actions)
    actions = truncate_actions(actions)

    lines = [
      "Episode (#{status}, #{result.steps} steps):",
      "  goal: #{goal_text}"
    ]

    lines =
      if recall_advice && recall_advice != "" do
        lines ++ ["  recall advice: #{inspect(recall_advice)}"]
      else
        lines
      end

    (lines ++ ["  actions: #{Enum.join(actions, " → ")}"])
    |> Enum.join("\n")
  end

  defp format_summaries(summaries) do
    Enum.map(summaries, fn s ->
      if s.discovery do
        "★ #{s.action_summary} [#{s.discovery}]"
      else
        s.action_summary
      end
    end)
  end

  defp collapse_subsequences(actions, subseq_len) do
    do_collapse(actions, subseq_len, [])
  end

  defp do_collapse([], _len, acc), do: Enum.reverse(acc)

  defp do_collapse(actions, len, acc) when length(actions) < len do
    Enum.reverse(acc) ++ actions
  end

  defp do_collapse(actions, len, acc) do
    pattern = Enum.take(actions, len)
    rest = Enum.drop(actions, len)
    {repeats, remaining} = count_repeats(rest, pattern, 1)

    if repeats >= 2 do
      loop_text = "[loop x#{repeats}: #{Enum.join(pattern, " → ")}]"
      do_collapse(remaining, len, [loop_text | acc])
    else
      do_collapse(tl(actions), len, [hd(actions) | acc])
    end
  end

  defp count_repeats(actions, pattern, count) do
    len = length(pattern)

    if length(actions) >= len and Enum.take(actions, len) == pattern do
      count_repeats(Enum.drop(actions, len), pattern, count + 1)
    else
      {count, actions}
    end
  end

  defp truncate_actions(actions) when length(actions) <= 13, do: actions

  defp truncate_actions(actions) do
    first = Enum.take(actions, 10)
    last = Enum.take(actions, -3)
    omitted = length(actions) - 13
    first ++ ["... (#{omitted} steps omitted)"] ++ last
  end
end
