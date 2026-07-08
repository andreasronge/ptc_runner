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
           messages [{"role" "user" "content" (mission "task")}]
           actions []]
      (if (>= turn (cfg "max_turns"))
        (fail {"reason" "turn_limit_exceeded" "turns" turn})
        (let [action (tool/llm-complete {"messages" messages "turn" turn})]
          (tool/log {"event" "action" "turn" turn "action" action})
          (let [actions2 (conj actions action)]
            (case (action "kind")
            "tool_call"
              (let [result (tool/eval-program {"program" (action "program")})]
                (tool/log {"event" "eval" "turn" turn "result" result})
                (case (result "status")
                  "return" (return {"value" (result "value")
                                    "trace" {"turns" (inc turn)
                                             "actions" actions2}})
                  "fail" (fail {"reason" "model_program_failed" "eval" result})
                  (recur (inc turn)
                         (conj messages
                               {"role" "assistant" "tool_calls" [(action "public_tool_call")]}
                               {"role" "tool" "tool_call_id" (action "tool_call_id")
                                "content" (eval-feedback result)})
                         actions2)))
            "protocol_error"
              (recur (inc turn)
                     (conj messages
                           {"role" "user" "content" (protocol-feedback action)})
                     actions2)
            "transport_error"
              (fail {"reason" "llm_transport_error" "error" action})
            (fail {"reason" "unknown_action" "action" action})))))))
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
        "max_turns" => Keyword.get(opts, :max_turns, 3)
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
    system_prompt = Keyword.get(opts, :system_prompt, render_system_prompt())

    tools = %{
      "llm-complete" =>
        {fn args ->
           request = %{
             system: system_prompt,
             messages: normalize_messages(Map.get(args, "messages", [])),
             tools: [Action.tool_schema()],
             tool_choice: %{type: "tool", name: "run_ptc_lisp"}
           }

           request
           |> llm.()
           |> normalize_llm_result()
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

  defp normalize_llm_result({:ok, response}) do
    response
    |> Action.normalize()
    |> Map.put(:transport_error, nil)
  end

  defp normalize_llm_result({:error, reason}) do
    %{
      kind: "transport_error",
      program: nil,
      reason: inspect(reason, limit: 10, printable_limit: 500),
      content: nil,
      tokens: %{},
      model: nil,
      provider: nil,
      provider_meta: %{},
      transport_error: true
    }
  end

  defp normalize_llm_result(response) do
    response
    |> Action.normalize()
    |> Map.put(:transport_error, nil)
  end

  defp normalize_messages(messages) when is_list(messages),
    do: Enum.map(messages, &normalize_message/1)

  defp normalize_messages(_), do: []

  defp normalize_message(%{} = message) do
    role = message_value(message, "role")

    %{}
    |> maybe_put(:role, normalize_role(role))
    |> maybe_put(:content, message_value(message, "content"))
    |> maybe_put(:tool_call_id, message_value(message, "tool_call_id"))
    |> maybe_put(:tool_calls, normalize_tool_calls(message_value(message, "tool_calls")))
  end

  defp normalize_message(message), do: message

  defp normalize_role(role) when role in [:system, :user, :assistant, :tool], do: role
  defp normalize_role("system"), do: :system
  defp normalize_role("user"), do: :user
  defp normalize_role("assistant"), do: :assistant
  defp normalize_role("tool"), do: :tool
  defp normalize_role(role), do: role

  defp normalize_tool_calls(nil), do: nil

  defp normalize_tool_calls(calls) when is_list(calls) do
    Enum.map(calls, fn
      %{} = call ->
        call
        |> atomize_known_key(:id, "id")
        |> atomize_known_key(:type, "type")
        |> atomize_function()

      other ->
        other
    end)
  end

  defp normalize_tool_calls(other), do: other

  defp atomize_function(call) do
    case message_value(call, "function") do
      %{} = function ->
        Map.put(call, :function, %{
          name: message_value(function, "name"),
          arguments: message_value(function, "arguments")
        })

      _ ->
        call
    end
  end

  defp atomize_known_key(map, atom_key, string_key) do
    case message_value(map, string_key) do
      nil -> map
      value -> Map.put(map, atom_key, value)
    end
  end

  defp message_value(%{} = map, key) when is_binary(key) do
    Map.get(map, key, Map.get(map, String.to_existing_atom(key)))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
