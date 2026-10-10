defmodule PtcRunner.Kernel.DeclaredReadEffectValidatorTest do
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.ServingTemplateHelpers

  alias PtcRunner.Kernel

  alias PtcRunner.Kernel.{
    Component,
    DeclaredReadEffectValidator,
    HostConfig,
    HostInstallation,
    InstallationCatalog,
    Library,
    RunAdmission,
    ServingOutcome,
    ServingTemplate
  }

  @workflow %{
    "components" => [
      %{"id" => "app", "path" => "workflow.clj", "dependencies" => ["kernel"]},
      %{"library" => "kernel"}
    ],
    "entry" => "app/run"
  }

  @moduletag :tmp_dir

  test "read eval-source and mission inspection helpers validate and execute", %{tmp_dir: dir} do
    path =
      fixture(
        dir,
        %{
          "workflow" => @workflow,
          "missions" => %{
            "default" => %{"components" => [%{"id" => "helper", "path" => "helper.clj"}]}
          }
        },
        ~S|(ns app) (defn run {:effect :read} [input] (return {"answer" (get (kernel/eval-source "default" "(return (+ 1 2))") :value)}))|
      )

    File.write!(
      Path.join(dir, "helper.clj"),
      ~S|(ns helper) (defn usage {:effect :read :signature "() -> :map"} [] (tool/runtime-usage {}))|
    )

    assert {:ok, template} = build(path)

    assert :ok =
             DeclaredReadEffectValidator.validate(
               template.workflow.bundle,
               Map.new(template.missions, fn {name, env} -> {name, env.bundle} end),
               template.package.missions,
               []
             )

    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    outcome = ServingTemplate.call(template, %{"answer" => 3}, host)
    assert ServingOutcome.code(outcome) == :success
    assert ServingOutcome.value(outcome) == {:ok, %{"answer" => 3}}
  end

  test "prepared validation joins all mission grants and classifies implicit routes" do
    {:ok, kernel} = Library.component("kernel")

    {:ok, component} =
      Component.new(
        id: "app",
        dependencies: ["kernel"],
        source:
          ~S|(ns app) (defn run {:effect :read} [x] (kernel/eval-source "default" "(+ 1 2)"))|
      )

    {:ok, workflow} = Kernel.compile_bundle([component, kernel])

    {:ok, helper} =
      Component.new(
        id: "helper",
        source:
          ~S|(ns helper) (defn usage {:effect :read :signature "() -> :map"} [] (tool/runtime-usage {}))|
      )

    {:ok, mission} = Kernel.compile_bundle([helper])

    for effect <- [:read, :write, :unknown] do
      preparations = [
        %{destination: :mission, index: 0, capability_effects: %{"unused" => effect}}
      ]

      result =
        DeclaredReadEffectValidator.validate_prepared(
          workflow,
          %{"default" => mission},
          %{"default" => %{provider_occurrences: [0]}},
          preparations
        )

      if effect == :read do
        assert result == :ok
      else
        assert {:error, {:declared_read_effect_violation, "app/run", ^effect}} = result
      end
    end
  end

  test "model calls retain their unknown effect", %{
    tmp_dir: dir
  } do
    path =
      fixture(
        dir,
        %{
          "providers" => %{"workflow" => [%{"name" => "model", "config" => %{}}]}
        },
        ~S|(ns app) (defn run {:effect :read} [input] (return (tool/llm-request {})))|
      )

    host_path = Path.join(dir, "host.json")

    File.write!(
      host_path,
      Jason.encode!(%{
        "credentials" => %{"key" => %{"literal" => "fixture-secret"}},
        "install" => %{
          "model" => %{
            "source" => "llm",
            "model" => "fixture:model",
            "credential" => "key",
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
            "installation_revision" => "v1"
          }
        }
      })
    )

    {:ok, host} = HostConfig.load(host_path)
    {:ok, catalog} = HostInstallation.catalog(host)
    on_exit(fn -> InstallationCatalog.close(catalog) end)
    assert {:error, :declared_read_effect_violation} = build(path, providers: catalog)
  end

  test "provider-bearing read entries check unreferenced mission exports and grants", %{
    tmp_dir: dir
  } do
    path =
      fixture(dir, %{
        "workflow" => @workflow,
        "missions" => %{
          "default" => %{
            "components" => [%{"id" => "helper", "path" => "helper.clj"}],
            "providers" => ["remote"]
          }
        },
        "providers" => %{
          "mission" => [%{"name" => "remote", "config" => %{"allow" => ["remote.echo"]}}]
        }
      })

    host_path = Path.join(dir, "host.json")

    for {export_effect, capability_effect} <- [
          {:read, :read},
          {:write, :read},
          {:unknown, :read},
          {:read, :write}
        ] do
      workflow_source =
        if {export_effect, capability_effect} == {:read, :read} do
          ~S|(ns app) (defn run {:effect :read} [input] (return {"answer" (get (kernel/eval-source "default" "(return (+ 1 2))") :value)}))|
        else
          "(ns app) (defn run {:effect :read} [input] (return input))"
        end

      File.write!(Path.join(dir, "workflow.clj"), workflow_source)

      File.write!(
        Path.join(dir, "helper.clj"),
        "(ns helper) (defn unused {:effect :#{export_effect}} [x] x)"
      )

      File.write!(
        host_path,
        Jason.encode!(%{
          "install" => %{
            "remote" => %{
              "source" => "mcp",
              "installation_revision" => "v1",
              "transport" => %{"type" => "stdio", "command" => "/bin/false"},
              "tools" => %{
                "echo" => %{"as" => "remote.echo", "effect" => Atom.to_string(capability_effect)}
              }
            }
          }
        })
      )

      {:ok, host} = HostConfig.load(host_path)
      {:ok, catalog} = HostInstallation.catalog(host)

      try do
        if {export_effect, capability_effect} == {:read, :read} do
          assert {:ok, %{effect: :read}} = build(path, providers: catalog)
        else
          result = build(path, providers: catalog)

          assert result == {:error, :declared_read_effect_violation},
                 inspect({export_effect, capability_effect, result})
        end
      after
        InstallationCatalog.close(catalog)
      end
    end
  end
end
