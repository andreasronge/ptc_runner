defmodule PtcRunnerMcp.Agentic.PlannerTest do
  # async: false — installs a mock LLM adapter via the global
  # `Application.put_env(:ptc_runner, :llm_adapter, …)` seam that
  # `PtcRunner.LLM.call/2` reads on every call (see `PtcRunner.LLM.adapter!/0`).
  # The original adapter is restored in `on_exit`.
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Agentic.Planner

  # ---------------------------------------------------------------------------
  # Mock adapter (the `:llm_adapter` seam read by `PtcRunner.LLM.call/2`).
  #
  # `Planner.call/3` resolves the model via `Registry.resolve!/1`, checks the
  # API key, then calls `PtcRunner.LLM.call(resolved, request)`, which dispatches
  # to `Application.get_env(:ptc_runner, :llm_adapter).call/2`. Each test stashes
  # the desired canned reply in the process dictionary and this mock returns it,
  # so the Planner's own response-unwrap logic runs with NO provider/network call.
  # ---------------------------------------------------------------------------
  defmodule MockAdapter do
    @moduledoc false
    @behaviour PtcRunner.LLM

    @impl true
    def call(model, request) do
      {reply, fun} = Process.get(:planner_mock_reply, {{:error, :no_reply_configured}, nil})
      if fun, do: fun.(model, request)
      reply
    end

    @impl true
    def stream(_model, _request), do: {:error, :streaming_not_supported}
  end

  # A model alias that resolves to a NON-openrouter provider id, so
  # `Planner.check_api_key/1` returns `:ok` without any environment variable.
  # `DefaultRegistry.resolve!("ollama:…")` passes through as `"ollama:…"`.
  @model "ollama:planner-probe-model"
  @prompt "render the data"
  @opts [timeout_ms: 1_000, max_output_tokens: 64]

  setup do
    original = Application.get_env(:ptc_runner, :llm_adapter)
    Application.put_env(:ptc_runner, :llm_adapter, MockAdapter)

    on_exit(fn ->
      if original do
        Application.put_env(:ptc_runner, :llm_adapter, original)
      else
        Application.delete_env(:ptc_runner, :llm_adapter)
      end
    end)

    :ok
  end

  defp stub_reply(reply, fun \\ nil) do
    Process.put(:planner_mock_reply, {reply, fun})
  end

  describe "provider-success path" do
    test "unwraps {:ok, %{content}} into {:ok, content, meta}" do
      content = "(return {:result 42})"
      stub_reply({:ok, %{content: content, tokens: %{input: 10, output: 5}}})

      assert {:ok, ^content, meta} = Planner.call(@model, @prompt, @opts)

      # Model is the resolved id; ollama aliases pass through unchanged.
      assert meta["model"] == @model
      # prompt_bytes counts the fixed system message PLUS the user prompt.
      assert meta["prompt_bytes"] ==
               byte_size(Planner.system_message()) + byte_size(@prompt)

      assert meta["output_bytes"] == byte_size(content)
      assert meta["completion_bytes"] == byte_size(content)
      assert meta["tokens"] == %{input: 10, output: 5}
      assert is_integer(meta["duration_ms"]) and meta["duration_ms"] >= 0
    end

    test "defaults tokens to an empty map when the response omits them" do
      content = "(return :ok)"
      stub_reply({:ok, %{content: content}})

      assert {:ok, ^content, meta} = Planner.call(@model, @prompt, @opts)
      assert meta["tokens"] == %{}
    end

    test "forwards the system message, user prompt, and request limits to the adapter" do
      test_pid = self()

      stub_reply({:ok, %{content: "(return 1)"}}, fn resolved, request ->
        send(test_pid, {:adapter_called, resolved, request})
      end)

      assert {:ok, _content, _meta} = Planner.call(@model, @prompt, @opts)

      assert_received {:adapter_called, @model, request}
      assert request.system == Planner.system_message()
      assert request.messages == [%{role: :user, content: @prompt}]
      assert request.receive_timeout == 1_000
      assert request.max_tokens == 64
    end
  end

  describe "provider non-success paths" do
    test "a successful reply without binary content is a :planner error" do
      stub_reply({:ok, %{tool_calls: [%{name: "do_thing"}]}})

      assert {:error, :planner, message, meta} = Planner.call(@model, @prompt, @opts)
      assert message =~ "planner returned no text content"
      assert meta["model"] == @model
      assert meta["prompt_bytes"] == byte_size(Planner.system_message()) + byte_size(@prompt)
      # The no-content branch does NOT compute duration/output byte counts.
      refute Map.has_key?(meta, "duration_ms")
      refute Map.has_key?(meta, "output_bytes")
    end

    test "a non-binary content value is treated as no text content" do
      stub_reply({:ok, %{content: nil}})

      assert {:error, :planner, message, _meta} = Planner.call(@model, @prompt, @opts)
      assert message =~ "planner returned no text content"
    end

    test "an adapter {:error, reason} becomes a :planner error carrying the reason" do
      stub_reply({:error, :timeout})

      assert {:error, :planner, message, meta} = Planner.call(@model, @prompt, @opts)
      assert message =~ "timeout"
      assert meta["model"] == @model
      assert meta["prompt_bytes"] == byte_size(Planner.system_message()) + byte_size(@prompt)
    end
  end
end
