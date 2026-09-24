defmodule PtcRunner.TestSupport.ServingTemplateHelpers do
  @moduledoc false

  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ServingTemplate

  @schema %{
    "type" => "object",
    "properties" => %{"answer" => %{"type" => "integer"}},
    "required" => ["answer"],
    "additionalProperties" => false
  }
  @source "(ns app) (defn run {:effect :read} [input] (return input))"

  def build(path, opts \\ []),
    do: ServingTemplate.from_directory(path, Limits.installed_defaults(), opts)

  def fixture(dir, changes \\ %{}, source \\ @source) do
    File.mkdir_p!(dir)

    manifest =
      Map.merge(
        %{
          "version" => 1,
          "workflow" => %{
            "components" => [%{"id" => "app", "path" => "workflow.clj"}],
            "entry" => "app/run"
          },
          "input" => %{"path" => "missing.json"},
          "contracts" => %{
            "input_schema" => %{"path" => "schema.json"},
            "result_schema" => %{"path" => "schema.json"}
          }
        },
        changes
      )

    File.write!(Path.join(dir, "workflow.clj"), source)
    File.write!(Path.join(dir, "schema.json"), Jason.encode!(@schema))
    path = Path.join(dir, "app.json")
    File.write!(path, Jason.encode!(manifest))
    path
  end
end
