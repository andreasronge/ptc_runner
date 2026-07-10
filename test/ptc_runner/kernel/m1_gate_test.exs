defmodule PtcRunner.Kernel.M1GateTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Tool
  alias PtcRunner.TraceLog
  alias PtcRunner.TraceLog.MemorySink

  test "LLM budget is claimed atomically before provider invocation and emits a terminal turn" do
    {:ok, sink} = TraceLog.start_memory_sink()
    parent = self()

    llm = fn _request ->
      send(parent, :llm_called)
      {:ok, %{content: "protocol error"}}
    end

    try do
      assert {:error, %{"reason" => "llm_budget_exhausted"}} =
               Kernel.run(%{"task" => "compute"},
                 llm: llm,
                 max_turns: 3,
                 max_llm_calls: 1,
                 unsafe_debug: true,
                 events: fn event -> send(parent, {:event, event}) end
               )

      assert_received :llm_called
      refute_received :llm_called

      assert [%{"data" => data} = turn | _] =
               sink
               |> MemorySink.events()
               |> Enum.filter(&(&1["event"] == "turn" and &1["driver"] == "kernel"))
               |> Enum.reverse()

      assert data["turn_type"] == "budget_exhausted"
      assert turn["committed"] == false
      assert turn["status"] == "error"
      assert data["fail"]["reason"] == "llm_budget_exhausted"

      unsafe_requests = collect_events([])
      assert Enum.count(unsafe_requests, &(&1["event"] == "unsafe_llm_request")) == 1
    after
      TraceLog.stop_memory_sink(sink)
    end
  end

  test "max_turns and max_llm_calls are positive integers validated before the model" do
    for {option, value} <- [max_turns: 0, max_turns: nil, max_llm_calls: -1, max_llm_calls: "2"] do
      assert {:error,
              %{reason: "invalid_kernel_option", option: option_name, value_type: value_type}} =
               Kernel.run(%{"task" => "compute"}, [{option, value}, {:llm, fail_llm()}])

      assert option_name == Atom.to_string(option)
      assert value_type in ["integer", "nil", "string"]
    end
  end

  test "private capabilities normalize names, reject ambiguity, and remain model-invisible" do
    private =
      {fn _args -> %{"secret" => "hidden"} end, [signature: "() -> :map", visibility: :private]}

    assert_preflight(:private_capabilities, %{"x" => private, x: private}, "duplicate_name")
    assert_preflight(:private_capabilities, %{"llm-complete" => private}, "reserved_name")
    assert_preflight(:private_capabilities, %{123 => private}, "invalid_name")
    huge_name = String.duplicate("x", 1_000)

    assert {:error, error} =
             Kernel.run(%{"task" => "test"},
               llm: fn _ -> flunk("LLM must not run") end,
               private_capabilities: %{huge_name => private}
             )

    assert error.detail == "invalid_name"
    assert byte_size(error.capability) <= 128

    assert_preflight(:private_capabilities, %{"x" => fn _ -> :no end}, "invalid_format")

    for options <- [
          [signature: "not a signature", visibility: :private],
          [description: 42, visibility: :private],
          [cache: :yes, visibility: :private],
          [expose: :unknown, visibility: :private],
          [expose: :both, cache: true, native_result: [preview: :metadata], visibility: :private],
          [native_result: :bad, visibility: :private],
          [visibility: :private, visibility: :private]
        ] do
      assert_preflight(
        :private_capabilities,
        %{"x" => {fn _ -> :no end, options}},
        "malformed_options"
      )
    end

    assert_preflight(
      :private_capabilities,
      %{"x" => {fn _ -> :no end, visibility: :public}},
      "not_private"
    )

    public_tool = %Tool{name: "x", function: fn _ -> :no end, type: :native}
    assert_preflight(:private_capabilities, %{"x" => public_tool}, "not_private")
  end

  test "private capability can be authorized by the loop prelude but not an inner program" do
    parent = self()

    core = """
    (ns agent.core {:visibility :prompt})
    (defn run-mission [mission cfg]
      (let [private-result (tool/state-summary {})
            action (tool/llm-complete {"system" "Use the required tool."
                                       "messages" [] "turn" 0})
            result (tool/eval-program {"program" (action "program") "turn" 0})]
        (if (= (result "status") "return")
          (return {"private" private-result "inner" (result "value")})
          (fail result))))
    """

    llm = fn request ->
      tool_names =
        Enum.map(request.tools, fn tool ->
          get_in(tool, [:function, :name]) || get_in(tool, ["function", "name"])
        end)

      send(parent, {:tool_names, tool_names})

      {:ok,
       %{
         tool_calls: [
           %{name: "run_ptc_lisp", args: %{"program" => "(return (tool/state-summary {}))"}}
         ]
       }}
    end

    private =
      {fn _args -> %{"defined_count" => 0} end, [signature: "() -> :map", visibility: :private]}

    result =
      Kernel.run(%{"task" => "compute"},
        llm: llm,
        private_capabilities: %{"state-summary" => private},
        prelude_source_overrides: %{"agent.core" => core}
      )

    assert {:error, %{"reason" => "unknown_tool"}} = result, inspect(result)

    assert_received {:tool_names, ["run_ptc_lisp"]}
  end

  test "all public preflight paths use bounded stable envelopes without raw values" do
    sentinel = "RAW-PREFLIGHT-SECRET"

    cases = [
      {[llm: sentinel], "llm"},
      {[llm: fail_llm(), timeout: sentinel], "timeout"},
      {[llm: fail_llm(), max_heap: nil], "max_heap"},
      {[llm: fail_llm(), setup_max_heap: 0], "setup_max_heap"},
      {[llm: fail_llm(), inner_timeout: -1], "inner_timeout"},
      {[llm: fail_llm(), inner_max_heap: sentinel], "inner_max_heap"},
      {[llm: fail_llm(), kernel_memory_byte_cap: sentinel], "kernel_memory_byte_cap"},
      {[llm: fail_llm(), role_policy: sentinel], "role_policy"},
      {[llm: fail_llm(), role_policy: %{"roles" => %{"worker" => %{}}}, role: sentinel], "role"},
      {[llm: fail_llm(), inner_preludes: [sentinel]], "inner_preludes"}
    ]

    for {opts, expected_option} <- cases do
      assert {:error,
              %{reason: "invalid_kernel_option", option: ^expected_option, value_type: type}} =
               Kernel.run(%{"task" => "compute"}, opts)

      assert type in ["integer", "nil", "string", "list", "map"]
      refute inspect(Kernel.run(%{"task" => "compute"}, opts)) =~ sentinel
    end
  end

  test "outer timeout and heap failures use the bounded kernel envelope" do
    blocking_llm = fn _request ->
      receive do
        :never -> {:ok, %{content: "unreachable"}}
      end
    end

    assert_kernel_limit_failure(
      Kernel.run(%{"task" => "compute"}, llm: blocking_llm, timeout: 10),
      :timeout
    )

    allocating_llm = fn _request ->
      _allocation = for i <- 1..100_000, do: %{i => i}
      {:ok, %{content: "unreachable"}}
    end

    assert_kernel_limit_failure(
      Kernel.run(%{"task" => "compute"},
        llm: allocating_llm,
        max_heap: 20_000,
        setup_max_heap: 16_000_000
      ),
      :memory_exceeded
    )
  end

  test "outer setup heap failure occurs before provider invocation" do
    mission = %{"task" => "compute", "context" => %{"rows" => Enum.to_list(1..100_000)}}

    assert_kernel_limit_failure(
      Kernel.run(mission,
        llm: fail_llm(),
        max_heap: 8_000_000,
        setup_max_heap: 20_000
      ),
      :memory_exceeded
    )
  end

  test "terminal transport failures never expose provider terms" do
    secret = "PROVIDER-SECRET-DO-NOT-RETURN"

    assert {:error,
            %{
              "reason" => "llm_transport_error",
              "error" => %{reason: "provider_error", kind: "transport_error"}
            } = error} =
             Kernel.run(%{"task" => "compute"}, llm: fn _ -> {:error, {:http, secret}} end)

    refute inspect(error) =~ secret
  end

  defp assert_preflight(option, value, detail) do
    assert {:error,
            %{
              reason: "invalid_private_capability",
              option: "private_capabilities",
              value_type: "map",
              detail: ^detail
            }} = Kernel.run(%{"task" => "compute"}, [{option, value}, {:llm, fail_llm()}])
  end

  defp fail_llm do
    fn _ -> flunk("LLM must not be called during preflight") end
  end

  defp assert_kernel_limit_failure(result, expected_reason) do
    assert {:error, %{reason: "kernel_error", step: step}} = result
    assert step.fail.reason == expected_reason
    assert byte_size(step.fail.message) <= 500
    assert length(step.prints) <= 8
    refute inspect(result) =~ "unreachable"
  end

  defp collect_events(acc) do
    receive do
      {:event, event} -> collect_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
