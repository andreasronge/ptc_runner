defmodule PtcRunner.Kernel.E2ETest do
  use ExUnit.Case, async: false

  @moduletag :e2e

  alias PtcRunner.Kernel
  alias PtcRunner.LLM
  alias PtcRunner.TestSupport.LLMSupport

  setup_all do
    LLMSupport.load_dotenv()
    model = System.get_env("PTC_TEST_MODEL") || "deepseek"
    resolved = LLMSupport.resolve_model(model)
    LLMSupport.ensure_api_key!(resolved)
    IO.puts("kernel e2e model=#{resolved}")
    {:ok, model: resolved}
  end

  test "deepseek/openrouter can call run_ptc_lisp once", %{model: model} do
    llm =
      LLM.callback(model,
        receive_timeout: LLMSupport.timeout(),
        req_http_options: LLMSupport.req_opts(),
        max_tokens: 512,
        temperature: 0.0
      )

    assert {:ok, %{"value" => 42}} =
             Kernel.run(%{"task" => "Return the integer result of 40 + 2."},
               llm: llm,
               max_turns: 2
             )
  end

  test "deepseek/openrouter accepts kernel-built retry messages", %{model: model} do
    real_llm =
      LLM.callback(model,
        receive_timeout: LLMSupport.timeout(),
        req_http_options: LLMSupport.req_opts(),
        max_tokens: 512,
        temperature: 0.0
      )

    {:ok, counter} = Agent.start(fn -> 0 end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

    llm = fn request ->
      turn = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

      with {:ok, response} <- real_llm.(request) do
        if turn == 0 do
          {:ok, rewrite_first_program(response, "(+ 1 2)")}
        else
          {:ok, response}
        end
      end
    end

    assert {:ok, %{"trace" => %{"turns" => 2}}} =
             Kernel.run(%{"task" => "Return the integer result of 40 + 2."},
               llm: llm,
               max_turns: 3
             )

    assert Agent.get(counter, & &1) == 2
  end

  defp rewrite_first_program(
         %{tool_calls: [%{args: %{"program" => _}} = call | rest]} = response,
         program
       ) do
    %{response | tool_calls: [%{call | args: %{"program" => program}} | rest]}
  end

  defp rewrite_first_program(response, _program), do: response
end
