defmodule PtcRunner.GatewayFrontendTest do
  use ExUnit.Case, async: false

  alias PtcRunner.GatewayFrontend
  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CommandParser
  alias PtcRunner.Kernel.ServingTemplate

  @input_schema ~S({"type":"object","properties":{"n":{"type":"integer"}},"required":["n"],"additionalProperties":false})
  @result_schema ~S({"type":"object","properties":{"answer":{"type":"integer"}},"required":["answer"],"additionalProperties":false})

  setup do
    tmp = Path.join(System.tmp_dir!(), "ptc-gateway-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    {:ok, tmp: tmp}
  end

  test "compiles two read-only tools and refuses write-effect configuration", %{tmp: tmp} do
    echo =
      write_app(
        tmp,
        "echo",
        ~S|(ns app) (defn run {:effect :read} [input] (return {"answer" (get input "n")}))|
      )

    double =
      write_app(
        tmp,
        "double",
        ~S|(ns app) (defn run {:effect :read} [input] (return {"answer" (* 2 (get input "n"))}))|
      )

    write =
      write_app(
        tmp,
        "write",
        ~S|(ns app) (defn run {:effect :write} [input] (return {"answer" 1}))|
      )

    config = Path.join(tmp, "gateway.json")
    write_config!(config, [echo_tool(echo, "echo"), echo_tool(double, "double")])

    assert {:ok, compiled} = GatewayFrontend.compile(config)
    names = Enum.map(compiled.tools, & &1.name)
    assert Enum.sort(names) == ["double", "echo"]

    echo = Enum.find(compiled.tools, &(&1.name == "echo"))
    double = Enum.find(compiled.tools, &(&1.name == "double"))
    assert {:ok, %{"answer" => 1}} = echo.call.(%{"n" => 1})
    assert {:ok, %{"answer" => 4}} = double.call.(%{"n" => 2})

    write_config!(config, [placeholder_tool(write, "write")])
    assert {:error, :effect_not_read} = GatewayFrontend.compile(config)
  end

  test "refuses a digest mismatch", %{tmp: tmp} do
    echo =
      write_app(
        tmp,
        "echo",
        ~S|(ns app) (defn run {:effect :read} [input] (return {"answer" (get input "n")}))|
      )

    tool = echo_tool(echo, "echo")
    bad = %{tool | application_content_digest: String.duplicate("a", 64)}
    config = Path.join(tmp, "gateway.json")
    write_config!(config, [bad])

    assert {:error, :digest_mismatch} = GatewayFrontend.compile(config)
  end

  test "parser and help declare serve" do
    assert {:ok, arguments} = CommandParser.parse(["serve", "gateway.json"])
    assert arguments.command == :serve
  end

  defp write_app(tmp, name, source) do
    dir = Path.join(tmp, name)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "ptc.json"),
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "app", "path" => "workflow.clj"}],
          "entry" => "app/run"
        },
        "input" => %{"value" => %{"n" => 1}},
        "contracts" => %{
          "input_schema" => %{"path" => "input.schema.json"},
          "result_schema" => %{"path" => "result.schema.json"}
        },
        "providers" => %{"workflow" => [], "mission" => []}
      })
    )

    File.write!(Path.join(dir, "workflow.clj"), source)
    File.write!(Path.join(dir, "input.schema.json"), @input_schema)
    File.write!(Path.join(dir, "result.schema.json"), @result_schema)
    dir
  end

  defp echo_tool(directory, name) do
    assert {:ok, package} = ApplicationPackage.package_directory(Path.join(directory, "ptc.json"))
    assert {:ok, template} = ServingTemplate.compile(package)

    %{
      name: name,
      description: name,
      directory: directory,
      application_content_digest: template.package.application_content_digest,
      effective_application_digest: template.effective_application_digest
    }
  end

  defp placeholder_tool(directory, name) do
    %{
      name: name,
      description: name,
      directory: directory,
      application_content_digest: String.duplicate("b", 64),
      effective_application_digest: "sha256:" <> String.duplicate("b", 64)
    }
  end

  defp write_config!(path, tools) do
    encoded = %{
      "version" => 1,
      "admission" => %{"max_in_flight" => 2},
      "tools" =>
        Map.new(tools, fn tool ->
          {tool.name,
           %{
             "source" => %{"directory" => tool.directory},
             "description" => tool.description,
             "digests" => %{
               "application_content_digest" => tool.application_content_digest,
               "effective_application_digest" => tool.effective_application_digest,
               "providers" => []
             }
           }}
        end)
    }

    File.write!(path, Jason.encode!(encoded))
  end
end
