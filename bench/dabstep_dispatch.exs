Code.require_file("support/dabstep.exs", __DIR__)

defmodule PtcRunner.Bench.DabstepDispatch do
  @moduledoc false
  alias PtcRunner.Bench.DabstepSupport, as: Bench

  alias PtcRunner.Kernel.{
    Capability,
    Dispatcher,
    EventSink,
    InspectionSink,
    Limits,
    PublicationHandle,
    RunState,
    WorkflowEnvironment
  }

  def run do
    page = "tmp/profiling/followup/page.json" |> File.read!() |> Jason.decode!()
    catalog = "tmp/profiling/followup/page.catalog.json" |> File.read!() |> Jason.decode!()
    tool = Enum.find(catalog["tools"], &(&1["name"] == "read_text_file"))

    for {label, schema?, capture} <- [
          {"dispatch_only", false, nil},
          {"schemas", true, nil},
          {"schemas_events", true, :events},
          {"schemas_digest", true, :digest_results},
          {"schemas_full", true, :full}
        ] do
      {:ok, capability} =
        Capability.new(
          name: "bench.read",
          callback: fn _ -> {:ok, page} end,
          effect: :read,
          input_schema:
            if(schema?,
              do: tool["inputSchema"],
              else: %{"type" => "object", "additionalProperties" => true}
            ),
          output_schema: if(schema?, do: tool["outputSchema"], else: nil),
          inspection_capture: if(capture == :full, do: :full, else: :digest_results)
        )

      {:ok, environment} = WorkflowEnvironment.new(capabilities: [capability])
      limits = Limits.defaults()
      {:ok, state} = RunState.start(limits)
      events = if capture, do: elem(EventSink.start(:normal, limits, run_id: "dispatch-bench"), 1)
      {inspection, handle} = inspection(capture)

      context = %{
        timeout_ms: 30_000,
        validation_heap_words: 5_000_000,
        evaluation_lease: nil,
        validation_deadline_ms: nil,
        mission_name: nil
      }

      try do
        Bench.measure(label, fn ->
          for _ <- 1..20 do
            %{status: :ok, value: ^page} =
              Dispatcher.dispatch(
                state,
                :workflow,
                environment,
                "bench.read",
                %{"path" => "payments.csv"},
                context,
                events,
                inspection
              )
          end

          %{dispatches: 20}
        end)

        if inspection do
          {:ok, seal} = InspectionSink.seal(inspection)

          IO.puts(
            Jason.encode!(%{
              experiment: label,
              dispatches: 120,
              inspection: Map.take(seal, [:total_bytes, :record_count])
            })
          )
        end
      after
        if inspection, do: InspectionSink.stop(inspection)
        if handle, do: PublicationHandle.discard(handle)
        if events, do: EventSink.stop(events)
        RunState.stop(state)
      end
    end
  end

  defp inspection(capture) when capture in [:full, :digest_results] do
    path =
      Path.expand(
        "tmp/profiling/followup/dispatch-#{capture}-#{System.unique_integer([:positive])}.jsonl"
      )

    {:ok, handle} = PublicationHandle.reserve_stream_for(path, :inspection, 0o600, self())

    {:ok, sink} =
      InspectionSink.start(
        run_id: "dispatch-bench",
        trace_id: "dispatch-trace",
        publication_handle: handle,
        max_total_bytes: 200_000_000
      )

    {sink, handle}
  end

  defp inspection(_), do: {nil, nil}
end

PtcRunner.Bench.DabstepDispatch.run()
