defmodule PtcRunner.Kernel.ServingTemplateTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.ApplicationPackage
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

  test "refuses provider-backed applications until host runtime exists" do
    documents =
      serving_documents(providers: %{"workflow" => [%{"name" => "selected"}], "mission" => []})

    assert {:ok, package} = ApplicationPackage.package_memory("app.json", documents)
    assert {:error, :providers_not_supported} = ServingTemplate.compile(package)
  end

  test "call rejects input that fails the frozen contract" do
    documents = serving_documents()
    assert {:ok, package} = ApplicationPackage.package_memory("app.json", documents)
    assert {:ok, template} = ServingTemplate.compile(package)
    assert {:error, %CommandOutcome{} = outcome} = ServingTemplate.call(template, %{})
    assert outcome.exit_status == 3
    assert CommandOutcome.to_map(outcome)["error"]["code"] == "input_contract_failed"
  end

  defp serving_documents(opts \\ []) do
    source =
      Keyword.get(
        opts,
        :source,
        ~S|(ns app) (defn run {:effect :read} [input] (return {"answer" (* 2 (get input "n"))}))|
      )

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
        "components" => [%{"id" => "app", "path" => "workflow.clj"}],
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
