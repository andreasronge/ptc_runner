defmodule PtcRunner.TestSupport.PtcToolCallTestHelpers do
  @moduledoc """
  Shared helpers for `ptc_transport: :tool_call` tests.

  Provides a scripted LLM stub plus builders for the canned `tool_calls` /
  `content` response maps the SubAgent loop expects, and a couple of
  assertion helpers for inspecting the resulting message history.

  `import` this module in a test:

      use ExUnit.Case, async: true
      import PtcRunner.TestSupport.PtcToolCallTestHelpers
  """

  @doc """
  Build an LLM callback that returns one of `responses` on each successive
  call (the last response repeats once exhausted).

  An entry of the form `{:error, reason}` is returned as `{:error, reason}`;
  anything else is wrapped as `{:ok, response}`.

  Options:

    * `:send_to` — a pid; each call sends `{:llm_request, index, input}` to it
      so tests can assert on what the loop passed to the LLM.
  """
  def scripted_llm(responses, opts \\ []) do
    counter = :counters.new(1, [:atomics])
    pid = Keyword.get(opts, :send_to)

    fn input ->
      :counters.add(counter, 1, 1)
      idx = :counters.get(counter, 1)

      if pid, do: send(pid, {:llm_request, idx, input})

      response = Enum.at(responses, idx - 1) || List.last(responses)

      case response do
        {:error, reason} -> {:error, reason}
        resp -> {:ok, resp}
      end
    end
  end

  @doc """
  Build a canned LLM response that calls the `lisp_eval` tool with
  `program`.

  Options:

    * `:id` — the tool-call id (default `"call_1"`)
    * `:content` — assistant text accompanying the tool call (default `nil`)
  """
  def tool_call_response(program, opts \\ []) do
    id = Keyword.get(opts, :id, "call_1")
    content = Keyword.get(opts, :content)

    %{
      content: content,
      tool_calls: [
        %{id: id, name: "lisp_eval", args: %{"program" => program}}
      ],
      tokens: %{input: 0, output: 0}
    }
  end

  @doc "Build a canned LLM response that is plain assistant text (no tool call)."
  def content_response(content) do
    %{content: content, tokens: %{input: 0, output: 0}}
  end

  @doc "True if `messages` contains a `:tool` message paired to `id`."
  def paired_tool_call_id?(messages, id) when is_list(messages) do
    Enum.any?(messages, fn
      %{role: :tool, tool_call_id: ^id} -> true
      _ -> false
    end)
  end

  def paired_tool_call_id?(_messages, _id), do: false

  @doc "The `:tool` message in `messages` paired to `id`, or `nil`."
  def find_tool_message(messages, id) when is_list(messages) do
    Enum.find(messages, fn
      %{role: :tool, tool_call_id: ^id} -> true
      _ -> false
    end)
  end

  @doc "Decode `message.content` as JSON and fetch `field`."
  def json_field(%{content: content}, field) do
    content |> Jason.decode!() |> Map.get(field)
  end
end
