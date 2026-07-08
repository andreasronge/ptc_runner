defmodule PtcRunner.Kernel do
  @moduledoc false

  alias PtcRunner.Kernel.Action
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Bundle
  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Step.Public

  @outer_timeout 30_000
  @outer_heap_words 8_000_000
  @inner_timeout 1_000
  @inner_heap_words 1_250_000

  @prelude_dir Path.expand("../../priv/preludes/agent", __DIR__)
  @prelude_paths %{
    "agent.prompt" => Path.join(@prelude_dir, "prompt.lisp"),
    "agent.feedback" => Path.join(@prelude_dir, "feedback.lisp"),
    "agent.core" => Path.join(@prelude_dir, "core.lisp")
  }
  @prelude_origin_paths %{
    "agent.prompt" => "priv/preludes/agent/prompt.lisp",
    "agent.feedback" => "priv/preludes/agent/feedback.lisp",
    "agent.core" => "priv/preludes/agent/core.lisp"
  }
  @external_resource @prelude_paths["agent.prompt"]
  @external_resource @prelude_paths["agent.feedback"]
  @external_resource @prelude_paths["agent.core"]
  @prelude_sources %{
    "agent.prompt" => File.read!(@prelude_paths["agent.prompt"]),
    "agent.feedback" => File.read!(@prelude_paths["agent.feedback"]),
    "agent.core" => File.read!(@prelude_paths["agent.core"])
  }
  @namespace_deps %{
    "agent.core" => ["agent.prompt", "agent.feedback"]
  }

  @spec prelude_source() :: String.t()
  def prelude_source do
    @prelude_sources
    |> Enum.sort_by(fn {namespace, _source} -> namespace end)
    |> Enum.map_join("\n", fn {_namespace, source} -> source end)
  end

  @spec compile_prelude(keyword()) :: {:ok, Prelude.t()} | {:error, term()}
  def compile_prelude(opts \\ []) when is_list(opts) do
    overrides = Keyword.get(opts, :prelude_source_overrides, %{})

    with {:ok, prompt} <- compile_component("agent.prompt", overrides),
         {:ok, feedback} <- compile_component("agent.feedback", overrides),
         {:ok, core} <-
           compile_component("agent.core", overrides,
             deps: [prompt, feedback],
             namespace_deps: @namespace_deps
           ) do
      Bundle.compile_precompiled(
        [
          component("agent.prompt", prompt, overrides),
          component("agent.feedback", feedback, overrides),
          component("agent.core", core, overrides)
        ],
        namespace_deps: @namespace_deps
      )
    end
  end

  @spec render_system_prompt() :: String.t()
  def render_system_prompt do
    "You are controlling PTC-Lisp through native tool calling.\n" <>
      "PTC-Lisp uses Clojure-like prefix syntax.\n" <>
      ~s|Call run_ptc_lisp exactly once per turn with JSON arguments {"program": "..."}.\n| <>
      "Successful programs end with (return value); explicit failures use (fail value).\n" <>
      "Read context key x as data/x and call granted tools as (tool/name args) inside the program.\n" <>
      "Do not answer in prose."
  end

  @spec run(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def run(mission, opts) when is_map(mission) and is_list(opts) do
    with {:ok, prelude} <- compile_prelude(opts),
         {:ok, tools} <- kernel_tools(mission, opts) do
      cfg = %{
        "max_turns" => Keyword.get(opts, :max_turns, 3),
        "tool_names" => opts |> Keyword.get(:tools, %{}) |> Map.keys() |> Enum.sort()
      }

      program = ~S|(agent.core/run-mission data/mission data/cfg)|

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
    system_prompt = Keyword.get(opts, :system_prompt)

    tools = %{
      "llm-complete" =>
        {fn args ->
           request = %{
             system: system_prompt || Map.get(args, "system") || render_system_prompt(),
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

  defp compile_component(namespace, overrides, opts \\ []) do
    namespace
    |> component_source(overrides)
    |> Compiler.compile(opts)
  end

  defp component(namespace, %Prelude{} = prelude, overrides) do
    %{
      id: namespace,
      source: component_source(namespace, overrides),
      prelude: prelude,
      origin: component_origin(namespace, overrides)
    }
  end

  defp component_source(namespace, overrides) do
    case Map.get(overrides, namespace, Map.get(overrides, String.to_atom(namespace))) do
      source when is_binary(source) -> source
      nil -> Map.fetch!(@prelude_sources, namespace)
    end
  end

  defp component_origin(namespace, overrides) do
    if Map.has_key?(overrides, namespace) or Map.has_key?(overrides, String.to_atom(namespace)) do
      :memory
    else
      {:file, Map.fetch!(@prelude_origin_paths, namespace)}
    end
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
    tool_calls = normalize_tool_calls(message_value(message, "tool_calls"))

    %{}
    |> maybe_put(:role, normalize_role(role))
    |> maybe_put_content(message_value(message, "content"), tool_calls)
    |> maybe_put(:tool_call_id, message_value(message, "tool_call_id"))
    |> maybe_put(:tool_calls, tool_calls)
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
        %{
          id: message_value(call, "id"),
          type: message_value(call, "type") || "function",
          function: normalize_tool_call_function(message_value(call, "function"))
        }

      other ->
        other
    end)
  end

  defp normalize_tool_calls(other), do: other

  defp normalize_tool_call_function(%{} = function) do
    %{
      name: message_value(function, "name"),
      arguments: message_value(function, "arguments")
    }
  end

  defp normalize_tool_call_function(function), do: function

  defp message_value(%{} = map, key) when is_binary(key) do
    Map.get(map, key, Map.get(map, String.to_existing_atom(key)))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_content(map, nil, tool_calls) when is_list(tool_calls),
    do: Map.put(map, :content, nil)

  defp maybe_put_content(map, content, _tool_calls), do: maybe_put(map, :content, content)

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
