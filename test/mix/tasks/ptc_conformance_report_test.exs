defmodule Mix.Tasks.Ptc.ConformanceReportTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Ptc.ConformanceReport

  test "the inventory gate rejects supported Java entries without explicit cases" do
    inventory = [
      %{
        namespace: "java.lang.Math",
        symbol: "Math/sqrt",
        status: :supported,
        compatibility_target: "Java"
      }
    ]

    assert_raise Mix.Error, ~r/java\.lang\.Math\/Math\/sqrt/, fn ->
      ConformanceReport.validate_supported_java_coverage!(inventory, [])
    end

    assert_raise Mix.Error, ~r/java\.lang\.Math\/Math\/sqrt/, fn ->
      ConformanceReport.validate_supported_java_coverage!(inventory, [
        %{namespace: "java.lang.Math", vars: ["Math/sqrt"], policy: :unsupported}
      ])
    end

    assert :ok =
             ConformanceReport.validate_supported_java_coverage!(inventory, [
               %{namespace: "java.lang.Math", vars: ["Math/sqrt"], policy: :match}
             ])
  end
end
