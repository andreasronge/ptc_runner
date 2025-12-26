defmodule PtcDemo.AgenticLoop do
  @moduledoc """
  A reusable agentic loop for PTC-Lisp.
  """

  import ReqLLM.Context

  @timeout 60_000

  def run(model, context, datasets, opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, 5)
    stop_on_success = Keyword.get(opts, :stop_on_success, false)
    memory = Keyword.get(opts, :memory, %{})
    usage = Keyword.get(opts, :usage, empty_usage())
    tools = Keyword.get(opts, :tools, %{})

    IO.puts("   [Loop] Tools available: #{Enum.join(Map.keys(tools), ", ")}")
    loop(model, context, datasets, usage, max_iterations, {nil, nil}, memory, stop_on_success, tools, [])
  end

  defp loop(_model, context, _datasets, usage, 0, _last_exec, _memory, _stop_on_success, _tools, trace) do
    {:error, "Max iterations reached", context, usage, Enum.reverse(trace)}
  end

  defp loop(model, context, datasets, usage, remaining, last_exec, memory, stop_on_success, tools, trace) do
    IO.puts("\n   [Loop] Generating response (#{remaining} iterations left)...")

    case ReqLLM.generate_text(model, context.messages,
           receive_timeout: @timeout,
           max_tokens: 1024,
           req_http_options: [retry: :transient, max_retries: 3]
         ) do
      {:ok, response} ->
        text = ReqLLM.Response.text(response)
        new_usage = add_usage(usage, ReqLLM.Response.usage(response))

        case validate_llm_response(text, response) do
          {:error, error_msg} ->
            new_context = ReqLLM.Context.append(context, user("[System Error]\n#{error_msg}"))
            new_step = %{iteration: remaining, error: error_msg, usage: ReqLLM.Response.usage(response)}
            loop(model, new_context, datasets, new_usage, remaining - 1, last_exec, memory, stop_on_success, tools, [new_step | trace])

          :ok ->
            case extract_ptc_program(text) do
              {:ok, program} ->
                IO.puts("   [Program] #{truncate(program, 100)}")
                # Run the program
                run_tracked_usage = increment_run_count(new_usage)

                # Augmented context with last result
                {_last_program, last_result} = last_exec
                augmented_context = Map.put(datasets, :"last-result", last_result)

                {:ok, recorder} = Agent.start_link(fn -> [] end)
                wrapped_tools = Map.new(tools, fn {name, fun} ->
                  {name, fn args ->
                    res = fun.(args)
                    Agent.update(recorder, &[%{name: name, args: args, result: res} | &1])
                    res
                  end}
                end)

                case PtcRunner.Lisp.run(program,
                       context: augmented_context,
                       memory: memory,
                       tools: wrapped_tools,
                       timeout: 5000,
                       float_precision: 2
                     ) do
                  {:ok, result, _delta, new_memory} ->
                    result_str = format_result(result)
                    IO.puts("   [Result] #{truncate(result_str, 80)}")
                      tool_calls = Agent.get(recorder, &Enum.reverse(&1))
                      Agent.stop(recorder)
                      new_step = %{iteration: remaining, program: program, result: result, tool_calls: tool_calls, usage: ReqLLM.Response.usage(response)}
                      new_trace = [new_step | trace]
                      new_last_exec = {program, result}

                      if stop_on_success do
                        final_context = context
                          |> ReqLLM.Context.append(assistant(text))
                          |> ReqLLM.Context.append(user("[Tool Result]\n#{result_str}"))
                        {:ok, result_str, final_context, run_tracked_usage, program, result, new_memory, Enum.reverse(new_trace)}
                      else
                        new_context = context
                          |> ReqLLM.Context.append(assistant(text))
                          |> ReqLLM.Context.append(user("[Tool Result]\n#{result_str}"))
                        loop(model, new_context, datasets, run_tracked_usage, remaining - 1, new_last_exec, new_memory, stop_on_success, tools, new_trace)
                      end

                  {:error, reason} ->
                    tool_calls = Agent.get(recorder, &Enum.reverse(&1))
                    Agent.stop(recorder)
                    error_msg = PtcRunner.Lisp.format_error(reason)
                    IO.puts("   [Error] #{error_msg}")
                    IO.puts("   [Raw Text] #{text}")
                      new_context = context
                        |> ReqLLM.Context.append(assistant(text))
                        |> ReqLLM.Context.append(user("[Tool Error]\n#{error_msg}"))
                      new_step = %{iteration: remaining, program: program, error: error_msg, tool_calls: tool_calls, usage: ReqLLM.Response.usage(response)}
                      loop(model, new_context, datasets, run_tracked_usage, remaining - 1, last_exec, memory, stop_on_success, tools, [new_step | trace])
                end

              :none ->
                IO.puts("   [Answer] Final response")
                final_context = ReqLLM.Context.append(context, assistant(text))
                {last_program, last_result} = last_exec
                new_step = %{iteration: remaining, answer: text, usage: ReqLLM.Response.usage(response)}
                {:ok, text, final_context, new_usage, last_program, last_result, memory, Enum.reverse([new_step | trace])}
            end
        end

      {:error, reason} ->
        {:error, "LLM error: #{inspect(reason)}", context, usage, Enum.reverse(trace)}
      end
  end

  # --- Helpers (Full versions from LispAgent) ---

  defp validate_llm_response(nil, response) do
    reason = cond do
      (finish_reason = ReqLLM.Response.finish_reason(response)) != nil ->
        "LLM returned no text content (finish_reason: #{finish_reason})"
      (_tool_calls = ReqLLM.Response.tool_calls(response)) != [] ->
        "LLM returned tool calls instead of text"
      true ->
        "LLM returned nil/empty text"
    end
    {:error, reason}
  end

  defp validate_llm_response("", _), do: {:error, "LLM returned empty text"}
  defp validate_llm_response(_, _), do: :ok

  defp extract_ptc_program(text) do
    case Regex.run(~r/```(?:lisp|clojure)?\s*([\s\S]+?)\s*```/, text) do
      [_, content] -> {:ok, String.trim(content)}
      nil ->
        case Regex.run(~r/\([\w-]+\s[\s\S]+?\)(?=\s*$|\s*\n\n)/m, text) do
          [match] -> {:ok, String.trim(match)}
          nil -> :none
        end
    end
  end

  @max_result_chars 300
  defp format_result(result) do
    full = inspect(result, limit: :infinity, pretty: false)
    if String.length(full) > @max_result_chars do
      String.slice(full, 0, @max_result_chars) <> "... (TRUNCATED)"
    else
      full
    end
  end

  defp truncate(str, max), do: (if String.length(str) > max, do: String.slice(str, 0, max) <> "...", else: str)

  defp empty_usage, do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, total_runs: 0, total_cost: 0.0, requests: 0}

  defp add_usage(acc, usage) when is_map(usage) do
    %{acc |
      input_tokens: acc.input_tokens + (usage[:input_tokens] || 0),
      output_tokens: acc.output_tokens + (usage[:output_tokens] || 0),
      total_tokens: acc.total_tokens + (usage[:total_tokens] || 0),
      requests: acc.requests + 1
    }
  end
  defp add_usage(acc, _), do: acc

  defp increment_run_count(usage), do: %{usage | total_runs: usage.total_runs + 1}
end
