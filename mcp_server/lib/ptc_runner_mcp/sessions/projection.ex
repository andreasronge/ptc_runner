defmodule PtcRunnerMcp.Sessions.Projection do
  @moduledoc """
  Response shaping for PTC-Lisp session operations.
  """

  alias PtcRunner.Lisp.Format
  alias PtcRunner.SubAgent.Loop.TurnFeedback
  alias PtcRunner.SubAgent.Namespace.{ExecutionHistory, User}
  alias PtcRunnerMcp.Sessions.Config
  alias PtcRunnerMcp.Sessions.Limits

  @session_feedback_max_chars 2048
  @collection_hint_min_items 20

  @doc "Render a session-start response."
  @spec start(map()) :: map()
  def start(state) do
    %{
      "status" => "ok",
      "session_id" => state.id,
      "expires_at" => DateTime.to_iso8601(state.expires_at),
      "limits" => Limits.project_limits(state.limits)
    }
  end

  @doc "Render a successful eval response."
  @spec eval_success(map(), map(), map(), [map()]) :: map()
  def eval_success(previous, committed, step, history_notices) do
    execution = eval_execution(previous, step)
    usage = session_usage(committed)

    %{
      "status" => "ok",
      "result" => execution.result,
      "prints" => execution.prints,
      "feedback" =>
        execution.feedback
        |> append_value_hints(execution.result_truncated, previous, step, history_notices)
        |> append_history_notices(history_notices),
      "memory" => %{
        "changed_keys" => changed_keys(execution.memory.changed),
        "stored_keys" => execution.memory.stored_keys,
        "truncated" => execution.memory.truncated
      },
      "session" => %{
        "session_id" => committed.id,
        "turn" => committed.turn,
        "memory_bytes" => usage.memory_bytes,
        "binding_count" => usage.binding_count
      },
      "history_notices" => history_notices,
      "truncated" => execution.truncated or history_notices != []
    }
  end

  @doc "Render the verbose successful eval payload retained for diagnostics."
  @spec eval_success_diagnostic(map(), map(), map(), [map()]) :: map()
  def eval_success_diagnostic(previous, committed, step, history_notices) do
    execution = eval_execution(previous, step)
    usage = session_usage(committed)

    %{
      "status" => "ok",
      "result" => execution.result,
      "prints" => execution.prints,
      "feedback" =>
        execution.feedback
        |> append_value_hints(execution.result_truncated, previous, step, history_notices)
        |> append_history_notices(history_notices),
      "memory" => %{
        "changed" => execution.memory.changed,
        "changed_keys" => changed_keys(execution.memory.changed),
        "stored_keys" => execution.memory.stored_keys,
        "truncated" => execution.memory.truncated
      },
      "session" => %{
        "session_id" => committed.id,
        "turn" => committed.turn,
        "memory_bytes" => usage.memory_bytes,
        "binding_count" => usage.binding_count
      },
      "history_notices" => history_notices,
      "truncated" => execution.truncated or history_notices != []
    }
  end

  defp eval_execution(previous, step) do
    execution =
      TurnFeedback.execution_feedback(
        session_agent(),
        %{memory: previous.memory || %{}},
        step
      )

    execution
  end

  # The collection hint (opt-in via --collection-hint) is more specific than
  # the generic truncation hint, so it replaces it when both would apply.
  # Two triggers: the eval result itself is a large collection of maps
  # (reachable as *1 unless history stored only a preview), or this eval
  # changed a session binding holding one (reachable by name, hinted only on
  # the defining eval so it does not repeat every turn).
  defp append_value_hints(feedback, result_truncated, previous, step, history_notices) do
    value = Map.get(step, :return)

    cond do
      not Config.get().collection_hint ->
        append_truncation_hint(feedback, result_truncated, history_notices)

      collection_of_maps?(value) and not history_entry_capped?(history_notices) ->
        append_collection_hint(feedback, "*1", Enum.count(value))

      binding = changed_collection_binding(previous, step) ->
        # The binding hint describes a different value than the eval result,
        # so a result-truncation hint (about *1) must still be preserved.
        {name, count} = binding

        feedback
        |> append_truncation_hint(result_truncated, history_notices)
        |> append_collection_hint(name, count)

      true ->
        append_truncation_hint(feedback, result_truncated, history_notices)
    end
  end

  defp changed_collection_binding(previous, step) do
    prev = Map.get(previous || %{}, :memory) || %{}

    (Map.get(step, :memory) || %{})
    |> Enum.filter(fn {key, value} ->
      collection_of_maps?(value) and Map.get(prev, key) != value
    end)
    |> Enum.map(fn {key, value} -> {to_string(key), Enum.count(value)} end)
    |> Enum.max_by(fn {_key, count} -> count end, fn -> nil end)
  end

  defp collection_of_maps?(value) when is_list(value) do
    Enum.count(value) >= @collection_hint_min_items and
      value |> Enum.take(3) |> Enum.all?(&(is_map(&1) and not is_struct(&1)))
  end

  defp collection_of_maps?(_value), do: false

  defp append_collection_hint(feedback, name, count) do
    subject = if name == "*1", do: "Result", else: "Binding `#{name}`"

    hint =
      "#{subject} is a collection of #{count} maps. " <>
        "`(describe #{name} {:paths true})` summarizes field coverage across all of them."

    cond do
      String.contains?(feedback, hint) -> feedback
      feedback == "" -> hint
      true -> feedback <> "\n" <> hint
    end
  end

  defp append_truncation_hint(feedback, false, _history_notices), do: feedback

  defp append_truncation_hint(feedback, true, history_notices) do
    if history_entry_capped?(history_notices) do
      feedback
    else
      append_result_describe_hint(feedback)
    end
  end

  defp append_result_describe_hint(feedback) do
    hint = "Result truncated. Try `(describe *1)` or `(describe *1 {:paths true :depth 2})`."

    cond do
      String.contains?(feedback, hint) -> feedback
      feedback == "" -> hint
      true -> feedback <> "\n" <> hint
    end
  end

  defp history_entry_capped?(history_notices) do
    Enum.any?(history_notices, fn notice ->
      Map.get(notice, :reason) == "max_history_entry_bytes" or
        Map.get(notice, "reason") == "max_history_entry_bytes"
    end)
  end

  defp session_agent do
    %{
      max_turns: 2,
      format_options: [
        feedback_max_chars: @session_feedback_max_chars,
        preview_max_chars: Config.get().max_session_preview_chars
      ]
    }
  end

  @doc "Render a Lisp execution failure. Session state was not committed."
  @spec eval_lisp_error(map(), map()) :: map()
  def eval_lisp_error(state, step) do
    fail = step.fail || %{}

    %{
      "status" => "error",
      "reason" => to_string(fail[:reason] || "eval_error"),
      "message" => fail[:message] || "PTC-Lisp eval failed",
      "prints" => step.prints || [],
      "session" => session_summary(state),
      "feedback" => fail[:message] || "PTC-Lisp eval failed"
    }
  end

  @doc "Render a session-specific error response."
  @spec error(atom(), String.t(), map()) :: map()
  def error(reason, message, extra \\ %{}) when is_atom(reason) and is_binary(message) do
    Map.merge(
      %{
        "status" => "error",
        "reason" => Atom.to_string(reason),
        "message" => message,
        "feedback" => message
      },
      stringify_keys(extra)
    )
  end

  @doc "Render an inspect response for a committed state snapshot."
  @spec inspect_view(map(), String.t()) :: map()
  def inspect_view(state, view) do
    base = %{
      "status" => "ok",
      "session_id" => state.id,
      "view" => view,
      "session" => session_summary(state)
    }

    Map.merge(base, view_payload(state, view))
  end

  @doc "Render a metadata-only live session list."
  @spec list([map()]) :: map()
  def list(sessions) when is_list(sessions) do
    %{
      "status" => "ok",
      "count" => length(sessions),
      "sessions" => sessions
    }
  end

  @doc "Render a forget response."
  @spec forget(map(), [String.t()], [String.t()]) :: map()
  def forget(state, removed_bindings, cleared) do
    %{
      "status" => "ok",
      "session_id" => state.id,
      "removed_bindings" => removed_bindings,
      "cleared" => cleared,
      "stored_keys" => Limits.stored_keys(state.memory),
      "usage" => session_usage(state)
    }
  end

  @doc "Render close confirmation."
  @spec close(map(), term()) :: map()
  def close(state, reason) do
    %{
      "status" => "ok",
      "session_id" => state.id,
      "closed" => true,
      "reason" => to_string(reason || "closed")
    }
  end

  defp view_payload(state, "overview") do
    has_prints? = state.prints != []

    sections =
      [
        User.render(state.memory, has_println: has_prints?),
        ExecutionHistory.render_output(state.prints, state.limits.max_print_entries, has_prints?),
        ExecutionHistory.render_tool_calls(
          state.tool_calls ++ state.upstream_calls,
          state.limits.max_tool_call_entries
        ),
        history_text(state.turn_history)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    %{"text" => sections, "usage" => session_usage(state)}
  end

  defp view_payload(state, "memory") do
    %{
      "text" =>
        User.render(state.memory, has_println: state.prints != []) || ";; No stored bindings",
      "stored_keys" => Limits.stored_keys(state.memory),
      "usage" => session_usage(state)
    }
  end

  defp view_payload(state, "prints") do
    %{
      "prints" => state.prints,
      "text" => ExecutionHistory.render_output(state.prints, state.limits.max_print_entries, true)
    }
  end

  defp view_payload(state, "tool_calls") do
    %{
      "tool_calls" => state.tool_calls,
      "upstream_calls" => state.upstream_calls,
      "text" =>
        ExecutionHistory.render_tool_calls(
          state.tool_calls ++ state.upstream_calls,
          state.limits.max_tool_call_entries
        )
    }
  end

  defp view_payload(state, "history") do
    %{
      "history" => history_entries(state.turn_history),
      "text" => history_text(state.turn_history)
    }
  end

  defp view_payload(state, "limits") do
    %{
      "limits" => Limits.project_limits(state.limits),
      "usage" => session_usage(state),
      "top_bindings" => Limits.top_bindings(state.memory, 10)
    }
  end

  defp view_payload(state, _view), do: view_payload(state, "overview")

  @doc "Render metadata-only summary for one committed session state."
  @spec session_summary(map()) :: map()
  def session_summary(state) do
    usage = session_usage(state)

    %{
      "session_id" => state.id,
      "title" => state.title,
      "turn" => state.turn,
      "created_at" => DateTime.to_iso8601(state.created_at),
      "updated_at" => DateTime.to_iso8601(state.updated_at),
      "expires_at" => DateTime.to_iso8601(state.expires_at),
      "eval_status" => if(state.eval, do: "running", else: "idle"),
      "memory_bytes" => usage.memory_bytes,
      "binding_count" => usage.binding_count
    }
  end

  defp session_usage(state) do
    Limits.usage(
      state.memory,
      state.turn_history,
      state.prints,
      state.tool_calls,
      state.upstream_calls
    )
  end

  defp changed_keys(changed) when is_map(changed) do
    changed
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp history_text([]), do: ";; History:\n;   *1 nil\n;   *2 nil\n;   *3 nil"

  defp history_text(history) do
    entries =
      history
      |> Enum.reverse()
      |> Enum.with_index(1)
      |> Enum.map(fn {value, index} ->
        {text, _truncated?} = Format.to_clojure(value, limit: 10, printable_limit: 120)
        ";   *#{index} #{text}"
      end)

    [";; History:" | entries] |> Enum.join("\n")
  end

  defp history_entries(history) do
    history
    |> Enum.reverse()
    |> Enum.with_index(1)
    |> Enum.map(fn {value, index} ->
      {text, truncated?} = Format.to_clojure(value, limit: 10, printable_limit: 120)
      %{"name" => "*#{index}", "preview" => text, "truncated" => truncated?}
    end)
  end

  defp append_history_notices(feedback, []), do: feedback

  defp append_history_notices(feedback, notices) do
    notice_text =
      Enum.map_join(notices, "\n", fn notice -> ";; #{notice.message}" end)

    [feedback, notice_text]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
