defmodule PtcRunner.Labs.LLMTransportBaseline do
  @moduledoc false

  alias PtcRunner.Kernel.LLMUsage
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMCapability
  alias PtcRunner.Kernel.LLMRouter
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.LLM.Invocation
  alias PtcRunner.LLM.ReqLLMAdapter
  alias PtcRunner.LLM.Requirements
  alias PtcRunner.TestSupport.MCPHTTPFixture
  alias PtcRunner.TestSupport.TestHelpers

  @model "openrouter:deepseek/deepseek-v4-flash"
  @capacity 2
  @cleanup_ms 1_000
  @tariff %{currency: "USD", id: "pilot-llmdb-2026.8.4"}

  def run do
    if Application.started_applications() |> Enum.any?(&(elem(&1, 0) == :req_llm)) do
      raise "run in a fresh Mix VM; the probe owns provider application configuration"
    end

    parent = self()
    server = MCPHTTPFixture.start(&serve(&1, parent))

    try do
      start_provider(server.endpoint)
      requirements = requirements()
      {:ok, target, status, ^requirements} = ReqLLMAdapter.prepare_model(@model, requirements)

      %{total_tokens: _, cost: %{microunits: _}} =
        bound = ReqLLMAdapter.reservation_bound(target, request("normal"), @tariff)

      # Warm up resolution/encoding before latency and resource observations.
      %{outcome: "ok"} = call(target, "warmup", 5_000)
      before = resources()
      normal = Enum.map(1..10, fn _ -> call(target, "normal", 5_000) end)
      %{result: %{status: :ok}} = kernel_normal = dispatch(target, "kernel-normal", 5_000)
      contention = contention(target)
      recovery = Enum.map(1..10, fn _ -> call(target, "recovery", 5_000) end)

      %{
        schema_version: 1,
        captured_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        source: source(),
        scope: "prepared adapter and Dispatcher over loopback HTTP/1; no aggregate host gate",
        model: @model,
        catalog_status: status,
        versions: versions(),
        runtime: %{
          elixir: System.version(),
          otp: System.otp_release(),
          schedulers: System.schedulers_online()
        },
        requirements: requirements,
        geometry: %{count: 1, size: @capacity, protocols: ["http1"]},
        criteria: %{cleanup_observation_ms: @cleanup_ms, queued_request_deadline_ms: 250},
        reservation: bound,
        normal: summarize(normal),
        kernel_normal: kernel_normal,
        contention: contention,
        recovery: summarize(recovery),
        resources: %{before: before, after: resources()},
        limitations: [
          "Fixture closes successful connections; these timings do not measure pool reuse or TLS.",
          "Direct adapter and one Dispatcher call: complete concurrent workflows remain a separate gate.",
          "Resource snapshots are diagnostic, not sustained leak or deployment capacity evidence.",
          "Local observation windows are provisional; deployment performance criteria remain open."
        ]
      }
    after
      server.close.()
      Application.stop(:req_llm)
      Application.stop(:llm_db)
    end
  end

  defp start_provider(endpoint) do
    Application.put_env(:req_llm, :load_dotenv, false)
    Application.put_env(:llm_db, :load_dotenv, false)
    Application.put_env(:req_llm, :openrouter, base_url: endpoint)

    Application.put_env(:req_llm, :finch,
      pools: %{default: [size: @capacity, count: 1, protocols: [:http1]]}
    )

    {:ok, _} = Application.ensure_all_started(:req_llm)
  end

  defp requirements do
    %{
      Requirements.interim(%{max_tokens: 4_096})
      | usage_guarantees: %{tokens: true, cost_currency: "USD"},
        reservation: %{total_tokens?: true, cost_tariff: @tariff}
    }
  end

  defp contention(target) do
    held = Enum.map(1..@capacity, &start_call(target, "hold-#{&1}", 10_000))

    try do
      Enum.each(held, fn {id, _, _} -> true = await({:arrived, id}, 5_000) end)
      kernel_queued = dispatch(target, "kernel-queued", 250)
      queued = call(target, "queued", 250)
      start = now()

      Enum.each(held, fn {_, pid, _} -> Process.exit(pid, :kill) end)

      closed =
        Enum.map(held, fn {id, pid, ref} ->
          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> :ok
          after
            5_000 -> raise "caller did not terminate"
          end

          %{id: id, closed: await({:closed, id}, max(0, start + @cleanup_ms - now()))}
        end)

      %{
        held_requests: @capacity,
        queued: queued,
        kernel_queued: kernel_queued,
        kernel_queued_reached_wire: await({:arrived, "kernel-queued"}, 0),
        queued_reached_wire: await({:arrived, "queued"}, 0),
        cancellation: closed,
        cleanup_duration_ms: now() - start
      }
    after
      Enum.each(held, fn {_, pid, ref} ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
      end)
    end
  end

  defp start_call(target, id, timeout) do
    {pid, ref} = spawn_monitor(fn -> call(target, id, timeout) end)
    {id, pid, ref}
  end

  def dispatch(target, id, timeout, adapter \\ ReqLLMAdapter) do
    requester = fn request, context ->
      {:ok, invocation} =
        Invocation.new(
          ProviderRegistry.adapter_request(request),
          false,
          if(adapter == ReqLLMAdapter, do: "loopback-only", else: nil),
          context.llm_request_deadline_ms
        )

      adapter.call(target, invocation)
    end

    {:ok, capability} =
      LLMCapability.new(requester: requester, usage_guarantees: requirements().usage_guarantees)

    {:ok, router} =
      LLMRouter.new([
        %{
          alias: "pilot",
          source: "llm",
          installation_revision: "pilot-v1",
          default?: true,
          capability: capability,
          max_calls: nil,
          output_tokens: 4_096,
          request_timeout_ms: timeout,
          reservation_tariff: @tariff,
          reservation_bound: fn request, tariff ->
            {:ok, adapter.reservation_bound(target, request, tariff)}
          end
        }
      ])

    {:ok, environment} = WorkflowEnvironment.new(capabilities: [router])
    {:ok, limits} = Limits.new(llm_total_tokens: 10_000, llm_cost_microusd: 10_000)
    {:ok, state} = RunState.start(limits)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "transport-pilot")
    start = now()

    try do
      result =
        Dispatcher.dispatch(
          state,
          :workflow,
          environment,
          "llm-request",
          %{"messages" => [%{"role" => "user", "content" => id}]},
          TestHelpers.dispatch_context(state, :workflow, 10_000),
          sink,
          nil
        )

      %{
        duration_ms: now() - start,
        result: result,
        ledger: RunState.usage(state).llm_budget
      }
    after
      RunState.close_and_drain(state)
      RunState.stop(state)
      EventSink.stop(sink)
    end
  end

  defp call(target, id, timeout) do
    start = now()
    {:ok, invocation} = Invocation.new(request(id), false, "loopback-only", start + timeout)

    result = invoke(target, invocation)
    Map.put(result, :duration_ms, now() - start)
  end

  defp invoke(target, invocation) do
    target |> ReqLLMAdapter.call(invocation) |> project()
  rescue
    exception -> %{outcome: "raised", exception: inspect(exception.__struct__)}
  catch
    :exit, _reason -> %{outcome: "exit"}
  end

  defp project({:ok, %{tokens: tokens}}) do
    {:ok, usage} = LLMUsage.normalize(tokens, requirements().usage_guarantees)
    %{outcome: "ok", usage: usage}
  end

  defp project({:error, error}) do
    %{outcome: "error", kind: Map.get(error, :kind), reason: Map.get(error, :reason)}
  end

  defp summarize(samples) do
    latencies = samples |> Enum.map(& &1.duration_ms) |> Enum.sort()

    %{
      requests: length(samples),
      outcomes: Enum.frequencies_by(samples, & &1.outcome),
      latency_ms: %{min: hd(latencies), median: Enum.at(latencies, 5), max: List.last(latencies)},
      first: hd(samples)
    }
  end

  defp serve(%{body: %{"messages" => messages}}, parent) do
    id = messages |> List.last() |> Map.fetch!("content")
    send(parent, {:arrived, id})

    if String.starts_with?(id, "hold-") do
      {:script,
       fn socket ->
         :ok = :inet.setopts(socket, active: :once)

         receive do
           {:tcp_closed, ^socket} -> send(parent, {:closed, id})
           {:tcp_error, ^socket, _} -> send(parent, {:closed, id})
         after
           15_000 -> :ok
         end

         :ok
       end}
    else
      {200, [{"content-type", "application/json"}], response()}
    end
  end

  defp response do
    Jason.encode!(%{
      id: "pilot-fixture",
      model: "deepseek/deepseek-v4-flash",
      choices: [%{index: 0, finish_reason: "stop", message: %{role: "assistant", content: "ok"}}],
      usage: %{prompt_tokens: 10, completion_tokens: 2, total_tokens: 12, cost: "0.000005"}
    })
  end

  defp await(message, timeout) do
    receive do
      ^message -> true
    after
      timeout -> false
    end
  end

  defp request(id), do: %{messages: [%{role: :user, content: id}]}
  defp now, do: System.monotonic_time(:millisecond)

  defp resources,
    do: %{processes: :erlang.system_info(:process_count), ports: length(Port.list())}

  defp versions do
    Map.new([:req_llm, :llm_db, :req, :finch, :mint], fn app ->
      {app, app |> Application.spec(:vsn) |> to_string()}
    end)
  end

  defp source do
    {revision, 0} = System.cmd("git", ["rev-parse", "HEAD"])

    %{
      revision: String.trim(revision),
      probe_sha256: hash_file(__ENV__.file),
      lock_sha256: hash_file("mix.lock"),
      catalog_sha256: hash_file(Application.app_dir(:llm_db, "priv/llm_db/snapshot.json"))
    }
  end

  defp hash_file(path),
    do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
end
