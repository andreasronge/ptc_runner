defmodule PtcRunner.Kernel.TutorialExamplesContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  @examples Path.expand("../../../examples/kernel-tutorial", __DIR__)
  @host Path.join(@examples, "ptc-host.json")
  @cost_budget_host Path.join(@examples, "ptc-host-cost-budget.json")
  @viewer_examples Path.expand("../../../scripts/labs/viewer-demo", __DIR__)
  @support_triage Path.expand("../../../examples/support-triage", __DIR__)

  test "models in shipped runnable examples belong to ReqLLM's catalog" do
    installations = host_installations()

    # A hand-written host list silently stops guarding the moment an example
    # gains a host document, which is how three `debug-a-failed-run` hosts came
    # to pin a model outside the catalog. Derive the list from the tree instead.
    assert length(installations) >= 12

    for {host, alias_name, model} <- installations do
      assert {:ok, _catalog_model} = LLMDB.model(model), "#{host} installs #{alias_name}"
    end
  end

  defp host_installations do
    ["examples", "scripts/labs"]
    |> Enum.flat_map(&Path.wildcard(Path.join([@repo_root, &1, "**", "*.json"])))
    |> Enum.flat_map(fn path ->
      case Jason.decode(File.read!(path)) do
        {:ok, %{"install" => install}} when is_map(install) ->
          for {alias_name, %{"model" => model}} <- install, do: {path, alias_name, model}

        _ ->
          []
      end
    end)
    |> Enum.sort()
  end

  test "the cost-budget tutorial label reports its dedicated host model" do
    model = @cost_budget_host |> decode!() |> get_in(["install", "deepseek", "model"])
    manifest = decode!(Path.join([@examples, "06-cost-budget", "ptc.json"]))

    assert manifest["labels"]["model"] == model
  end

  test "live tutorial labels report the model installed by the host" do
    model = @host |> decode!() |> get_in(["install", "deepseek", "model"])

    for example <- ~w(02-deepseek-extract 03-file-agent 04-multi-turn-agent 07-parallel-fan-out) do
      manifest = decode!(Path.join([@examples, example, "ptc.json"]))
      assert manifest["labels"]["model"] == model
    end
  end

  test "the multi-turn tutorial relies on the default Kernel run clocks" do
    manifest = decode!(Path.join([@examples, "04-multi-turn-agent", "ptc.json"]))

    refute Map.has_key?(manifest, "limits")
  end

  test "the file-agent wrapper publishes the MCP result shape to the model" do
    source = File.read!(Path.join([@examples, "03-file-agent", "files.clj"]))

    assert source =~
             "-> {items [{byte_offset :int, text :string}], next_cursor :string?, content_hash :string}"
  end

  test "shipped prompt-visible example components do not hide stable results behind any" do
    examples_root = Path.expand("../../../examples", __DIR__)

    for path <- Path.wildcard(Path.join(examples_root, "**/*.clj")),
        source = File.read!(path),
        source =~ ":visibility :prompt" do
      refute source =~ "-> :any", path
    end
  end

  test "support-triage labels report the model installed by the host" do
    model =
      @support_triage
      |> Path.join("ptc-host.json")
      |> decode!()
      |> get_in(["install", "deepseek", "model"])

    for step <- ~w(01-one-question 02-domain-api 03-specialists) do
      manifest = decode!(Path.join([@support_triage, step, "ptc.json"]))
      assert manifest["labels"]["model"] == model
    end
  end

  test "viewer example labels report the model installed by the host" do
    model =
      @viewer_examples
      |> Path.join("ptc-host.json")
      |> decode!()
      |> get_in(["install", "deepseek", "model"])

    for journey <- ~w(01-recovery 02-bulk 03-limits 04-loop-limit 05-memory) do
      manifest = decode!(Path.join(@viewer_examples, "#{journey}.json"))
      assert manifest["labels"]["model"] == model
    end
  end

  test "the viewer memory journey preserves feedback and forces a terminal demo error" do
    manifest = decode!(Path.join(@viewer_examples, "05-memory.json"))

    assert manifest["input"]["value"]["max_turns"] == 2
    assert manifest["workflow"]["entry"] == "demo.agent/run-terminal-error"
  end

  defp decode!(path), do: path |> File.read!() |> Jason.decode!()
end
