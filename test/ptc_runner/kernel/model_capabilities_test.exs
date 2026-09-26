defmodule PtcRunner.Kernel.ModelCapabilitiesTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.MCPSource
  alias PtcRunner.Kernel.ModelCapabilities
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.TestSupport.TestHelpers

  test "model and chat classification accepts strings and atoms" do
    for name <- ["llm-request", :"llm-request"] do
      assert ModelCapabilities.model_call?(name)
      assert ModelCapabilities.chat?(name)
      assert ModelCapabilities.reserved_name?(name)
    end

    for name <- ["decision-request", :"decision-request"] do
      refute ModelCapabilities.model_call?(name)
      refute ModelCapabilities.chat?(name)
      assert ModelCapabilities.reserved_name?(name)
    end

    for name <- ["workspace.read", nil, 42] do
      refute ModelCapabilities.model_call?(name)
      refute ModelCapabilities.chat?(name)
      refute ModelCapabilities.reserved_name?(name)
    end
  end

  test "MCP public mappings cannot claim current or future model names" do
    for name <- ["llm-request", "decision-request"] do
      assert_raise ArgumentError, fn ->
        MCPSource.builder(
          transport: {:streamable_http, endpoint: "https://example.com/mcp"},
          tools: %{"upstream" => %{as: name, effect: :read}}
        )
      end
    end
  end

  test "a host-built chat capability retains model-call treatment by name" do
    documents = %{
      "ptc.json" => Jason.encode!(TestHelpers.valid_manifest()),
      "main.clj" => "(ns app) (defn run [input] (return input))"
    }

    assert {:ok, package, _input} = ApplicationPackage.acquire_memory("ptc.json", documents)

    {:ok, capability} =
      Capability.new(
        name: "llm-request",
        input_schema: %{"type" => "object"},
        callback: fn _arguments -> {:ok, %{}} end
      )

    assert {:ok, environment} =
             WorkflowEnvironment.new_for_package([capabilities: [capability]], package)

    assert Map.has_key?(environment.capabilities, "llm-request")
  end

  @site_classes %{
    "kernel/dispatcher.ex" => %{
      put_llm_requester_deadline: :model_call?,
      maybe_put_llm_request_hash: :model_call?,
      await_provider: :model_call?,
      compile_request_schema: :chat?,
      attest_llm_reservation: :model_call?,
      llm_provider_error: :model_call?,
      request_schema_value: :chat?,
      llm_spend_identity?: :model_call?
    },
    "kernel/trace_log.ex" => %{
      compile_analysis: :model_call?,
      chat_call_count: :chat?,
      capability_name_count: :chat?
    },
    "kernel/llm_usage_summary.ex" => %{
      llm_accounting_event: :model_call?,
      llm_usage_event?: :model_call?
    },
    "kernel/provider_acquisition.ex" => %{
      no_unclaimed_llm_request: :chat?,
      build_llm_router_entry: :chat?
    },
    "kernel/inspection_record.ex" => %{
      capability_input_fields: :model_call?,
      valid_capability_request_hash?: :model_call?
    },
    "kernel/inspection_artifact/conversation.ex" => %{
      model_input?: :chat?,
      model_output?: :chat?
    },
    "kernel/inspection_artifact/assembler.ex" => %{capability_class: :model_call?},
    "kernel/llm_router.ex" => %{valid_route?: :chat?},
    "kernel/declared_read_effect_validator.ex" => %{declaration_effects: :model_call_name},
    "cli_progress/format.ex" => %{llm_count: :chat?}
  }

  test "every policy site uses its general or chat-only classification" do
    for {path, functions} <- @site_classes do
      source = Path.join("lib/ptc_runner", path)
      ast = source |> File.read!() |> Code.string_to_quoted!()
      calls = classified_function_calls(ast)

      for {function, expected} <- functions do
        actual = Map.get(calls, function, MapSet.new())
        assert MapSet.member?(actual, expected), "#{source}:#{function} lacks #{expected}"

        opposite = if expected == :chat?, do: :model_call?, else: :chat?
        refute MapSet.member?(actual, opposite), "#{source}:#{function} uses #{opposite}"
      end
    end
  end

  defp classified_function_calls(ast) do
    {_ast, calls} =
      Macro.prewalk(ast, %{}, fn
        {definition, _, [head, blocks]} = node, acc
        when definition in [:def, :defp] and is_list(blocks) ->
          name = function_name(head)
          names = classification_calls(Keyword.fetch!(blocks, :do))
          {node, Map.update(acc, name, names, &MapSet.union(&1, names))}

        node, acc ->
          {node, acc}
      end)

    calls
  end

  defp function_name({:when, _, [head | _guards]}), do: function_name(head)
  defp function_name({name, _, _args}), do: name

  defp classification_calls(body) do
    {_body, names} =
      Macro.prewalk(body, MapSet.new(), fn
        {{:., _, [{:__aliases__, _, [:ModelCapabilities]}, name]}, _, _args} = node, acc ->
          {node, MapSet.put(acc, name)}

        node, acc ->
          {node, acc}
      end)

    names
  end
end
