defmodule PtcDemo.SubAgent do
  @moduledoc """
  SubAgent coordinator for the spike.
  """

  alias PtcDemo.AgenticLoop
  alias PtcDemo.RefExtractor

  @doc """
  Delegates a task to a sub-agent.

  Options:
  - `:tools` - Map of tool names to functions
  - `:context` - Map of values for the sub-agent
  - `:refs` - Map of ref specifications for extraction
  - `:model` - LLM model name
  """
  import ReqLLM.Context

  def delegate(task, opts \\ []) do
    model_name = opts[:model] || System.get_env("PTC_DEMO_MODEL") || PtcDemo.ModelRegistry.default_model()
    model = PtcDemo.ModelRegistry.resolve!(model_name)
    tools = opts[:tools] || %{}
    context_data = opts[:context] || %{}
    refs_spec = opts[:refs] || %{}

    # Build system prompt for sub-agent
    _system_prompt = build_system_prompt(tools)

    # Build messages using helpers
    context = ReqLLM.Context.new([
      system(build_system_prompt(tools)),
      user(task)
    ])

    case AgenticLoop.run(model, context, context_data, tools: tools) do
      {:ok, answer, _context, usage, _last_prog, last_result, _memory, trace} ->
        # Extract refs
        refs = RefExtractor.extract(last_result, refs_spec)
        IO.puts("   [SubAgent] Extracted refs: #{inspect(refs)}")

        {:ok, %{
          result: last_result,
          summary: answer,
          refs: refs,
          usage: usage,
          trace: trace
        }}

      {:error, reason, _context, usage, trace} ->
        {:error, %{reason: reason, usage: usage, trace: trace}}
    end
  end

  defp build_system_prompt(tools) do
    tool_descriptions = Enum.map_join(tools, "\n", fn {name, _} -> "- #{name}" end)

    """
    You are a specialized SubAgent. Your goal is to solve the assigned task efficiently.
    Query data by outputting a PTC-Lisp program in a ```clojure code block.
    Format: (call "tool-name" {:arg1 "val1"})

    When you have the final answer, provide a concise summary WITHOUT a code block.

    Available tools:
    #{tool_descriptions}

    Example:
    ```clojure
    (call "list_emails" {})
    ```
    """
  end

  @doc """
  Wraps the sub-agent as a tool for a main agent.
  """
  def as_tool(opts) do
    model = opts[:model]
    tools = opts[:tools] || %{}
    refs = opts[:refs] || %{}

    # Return a function that matches the PTC-Lisp tool signature: (args_map) -> term
    fn args ->
      task = args[:task] || args["task"]
      case delegate(task, model: model, tools: tools, refs: refs) do
        {:ok, result} ->
          # Return the summary, refs, and the raw result back to the main agent
          %{summary: result.summary, refs: result.refs, result: result.result, trace: result.trace}
        {:error, fault} ->
          {:error, fault}
      end
    end
  end
end
