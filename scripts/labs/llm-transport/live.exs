# Explicit live probe: one 512-token text request per adapter, optionally the
# checked-in three-turn workflow at its original 4096-token cap. No retries or
# response content are printed. The first argument is an exact env file.
Code.require_file("support/http_adapter.exs", __DIR__)
Code.require_file("../../../test/support/test_helpers.ex", __DIR__)
Code.require_file("../../../test/support/run_lifecycle.ex", __DIR__)
Code.require_file("support/workflow_probe.exs", __DIR__)

case System.argv() do
  [] -> :ok
  [env_file] -> :ok = PtcRunner.Dotenv.load_file(env_file)
  _ -> raise "usage: mix run scripts/labs/llm-transport/live.exs [ENV_FILE]"
end

Logger.configure(level: :critical)

:telemetry.attach(
  "pilot-errors",
  [:ptc_runner, :pilot_http, :failure],
  fn _event, _measurements, facts, _config ->
    IO.puts(Jason.encode!(%{transport_error: facts}))
  end,
  nil
)

Application.put_env(:req_llm, :load_dotenv, false)
Application.put_env(:llm_db, :load_dotenv, false)
{:ok, _} = Application.ensure_all_started(:req_llm)

{:ok, runtime} =
  PtcRunner.Labs.HttpAdapter.start_runtime(max_concurrency: 2, groups: %{"openrouter" => 2})

credential = System.fetch_env!("OPENROUTER_API_KEY")
model = "openrouter:deepseek/deepseek-v4-flash"

adapters =
  case System.get_env("PTC_PILOT_ADAPTER") do
    "http" -> [PtcRunner.Labs.HttpAdapter]
    _ -> [PtcRunner.LLM.ReqLLMAdapter, PtcRunner.Labs.HttpAdapter]
  end

requirements = %{
  PtcRunner.LLM.Requirements.interim(%{max_tokens: 512})
  | usage_guarantees: %{tokens: true, cost_currency: "USD"},
    reservation: %{
      total_tokens?: true,
      cost_tariff: %{currency: "USD", id: "pilot-llmdb-2026.8.4"}
    }
}

try do
  text_outcomes =
    for adapter <- adapters do
      {:ok, prepared} = PtcRunner.LLM.prepare(model, requirements, adapter)
      {:ok, callback} = PtcRunner.LLM.callback(prepared, %{credential: credential, cache: false})
      start = System.monotonic_time(:millisecond)

      result =
        callback.(
          %{messages: [%{role: :user, content: "Reply with the word OK."}]},
          %{llm_request_deadline_ms: start + 30_000}
        )

      summary =
        case result do
          {:ok, response} ->
            %{
              outcome: "ok",
              usage: response.tokens,
              content_present: is_binary(response[:content]) and response.content != "",
              finish_reason: response[:finish_reason]
            }

          {:error, error} ->
            %{outcome: "error", kind: error.kind, retryable: error.retryable?}
        end

      IO.puts(
        Jason.encode!(
          Map.merge(summary, %{
            adapter: inspect(adapter),
            model: model,
            duration_ms: System.monotonic_time(:millisecond) - start
          })
        )
      )

      summary.outcome == "ok"
    end

  workflow_outcomes =
    if System.get_env("PTC_PILOT_WORKFLOW") == "1" do
      # The checked-in workflow limits its agent to three turns. Retain its
      # original 4096-token cap: lowering it would change the workload.
      requirements = %{requirements | exact_options: %{max_tokens: 4096}}

      for adapter <- adapters do
        start = System.monotonic_time(:millisecond)

        summary =
          case PtcRunner.Labs.WorkflowProbe.run(adapter, requirements, credential) do
            {:ok, result} ->
              %{
                outcome: "ok",
                correct_result: result.value == %{"ok" => true, "value" => ["T-1001", "T-1004"]},
                usage: Map.take(result.usage, [:llm_budget, :llm_usage])
              }

            {:error, %PtcRunner.Kernel.Error{kind: kind, reason: reason}} ->
              %{outcome: "error", kind: kind, reason: reason}

            {:error, _} ->
              %{outcome: "error", kind: :unclassified_workflow_error}
          end

        IO.puts(
          Jason.encode!(
            Map.merge(summary, %{
              adapter: inspect(adapter),
              workflow: "support-triage/01-one-question",
              duration_ms: System.monotonic_time(:millisecond) - start
            })
          )
        )

        summary.outcome == "ok" and summary.correct_result
      end
    else
      []
    end

  unless Enum.all?(text_outcomes ++ workflow_outcomes),
    do: raise("live pilot failed; see closed outcomes above")
after
  Supervisor.stop(runtime)
end
