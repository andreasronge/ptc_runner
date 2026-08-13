defmodule PtcRunner.Kernel.ConcurrentAgentContentionLiveE2ETest do
  @moduledoc """
  The closure criterion for issues #1241 and #1287: eight `agent.core` loops under `pcalls`
  against a live provider must not burn `run_duration_ms`.

  The deterministic half of #1241 is pinned elsewhere — `agent_evaluation_
  contention_test.exs` forces the collision with a barrier and a stub requester,
  so it proves the admission queue serializes concurrent `kernel/eval-source`
  callers rather than failing them. What that test cannot reproduce is the
  original live symptom: a run that neither succeeded nor failed fast but
  consumed its whole 150 s budget. Only real provider latency schedules the
  agents against each other the way the reported hang did.

  So this test contends for real and classifies each run:

  - `:ok` — every agent returned its model-authored value;
  - `:admission` — a typed `evaluation-unavailable`, the queue's bounded
    expiry, which is a fast failure and therefore not the reported symptom;
  - `:provider` — the live provider failed one branch (a rate limit on eight
    concurrent requests will do it), which `fail`-inside-`pcalls` turns into a
    whole-run failure; a fact about the provider, not the queue;
  - `:deadline` — the run burned `run_duration_ms`. **This is the symptom.**

  A single `:deadline` classification fails the test. Everything else is
  reported so a run that fails for an unrelated live reason (provider outage,
  a model that will not emit a tool call) is legible instead of silently
  counted as a pass.

  `PTC_CONTENTION_RUNS` sets the repetition count; the issue asks for ~10.
  The default is deliberately low so the `:e2e` suite stays affordable.
  """

  use ExUnit.Case, async: false

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.TestSupport.LLMSupport

  @host Path.expand("../../../examples/kernel-tutorial/ptc-host.json", __DIR__)

  @agents 8
  @max_turns 2
  @run_duration_ms 150_000
  @runs String.to_integer(System.get_env("PTC_CONTENTION_RUNS", "2"))

  @moduletag :e2e
  @moduletag timeout: @runs * (@run_duration_ms + 30_000)

  setup_all do
    :ok = LLMSupport.load_dotenv()
    :ok = LLMSupport.admit_provider_application!()
    assert Application.get_env(:req_llm, :stream_pool_count) == 1
    assert Application.get_env(:req_llm, :stream_pool_size) == 8

    if System.get_env("OPENROUTER_API_KEY") do
      :ok
    else
      {:skip, "OPENROUTER_API_KEY is not configured"}
    end
  end

  test "#{@agents} concurrent live agent loops never burn run_duration_ms" do
    results = Enum.map(1..@runs, &contend/1)

    Enum.each(results, fn result ->
      IO.puts(
        "[contention run #{result.index}] #{result.class} elapsed_ms=#{result.elapsed_ms} " <>
          "#{result.detail}"
      )
    end)

    burned = Enum.filter(results, &(&1.class == :deadline))

    assert burned == [],
           "#{length(burned)}/#{@runs} live runs burned run_duration_ms: #{inspect(burned)}"

    # A run that ends any other way must still end promptly. This catches a
    # hang that resolves as some other failure just under the deadline, which
    # the classification above would otherwise let through.
    slow = Enum.filter(results, &(&1.elapsed_ms > div(@run_duration_ms, 2)))

    assert slow == [],
           "runs exceeded half the run deadline without contending for that long: #{inspect(slow)}"

    succeeded = Enum.count(results, &(&1.class == :ok))
    IO.puts("[contention] #{succeeded}/#{@runs} runs completed all #{@agents} agents")

    # The point of the admission queue is that contention resolves into
    # completed work, not that failures are merely fast. One clean run proves
    # the queue grants; a suite where every run fails is a regression even
    # though no run hung.
    assert succeeded > 0, "no live run completed; see the per-run detail above"
  end

  defp contend(index) do
    operands = Enum.map(1..@agents, fn _ -> {rand(), rand()} end)
    expected = Enum.map(operands, fn {a, b} -> a + b end)

    {:ok, limits} =
      Limits.new(
        run_duration_ms: @run_duration_ms,
        workflow_timeout_ms: @run_duration_ms,
        # Generous, so a stalled branch surfaces as a run-deadline burn (the
        # symptom under test) rather than being masked by the parallel deadline.
        parallel_timeout_ms: 120_000,
        evaluation_timeout_ms: 10_000,
        subordinate_evaluations: 16,
        workflow_capability_calls: 64
      )

    {:ok, %{capabilities: [capability], close: close}} = build_live_llm(limits)

    names =
      ~w(agent.core agent.feedback agent.native agent.prompt agent.retry
         kernel llm result workflow.event)

    {:ok, components} = Library.components(names)
    {:ok, bundle} = Kernel.compile_bundle(components)
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: [capability])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "contention-live-#{index}")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    started = System.monotonic_time(:millisecond)
    outcome = Kernel.run(source(operands), config)
    elapsed_ms = System.monotonic_time(:millisecond) - started

    if close, do: close.()

    result = classify(outcome, expected)
    Map.merge(result, %{index: index, elapsed_ms: elapsed_ms})
  end

  defp rand do
    <<n::unsigned-16>> = :crypto.strong_rand_bytes(2)
    rem(n, 900) + 100
  end

  defp source(operands) do
    branches =
      Enum.map_join(operands, "\n", fn {a, b} ->
        ~s|    #(agent.core/run-value "Return the integer sum of #{a} and #{b}." | <>
          ~s|{"max_turns" #{@max_turns}})|
      end)

    """
    (return
      (pcalls
    #{branches}))
    """
  end

  defp classify({:ok, %{value: values}}, expected) when is_list(values) do
    if values == expected do
      %{class: :ok, detail: "values=#{inspect(values)}"}
    else
      %{class: :wrong_value, detail: "got=#{inspect(values)} expected=#{inspect(expected)}"}
    end
  end

  defp classify({:error, %{kind: :limit_exceeded, reason: :timeout} = error}, _expected) do
    %{class: :deadline, detail: inspect(error.details)}
  end

  defp classify({:error, error}, _expected) do
    rendered = inspect(error, limit: :infinity, printable_limit: 2_000)

    cond do
      String.contains?(rendered, "evaluation-unavailable") ->
        %{class: :admission, detail: rendered}

      # A live provider that rate-limits or drops one of the eight concurrent
      # requests fails that branch, and `fail` inside `pcalls` aborts the run.
      # That is the provider, not the admission queue — named separately so it
      # cannot be mistaken for either a pass or the reported hang.
      String.contains?(rendered, "llm-provider-error") ->
        %{class: :provider, detail: rendered}

      true ->
        %{class: :error, detail: rendered}
    end
  end

  defp classify(other, _expected), do: %{class: :error, detail: inspect(other, limit: 8)}

  defp build_live_llm(limits) do
    {:ok, host} = HostConfig.load(@host)

    host =
      update_in(host.install["deepseek"], fn installation ->
        %{
          installation
          | model: LLMSupport.model(),
            params: %{temperature: 0.0, max_tokens: 1_024}
        }
      end)

    {:ok, catalog} = HostInstallation.catalog(host)
    {:ok, registry} = HostInstallation.runtime_registry(host, catalog)

    ProviderRegistry.build(registry, "deepseek", %{}, %{
      application_content_digest: String.duplicate("0", 64),
      destination: :workflow,
      owner: self(),
      limits: limits,
      installed_limits: host.limits
    })
  end
end
