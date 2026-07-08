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
end
