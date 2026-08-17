defmodule PtcRunner.Kernel.ServingTemplateTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.ServingTemplate

  @input_schema ~S({"type":"object","properties":{"n":{"type":"integer"}},"required":["n"],"additionalProperties":false})
  @result_schema ~S({"type":"object","properties":{"answer":{"type":"integer"}},"required":["answer"],"additionalProperties":false})

  test "compiles a provider-free package and returns CommandOutcome without recompilation" do
    documents = serving_documents()
    assert {:ok, package} = ApplicationPackage.package_memory("app.json", documents)
    assert {:ok, template} = ServingTemplate.compile(package)
    assert ServingTemplate.valid?(template)

    assert {:ok, first} = ServingTemplate.call(template, %{"n" => 21})
    assert {:ok, second} = ServingTemplate.call(template, %{"n" => 2})

    assert CommandOutcome.valid?(first)
    assert first.exit_status == 0
    assert CommandOutcome.to_map(first)["result"]["value"] == %{"answer" => 42}
    assert CommandOutcome.to_map(second)["result"]["value"] == %{"answer" => 4}

    assert {:ok, replay} =
             ApplicationPackage.request_memory("app.json", documents, result_projection: :json)

    assert {:ok, catalog} =
             InstallationCatalog.new(%{}, installed_limits: replay.package.installed_limits)

    assert {:ok, prepared} = RunCoordinator.prepare(replay, catalog)

    assert template.effective_application_digest == prepared.effective_application_digest

    assert template.package.application_content_digest ==
             replay.package.application_content_digest
  end

  test "skips a missing manifest input that would fail request acquisition" do
    documents = serving_documents(input: %{"path" => "missing-input.json"})
    assert {:error, _reason} = ApplicationPackage.request_memory("app.json", documents)
    assert {:ok, package} = ApplicationPackage.package_memory("app.json", documents)
    assert {:ok, template} = ServingTemplate.compile(package)
    assert {:ok, outcome} = ServingTemplate.call(template, %{"n" => 1})
    assert CommandOutcome.to_map(outcome)["result"]["value"] == %{"answer" => 2}
  end

  test "refuses a missing result contract" do
    documents = serving_documents(result?: false)
    assert {:ok, package} = ApplicationPackage.package_memory("app.json", documents)
    assert {:error, :serving_contracts_required} = ServingTemplate.compile(package)
  end

  test "fails closed when a local export is not provably read" do
    unknown = serving_documents(source: "(ns app) (defn run [input] (return {\"answer\" 1}))")

    write =
      serving_documents(
        source: ~S|(ns app) (defn run {:effect :write} [input] (return {"answer" 1}))|
      )

    assert {:ok, unknown_package} = ApplicationPackage.package_memory("app.json", unknown)
    assert {:error, :effect_not_read} = ServingTemplate.compile(unknown_package)

    assert {:ok, write_package} = ApplicationPackage.package_memory("app.json", write)
    assert {:error, :effect_not_read} = ServingTemplate.compile(write_package)
  end

  test "fails closed on write exports whose Lisp namespace differs from the component id" do
    documents =
      serving_documents(
        component_id: "different-component-id",
        source: """
        (ns app)
        (defn run {:effect :read} [input] (return {"answer" 1}))
        (defn mutate {:effect :write} [input] (return {"answer" 1}))
        """
      )

    assert {:ok, package} = ApplicationPackage.package_memory("app.json", documents)
    assert {:error, :effect_not_read} = ServingTemplate.compile(package)
  end

  test "binds frozen inspection capture onto the per-call publication authority" do
    documents = serving_documents()
    assert {:ok, package} = ApplicationPackage.package_memory("app.json", documents)
    assert {:ok, template} = ServingTemplate.compile(package, inspection_capture: true)
    assert template.policy.inspection_capture

    assert {:ok, outcome} = ServingTemplate.call(template, %{"n" => 1})
    envelope = CommandOutcome.to_map(outcome)
    assert outcome.exit_status == 0
    refute envelope["error"]["code"] == "internal_error"
    assert envelope["artifact_state"]["inspection"] in ["written", "not_written"]
  end

  test "compiles provider-backed packages and requires HostRuntime for calls" do
    documents =
      serving_documents(providers: %{"workflow" => [%{"name" => "selected"}], "mission" => []})

    assert {:ok, package} = ApplicationPackage.package_memory("app.json", documents)

    assert {:error, %CommandDiagnostic{code: :provider_unknown}} =
             ServingTemplate.compile(package)
  end

  test "call preserves input-contract classification and invalid_input separately" do
    documents = serving_documents()
    assert {:ok, package} = ApplicationPackage.package_memory("app.json", documents)
    assert {:ok, template} = ServingTemplate.compile(package)

    assert {:error, %CommandOutcome{} = contract_outcome} = ServingTemplate.call(template, %{})
    contract_error = CommandOutcome.to_map(contract_outcome)["error"]
    assert contract_outcome.exit_status == 3
    assert contract_error["code"] == "input_contract_failed"
    assert contract_error["path"] == "/n"

    assert {:error, %CommandOutcome{} = invalid_outcome} =
             ServingTemplate.call(template, %{"n" => :not_json})

    invalid_error = CommandOutcome.to_map(invalid_outcome)["error"]
    assert invalid_outcome.exit_status == 3
    assert invalid_error["code"] == "input_invalid"
  end

  defp serving_documents(opts \\ []) do
    source =
      Keyword.get(
        opts,
        :source,
        ~S|(ns app) (defn run {:effect :read} [input] (return {"answer" (* 2 (get input "n"))}))|
      )

    component_id = Keyword.get(opts, :component_id, "app")
    input = Keyword.get(opts, :input, %{"value" => %{"n" => 1}})
    providers = Keyword.get(opts, :providers, %{"workflow" => [], "mission" => []})
    result? = Keyword.get(opts, :result?, true)

    contracts =
      if result? do
        %{
          "input_schema" => %{"path" => "input.schema.json"},
          "result_schema" => %{"path" => "result.schema.json"}
        }
      else
        %{"input_schema" => %{"path" => "input.schema.json"}}
      end

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => component_id, "path" => "workflow.clj"}],
        "entry" => "app/run"
      },
      "input" => input,
      "contracts" => contracts,
      "providers" => providers
    }

    documents = %{
      "app.json" => Jason.encode!(manifest),
      "workflow.clj" => source,
      "input.schema.json" => @input_schema
    }

    if result?,
      do: Map.put(documents, "result.schema.json", @result_schema),
      else: documents
  end
end
