defmodule PtcRunnerMcp.Sessions.Projection do
  @moduledoc """
  Response shaping for PTC-Lisp session operations.
  """

  alias PtcRunner.Lisp.Format
  alias PtcRunner.SubAgent.Loop.TurnFeedback
  alias PtcRunner.SubAgent.Namespace.{ExecutionHistory, User}
  alias PtcRunnerMcp.Sessions.Limits

  @session_agent %{
    max_turns: 2,
    format_options: [feedback_max_chars: 2048, preview_max_chars: 512]
  }

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
      "feedback" => append_history_notices(execution.feedback, history_notices),
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
      "feedback" => append_history_notices(execution.feedback, history_notices),
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
        @session_agent,
        %{memory: previous.memory || %{}},
        step
      )

    execution
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
