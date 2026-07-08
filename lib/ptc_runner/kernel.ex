defmodule PtcRunner.Kernel do
  @moduledoc false

  alias PtcRunner.Kernel.Action
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.ExecutionError
  alias PtcRunner.Lisp.Format
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Bundle
  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Lisp.RetainedSize
  alias PtcRunner.Step
  alias PtcRunner.Step.Public

  @outer_timeout 30_000
  @outer_heap_words 8_000_000
  @inner_timeout 1_000
  @inner_heap_words 1_250_000
  @memory_byte_cap 2_000_000
  @summary_name_limit 24
  @summary_entry_limit 8
  @summary_preview_chars 160

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

  @spec run(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def run(mission, opts) when is_map(mission) and is_list(opts) do
    with {:ok, memory_cap} <- memory_byte_cap(opts),
         opts = Keyword.put(opts, :kernel_memory_byte_cap, memory_cap),
         {:ok, prelude} <- compile_prelude(opts),
         :ok <- log_prelude(opts, prelude),
         {:ok, memory} <- Agent.start_link(fn -> %{memory: %{}, busy?: false} end),
         {:ok, tools} <- kernel_tools(mission, opts, memory) do
      cfg = %{
        "max_turns" => Keyword.get(opts, :max_turns, 3),
        "tool_names" => opts |> Keyword.get(:tools, %{}) |> Map.keys() |> Enum.sort()
      }

      program = ~S|(agent.core/run-mission data/mission data/cfg)|

      try do
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
      after
        stop_agent(memory)
      end
    end
  end

  defp kernel_tools(mission, opts, memory) do
    llm = Keyword.fetch!(opts, :llm)
    events = Keyword.get(opts, :events)
    mission_tools = Keyword.get(opts, :tools, %{})
    system_prompt = Keyword.get(opts, :system_prompt)

    tools = %{
      "llm-complete" =>
        {fn args ->
           system = resolve_system_prompt(args, system_prompt)

           request = %{
             system: system,
             messages: normalize_messages(Map.get(args, "messages", [])),
             tools: [Action.tool_schema()],
             tool_choice: %{type: "tool", name: "run_ptc_lisp"}
           }

           request
           |> llm.()
           |> normalize_llm_result()
           |> add_public_tool_call()
         end,
         [signature: "(system :string?, messages :any, turn :int) -> :map", visibility: :private]},
      "eval-program" =>
        {fn args ->
           args
           |> Map.fetch!("program")
           |> eval_program(mission, mission_tools, opts, memory, events)
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

  defp log_prelude(opts, prelude) do
    events = Keyword.get(opts, :events)

    if is_function(events, 1) do
      events.(%{
        "event" => "prelude",
        "prelude" => Prelude.trace_summary(prelude)
      })
    end

    :ok
  end

  defp resolve_system_prompt(args, override) do
    system = override || Map.get(args, "system")

    if is_binary(system) and String.trim(system) != "" do
      system
    else
      raise ExecutionError,
        reason: :missing_system_prompt,
        message: ~s|agent.core must pass a non-empty "system" field to llm-complete|,
        data: %{tool: "llm-complete"}
    end
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
    case component_override(namespace, overrides) do
      %{source: source} when is_binary(source) -> source
      %{"source" => source} when is_binary(source) -> source
      {source, _origin} when is_binary(source) -> source
      source when is_binary(source) -> source
      nil -> Map.fetch!(@prelude_sources, namespace)
    end
  end

  defp component_origin(namespace, overrides) do
    case component_override(namespace, overrides) do
      %{origin: origin} -> origin
      %{"origin" => origin} -> origin
      {_source, origin} -> origin
      nil -> {:file, Map.fetch!(@prelude_origin_paths, namespace)}
      _source -> :memory
    end
  end

  defp component_override(namespace, overrides) do
    Map.get(overrides, namespace, Map.get(overrides, String.to_atom(namespace)))
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

  defp memory_byte_cap(opts) do
    case Keyword.get(opts, :kernel_memory_byte_cap, @memory_byte_cap) do
      cap when is_integer(cap) and cap > 0 ->
        {:ok, cap}

      cap ->
        {:error,
         %{
           reason: "invalid_kernel_memory_byte_cap",
           message: "kernel_memory_byte_cap must be a positive integer",
           value: inspect(cap, limit: 5, printable_limit: 100)
         }}
    end
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

  defp eval_program(program, mission, mission_tools, opts, memory_agent, events) do
    result =
      case checkout_memory(memory_agent) do
        {:ok, prior_memory} ->
          try do
            {result, next_memory} =
              run_inner_program(program, mission, mission_tools, opts, prior_memory)

            checkin_memory(memory_agent, next_memory)
            result
          rescue
            e ->
              release_memory(memory_agent)
              reraise e, __STACKTRACE__
          catch
            kind, reason ->
              release_memory(memory_agent)
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        {:busy, prior_memory} ->
          concurrent_eval_error(prior_memory)
      end

    log_memory_size(events, result)
    result
  end

  defp run_inner_program(program, mission, mission_tools, opts, prior_memory) do
    case Lisp.run_native(program,
           context: Map.get(mission, "context", %{}),
           tools: mission_tools,
           prelude: nil,
           runtime: nil,
           discovery_exec: nil,
           memory: prior_memory,
           preserve_runtime_callables: true,
           timeout: Keyword.get(opts, :inner_timeout, @inner_timeout),
           max_heap: Keyword.get(opts, :inner_max_heap, @inner_heap_words),
           max_tool_calls:
             Keyword.get(opts, :inner_max_tool_calls, Keyword.get(opts, :max_tool_calls))
         ) do
      {:ok, step} -> commit_and_project_step(:ok, step, prior_memory, opts)
      {:error, step} -> commit_and_project_step(:error, step, prior_memory, opts)
    end
  end

  defp checkout_memory(memory_agent) do
    Agent.get_and_update(memory_agent, fn
      %{memory: memory, busy?: false} = state ->
        {{:ok, memory}, %{state | busy?: true}}

      %{memory: memory} = state ->
        {{:busy, memory}, state}
    end)
  end

  defp checkin_memory(memory_agent, memory) do
    Agent.update(memory_agent, fn state -> %{state | memory: memory, busy?: false} end)
  end

  defp release_memory(memory_agent) do
    Agent.update(memory_agent, fn state -> %{state | busy?: false} end)
  end

  defp concurrent_eval_error(prior_memory) do
    error_step =
      Step.error(
        :concurrent_eval_program,
        "eval-program cannot be called concurrently; run PTC-Lisp programs sequentially.",
        prior_memory,
        %{}
      )

    project_step(:error, error_step, prior_memory, prior_memory, retained_size(prior_memory))
  end

  defp commit_and_project_step(tag, step, prior_memory, opts) do
    candidate_memory = step.memory || prior_memory
    cap = Keyword.get(opts, :kernel_memory_byte_cap, @memory_byte_cap)
    candidate_bytes = RetainedSize.bytes_with_cap(candidate_memory, cap)

    case candidate_bytes do
      bytes when is_integer(bytes) and bytes <= cap ->
        {project_step(tag, step, prior_memory, candidate_memory, bytes), candidate_memory}

      bytes ->
        error_step =
          Step.error(
            :memory_limit_exceeded,
            "Kernel PTC-Lisp memory exceeded #{cap} bytes; previous memory was preserved.",
            prior_memory,
            %{limit_bytes: cap, candidate_bytes: candidate_bytes_detail(bytes)}
          )

        {project_step(
           :error,
           error_step,
           prior_memory,
           prior_memory,
           retained_size(prior_memory)
         ), prior_memory}
    end
  end

  defp project_step(_tag, step, prior_memory, current_memory, memory_bytes) do
    memory_summary = memory_summary(prior_memory, current_memory, memory_bytes)

    cond do
      match?({:__ptc_return__, _}, step.return) ->
        {:__ptc_return__, value} = step.return

        %{
          "status" => "return",
          "value" => public_eval_value(value),
          "prints" => bound_list(step.prints),
          "memory_summary" => memory_summary
        }

      match?({:__ptc_fail__, _}, step.return) ->
        {:__ptc_fail__, value} = step.return

        %{
          "status" => "fail",
          "value" => public_eval_value(value),
          "prints" => bound_list(step.prints),
          "memory_summary" => memory_summary
        }

      step.fail ->
        %{
          "status" => "error",
          "reason" => to_string(step.fail.reason),
          "message" => step.fail.message,
          "details" => public_eval_value(Map.get(step.fail, :details, %{})),
          "prints" => bound_list(step.prints),
          "memory_summary" => memory_summary
        }

      true ->
        %{
          "status" => "continue",
          "value" => public_eval_value(step.return),
          "prints" => bound_list(step.prints),
          "memory_summary" => memory_summary
        }
    end
  end

  defp memory_summary(prior_memory, current_memory, memory_bytes) do
    defined_names = current_memory |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

    changed_names =
      current_memory
      |> Enum.filter(fn {name, value} ->
        Map.get(prior_memory, name, :__ptc_missing__) != value
      end)
      |> Enum.map(fn {name, _value} -> to_string(name) end)
      |> Enum.sort()

    {defined, defined_truncated?} = take_bounded(defined_names, @summary_name_limit)
    {changed, changed_truncated?} = take_bounded(changed_names, @summary_name_limit)
    {entry_names, entries_truncated?} = take_bounded(changed_names, @summary_entry_limit)

    {entries, child_truncated?} =
      Enum.map_reduce(entry_names, false, fn name, truncated? ->
        {entry, entry_truncated?} = memory_entry(name, current_memory)
        {entry, truncated? or entry_truncated?}
      end)

    omitted_count =
      max(length(defined_names) - length(defined), 0) +
        max(length(changed_names) - length(entry_names), 0)

    %{
      "defined" => defined,
      "defined_count" => length(defined_names),
      "changed" => changed,
      "changed_count" => length(changed_names),
      "entries" => entries,
      "truncated" =>
        defined_truncated? or changed_truncated? or entries_truncated? or child_truncated?,
      "omitted_count" => omitted_count,
      "memory_bytes" => memory_bytes
    }
  end

  defp memory_entry(name, memory) do
    {_raw_name, value} =
      Enum.find(memory, fn {raw_name, _value} -> to_string(raw_name) == name end)

    {preview, truncated?} =
      Format.to_clojure(value, limit: 4, printable_limit: @summary_preview_chars)

    {%{
       "name" => name,
       "kind" => memory_kind(value),
       "preview" => preview,
       "truncated" => truncated?
     }, truncated?}
  end

  defp memory_kind({:closure, _params, _body, _env, _history, _metadata}), do: "function"
  defp memory_kind({:juxt_fn, fns}) when is_list(fns), do: "function"
  defp memory_kind({:partial_fn, _f, fixed}) when is_list(fixed), do: "function"
  defp memory_kind({tag, _}) when tag in [:complement_fn, :constantly_fn], do: "function"

  defp memory_kind({tag, fns}) when tag in [:comp_fn, :every_pred_fn, :some_fn] and is_list(fns),
    do: "function"

  defp memory_kind({:fnil_fn, _f, _default}), do: "function"
  defp memory_kind(%PtcRunner.Lisp.RuntimeCallable{}), do: "function"
  defp memory_kind(f) when is_function(f), do: "function"
  defp memory_kind(_), do: "value"

  defp public_eval_value(value) do
    value
    |> Public.value()
    |> Jason.encode!()
    |> Jason.decode!()
  rescue
    _ ->
      value
      |> Format.to_clojure(limit: 4, printable_limit: @summary_preview_chars)
      |> elem(0)
  end

  defp take_bounded(list, limit) do
    bounded = Enum.take(list, limit)
    {bounded, length(list) > length(bounded)}
  end

  defp retained_size(value) do
    case RetainedSize.bytes(value) do
      bytes when is_integer(bytes) -> bytes
      :oversized -> 0
    end
  end

  defp candidate_bytes_detail(:oversized), do: "oversized"
  defp candidate_bytes_detail(bytes), do: bytes

  defp log_memory_size(events, %{"memory_summary" => summary}) when is_function(events, 1) do
    events.(%{
      "event" => "memory",
      "memory_bytes" => Map.get(summary, "memory_bytes"),
      "defined_count" => Map.get(summary, "defined_count"),
      "changed_count" => Map.get(summary, "changed_count")
    })
  end

  defp log_memory_size(_events, _result), do: :ok

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

  defp stop_agent(pid) do
    if Process.alive?(pid), do: Agent.stop(pid)
  end
end
