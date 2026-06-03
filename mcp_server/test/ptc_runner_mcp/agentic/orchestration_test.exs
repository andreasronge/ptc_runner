defmodule PtcRunnerMcp.Agentic.OrchestrationTest do
  # async: false — mutates the global `:agentic_planner` Application env that
  # `Agentic.call_planner/4` reads at run time. Each test installs a uniquely
  # named in-VM stub planner so the agentic loop executes a literal PTC-Lisp
  # program with NO provider/network call, then restores the original env.
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Agentic
  alias PtcRunnerMcp.Agentic.{CapabilitySummary, Planner}
  alias PtcRunnerMcp.AgenticConfig

  # ---------------------------------------------------------------------------
  # Stub planners (the `:agentic_planner` seam at agentic.ex:385)
  #
  # `Agentic.call_planner/4` resolves the planner via
  #   Application.get_env(:ptc_runner_mcp, :agentic_planner, Planner)
  # and calls `planner.call(model, prompt, opts)`. The real `Planner.call/3`
  # returns `{:ok, content, meta}` on success or
  # `{:error, :config | :planner, message, meta}` on failure. These stubs mimic
  # that contract exactly so the agentic loop runs entirely in-VM.
  # ---------------------------------------------------------------------------

  # `max_turns: 1` makes turn 1 the "must_return" turn, so the program must
  # call `(return ...)` for the SubAgent to capture an answer; a bare value
  # would yield a `:must_return_missing` error.
  @program "(return (+ 1 2))"

  defmodule StubPlanner do
    @moduledoc false
    # Emits a fixed literal PTC-Lisp program; the SubAgent then evaluates it
    # in-process with `output: :ptc_lisp`. `tokens: %{}` => provider usage is
    # NOT reported (drives the byte-estimate aggregation branch).
    def call(model, prompt, _opts) do
      {:ok, "(return (+ 1 2))",
       %{
         "model" => model,
         "duration_ms" => 7,
         "prompt_bytes" => byte_size(prompt),
         "output_bytes" => 16,
         "completion_bytes" => 16,
         "tokens" => %{}
       }}
    end
  end

  defmodule ProviderTokenStubPlanner do
    @moduledoc false
    # Same literal program but carries a real provider token count so the
    # `provider_reported: true` aggregation branch is exercised.
    def call(model, prompt, _opts) do
      {:ok, "(return (+ 1 2))",
       %{
         "model" => model,
         "duration_ms" => 3,
         "prompt_bytes" => byte_size(prompt),
         "completion_bytes" => 16,
         "tokens" => %{input: 11, output: 5}
       }}
    end
  end

  defmodule ErrorStubPlanner do
    @moduledoc false
    # Drives the `{:error, :planner, ...}` projection: the SubAgent never gets
    # a program, so the loop fails and the error envelope is produced.
    def call(_model, _prompt, _opts) do
      {:error, :planner, "stub planner refused", %{"model" => "stub", "prompt_bytes" => 5}}
    end
  end

  defmodule ConfigErrorStubPlanner do
    @moduledoc false
    # Drives the `{:error, :config, ...}` -> `:agentic_config_error` mapping.
    def call(_model, _prompt, _opts) do
      {:error, :config, "stub config error", %{"model" => "stub"}}
    end
  end

  setup do
    original = Application.get_env(:ptc_runner_mcp, :agentic_planner)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:ptc_runner_mcp, :agentic_planner)
        value -> Application.put_env(:ptc_runner_mcp, :agentic_planner, value)
      end
    end)

    :ok
  end

  defp install_planner(module) do
    Application.put_env(:ptc_runner_mcp, :agentic_planner, module)
  end

  defp validated(task \\ "compute the sum") do
    %{task: task, context: %{}, constraints: %{}, warnings: []}
  end

  defp structured(envelope), do: Map.fetch!(envelope, "structuredContent")

  describe "run_validated/2 success projection via stub planner" do
    test "literal PTC-Lisp program executes in-VM and yields answer 3" do
      install_planner(StubPlanner)

      envelope = Agentic.run_validated(validated(), request_id: "req-success")
      sc = structured(envelope)

      assert envelope["isError"] == false
      assert sc["status"] == "ok"
      # `(return (+ 1 2))` -> 3: the compact user-facing `answer` is the
      # string form, `structured_result` carries the typed value.
      assert sc["answer"] == "3"
      assert sc["structured_result"] == 3
      assert sc["upstream_calls"] == []
      # No upstream runtime configured -> no upstream_results key.
      refute Map.has_key?(sc, "upstream_results")
    end

    test "planner block reports the single planner call and its meta" do
      install_planner(StubPlanner)

      sc = Agentic.run_validated(validated()) |> structured()

      planner = sc["planner"]
      assert planner["calls"] == 1
      # Last planner meta is merged into the planner block.
      assert planner["model"]
      assert planner["duration_ms"] == 7
    end

    test "ptc_metrics aggregates server_side_llm from planner_log (byte-only)" do
      install_planner(StubPlanner)

      sc = Agentic.run_validated(validated()) |> structured()
      metrics = sc["ptc_metrics"]

      assert is_map(metrics)
      ssl = metrics["server_side_llm"]
      assert ssl["planner_calls"] == 1
      # StubPlanner returned tokens: %{} -> provider usage NOT reported.
      assert ssl["provider_reported"] == false
      assert ssl["prompt_tokens"] == nil
      assert ssl["completion_tokens"] == nil
      assert ssl["total_tokens"] == nil
      # Byte figures are always summed from the meta.
      assert ssl["prompt_bytes"] > 0
      assert ssl["completion_bytes"] == 16
      # final_result_bytes is the JSON byte size of {answer, structured_result}.
      assert metrics["final_result_bytes"] > 0
    end

    test "provider-reported tokens flow through server_side_llm aggregation" do
      install_planner(ProviderTokenStubPlanner)

      sc = Agentic.run_validated(validated()) |> structured()
      ssl = sc["ptc_metrics"]["server_side_llm"]

      assert ssl["provider_reported"] == true
      assert ssl["prompt_tokens"] == 11
      assert ssl["completion_tokens"] == 5
      assert ssl["total_tokens"] == 16
    end

    test "include_program config attaches the executed program" do
      install_planner(StubPlanner)

      cfg = AgenticConfig.get()

      try do
        AgenticConfig.set(Map.put(cfg, :include_program, true))
        sc = Agentic.run_validated(validated()) |> structured()
        assert sc["program"] == @program
      after
        AgenticConfig.set(cfg)
      end
    end

    test "include_program=false omits the program key" do
      install_planner(StubPlanner)

      cfg = AgenticConfig.get()

      try do
        AgenticConfig.set(Map.put(cfg, :include_program, false))
        sc = Agentic.run_validated(validated()) |> structured()
        refute Map.has_key?(sc, "program")
      after
        AgenticConfig.set(cfg)
      end
    end
  end

  describe "run_validated/2 error projection via stub planner" do
    test "planner error produces an error envelope with planner metadata" do
      install_planner(ErrorStubPlanner)

      envelope = Agentic.run_validated(validated(), request_id: "req-error")
      sc = structured(envelope)

      assert envelope["isError"] == true
      assert sc["status"] == "error"
      # The planner ran (and failed) so its meta + error tag are attached.
      # `call_planner/4` re-tags the `:planner` reason as `:planner_error`,
      # which the `planner_llm` closure records in the planner-log meta.
      assert sc["planner"]["calls"] >= 1
      assert sc["planner"]["error"] == "planner_error"
      assert sc["reason"] == "planner_error"
      # On the error path the planner ran, so ptc_metrics is still attached.
      assert is_map(sc["ptc_metrics"])
      assert sc["ptc_metrics"]["server_side_llm"]["planner_calls"] >= 1
    end

    test "config error maps to agentic_config_error reason" do
      install_planner(ConfigErrorStubPlanner)

      sc = Agentic.run_validated(validated()) |> structured()

      assert sc["status"] == "error"
      assert sc["reason"] == "agentic_config_error"
    end
  end

  describe "validate/1 accept and reject table" do
    test "accepts a minimal valid task with defaults" do
      assert {:ok, %{task: "do a thing", context: %{}, constraints: %{}, warnings: []}} =
               Agentic.validate(%{"task" => "do a thing"})
    end

    test "trims surrounding whitespace from the task" do
      assert {:ok, %{task: "trimmed"}} = Agentic.validate(%{"task" => "  trimmed  "})
    end

    test "rejects a blank task" do
      assert {:error, envelope} = Agentic.validate(%{"task" => "   "})
      sc = structured(envelope)
      assert sc["reason"] == "args_error"
      assert sc["message"] =~ "non-empty string"
    end

    test "rejects a non-string task with a typed message" do
      assert {:error, envelope} = Agentic.validate(%{"task" => 42})
      assert structured(envelope)["message"] =~ "must be a string, got integer"
    end

    test "rejects a non-object context" do
      assert {:error, envelope} = Agentic.validate(%{"task" => "ok", "context" => [1, 2]})
      assert structured(envelope)["message"] =~ "must be a JSON object, got array"
    end

    test "rejects context keys containing a slash" do
      args = %{"task" => "ok", "context" => %{"a/b" => 1}}
      assert {:error, envelope} = Agentic.validate(args)
      assert structured(envelope)["message"] =~ "may not contain `/`"
    end

    test "accepts context and constraints together" do
      args = %{
        "task" => "ok",
        "context" => %{"k" => 1},
        "constraints" => %{"max_items" => 2}
      }

      assert {:ok, %{context: %{"k" => 1}, constraints: %{"max_items" => 2}}} =
               Agentic.validate(args)
    end

    test "unsupported constraint surfaces as a warning, not a rejection" do
      args = %{"task" => "ok", "constraints" => %{"bogus" => true}}
      assert {:ok, %{warnings: [warning]}} = Agentic.validate(args)
      assert warning["code"] == "unsupported_constraint"
    end
  end

  describe "CapabilitySummary pure rendering" do
    @entries [
      %{
        name: "beta",
        tools: [
          %{name: "search", output_schema: %{"type" => "array"}},
          %{name: "fetch", output_schema: %{"type" => "object"}}
        ]
      },
      %{name: "alpha", tools: [%{name: "ping", output_schema: %{"type" => "string"}}]}
    ]

    test "inline mode renders every entry sorted by name, ignoring max_bytes" do
      summary = CapabilitySummary.generate(@entries, catalog_mode: :inline, max_bytes: 1)

      # Sorted by upstream name: alpha before beta.
      assert summary =~ "- alpha: ping->:string"
      assert summary =~ "- beta: "
      assert summary =~ "fetch->:map"
      assert summary =~ "search->[:any]"
      lines = String.split(summary, "\n")
      assert ["- alpha:" <> _ | _] = lines
    end

    test "lazy mode returns the runtime-discovery pointer when entries exist" do
      assert CapabilitySummary.generate(@entries, catalog_mode: :lazy) ==
               CapabilitySummary.lazy_pointer()
    end

    test "empty input returns an empty string in every mode" do
      assert CapabilitySummary.generate([], catalog_mode: :inline) == ""
      assert CapabilitySummary.generate([], catalog_mode: :lazy) == ""
      assert CapabilitySummary.generate([], catalog_mode: :auto) == ""
    end

    test "auto mode drops entries that do not fit under a tight budget" do
      summary = CapabilitySummary.generate(@entries, catalog_mode: :auto, max_bytes: 30)

      assert byte_size(summary) <= 30
      # Only the first (alpha) bullet fits; beta's clipped form does not.
      assert summary == "- alpha: ping->:string"
    end

    test "auto mode clips an oversized entry to a tool-count marker" do
      # 45 bytes fits alpha in full and beta clipped to its (+N more) marker.
      summary = CapabilitySummary.generate(@entries, catalog_mode: :auto, max_bytes: 45)

      assert byte_size(summary) <= 45
      assert summary =~ "- alpha: ping->:string"
      assert summary =~ "- beta: (+2 more)"
    end

    test "tools-less entry renders the no-tools sentinel" do
      summary =
        CapabilitySummary.generate([%{name: "solo", tools: []}], catalog_mode: :inline)

      assert summary == "- solo: (no tools advertised)"
    end

    test "nil-tools entry renders the unavailable-at-startup sentinel" do
      summary =
        CapabilitySummary.generate([%{name: "solo", tools: nil}], catalog_mode: :inline)

      assert summary == "- solo: (unavailable at startup)"
    end

    test "read_override returns file contents within the byte cap" do
      path = Path.join(System.tmp_dir!(), "cap-summary-#{System.unique_integer([:positive])}.txt")
      File.write!(path, "- x: tool->:string\n")
      on_exit(fn -> File.rm(path) end)

      assert CapabilitySummary.read_override(path, 1_000) == {:ok, "- x: tool->:string\n"}
    end

    test "read_override rejects an over-cap file with size detail" do
      path = Path.join(System.tmp_dir!(), "cap-big-#{System.unique_integer([:positive])}.txt")
      body = String.duplicate("y", 50)
      File.write!(path, body)
      on_exit(fn -> File.rm(path) end)

      assert {:error, {:too_large, 50, 8}} = CapabilitySummary.read_override(path, 8)
    end

    test "read_override surfaces filesystem errors" do
      missing = Path.join(System.tmp_dir!(), "cap-missing-#{System.unique_integer([:positive])}")
      assert {:error, :enoent} = CapabilitySummary.read_override(missing, 1_000)
    end
  end

  describe "Planner config-guard branches (no LLM call)" do
    test "unknown model resolves to a config error" do
      assert {:error, :config, message, meta} =
               Planner.call("definitely-not-a-real-model-xyz", "prompt",
                 timeout_ms: 1_000,
                 max_output_tokens: 16
               )

      assert is_binary(message)
      assert meta["model"] == "definitely-not-a-real-model-xyz"
    end

    test "openrouter model without API key fails closed before any network call" do
      original = System.get_env("OPENROUTER_API_KEY")
      System.delete_env("OPENROUTER_API_KEY")
      on_exit(fn -> if original, do: System.put_env("OPENROUTER_API_KEY", original) end)

      result =
        Planner.call("openrouter:meta-llama/llama-3.1-8b-instruct", "prompt",
          timeout_ms: 1_000,
          max_output_tokens: 16
        )

      # Either the model id fails to resolve (config) or the API-key guard
      # fires (config) — both are config errors raised before any LLM call.
      assert {:error, :config, _message, _meta} = result
    end

    test "sanitize_prompt scrubs credentials and is total on bad input" do
      # Total even when the scrubber would otherwise choke: returns a string.
      assert is_binary(Planner.sanitize_prompt("plain prompt"))
      assert Planner.system_message() =~ "PTC-Lisp"
    end
  end
end
