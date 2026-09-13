defmodule PtcRunner.Kernel.ServingTemplateTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.EffectiveApplication
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.ExecutionInput
  alias PtcRunner.Kernel.ExecutionPolicy
  alias PtcRunner.Kernel.ExecutionSessionOwner
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunAdmission
  alias PtcRunner.Kernel.RunRequest
  alias PtcRunner.Kernel.ServingCall
  alias PtcRunner.Kernel.ServingOutcome
  alias PtcRunner.Kernel.ServingTemplate
  alias PtcRunner.Kernel.ValueContract

  @schema %{
    "type" => "object",
    "properties" => %{"answer" => %{"type" => "integer"}},
    "required" => ["answer"],
    "additionalProperties" => false
  }
  @source "(ns app) (defn run {:effect :read} [input] (return input))"

  @tag :tmp_dir
  test "captures compiled contracts and frozen policy without opening declared input", %{
    tmp_dir: dir
  } do
    path = fixture(dir)
    assert {:ok, template} = build(path)
    assert {:error, _reason} = ApplicationPackage.request_directory(path)
    assert {:ok, package, _input} = ApplicationPackage.acquire_directory(path, omit_input: true)
    assert ServingTemplate.input_schema(template) == package.contracts.input.schema
    assert ServingTemplate.output_schema(template) == package.contracts.result.schema
    assert ServingTemplate.effect(template) == :read
    assert ServingTemplate.installation_config_digests(template) == %{}

    assert ServingTemplate.policy(template) == %{
             input_authority_class: :normal,
             effective_event_policy: :normal,
             inspection_capture: false,
             result_projection: :json,
             publication: :artifact_free,
             deadline: :absolute_from_reservation
           }

    assert ServingTemplate.limits(template) == package.limits
    assert {:ok, encoded} = DeterministicJSON.encode(ServingTemplate.input_schema(template))
    assert Jason.decode!(encoded) == ServingTemplate.input_schema(template)
    refute owned?(template)
    refute inspect(template) =~ dir
    File.rm_rf!(dir)
    assert :ok = ServingTemplate.close(template)

    results =
      1..16
      |> Task.async_stream(fn _ ->
        assert ValueContract.valid?(template.package.contracts.input, %{"answer" => 1})
        refute ValueContract.valid?(template.package.contracts.input, %{"answer" => "bad"})
        assert :ok = ServingTemplate.close(template)
        DeterministicJSON.encode(ServingTemplate.input_schema(template))
      end)
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, {:ok, encoded}}))
    assert :ok = ServingTemplate.close(template)
  end

  @tag :tmp_dir
  test "content pin cannot be confused with existing effective identity", %{tmp_dir: dir} do
    path = fixture(dir)
    assert {:ok, template} = build(path)
    content = ServingTemplate.application_content_digest(template)
    effective = ServingTemplate.effective_application_digest(template)
    assert content =~ ~r/\Asha256:[0-9a-f]{64}\z/
    assert effective =~ ~r/\Asha256:[0-9a-f]{64}\z/
    refute content == effective
    assert {:ok, _template} = build(path, expected_application_content_digest: content)

    assert {:error, :application_content_digest_mismatch} =
             build(path, expected_application_content_digest: effective)

    assert {:error, :application_content_digest_mismatch} =
             build(path,
               expected_application_content_digest: "sha256:" <> String.duplicate("0", 64)
             )

    assert {:ok, input} = ExecutionInput.new(%{"answer" => 3}, :normal)
    assert {:ok, policy} = ExecutionPolicy.new(result_projection: :json)
    assert {:ok, request} = RunRequest.new(template.package, input, policy)
    bundles = Map.new(template.missions, fn {name, mission} -> {name, mission.bundle} end)

    assert {:ok, identity} =
             EffectiveApplication.build(
               request,
               template.workflow.bundle,
               bundles,
               %{workflow: [], mission: []},
               :normal
             )

    assert identity.digest == effective

    # Installed-only limits affect behavior, but never application content.
    {:ok, installed} = Limits.new(provider_cleanup_timeout_ms: 1_234)
    assert {:ok, changed} = ServingTemplate.from_directory(path, installed)
    assert ServingTemplate.application_content_digest(changed) == content
    refute ServingTemplate.effective_application_digest(changed) == effective
  end

  @tag :tmp_dir
  test "contracts, identities, providers and entry shape are rejected at the constructor", %{
    tmp_dir: dir
  } do
    for {change, code} <- [
          {%{"contracts" => %{}}, :contracts_required},
          {%{"contracts" => %{"input_schema" => %{"path" => "schema.json"}}},
           :contracts_required},
          {%{"events" => %{"run_id" => "owned"}}, :manifest_identity_forbidden},
          {%{"events" => %{"trace_id" => "owned"}}, :manifest_identity_forbidden},
          {%{"providers" => %{"workflow" => [%{"name" => "provider"}]}},
           :provider_runtime_required},
          {%{"providers" => %{"mission" => [%{"name" => "provider"}]}},
           :provider_runtime_required},
          {%{
             "workflow" => %{
               "components" => [%{"id" => "app", "path" => "workflow.clj"}],
               "entry" => "app/missing"
             }
           }, :entry_invalid},
          {%{"workflow" => %{"components" => [], "entry" => "app/run"}}, :entry_invalid},
          {%{"input" => %{"path" => 1}}, :invalid_application},
          {%{"input" => %{"path" => "missing.json", "value" => %{}}}, :invalid_application},
          {%{"input" => nil}, :invalid_application}
        ] do
      assert {:error, ^code} = build(fixture(dir, change))
    end

    for schema <- [
          %{"type" => "string"},
          %{"type" => "array"},
          %{"type" => "object", "$ref" => "private"}
        ] do
      path = fixture(dir)
      File.write!(Path.join(dir, "schema.json"), Jason.encode!(schema))
      assert {:error, :invalid_application} = build(path)
    end

    for source <- ["(ns app) (defn run {:effect :read} [] (return {}))", "(ns app) (def run 1)"] do
      assert {:error, :entry_invalid} = build(fixture(dir, %{}, source))
    end

    assert {:error, :compilation_failed} =
             build(fixture(dir, %{}, "(ns app) (defn run [input] missing)"))
  end

  @tag :tmp_dir
  test "the full declared and resolved entry matrix includes every selectable mission", %{
    tmp_dir: dir
  } do
    for declared <- [:read, :write, :unknown, nil], resolved <- [:read, :write, :unknown] do
      metadata = if declared, do: "{:effect :#{declared}}", else: ""
      workflow = "(ns app) (defn run #{metadata} [input] (return input))"
      mission = "(ns mission) (defn helper {:effect :#{resolved}} [x] x)"

      path =
        fixture(
          dir,
          %{
            "missions" => %{
              "worker" => %{"components" => [%{"id" => "mission", "path" => "mission.clj"}]}
            }
          },
          workflow
        )

      File.write!(Path.join(dir, "mission.clj"), mission)

      case {declared, resolved} do
        {:read, :read} -> assert {:ok, %{effect: :read}} = build(path)
        {:read, _} -> assert {:error, :declared_read_effect_violation} = build(path)
        {:write, _} -> assert {:ok, %{effect: :write}} = build(path)
        _ -> assert {:error, :effect_declaration_required} = build(path)
      end
    end
  end

  @tag :tmp_dir
  test "direct and transitive reserved routes resolve read and other invalid read exports reject",
       %{tmp_dir: dir} do
    source =
      "(ns app) (defn- helper [x] (tool/runtime-usage {})) (defn run {:effect :read} [x] (return (helper x)))"

    assert {:ok, %{effect: :read}} = build(fixture(dir, %{}, source))

    source =
      "(ns app) (defn helper {:effect :unknown} [x] x) (defn run {:effect :read} [x] (return (helper x)))"

    assert {:error, :declared_read_effect_violation} = build(fixture(dir, %{}, source))

    source =
      "(ns app) (defn helper {:effect :write} [x] x) (defn run {:effect :read} [x] (return (helper x)))"

    assert {:error, :declared_read_effect_violation} = build(fixture(dir, %{}, source))

    source =
      "(ns app) (defn helper {:effect :write} [x] x) (defn bad {:effect :read} [x] (helper x)) (defn run {:effect :write} [x] (return x))"

    assert {:error, :declared_read_effect_violation} = build(fixture(dir, %{}, source))
  end

  @tag :tmp_dir
  test "mission implicit inspection routes contribute their maintained read effects", %{
    tmp_dir: dir
  } do
    path =
      fixture(dir, %{
        "missions" => %{
          "worker" => %{"components" => [%{"id" => "mission", "path" => "mission.clj"}]}
        }
      })

    File.write!(
      Path.join(dir, "mission.clj"),
      "(ns mission) (defn helper {:effect :read} [x] (tool/runtime-usage {}))"
    )

    assert {:ok, %{effect: :read}} = build(path)
  end

  @tag :tmp_dir
  test "private templates are rejected before serving", %{tmp_dir: dir} do
    path =
      fixture(dir, %{
        "events" => %{"policy" => "private"},
        "limits" => %{"run_duration_ms" => 500}
      })

    assert {:error, :private_result_unservable} = build(path)

    assert {:error, :invalid_application} =
             build(fixture(dir, %{"limits" => %{"run_duration_ms" => 9_999_999}}))
  end

  @tag :tmp_dir
  test "inline input is excluded and tagged object schemas retain their compiled normalization",
       %{tmp_dir: dir} do
    branch = fn tag ->
      %{
        "type" => "object",
        "properties" => %{"kind" => %{"type" => "string", "const" => tag}},
        "required" => ["kind"],
        "additionalProperties" => false
      }
    end

    schema = %{"oneOf" => [branch.("a"), branch.("b")], "title" => "Object alternatives"}
    path = fixture(dir, %{"input" => %{"value" => %{"wrong" => "not contract valid"}}})
    File.write!(Path.join(dir, "schema.json"), Jason.encode!(schema))
    assert {:ok, template} = build(path)
    assert {:error, _reason} = ApplicationPackage.request_directory(path)
    {:ok, compiled} = ValueContract.compile(schema)
    assert ServingTemplate.input_schema(template) == compiled.schema
    assert ServingTemplate.output_schema(template) == compiled.schema
    assert {:ok, encoded} = DeterministicJSON.encode(compiled.schema)
    assert {:ok, ^encoded} = DeterministicJSON.encode(ServingTemplate.input_schema(template))
    assert ValueContract.valid?(template.package.contracts.input, %{"kind" => "a"})
    refute ValueContract.valid?(template.package.contracts.input, %{"kind" => "c"})
    content = ServingTemplate.application_content_digest(template)
    path = fixture(dir, %{"input" => %{"path" => "missing.json"}})
    File.write!(Path.join(dir, "schema.json"), Jason.encode!(schema))
    assert {:ok, template} = build(path, expected_application_content_digest: content)
    File.write!(Path.join(dir, "missing.json"), Jason.encode!(%{"kind" => "b"}))
    assert {:ok, request} = ApplicationPackage.request_directory(path)
    assert request.input.value == %{"kind" => "b"}

    assert {:ok, _same} =
             build(path,
               expected_application_content_digest:
                 ServingTemplate.application_content_digest(template)
             )
  end

  test "closed pre-acquisition failures contain no private details" do
    path = "/private/nonexistent/payload"

    for opts <- [
          [unknown: true],
          [expected_application_content_digest: nil],
          [expected_application_content_digest: String.duplicate("a", 64)],
          [expected_application_content_digest: "sha256:" <> String.duplicate("A", 64)],
          [
            expected_application_content_digest: "sha256:" <> String.duplicate("a", 64),
            expected_application_content_digest: "sha256:" <> String.duplicate("a", 64)
          ],
          nil
        ] do
      assert {:error, :invalid_options} = build(path, opts)
    end

    assert {:error, :invalid_installed_limits} = ServingTemplate.from_directory(path, %{})
    assert {:error, :invalid_application} = build(path)
  end

  @tag :tmp_dir
  test "calls reuse the compiled application after its directory is removed", %{tmp_dir: dir} do
    assert {:ok, template} = build(fixture(dir))
    host = start_supervised!({RunAdmission, max_concurrent_runs: 2})
    File.rm_rf!(dir)

    for answer <- 1..3 do
      assert {:ok, reservation} = ServingTemplate.reserve(template, %{"answer" => answer}, host)
      outcome = ServingTemplate.activate(reservation)
      assert ServingOutcome.code(outcome) == :success
      assert ServingOutcome.value(outcome) == {:ok, %{"answer" => answer}}
    end

    outcome = ServingTemplate.call(template, %{"answer" => "invalid"}, host)
    assert ServingOutcome.code(outcome) == :invalid_input

    assert ServingOutcome.metadata(outcome) == %{
             dispatched: false,
             write_effects_possible: false
           }

    assert {:ok, %{in_use: 0, status: :ready}} = RunAdmission.snapshot(host)
  end

  @tag :tmp_dir
  test "publication retains capacity through success, failure and uncertain cleanup", %{
    tmp_dir: dir
  } do
    assert {:ok, template} = build(fixture(dir))
    parent = self()

    for mode <- [:success, :publication_failed, :cleanup_failed] do
      {:ok, host} = RunAdmission.start_link(max_concurrent_runs: 1)

      task =
        Task.async(fn ->
          {:ok, reservation} = ServingTemplate.reserve(template, %{"answer" => 1}, host)

          hooks = %{
            before_publication: fn authority ->
              send(parent, {:publishing, self()})
              receive do: (:publish -> :ok)

              if mode == :publication_failed,
                do: PublicationAuthority.abort(authority)
            end,
            cleanup: fn authority ->
              :ok = PublicationAuthority.abort(authority)
              if mode == :cleanup_failed, do: {:error, :uncertain}, else: :ok
            end
          }

          ServingCall.activate(reservation, hooks)
        end)

      assert_receive {:publishing, worker}
      assert {:ok, %{in_use: 1}} = RunAdmission.snapshot(host)

      assert ServingOutcome.code(ServingTemplate.call(template, %{"answer" => 2}, host)) == :busy

      send(worker, :publish)
      result = Task.await(task)
      assert ServingOutcome.code(result) == mode
      assert {:ok, %{in_use: 0, status: status}} = RunAdmission.snapshot(host)
      assert status == if(mode == :cleanup_failed, do: :unavailable, else: :ready)
      GenServer.stop(host)
    end
  end

  @tag :tmp_dir
  test "unused and foreign reservations cannot dispatch and release capacity", %{tmp_dir: dir} do
    assert {:ok, template} = build(fixture(dir))
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    {:ok, reservation} = ServingTemplate.reserve(template, %{"answer" => 1}, host)
    task = Task.async(fn -> ServingTemplate.activate(reservation) end)
    assert ServingOutcome.code(Task.await(task)) == :internal_error
    assert {:ok, %{in_use: 1}} = RunAdmission.snapshot(host)
    assert :ok = ServingTemplate.close(reservation)
    assert {:ok, %{in_use: 0}} = RunAdmission.snapshot(host)
    outcome = ServingTemplate.activate(reservation)
    assert ServingOutcome.code(outcome) == :admission_unavailable
    assert ServingOutcome.metadata(outcome).dispatched == false
  end

  @tag :tmp_dir
  test "closed refusals never contain input or internal detail", %{tmp_dir: dir} do
    assert {:ok, template} = build(fixture(dir))
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})

    for {input, deadline, code} <- [
          {%{"secret" => "credential"}, :infinity, :invalid_input},
          {%{"answer" => 1}, System.monotonic_time(:millisecond) - 1, :cancelled},
          {%{"answer" => 1}, :invalid, :internal_error}
        ] do
      result = ServingTemplate.call(template, input, host, deadline)
      assert ServingOutcome.code(result) == code
      assert ServingOutcome.value(result) == :error
      refute inspect(result) =~ "credential"
      assert ServingOutcome.metadata(result).dispatched == false
    end

    GenServer.stop(host)

    assert ServingOutcome.code(ServingTemplate.call(template, %{"answer" => 1}, host)) ==
             :admission_unavailable
  end

  @tag :tmp_dir
  test "failing and successful concurrent calls cannot contaminate fresh values", %{tmp_dir: dir} do
    source =
      "(ns app) (defn run {:effect :write} [input] (if (= (get input :answer) 0) (return {}) (return input)))"

    assert {:ok, template} = build(fixture(dir, %{}, source))
    host = start_supervised!({RunAdmission, max_concurrent_runs: 16})

    outcomes =
      0..15
      |> Task.async_stream(
        fn answer ->
          {answer, ServingTemplate.call(template, %{"answer" => answer}, host)}
        end,
        max_concurrency: 16
      )
      |> Enum.map(fn {:ok, value} -> value end)

    for {answer, result} <- outcomes do
      assert ServingOutcome.code(result) ==
               if(answer == 0, do: :invalid_result, else: :success)

      assert ServingOutcome.metadata(result).write_effects_possible

      if answer > 0,
        do: assert(ServingOutcome.value(result) == {:ok, %{"answer" => answer}})
    end

    assert {:ok, %{in_use: 0, status: :ready}} = RunAdmission.snapshot(host)
  end

  @tag :tmp_dir
  test "publication deadline shares the reservation deadline and cleanup wins", %{tmp_dir: dir} do
    assert {:ok, template} = build(fixture(dir))

    for clean? <- [true, false] do
      {:ok, host} = RunAdmission.start_link(max_concurrent_runs: 1)
      deadline = System.monotonic_time(:millisecond) + 200
      {:ok, reservation} = ServingTemplate.reserve(template, %{"answer" => 1}, host, deadline)

      hooks = %{
        before_publication: fn _ ->
          Process.send_after(
            self(),
            :deadline,
            max(0, deadline - System.monotonic_time(:millisecond) + 1)
          )

          receive do: (:deadline -> :ok)
        end,
        cleanup: fn authority ->
          :ok = PublicationAuthority.abort(authority)
          if clean?, do: :ok, else: {:error, :uncertain}
        end
      }

      result = ServingCall.activate(reservation, hooks)

      assert ServingOutcome.code(result) ==
               if(clean?, do: :cancelled, else: :cleanup_failed)

      assert ServingOutcome.value(result) == :error
      GenServer.stop(host)
    end
  end

  @tag :tmp_dir
  test "execution failures and oversized results stay closed", %{tmp_dir: dir} do
    for {source, limits, code} <- [
          {~s|(ns app) (defn run {:effect :write} [input] (fail {"secret" "must-not-escape"}))|,
           %{}, :execution_failed},
          {@source, %{"terminal_result_bytes" => 1}, :invalid_result}
        ] do
      assert {:ok, template} = build(fixture(dir, %{"limits" => limits}, source))
      host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
      result = ServingTemplate.call(template, %{"answer" => 1}, host)
      assert ServingOutcome.code(result) == code
      assert ServingOutcome.value(result) == :error
      refute inspect(result) =~ "must-not-escape"
      stop_supervised!(RunAdmission)
    end
  end

  @tag :tmp_dir
  test "calling worker death during publication fences its retained lease", %{tmp_dir: dir} do
    assert {:ok, template} = build(fixture(dir))
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        {:ok, reservation} = ServingTemplate.reserve(template, %{"answer" => 1}, host)

        ServingCall.activate(reservation, %{
          before_publication: fn _ ->
            send(parent, :publishing)
            receive do: (:never -> :ok)
          end
        })
      end)

    assert_receive :publishing
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert {:ok, %{in_use: 0, status: :unavailable}} = RunAdmission.snapshot(host)

    assert ServingOutcome.code(ServingTemplate.call(template, %{"answer" => 1}, host)) ==
             :admission_unavailable
  end

  test "cancellation during call preparation holds capacity until worker cleanup" do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    {:ok, lease} = RunAdmission.reserve(host, :infinity)
    :ok = RunAdmission.retain_publication(lease)
    :ok = RunAdmission.cancel(lease)
    assert {:ok, %{in_use: 1}} = RunAdmission.snapshot(host)
    assert {:error, :run_capacity_exhausted} = RunAdmission.reserve(host, :infinity)
    assert {:error, :call_cancelled} = RunAdmission.finish_publication(lease, true)
    assert {:ok, %{in_use: 0, status: :ready}} = RunAdmission.snapshot(host)
  end

  @tag :tmp_dir
  test "fencing between reserve and activation remains an admission refusal", %{tmp_dir: dir} do
    assert {:ok, template} = build(fixture(dir))

    for phase <- [:before_retention, :after_retention] do
      host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
      {:ok, reservation} = ServingTemplate.reserve(template, %{"answer" => 1}, host)
      fence = fn -> :sys.replace_state(host, &%{&1 | status: :unavailable}) end
      if phase == :before_retention, do: fence.()
      hooks = if phase == :after_retention, do: %{after_retention: fence}, else: %{}
      result = ServingCall.activate(reservation, hooks)
      assert ServingOutcome.code(result) == :admission_unavailable
      assert ServingOutcome.metadata(result).dispatched == false
      assert {:ok, %{in_use: 0, status: :unavailable}} = RunAdmission.snapshot(host)
      stop_supervised!(RunAdmission)
    end
  end

  test "fenced transfer refusal survives activation-failure cancellation" do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    {:ok, {RunAdmission, ^host, ref} = lease} = RunAdmission.reserve(host, :infinity)
    :ok = RunAdmission.retain_publication(lease)
    {:ok, ticket} = GenServer.call(host, {:begin_activation, ref})
    :sys.replace_state(host, &%{&1 | status: :unavailable})
    caller = self()
    task = Task.async(fn -> RunAdmission.transfer(host, ref, ticket, caller) end)
    assert Task.await(task) == {:error, :run_admission_unavailable}
    :ok = RunAdmission.cancel(lease)
    assert {:error, :call_admission_refused} = RunAdmission.finish_publication(lease, true)
    assert {:ok, %{in_use: 0, status: :unavailable}} = RunAdmission.snapshot(host)
  end

  @tag :tmp_dir
  test "admission death after dispatch preserves write uncertainty", %{tmp_dir: dir} do
    source = "(ns app) (defn run {:effect :write} [input] (loop [n 0] (recur (inc n))))"
    assert {:ok, template} = build(fixture(dir, %{}, source))
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    {:ok, reservation} = ServingTemplate.reserve(template, %{"answer" => 1}, host)

    hooks = %{
      after_activation: fn {RunAdmission, _, session} ->
        owner = ExecutionSessionOwner.pid(session)
        state = :sys.get_state(owner)
        await_dispatch(state.opened_sinks.event_sink, System.monotonic_time(:millisecond) + 2000)
        GenServer.stop(host)
        send(self(), :admission_closed_after_dispatch)
      end
    }

    result = ServingCall.activate(reservation, hooks)
    assert ServingOutcome.code(result) == :cleanup_failed
    assert ServingOutcome.metadata(result).dispatched == :unknown
    assert ServingOutcome.metadata(result).write_effects_possible
    assert_receive :admission_closed_after_dispatch
  end

  @tag :tmp_dir
  test "execution-owner death retains fenced capacity through caller cleanup", %{tmp_dir: dir} do
    source = "(ns app) (defn run {:effect :write} [input] (loop [n 0] (recur (inc n))))"
    assert {:ok, template} = build(fixture(dir, %{}, source))

    for mode <- [:owner_death, :unclean_completion] do
      host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
      parent = self()

      task =
        Task.async(fn ->
          {:ok, reservation} = ServingTemplate.reserve(template, %{"answer" => 1}, host)

          hooks = %{
            after_activation: fn {RunAdmission, _, session} ->
              owner = ExecutionSessionOwner.pid(session)

              case mode do
                :owner_death ->
                  Process.exit(owner, :kill)

                :unclean_completion ->
                  :sys.replace_state(owner, &%{&1 | cleanup: {:error, :injected}})
                  send(owner, {:run_admission_cancel, host})
              end
            end,
            cleanup: fn authority ->
              send(parent, {:closing, self()})
              receive do: (:close -> :ok)
              PublicationAuthority.abort(authority)
            end
          }

          ServingCall.activate(reservation, hooks)
        end)

      assert_receive {:closing, worker}, 5000
      assert {:ok, %{in_use: 1, status: :unavailable}} = RunAdmission.snapshot(host)
      send(worker, :close)
      assert ServingOutcome.code(Task.await(task)) == :cleanup_failed
      assert {:ok, %{in_use: 0, status: :unavailable}} = RunAdmission.snapshot(host)
      stop_supervised!(RunAdmission)
    end
  end

  @tag :tmp_dir
  test "queued reservation expiry takes precedence over admission refusal", %{tmp_dir: dir} do
    assert {:ok, template} = build(fixture(dir))
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    :sys.suspend(host)
    deadline = System.monotonic_time(:millisecond) + 500
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :reserving)
        ServingTemplate.reserve(template, %{"answer" => 1}, host, deadline)
      end)

    assert_receive :reserving
    await_reservation_message(host, deadline)

    Process.send_after(
      self(),
      :expired,
      max(0, deadline - System.monotonic_time(:millisecond) + 1)
    )

    assert_receive :expired, 1000
    :sys.resume(host)
    result = Task.await(task)
    assert ServingOutcome.code(result) == :cancelled
    assert ServingOutcome.metadata(result).dispatched == false
    assert {:ok, %{in_use: 0, status: :ready}} = RunAdmission.snapshot(host)
  end

  @tag :tmp_dir
  test "caller finishing before admission sees owner death still drains the lease", %{
    tmp_dir: dir
  } do
    source = "(ns app) (defn run {:effect :write} [input] (loop [n 0] (recur (inc n))))"
    assert {:ok, template} = build(fixture(dir, %{}, source))
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    parent = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        {:ok, reservation} = ServingTemplate.reserve(template, %{"answer" => 1}, host)

        hooks = %{
          after_activation: fn {RunAdmission, _, session} ->
            owner = ExecutionSessionOwner.pid(session)
            state = :sys.get_state(owner)
            activity = state.prepared.provider_activity.owner
            activity_ref = Process.monitor(activity)
            :sys.suspend(host)
            Process.exit(owner, :kill)

            receive do
              {:DOWN, ^activity_ref, :process, ^activity, _} -> :ok
            after
              2000 -> flunk("activity did not close after owner death")
            end
          end,
          cleanup: fn authority ->
            result = PublicationAuthority.abort(authority)
            send(parent, {:cleanup_finished, self()})
            result
          end
        }

        result = ServingCall.activate(reservation, hooks)
        send(parent, {:returned, result})
        receive do: (:stop -> :ok)
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:cleanup_finished, ^caller}, 5000
    await_finish_message(host, System.monotonic_time(:millisecond) + 2000)
    {:messages, messages} = Process.info(host, :messages)

    {finishes, rest} =
      Enum.split_with(messages, &match?({:"$gen_call", _, {:finish_publication, _, true}}, &1))

    :sys.replace_state(host, fn state ->
      for _ <- messages do
        receive do: (_ -> :ok)
      end

      Enum.each(finishes ++ rest, &send(host, &1))
      state
    end)

    :sys.resume(host)
    assert_receive {:returned, result}, 5000
    assert ServingOutcome.code(result) == :cleanup_failed
    assert Process.alive?(caller)
    assert {:ok, %{in_use: 0, status: :unavailable}} = RunAdmission.snapshot(host)
    send(caller, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
  end

  defp await_reservation_message(host, deadline) do
    await_message(host, deadline, fn message ->
      match?({:"$gen_call", _, {:reserve, _}}, message)
    end)
  end

  defp await_finish_message(host, deadline) do
    await_message(host, deadline, fn message ->
      match?({:"$gen_call", _, {:finish_publication, _, true}}, message)
    end)
  end

  defp await_message(host, deadline, predicate) do
    {:messages, messages} = Process.info(host, :messages)

    unless Enum.any?(messages, predicate) do
      assert System.monotonic_time(:millisecond) < deadline
      await_message(host, deadline, predicate)
    end
  end

  defp await_dispatch(sink, deadline) do
    events = EventSink.events(sink)

    if Enum.any?(events, &((Map.get(&1, :type) || Map.get(&1, "type")) == "evaluation-started")) do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline
      await_dispatch(sink, deadline)
    end
  end

  defp build(path, opts \\ []),
    do: ServingTemplate.from_directory(path, Limits.installed_defaults(), opts)

  defp fixture(dir, changes \\ %{}, source \\ @source) do
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

  defp owned?(value)
       when is_pid(value) or is_reference(value) or is_function(value) or is_port(value), do: true

  defp owned?(%module{}) when module in [ExecutionInput, ExecutionPolicy], do: true
  defp owned?(map) when is_map(map), do: Enum.any?(Map.to_list(map), &owned?/1)
  defp owned?(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.any?(&owned?/1)
  defp owned?(list) when is_list(list), do: Enum.any?(list, &owned?/1)
  defp owned?(_value), do: false
end
