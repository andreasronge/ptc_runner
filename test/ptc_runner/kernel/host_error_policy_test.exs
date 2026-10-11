defmodule PtcRunner.Kernel.HostErrorPolicyTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.HostErrorPolicy
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Prelude.Compiler

  test "parallel program taxonomy is validated by the kernel catalog" do
    {:ok, prelude} =
      Compiler.compile("""
      (ns api "API" {:visibility :prompt})
      (defn known [] (pcalls #(fail {:kind :evaluation-unavailable :reason "PRIVATE"})))
      (defn custom [] (pmap (fn [_] (fail {:kind :custom-domain :reason "PRIVATE"})) [1]))
      """)

    assert {:error, known} =
             Lisp.run("(api/known)", prelude: prelude, host_error_policy: HostErrorPolicy)

    assert known.fail.details == %{failure_kind: "evaluation-unavailable"}

    assert {:error, custom} =
             Lisp.run("(api/custom)", prelude: prelude, host_error_policy: HostErrorPolicy)

    assert %{failure_kind_fingerprint: fingerprint} = custom.fail.details
    assert is_binary(fingerprint)
    refute inspect(custom.fail) =~ "PRIVATE"
    refute inspect(custom.fail) =~ "custom-domain"
  end

  test "kernel injects its catalog into fresh subordinate evaluations" do
    {:ok, component} =
      Component.new(
        id: "api",
        source: """
        (ns api)
        (defn custom [] (pcalls #(fail {:kind :custom-domain :reason "PRIVATE"})))
        """
      )

    {:ok, bundle} = Kernel.compile_bundle([component])
    {:ok, components} = Library.resolve_components([{:library, "kernel"}])
    {:ok, workflow_bundle} = Kernel.compile_bundle(components)
    {:ok, workflow} = WorkflowEnvironment.new(bundle: workflow_bundle)
    {:ok, mission} = MissionEnvironment.new(bundle: bundle)
    {:ok, limits} = Limits.new([])
    {:ok, sink} = EventSink.start(:normal, limits)
    on_exit(fn -> EventSink.stop(sink) end)

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: value}} =
             Kernel.run(~S|(return (kernel/eval-source "default" "(api/custom)"))|, config)

    assert value["kind"] == "pcalls_error"
    refute inspect(value) =~ "PRIVATE"

    assert is_binary(value["details"]["failure_kind_fingerprint"])
    refute Map.has_key?(value["details"], "failure_kind")
    refute inspect(value) =~ "custom-domain"
  end
end
