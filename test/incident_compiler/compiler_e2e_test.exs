defmodule IncidentCompiler.CompilerE2ETest do
  @moduledoc """
  One live-model run of the incident-evidence compiler.

  The credential-free suite proves the compiler's machinery. This proves the
  same application works when the model is not scripted: the prompt is enough
  to reach the tools, the result contract is satisfiable by a real model, and
  every citation a real model writes resolves to a real record.

  It deliberately asserts nothing about diagnostic quality. Whether the model
  reaches the right root cause is a benchmark question, not an exit gate.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :e2e
  @moduletag timeout: 600_000

  alias Mix.Tasks.Ptc.Run

  @app Path.expand("../../incident_compiler", __DIR__)

  setup_all do
    :ok = PtcRunner.Dotenv.load()

    if System.get_env("OPENROUTER_API_KEY") do
      :ok
    else
      {:skip, "OPENROUTER_API_KEY is not configured"}
    end
  end

  test "a live model compiles checkout-5xx into a grounded report" do
    output =
      capture_io(fn ->
        Mix.Task.reenable("ptc.run")

        Run.run([
          Path.join(@app, "ptc.live.json"),
          "--host-config",
          Path.join(@app, "ptc-host.json")
        ])
      end)

    report =
      output
      |> String.split("\n", trim: true)
      |> List.last()
      |> Jason.decode!()
      |> Map.fetch!("value")

    assert report["incident_id"] == "checkout-5xx"

    # Deliberately not `in ["report", "insufficient_evidence"]`. Accepting
    # abstention here would let a model that never publishes anything pass the
    # gate, and this incident carries thirteen records and a cause the evidence
    # states outright. Abstaining on it is a failure, not a judgement call.
    assert report["status"] == "report"

    # Publication already required every citation to resolve, so reaching here
    # at all is most of the assertion. These reject a degenerate report.
    assert length(report["observed_facts"]) >= 3
    assert Enum.all?(report["observed_facts"], &(&1["citations"] != []))
    assert report["timeline"] != []
  end
end
