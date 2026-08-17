defmodule PtcViewer.LiveLaunchTest do
  use ExUnit.Case, async: true

  alias PtcViewer.LiveLaunch
  alias PtcViewer.LiveStore

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "ptc.json"), "{}")
    {:ok, store} = LiveStore.start(self())

    adapter = fn _request, _report -> {0, "ok"} end
    %{spec: %{manifest: "ptc.json", cwd: tmp_dir, adapter: adapter}, store: store}
  end

  describe "validate/1" do
    test "accepts a fixed manifest and host adapter", %{spec: spec} do
      assert :ok = LiveLaunch.validate(spec)
      assert :ok = LiveLaunch.validate(Map.put(spec, :input, %{"from" => "host"}))
    end

    test "rejects a missing or malformed adapter", %{spec: spec} do
      assert {:error, :invalid_launch_config} = LiveLaunch.validate(Map.delete(spec, :adapter))

      assert {:error, :invalid_launch_config} =
               LiveLaunch.validate(Map.put(spec, :adapter, fn _request -> :ok end))

      assert {:error, :invalid_launch_config} =
               LiveLaunch.validate(Map.put(spec, :input, "not-an-object"))
    end
  end

  describe "prepare/3" do
    test "is side-effect free until the single-flight gate invokes it", %{
      spec: spec,
      store: store
    } do
      existing = Path.join(spec.cwd, "live-input.json")
      File.write!(existing, "operator-owned")

      assert {:ok, run} = LiveLaunch.prepare(spec, %{"value" => 42}, store)
      assert is_function(run, 0)
      assert File.read!(existing) == "operator-owned"
      assert Enum.sort(File.ls!(spec.cwd)) == ["live-input.json", "ptc.json"]
    end

    test "invokes the adapter in-process and streams frames directly", %{
      spec: spec,
      store: store
    } do
      test_process = self()

      adapter = fn request, report ->
        send(test_process, {:request, request})
        :ok = report.("run-direct", %{phase: "running", seq: 0})
        {0, "completed"}
      end

      assert {:ok, run} =
               LiveLaunch.prepare(Map.put(spec, :adapter, adapter), %{"value" => 42}, store)

      assert {0, "completed"} = run.()
      assert_receive {:request, {:workflow, %{input: input_name}}}
      assert String.starts_with?(input_name, "ptc-viewer-input-")
      refute File.exists?(Path.join(spec.cwd, input_name))

      assert [%{"phase" => "running", "run_id" => "run-direct", "seq" => 0}] =
               LiveStore.snapshot(store)
    end

    test "temporary input names satisfy the application logical-name grammar" do
      names = Enum.map(1..100, fn _index -> LiveLaunch.temporary_input_name() end)

      assert Enum.uniq(names) == names
      assert Enum.all?(names, &Regex.match?(~r/\A[a-z0-9][a-z0-9._-]{0,127}\z/, &1))
    end
  end

  describe "prepare_mission/4" do
    test "sends a semantic mission request to the same adapter", %{spec: spec, store: store} do
      test_process = self()

      adapter = fn request, _report ->
        send(test_process, {:request, request})
        {0, "42"}
      end

      assert {:ok, run} =
               LiveLaunch.prepare_mission(
                 Map.put(spec, :adapter, adapter),
                 "review",
                 "(+ 40 2)",
                 store
               )

      assert {0, "42"} = run.()
      assert_receive {:request, {:mission, %{name: "review", expression: "(+ 40 2)"}}}
    end

    test "refuses invalid mission names and blank expressions", %{spec: spec, store: store} do
      for name <- ["--host-config", "Review", "", "a b", "../escape"] do
        assert {:error, :invalid_mission} =
                 LiveLaunch.prepare_mission(spec, name, "(dir)", store)
      end

      assert {:error, :invalid_mission} =
               LiveLaunch.prepare_mission(spec, "review", "   ", store)
    end

    test "retains a byte-bounded valid UTF-8 output tail", %{spec: spec, store: store} do
      output = String.duplicate("€", 667)
      adapter = fn _request, _report -> {0, output} end

      assert {:ok, run} =
               LiveLaunch.prepare_mission(
                 Map.put(spec, :adapter, adapter),
                 "review",
                 "(+ 40 2)",
                 store
               )

      assert {0, tail} = run.()
      assert String.valid?(tail)
      assert byte_size(tail) <= 2_000
      assert String.ends_with?(output, tail)
    end

    test "rejects invalid UTF-8 adapter output", %{spec: spec, store: store} do
      adapter = fn _request, _report -> {0, <<255>>} end

      assert {:ok, run} =
               LiveLaunch.prepare_mission(
                 Map.put(spec, :adapter, adapter),
                 "review",
                 "(+ 40 2)",
                 store
               )

      assert {1, "viewer launch failed: invalid adapter result"} = run.()
    end
  end
end
