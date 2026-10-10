defmodule PtcRunner.Scripts.LayerGateTest do
  use ExUnit.Case, async: true
  @moduletag :operator
  @moduletag :nightly

  @jason Path.expand("../../deps/jason", __DIR__)
  @task Path.expand("../../lib/mix/tasks/ptc.check_layers.ex", __DIR__)

  test "compiled compile, export and runtime edges obey the shrinking baseline" do
    root = Path.join(System.tmp_dir!(), "layer-gate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(Path.join(root, "mix.exs"), """
    defmodule LayerFixture.MixProject do
      use Mix.Project
      def project, do: [app: :layer_fixture, version: "0.1.0", deps: [{:jason, path: #{inspect(@jason)}}]]
    end
    """)

    baseline = Path.join(root, "baseline.json")
    File.write!(baseline, "[]")

    for body <- [
          "def run, do: PtcRunner.Kernel.GateFixture.run()",
          "def run(%PtcRunner.Kernel.GateFixture{}), do: :ok",
          "@value PtcRunner.Kernel.GateFixture.run(); def run, do: @value"
        ] do
      File.write!(Path.join(root, "lib/kernel.ex"), """
      defmodule PtcRunner.Kernel.GateFixture do
        defstruct []
        def run, do: :ok
      end
      """)

      File.write!(Path.join(root, "lib/lisp.ex"), """
      defmodule PtcRunner.Lisp.GateFixture do
        #{body}
      end
      """)

      assert {output, 1} = run(root, baseline)

      assert output =~
               "new forbidden edge: PtcRunner.Lisp.GateFixture -> PtcRunner.Kernel.GateFixture"
    end

    File.write!(baseline, """
    [{"from":"PtcRunner.Lisp.GateFixture","to":"PtcRunner.Kernel.GateFixture","issue":2230}]
    """)

    assert {_, 0} = run(root, baseline)

    File.write!(Path.join(root, "lib/kernel.ex"), """
    defmodule PtcRunner.Kernel.GateFixture do
      def run, do: PtcRunner.LiveStatus.GateFixture.run()
    end
    """)

    File.write!(Path.join(root, "lib/frontend.ex"), """
    defmodule PtcRunner.LiveStatus.GateFixture do
      def run, do: :ok
    end
    """)

    File.write!(Path.join(root, "lib/lisp.ex"), """
    defmodule PtcRunner.Lisp.GateFixture do
      def run, do: :ok
    end
    """)

    assert {output, 1} = run(root, baseline)

    assert output =~
             "stale baseline edge: PtcRunner.Lisp.GateFixture -> PtcRunner.Kernel.GateFixture"

    assert output =~
             "new forbidden edge: PtcRunner.Kernel.GateFixture -> PtcRunner.LiveStatus.GateFixture"

    File.write!(baseline, "[]")

    File.write!(Path.join(root, "lib/kernel.ex"), """
    defmodule PtcRunner.Kernel.GateFixture do
      def run, do: :ok
    end
    """)

    File.write!(Path.join(root, "lib/neutral.ex"), """
    defmodule PtcRunner.ChildEnvironment do
      def run, do: PtcRunner.BuildIdentity.run()
    end
    """)

    File.write!(Path.join(root, "lib/identity.ex"), """
    defmodule PtcRunner.BuildIdentity do
      def run, do: PtcRunner.Kernel.GateFixture.run()
    end
    """)

    assert {output, 1} = run(root, baseline)
    assert output =~ "new forbidden edge: PtcRunner.BuildIdentity -> PtcRunner.Kernel.GateFixture"
    refute output =~ "PtcRunner.ChildEnvironment -> PtcRunner.BuildIdentity"

    File.write!(Path.join(root, "lib/identity.ex"), """
    defmodule PtcRunner.BuildIdentity do
      def run, do: {String.length("neutral"), :crypto.hash(:sha256, "neutral")}
    end
    """)

    assert {_, 0} = run(root, baseline)

    File.write!(Path.join(root, "lib/identity.ex"), """
    defmodule PtcRunner.BuildIdentity do
      def run, do: Jason.encode!(%{})
    end
    """)

    assert {output, 1} = run(root, baseline)
    assert output =~ "new forbidden edge: PtcRunner.BuildIdentity -> Jason"

    File.write!(Path.join(root, "lib/unknown.ex"), """
    defmodule PtcRunner.Utf8.NotInfrastructure do
      def run, do: :ok
    end
    """)

    assert {output, 1} = run(root, baseline)
    assert output =~ "unclassified module: PtcRunner.Utf8.NotInfrastructure"
  end

  defp run(root, baseline) do
    System.cmd(
      "mix",
      [
        "run",
        "--no-start",
        "-r",
        @task,
        "-e",
        "Mix.Tasks.Ptc.CheckLayers.run([\"--baseline\", #{inspect(baseline)}])"
      ],
      cd: root,
      stderr_to_stdout: true,
      env: [{"MIX_ENV", "dev"}]
    )
  end
end
