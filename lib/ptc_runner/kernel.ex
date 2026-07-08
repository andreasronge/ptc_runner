defmodule PtcRunner.Kernel do
  @moduledoc false

  alias PtcRunner.Kernel.Action
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Step.Public

  @outer_timeout 30_000
  @outer_heap_words 8_000_000
  @inner_timeout 1_000
  @inner_heap_words 1_250_000

  @prelude_source """
  (ns agent
    "Minimal native-action kernel spike loop."
    {:visibility :prompt})

  (defn- protocol-feedback [action]
    (str "Protocol error: " (action "reason")
         ". Call `run_ptc_lisp` with exactly one valid `program` string."))

  (defn- eval-feedback [result]
    (str "Program did not return successfully. Result: " result
         ". Call `run_ptc_lisp` again with a corrected program."))

  (defn run-mission
    "Run the minimal native-action loop."
    [mission cfg]
    (loop [turn 0
           messages [{"role" "system" "content" (cfg "system_prompt")}
                     {"role" "user" "content" (mission "task")}]]
      (if (>= turn (cfg "max_turns"))
        (fail {"reason" "turn_limit_exceeded" "turns" turn})
        (let [action (tool/llm-complete {"messages" messages "turn" turn})]
          (tool/log {"event" "action" "turn" turn "action" action})
          (case (action "kind")
            "tool_call"
              (let [result (tool/eval-program {"program" (action "program")})]
                (tool/log {"event" "eval" "turn" turn "result" result})
                (case (result "status")
                  "return" (return {"value" (result "value")
                                    "trace" {"turns" (inc turn)
                                             "actions" (conj (cfg "actions") action)}})
                  "fail" (fail {"reason" "model_program_failed" "eval" result})
                  (recur (inc turn)
                         (conj messages
                               {"role" "assistant" "tool_calls" [(action "public_tool_call")]}
                               {"role" "tool" "tool_call_id" (action "tool_call_id")
                                "content" (eval-feedback result)}))))
            "protocol_error"
              (recur (inc turn)
                     (conj messages
                           {"role" "user" "content" (protocol-feedback action)}))
            (fail {"reason" "unknown_action" "action" action}))))))
  """

  @spec prelude_source() :: String.t()
  def prelude_source, do: @prelude_source

  @spec render_system_prompt() :: String.t()
  def render_system_prompt do
    """
    You are controlling PTC-Lisp through native tool calling.
    You must call run_ptc_lisp exactly once per turn with JSON arguments {"program": "..."}.
    The program must produce the answer via (return value) or report failure via (fail value).
    Do not answer in prose.
    """
  end

  @spec run(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def run(mission, opts) when is_map(mission) and is_list(opts) do
    with {:ok, prelude} <- Compiler.compile(@prelude_source),
         {:ok, tools} <- kernel_tools(mission, opts) do
      cfg = %{
        "system_prompt" => Keyword.get(opts, :system_prompt, render_system_prompt()),
        "max_turns" => Keyword.get(opts, :max_turns, 3),
        "actions" => []
      }

      program = ~S|(agent/run-mission data/mission data/cfg)|

      case Lisp.run(program,
             prelude: prelude,
             tools: tools,
             context: %{mission: mission, cfg: cfg},
             filter_context: false,
             timeout: Keyword.get(opts, :timeout, @outer_timeout),
             max_heap: Keyword.get(opts, :max_heap, @outer_heap_words),
             setup_max_heap: Keyword.get(opts, :setup_max_heap, @outer_heap_words * 2)
           ) do
        {:ok, step} -> unwrap_outer_step(step)
        {:error, step} -> {:error, %{reason: "kernel_error", step: project_public_step(step)}}
      end
    end
  end

  defp kernel_tools(mission, opts) do
    llm = Keyword.fetch!(opts, :llm)
    events = Keyword.get(opts, :events)
    mission_tools = Keyword.get(opts, :tools, %{})

    tools = %{
      "llm-complete" =>
        {fn args ->
           request = %{
             system: render_system_prompt(),
             messages: Map.get(args, "messages", []),
             tools: [Action.tool_schema()],
             tool_choice: %{type: "tool", name: "run_ptc_lisp"}
           }

           llm.(request)
           |> case do
             {:ok, response} -> response
             response -> response
           end
           |> Action.normalize()
           |> add_public_tool_call()
         end, [signature: "(messages :any, turn :int) -> :map", visibility: :private]},
      "eval-program" =>
        {fn args ->
           args
           |> Map.fetch!("program")
           |> eval_program(mission, mission_tools, opts)
         end, [signature: "(program :string) -> :map", visibility: :private]},
      "log" =>
        {fn args ->
           if is_function(events, 1), do: events.(args)
           %{"ok" => true}
         end, [signature: "(event :string) -> :map", visibility: :private]}
    }

    {:ok, tools}
  end

  defp add_public_tool_call(%{kind: "tool_call", program: program} = action) do
    id = "run_ptc_lisp_#{System.unique_integer([:positive])}"

    action
    |> Map.put(:tool_call_id, id)
    |> Map.put(:public_tool_call, %{
      "id" => id,
      "type" => "function",
      "function" => %{
        "name" => "run_ptc_lisp",
        "arguments" => Jason.encode!(%{"program" => program})
      }
    })
  end

  defp add_public_tool_call(action), do: action

  defp eval_program(program, mission, mission_tools, opts) do
    case Lisp.run(program,
           context: Map.get(mission, "context", %{}),
           tools: mission_tools,
           prelude: nil,
           runtime: nil,
           discovery_exec: nil,
           timeout: Keyword.get(opts, :inner_timeout, @inner_timeout),
           max_heap: Keyword.get(opts, :inner_max_heap, @inner_heap_words)
         ) do
      {:ok, step} -> project_step(:ok, step)
      {:error, step} -> project_step(:error, step)
    end
  end

  defp project_step(_tag, step) do
    cond do
      match?({:__ptc_return__, _}, step.return) ->
        {:__ptc_return__, value} = step.return

        %{
          "status" => "return",
          "value" => Public.value(value),
          "prints" => bound_list(step.prints)
        }

      match?({:__ptc_fail__, _}, step.return) ->
        {:__ptc_fail__, value} = step.return
        %{"status" => "fail", "value" => Public.value(value), "prints" => bound_list(step.prints)}

      step.fail ->
        %{
          "status" => "error",
          "reason" => to_string(step.fail.reason),
          "message" => step.fail.message,
          "prints" => bound_list(step.prints)
        }

      true ->
        %{
          "status" => "continue",
          "value" => Public.value(step.return),
          "prints" => bound_list(step.prints)
        }
    end
  end

  defp unwrap_outer_step(step) do
    case step.return do
      {:__ptc_return__, value} -> {:ok, value}
      {:__ptc_fail__, value} -> {:error, value}
      other -> {:ok, other}
    end
  end

  defp project_public_step(step) do
    %{
      fail: step.fail,
      return: Public.value(step.return),
      prints: bound_list(step.prints)
    }
  end

  defp bound_list(list) when is_list(list), do: Enum.take(list, 8)
  defp bound_list(_), do: []
end
