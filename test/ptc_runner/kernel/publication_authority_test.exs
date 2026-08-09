defmodule PtcRunner.Kernel.PublicationAuthorityTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandPreparation
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.PublicationHandle
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.TraceLog

  @tag :tmp_dir
  test "phase six reserves exact normal trace names before provider activity", %{tmp_dir: dir} do
    File.mkdir!(Path.join(dir, "traces"))
    application = application!(dir, "normal")

    assert {:ok, preparation} =
             CommandEngine.prepare(["run", application, "--trace-dir", Path.join(dir, "traces")])

    assert ProviderActivity.value(preparation.prepared_run.provider_activity) == false
    assert {:ok, authority} = CommandEngine.preflight(preparation)
    assert ProviderActivity.value(preparation.prepared_run.provider_activity) == false

    trace = Keyword.fetch!(PublicationAuthority.destination_options(authority), :trace)
    assert trace == Path.join([dir, "traces", preparation.run_ref <> ".jsonl"])
    assert File.lstat(trace) == {:error, :enoent}
    assert :ok = PublicationAuthority.abort(authority)
    assert :ok = CommandPreparation.close(preparation)
  end

  @tag :tmp_dir
  test "private phase six reserves owner-only recovery and private trace names", %{tmp_dir: dir} do
    traces = Path.join(dir, "traces")
    File.mkdir!(traces)
    application = application!(dir, "private", %{"events" => %{"policy" => "private"}})
    output = Path.join(dir, "answer.json")

    assert {:ok, preparation} =
             CommandEngine.prepare([
               "run",
               application,
               "--trace-dir",
               traces,
               "--private-output",
               output
             ])

    assert {:ok, authority} = CommandEngine.preflight(preparation)
    options = PublicationAuthority.destination_options(authority)
    trace = Keyword.fetch!(options, :trace)
    assert trace == Path.join([traces, preparation.run_ref <> ".private.jsonl"])
    assert Keyword.fetch!(options, :private_output) == output

    recovery = PublicationAuthority.handles(authority) |> Map.fetch!(:recovery)

    assert Path.basename(PublicationHandle.path(recovery)) ==
             ".ptc-private-result-#{preparation.run_ref}.json"

    assert {:ok, %{mode: mode}} = File.stat(PublicationHandle.path(recovery))
    assert Bitwise.band(mode, 0o777) == 0o600

    assert :ok = PublicationAuthority.abort(authority)
    assert :ok = CommandPreparation.close(preparation)
    refute File.exists?(PublicationHandle.path(recovery))
  end

  @tag :tmp_dir
  test "trace-directory destinations publish and discover exact normal and private names", %{
    tmp_dir: dir
  } do
    Enum.each([:normal, :private], fn policy ->
      traces = Path.join(dir, "#{policy}-traces")
      File.mkdir!(traces)

      overrides =
        if policy == :private,
          do: %{"events" => %{"policy" => "private"}},
          else: %{}

      application = application!(dir, "#{policy}-discovery", overrides)

      argv =
        ["run", application, "--trace-dir", traces]
        |> maybe_private_output(policy, Path.join(dir, "#{policy}-result.json"))

      assert {:ok, preparation} = CommandEngine.prepare(argv)
      assert {:ok, authority} = CommandEngine.preflight(preparation)
      assert {:ok, outcome} = RunCoordinator.execute(preparation.prepared_run, authority)
      assert {:ok, report} = RunBuilder.publish_execution_report(outcome, authority)
      assert report.artifact_state["trace"] == "written"
      assert :ok = PublicationAuthority.close(authority)

      suffix = if policy == :private, do: ".private.jsonl", else: ".jsonl"
      assert File.ls!(traces) == [preparation.run_ref <> suffix]

      source = if policy == :private, do: {:private_directory, traces}, else: {:directory, traces}
      assert {:ok, trace_log} = TraceLog.new(source: source)

      assert {:ok, %{"items" => [%{"run_id" => run_ref}]}} =
               TraceLog.query(trace_log, :list_runs, %{})

      assert run_ref == preparation.run_ref
      assert :ok = CommandPreparation.close(preparation)
    end)
  end

  @tag :tmp_dir
  test "collision, symlink, and unsafe permissions fail closed without paths", %{tmp_dir: dir} do
    traces = Path.join(dir, "traces")
    File.mkdir!(traces)
    application = application!(dir, "collision")

    assert {:ok, collision} =
             CommandEngine.prepare(["run", application, "--trace-dir", traces])

    collision_path = Path.join(traces, collision.run_ref <> ".jsonl")
    File.write!(collision_path, "occupied")
    assert {:error, collision_outcome} = CommandEngine.preflight(collision)
    assert collision_outcome.envelope["error"]["code"] == "destination_exists"
    assert collision_outcome.envelope["error"]["provider_activity"] == false
    assert collision_outcome.envelope["artifact_state"]["trace"] == "not_written"
    refute Jason.encode!(collision_outcome.envelope) =~ dir

    assert {:ok, symlink} = CommandEngine.prepare(["run", application, "--trace-dir", traces])
    symlink_path = Path.join(traces, symlink.run_ref <> ".jsonl")
    File.ln_s("not-the-authorized-target", symlink_path)
    assert {:error, symlink_outcome} = CommandEngine.preflight(symlink)
    assert symlink_outcome.envelope["error"]["code"] == "destination_exists"
    assert File.read_link!(symlink_path) == "not-the-authorized-target"

    unsafe = Path.join(dir, "unsafe")
    File.mkdir!(unsafe)
    File.chmod!(unsafe, 0o777)

    assert {:ok, unsafe_preparation} =
             CommandEngine.prepare(["run", application, "--trace-dir", unsafe])

    assert {:error, unsafe_outcome} = CommandEngine.preflight(unsafe_preparation)
    assert unsafe_outcome.envelope["error"]["code"] == "invalid_destination"
    assert unsafe_outcome.envelope["error"]["provider_activity"] == false
    File.chmod!(unsafe, 0o700)
  end

  @tag :tmp_dir
  test "parent replacement after reservation fails closed", %{tmp_dir: dir} do
    parent = Path.join(dir, "destination")
    moved = Path.join(dir, "moved-destination")
    File.mkdir!(parent)
    target = Path.join(parent, "run.jsonl")

    assert {:ok, handle} = PublicationHandle.reserve(target, :trace, 0o600)
    assert :ok = File.rename(parent, moved)
    File.mkdir!(parent)

    assert {:error, :publication_collision} = PublicationHandle.write(handle, "[]\n")
    assert {:error, :publication_collision} = PublicationHandle.verify(handle)
    refute File.exists?(target)

    assert :ok = PublicationHandle.close(handle)
    File.rm_rf!(moved)
  end

  @tag :tmp_dir
  test "exclusive handle operations remain owned across caller processes", %{tmp_dir: dir} do
    target = Path.join(dir, "cross-process.jsonl")
    assert {:ok, handle} = PublicationHandle.reserve(target, :trace, 0o600)
    parent = self()

    spawn(fn -> send(parent, {:write, PublicationHandle.write(handle, "[]\n")}) end)
    assert_receive {:write, :ok}

    spawn(fn -> send(parent, {:sync, PublicationHandle.sync(handle)}) end)
    assert_receive {:sync, :ok}

    spawn(fn -> send(parent, {:publish, PublicationHandle.publish(handle)}) end)
    assert_receive {:publish, :ok}
    assert File.read!(target) == "[]\n"
    assert :ok = PublicationHandle.close(handle)
  end

  @tag :tmp_dir
  test "phase-six creator death does not revoke an already claimed authority", %{tmp_dir: dir} do
    parent = self()
    target = Path.join(dir, "claimed.jsonl")

    caller =
      spawn(fn ->
        assert {:ok, authority} =
                 PublicationAuthority.authorize(
                   "caller-transfer",
                   [trace: target],
                   :normal,
                   :normal
                 )

        send(parent, {:authority, authority})
        assert_receive :release
      end)

    caller_ref = Process.monitor(caller)
    assert_receive {:authority, authority}, 1_000

    assert {:ok, lease} = PublicationAuthority.claim(authority)
    send(caller, :release)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
    handle = PublicationAuthority.handles(authority) |> Map.fetch!(:trace)
    assert PublicationAuthority.lease_valid?(authority, lease)
    assert :ok = PublicationHandle.write(handle, "[]\n")
    assert :ok = PublicationHandle.sync(handle)
    assert :ok = PublicationHandle.publish(handle)
    assert File.read!(target) == "[]\n"
    assert :ok = PublicationAuthority.close(authority)
  end

  @tag :tmp_dir
  test "independent authorities cannot reserve the same requested name", %{tmp_dir: dir} do
    target = Path.join(dir, "same-target.jsonl")

    assert {:ok, first} =
             PublicationAuthority.authorize(
               "first-authority",
               [trace: target],
               :normal,
               :normal
             )

    assert {:error, :destination_exists} =
             PublicationAuthority.authorize(
               "second-authority",
               [trace: target],
               :normal,
               :normal
             )

    assert :ok = PublicationAuthority.abort(first)

    assert {:ok, second} =
             PublicationAuthority.authorize(
               "second-authority-after-release",
               [trace: target],
               :normal,
               :normal
             )

    assert :ok = PublicationAuthority.abort(second)
  end

  @tag :tmp_dir
  test "trace reservations remain exclusive across target existence changes", %{tmp_dir: dir} do
    target = Path.join(dir, "changing-trace.jsonl")

    assert {:ok, missing_first} =
             PublicationAuthority.authorize(
               "missing-first",
               [trace: target],
               :normal,
               :normal
             )

    File.write!(target, "")

    assert {:error, :destination_exists} =
             PublicationAuthority.authorize(
               "missing-second",
               [trace: target],
               :normal,
               :normal
             )

    File.rm!(target)
    assert :ok = PublicationAuthority.abort(missing_first)

    File.write!(target, "")

    assert {:ok, existing_first} =
             PublicationAuthority.authorize(
               "existing-first",
               [trace: target],
               :normal,
               :normal
             )

    File.rm!(target)

    assert {:error, :destination_exists} =
             PublicationAuthority.authorize(
               "existing-second",
               [trace: target],
               :normal,
               :normal
             )

    assert :ok = PublicationAuthority.abort(existing_first)
  end

  @tag :tmp_dir
  test "failed append-handle initialization preserves an existing trace", %{tmp_dir: dir} do
    target = Path.join(dir, "preserved-trace.jsonl")
    source = "existing\n"
    File.write!(target, source)

    assert {:error, :forced_append_initialization} =
             PublicationHandle.reserve_append_direct(
               target,
               :trace,
               0,
               self(),
               fn :after_open -> {:error, :forced_append_initialization} end
             )

    assert File.read!(target) == source
  end

  @tag :tmp_dir
  test "private result reservations also claim the requested name", %{tmp_dir: dir} do
    target = Path.join(dir, "same-private-result.json")

    assert {:ok, first} =
             PublicationAuthority.authorize(
               "private-first",
               [private_output: target],
               :private,
               :normal
             )

    assert {:error, :destination_exists} =
             PublicationAuthority.authorize(
               "private-second",
               [private_output: target],
               :private,
               :normal
             )

    assert :ok = PublicationAuthority.abort(first)

    assert {:ok, second} =
             PublicationAuthority.authorize(
               "private-second-after-release",
               [private_output: target],
               :private,
               :normal
             )

    assert :ok = PublicationAuthority.abort(second)
  end

  @tag :tmp_dir
  test "creator death reclaims an unclaimed authority", %{tmp_dir: dir} do
    parent = self()
    target = Path.join(dir, "creator-abandoned.jsonl")

    creator =
      spawn(fn ->
        assert {:ok, _authority} =
                 PublicationAuthority.authorize(
                   "creator-abandoned",
                   [trace: target],
                   :normal,
                   :normal
                 )

        send(parent, :authorized)
      end)

    creator_ref = Process.monitor(creator)
    assert_receive :authorized, 1_000
    assert_receive {:DOWN, ^creator_ref, :process, ^creator, :normal}
    refute File.exists?(target)

    assert {:ok, authority} = authorize_after_creator_cleanup(target)

    assert :ok = PublicationAuthority.abort(authority)
  end

  @tag :tmp_dir
  test "claimant death cleans every reserved destination", %{tmp_dir: dir} do
    parent = self()
    target = Path.join(dir, "abandoned.jsonl")

    assert {:ok, authority} =
             PublicationAuthority.authorize(
               "claimant-death",
               [trace: target],
               :normal,
               :normal
             )

    claimant =
      spawn(fn ->
        assert {:ok, _lease} = PublicationAuthority.claim(authority)
        send(parent, :claimed)
      end)

    claimant_ref = Process.monitor(claimant)
    assert_receive :claimed
    assert_receive {:DOWN, ^claimant_ref, :process, ^claimant, :normal}
    refute PublicationAuthority.authorized?(authority)
    refute File.exists?(target)
  end

  test "unreserved authority rejects duplicate destination keys before allocation" do
    assert {:error, :invalid_publication_authority} =
             PublicationAuthority.new(trace: "/tmp/a.jsonl", trace: "/tmp/b.jsonl")
  end

  @tag :tmp_dir
  test "a later reservation failure releases earlier exclusive handles", %{tmp_dir: dir} do
    trace = Path.join(dir, "run.jsonl")
    inspection = Path.join(dir, "run.inspection.jsonl")
    File.write!(inspection, "occupied")

    assert {:error, :destination_exists} =
             PublicationAuthority.authorize(
               "reservation-rollback",
               [trace: trace, inspect: inspection],
               :normal,
               :normal
             )

    assert File.lstat(trace) == {:error, :enoent}
    assert File.ls!(dir) == ["run.inspection.jsonl"]
  end

  @tag :tmp_dir
  test "command authorization validates inspection destinations centrally", %{tmp_dir: dir} do
    application = application!(dir, "invalid-inspection")
    invalid_inspection = Path.join(dir, "inspection.json")

    assert {:ok, preparation} =
             CommandEngine.prepare(["run", application, "--inspect", invalid_inspection])

    assert {:error, outcome} = CommandEngine.preflight(preparation)
    assert outcome.envelope["error"]["code"] == "invalid_destination"
    assert outcome.envelope["error"]["provider_activity"] == false
    refute Jason.encode!(outcome.envelope) =~ dir
  end

  @tag :tmp_dir
  test "invalid preparation references still return a valid path-free outcome", %{tmp_dir: dir} do
    application = application!(dir, "invalid-reference")

    assert {:ok, preparation} = CommandEngine.prepare(["run", application])
    tampered = %{preparation | run_ref: "cmd-invalid"}

    assert {:error, outcome} = CommandEngine.preflight(tampered)
    assert CommandOutcome.valid?(outcome)
    assert outcome.envelope["error"]["code"] == "internal_error"
    refute Jason.encode!(outcome.envelope) =~ dir

    assert :ok = CommandPreparation.close(preparation)
  end

  defp application!(dir, name, overrides \\ %{}) do
    root = Path.join(dir, name)
    File.mkdir!(root)
    File.write!(Path.join(root, "main.clj"), "(ns app) (defn run [input] (return input))")

    manifest =
      ~S({"version":1,"workflow":{"components":[{"id":"app","path":"main.clj"}],"entry":"app/run"},"input":{"value":{}},"providers":{"workflow":[],"mission":[]}})
      |> Jason.decode!()
      |> Map.merge(overrides)

    path = Path.join(root, "ptc.json")
    File.write!(path, Jason.encode!(manifest))
    path
  end

  defp maybe_private_output(argv, :normal, _output), do: argv

  defp maybe_private_output(argv, :private, output),
    do: argv ++ ["--private-output", output]

  defp authorize_after_creator_cleanup(target, attempts \\ 100)

  defp authorize_after_creator_cleanup(_target, 0),
    do: {:error, :creator_cleanup_timeout}

  defp authorize_after_creator_cleanup(target, attempts) do
    case PublicationAuthority.authorize(
           "creator-reuse-#{attempts}",
           [trace: target],
           :normal,
           :normal
         ) do
      {:error, :destination_exists} ->
        :erlang.yield()
        authorize_after_creator_cleanup(target, attempts - 1)

      result ->
        result
    end
  end
end
