defmodule PtcRunner.Labs.WorkflowProbe do
  @moduledoc false
  alias PtcRunner.Kernel.{ApplicationPackage, LLMCapability, ProviderRegistry}
  alias PtcRunner.TestSupport.{RunLifecycle, TestHelpers}

  def run(adapter, requirements, credential \\ :loopback) do
    {:ok, prepared} =
      PtcRunner.LLM.prepare("openrouter:deepseek/deepseek-v4-flash", requirements, adapter)

    credential =
      case credential do
        :loopback -> if adapter == PtcRunner.LLM.ReqLLMAdapter, do: "loopback-only", else: nil
        credential -> credential
      end

    {:ok, callback} = PtcRunner.LLM.callback(prepared, %{credential: credential, cache: false})

    builder =
      TestHelpers.staged_provider(fn _config, _context ->
        {:ok, capability} =
          LLMCapability.new(
            requester: fn request, context ->
              callback.(ProviderRegistry.adapter_request(request), context)
            end,
            usage_guarantees: requirements.usage_guarantees,
            llm_reservation: %{
              source: "llm",
              output_tokens: requirements.exact_options.max_tokens,
              tariff: requirements.reservation.cost_tariff,
              bound: fn request, tariff ->
                PtcRunner.LLM.reservation_bound(prepared, request, tariff)
              end
            }
          )

        {:ok, %{capabilities: [capability]}}
      end)

    {:ok, registry} = ProviderRegistry.new(%{"deepseek" => builder})

    "examples/support-triage/01-one-question/ptc.json"
    |> ApplicationPackage.request_directory(installed_limits: registry.installed_limits)
    |> RunLifecycle.build(registry)
    |> RunLifecycle.execute()
  end

  def response(request) do
    completed = Enum.count(request["messages"], &(&1["role"] == "tool"))

    program =
      if completed == 0 do
        "(count data/tickets)"
      else
        "(return (vec (map (fn [t] (get t \"id\")) (filter (fn [t] (str/includes? (str/lower-case (get t \"subject\")) \"refund\")) data/tickets))))"
      end

    %{
      id: "pilot-fixture",
      model: "deepseek/deepseek-v4-flash",
      choices: [
        %{
          index: 0,
          finish_reason: "tool_calls",
          message: %{
            role: "assistant",
            content: nil,
            tool_calls: [
              %{
                id: "call-#{completed}",
                type: "function",
                function: %{name: "run_ptc_lisp", arguments: Jason.encode!(%{program: program})}
              }
            ]
          }
        }
      ],
      usage: %{
        prompt_tokens: 100,
        completion_tokens: 20,
        total_tokens: 120,
        prompt_tokens_details: %{cached_tokens: 10, cache_write_tokens: 5},
        cost: "0.0000051"
      }
    }
  end
end
