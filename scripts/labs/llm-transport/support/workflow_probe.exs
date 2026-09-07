defmodule PtcRunner.Labs.WorkflowProbe do
  @moduledoc false
  alias PtcRunner.Kernel.{ApplicationPackage, LLMCapability, ProviderRegistry}
  alias PtcRunner.TestSupport.RunLifecycle

  alias PtcRunner.Kernel.{
    InstallationCatalog,
    PreparedRun,
    ProviderDescriptor,
    ProviderRuntimeServices,
    PublicationAuthority,
    RunAdmission,
    RunBuilder,
    RunCoordinator,
    SelectionRules
  }

  def run(adapter, requirements, credential \\ :loopback) do
    builder = builder(adapter, requirements, credential, fn -> :ok end)
    {:ok, registry} = ProviderRegistry.new(%{"deepseek" => ProviderRegistry.staged(builder)})

    "examples/support-triage/01-one-question/ptc.json"
    |> ApplicationPackage.request_directory(installed_limits: registry.installed_limits)
    |> RunLifecycle.build(registry)
    |> RunLifecycle.execute()
  end

  # Deliberately rebuilds one preparation per request. This is a lifecycle
  # experiment, not the compile-once serving facade proposed in #1465.
  def run_admitted(host, adapter, requirements, opts \\ []) do
    builder = builder(adapter, requirements, :loopback, Keyword.get(opts, :close, fn -> :ok end))
    {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

    {:ok, descriptor} =
      ProviderDescriptor.new(
        source: :custom,
        installation_revision: "lab-http-v1",
        credential_names: [],
        authorization_mode: :none,
        data_class: :normal,
        accepts_data: [:normal],
        requires: [],
        provides: [],
        destinations: [:workflow],
        # The lab installs an inline LLM capability, as the baseline does; it
        # does not imitate a shipped host installation or named LLM route.
        workflow_llm?: false,
        connectivity_mode: :none,
        probe_effect: nil,
        selection_validation: :declarative,
        selection_rules: rules,
        authority_fingerprint: nil,
        local_preflight: :none
      )

    {:ok, catalog} =
      InstallationCatalog.new(%{
        "deepseek" => %{
          descriptor: descriptor,
          implementation: %{builder: builder},
          authority: nil
        }
      })

    try do
      {:ok, request} =
        ApplicationPackage.request_directory(
          "examples/support-triage/01-one-question/ptc.json",
          result_projection: :json,
          installed_limits: catalog.installed_limits
        )

      {:ok, prepared} = RunCoordinator.prepare(request, catalog)

      try do
        execute_prepared(host, prepared, catalog)
      after
        PreparedRun.close(prepared)
      end
    after
      InstallationCatalog.close(catalog)
    end
  end

  defp execute_prepared(host, prepared, catalog) do
    {:ok, services} = ProviderRuntimeServices.new(provider_application_mode: :host_owned)

    {:ok, authority} =
      PublicationAuthority.authorize(
        "lab-#{System.unique_integer([:positive])}",
        [],
        prepared.effective_event_policy,
        prepared.effective_data_class
      )

    try do
      with {:ok, outcome} <- RunAdmission.execute(host, prepared, authority, catalog, services),
           {:ok, %{result: {:ok, result}, result_class: :normal}} <-
             RunBuilder.publish_execution_report(outcome, authority),
           :ok <- PublicationAuthority.close(authority) do
        {:ok, result.value}
      else
        {:error, reason} when reason in [:run_capacity_exhausted, :run_admission_unavailable] ->
          {:error, reason}

        _ ->
          {:error, :run_failed}
      end
    after
      PublicationAuthority.abort(authority)
    end
  end

  defp builder(adapter, requirements, credential, close) do
    {:ok, prepared} =
      PtcRunner.LLM.prepare("openrouter:deepseek/deepseek-v4-flash", requirements, adapter)

    credential =
      case credential do
        :loopback -> if adapter == PtcRunner.LLM.ReqLLMAdapter, do: "loopback-only", else: nil
        credential -> credential
      end

    {:ok, callback} = PtcRunner.LLM.callback(prepared, %{credential: credential, cache: false})

    fn _config, _context ->
      {:ok,
       %{
         credential_names: [],
         preflight: fn ->
           {:ok,
            fn %{} ->
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

              {:ok, %{capabilities: [capability], close: close}}
            end}
         end
       }}
    end
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
