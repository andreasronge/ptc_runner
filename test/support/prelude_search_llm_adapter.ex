defmodule PtcRunner.TestSupport.PreludeSearchLLMAdapter do
  @moduledoc false
  alias PtcRunner.LLM.Requirements

  def prepare_model(model, requirements) do
    {:ok, canonical} = Requirements.canonical(requirements)
    {:ok, %{selector: model}, :unavailable, canonical}
  end

  def reservation_bound(_target, _request, tariff),
    do: %{total_tokens: 32_000, cost: %{currency: "USD", microunits: 1_000, tariff_id: tariff.id}}

  def public_model(model), do: {:ok, model}
  def provider_application(_model), do: nil
  def ensure_ready, do: :ok

  def call(_target, _invocation) do
    counter = Application.fetch_env!(:ptc_runner, :prelude_search_test_counter)
    index = Agent.get_and_update(counter, &{&1, &1 + 1})

    if index == 0 do
      {:ok,
       %{
         content: "",
         finish_reason: "tool_calls",
         tool_calls: [
           %{
             id: "repair",
             name: "run_ptc_lisp",
             args: %{
               "program" =>
                 ~S|(return {"candidate_source" "" "diagnosis" {"function" "unknown" "form" "unknown" "cited_executions" []}})|
             }
           }
         ],
         tokens: %{input: 10, output: 10, total_cost: %{currency: "USD", microunits: 1}}
       }}
    else
      receive do
        :unblock -> {:error, :unexpected_unblock}
      end
    end
  end
end
