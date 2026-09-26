defmodule PtcRunner.ReplFrontendGlobalStateTest do
  # async: false — these cases compare the whole global :stderr, sweep the VM process list for
  # AnalysisSession owners, load a credential into the OS environment, or start the :req_llm
  # application (class D). One runs `mix ptc` in this checkout and holds Mix's build-directory
  # lock that the guide examples need (class C). One writes forty sealed fixtures and is too
  # heavy to share the async phase.
  use ExUnit.Case, async: false
  @moduletag :operator

  import ExUnit.CaptureIO
  import PtcRunner.TestSupport.ReplFrontendFixtures

  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Lisp.NamespaceDiagnostic
  alias PtcRunner.TestSupport.PrivateInspectionFixture

  @stdio_root Path.expand("../../..", __DIR__)
  @stdio_fixture Path.expand("../../support/mcp_stdio_source_fixture.sh", __DIR__)

  test "direct eval renders each error once without leaking module names" do
    cases = [
      {"(+ 1 2))", "parse_error",
       "unbalanced parentheses: 1 extra ')' (first at line 1, column 8)"},
      {"(/ 1 0)", "arithmetic_error", "division by zero"},
      {~S|(kernel/mission-model-context "reader")|, "invalid_form",
       NamespaceDiagnostic.message("kernel")},
      {~S|(str/split "a-VERDICT-b" "VERDICT")|, "type_error",
       ~S|split: delimiter must be a regex pattern, got plain string "VERDICT"|}
    ]

    for {source, kind, detail} <- cases do
      rendered = "Error (#{kind}): #{detail}"

      output =
        capture_io(:stderr, fn ->
          error = assert_raise Mix.Error, fn -> run_repl(["-e", source]) end
          assert error.message =~ "Error (#{kind}):"
          if kind != "invalid_form", do: assert(error.message =~ detail)
          refute error.message =~ "PtcRunner.Lisp"
          refute error.message =~ "#{kind}: #{kind}"
        end)

      assert output == rendered <> "\n"
      refute output =~ "PtcRunner.Lisp"
    end
  end

  test "direct repeated eval retains the ordinary session ceiling" do
    arguments = Enum.flat_map(1..129, &["--eval", Integer.to_string(&1)])

    stderr =
      capture_io(:stderr, fn ->
        _stdout =
          capture_io(fn ->
            error = assert_raise Mix.Error, fn -> run_repl(arguments) end

            assert error.message =~
                     "subordinate_evaluations limit 128 was exceeded"

            refute error.message =~ "manifest"
          end)
      end)

    assert stderr =~ "subordinate_evaluations limit 128 was exceeded"
    refute stderr =~ "manifest"
  end

  @tag :tmp_dir
  test "a host-backed manifest acquires once and reuses one provider session", %{
    tmp_dir: directory
  } do
    environment_name = "PTC_REPL_SCOPED_CREDENTIAL"
    previous_environment = System.get_env(environment_name)
    System.delete_env(environment_name)

    on_exit(fn ->
      if previous_environment,
        do: System.put_env(environment_name, previous_environment),
        else: System.delete_env(environment_name)
    end)

    marker = Path.join(directory, "provider-lifecycle")
    manifest_path = Path.join(directory, "provider-repl.json")
    host_path = Path.join(directory, "ptc-host.json")
    env_file = Path.join(directory, "repl.env")
    File.write!(env_file, "#{environment_name}=from-file\n")

    File.write!(Path.join(directory, "main.clj"), "(ns app) (defn run [x] (return x))")

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "app", "path" => "main.clj"}],
          "entry" => "app/run"
        },
        "providers" => %{
          "workflow" => [],
          "mission" => [
            %{"name" => "workspace", "config" => %{"allow" => ["workspace.structured"]}}
          ]
        },
        "input" => %{"value" => %{}},
        "limits" => %{"evaluation_timeout_ms" => 5_000, "run_duration_ms" => 20_000}
      })
    )

    File.write!(
      host_path,
      Jason.encode!(%{
        "credentials" => %{"token" => %{"env" => environment_name}},
        "install" => %{
          "workspace" => %{
            "source" => "mcp",
            "installation_revision" => "repl-stdio-v1",
            "transport" => %{
              "type" => "stdio",
              "command" => System.find_executable("sh"),
              "cwd" => @stdio_root,
              "args" => [@stdio_fixture, marker, "mark-close"],
              "env" => %{"TOKEN" => %{"binding" => "token"}},
              "start_timeout_ms" => 5_000
            },
            "tools" => %{
              "structured" => %{
                "as" => "workspace.structured",
                "effect" => "write",
                "model_visible" => true
              }
            },
            "ceilings" => %{"timeout_ms" => 5_000}
          }
        }
      })
    )

    output =
      capture_io(fn ->
        run_repl([
          "--manifest",
          manifest_path,
          "--host-config",
          host_path,
          "--env-file",
          env_file,
          "-e",
          "(def x 41)",
          "-e",
          "(+ x 1)"
        ])
      end)

    assert output =~ "#'x\n42\n"

    lifecycle = marker |> File.read!() |> String.split("\n", trim: true)
    assert Enum.count(lifecycle, &String.ends_with?(&1, ":server/discover")) == 1
    assert Enum.count(lifecycle, &String.ends_with?(&1, ":tools/list")) == 2
    assert Enum.count(lifecycle, &(&1 == "session-closed")) == 1
    assert System.get_env(environment_name) == nil
  end

  @tag :tmp_dir
  test "profile evals share mission state and persist outside the source", %{tmp_dir: directory} do
    source = Path.join(directory, "source")
    output_directory = Path.join(directory, "output")
    File.mkdir!(source)
    File.mkdir!(output_directory)
    seed_trace(source, "seed")
    before_sessions = log_analysis_session_pids()

    output =
      capture_io(fn ->
        run_repl([
          "--profile",
          "run-analysis-v1",
          "--resource",
          "traces=#{source}",
          "--session-trace-dir",
          output_directory,
          "-e",
          "(def runs (analysis/runs {}))",
          "-e",
          "(count (get runs \"items\"))"
        ])
      end)

    assert output =~ "Captured traces: 1 file, 1 run"
    assert output =~ "#'runs\n"
    assert output =~ "1\n"
    assert output =~ "Analysis trace:"
    assert File.ls!(source) == ["seed.jsonl"]
    assert [trace_name] = File.ls!(output_directory)
    assert String.starts_with?(trace_name, "run-analysis-")
    assert String.ends_with?(trace_name, ".jsonl")
    assert log_analysis_session_pids() == before_sessions

    trace_path = Path.join(output_directory, trace_name)
    assert {:ok, trace} = TraceLog.new(source: {:file, trace_path})

    assert {:ok, %{"items" => [%{"name" => name, "session_profile" => profile}]}} =
             TraceLog.query(trace, :list_runs, %{})

    assert name == SafeMetadata.fingerprint("ptc.run-analysis.repl")
    assert profile["id"] == "run-analysis-v1"
    assert profile["digest"] =~ ~r/\Asha256:[0-9a-f]{64}\z/
  end

  @tag :tmp_dir
  test "JSONL continue-on-error preserves later feedback and exits unsuccessfully", %{
    tmp_dir: directory
  } do
    source = Path.join(directory, "source")
    output_directory = Path.join(directory, "output")
    File.mkdir!(source)
    File.mkdir!(output_directory)
    seed_trace(source, "seed")
    before_sessions = log_analysis_session_pids()

    output =
      capture_io(fn ->
        assert_raise Mix.Error,
                     ~r|repl/profile_evaluation_failed: profile evaluation failed|,
                     fn ->
                       run_repl([
                         "--profile",
                         "run-analysis-v1",
                         "--resource",
                         "traces=#{source}",
                         "--session-trace-dir",
                         output_directory,
                         "--format",
                         "jsonl",
                         "--continue-on-error",
                         "-e",
                         "(def x 40)",
                         "-e",
                         "missing-value",
                         "-e",
                         "(+ x 2)"
                       ])
                     end
      end)

    records = decode_jsonl(output)

    assert Enum.map(records, & &1["type"]) ==
             [
               "session-started",
               "evaluation",
               "evaluation",
               "evaluation",
               "session-closed",
               "command-error"
             ]

    assert List.first(records)["capture"] == %{
             "traces" => %{"file_count" => 1, "run_count" => 1}
           }

    evaluations = Enum.filter(records, &(&1["type"] == "evaluation"))
    assert Enum.map(evaluations, & &1["result"]["status"]) == ["ok", "error", "ok"]
    assert List.last(evaluations)["result"]["value"] == 42
    assert List.first(evaluations)["result"]["value_available"] == true
    assert List.first(evaluations)["result"]["formatted_truncated"] == false
    assert Enum.at(evaluations, 1)["result"]["continuation_effect"] == "preserved"
    assert List.last(records)["evaluation_indexes"] == [2]
    assert File.regular?(Enum.at(records, -2)["trace_path"])
    assert log_analysis_session_pids() == before_sessions
  end

  @tag :tmp_dir
  test "profile input and persistence failures terminate session owners", %{tmp_dir: directory} do
    source = Path.join(directory, "source")
    input_output = Path.join(directory, "input-output")
    persistence_output = Path.join(directory, "persistence-output")
    File.mkdir!(source)
    File.mkdir!(input_output)
    File.mkdir!(persistence_output)
    seed_trace(source, "seed")
    before_sessions = log_analysis_session_pids()

    capture_io(fn ->
      assert_raise Mix.Error, ~r/could not read the profile script/, fn ->
        run_repl(profile_args(source, input_output) ++ [Path.join(directory, "missing.clj")])
      end
    end)

    assert log_analysis_session_pids() == before_sessions
    File.chmod!(persistence_output, 0o500)

    try do
      capture_io(fn ->
        assert_raise Mix.Error, ~r/profile trace persistence failed/, fn ->
          run_repl(profile_args(source, persistence_output) ++ ["-e", "42"])
        end
      end)

      assert log_analysis_session_pids() == before_sessions
    after
      File.chmod!(persistence_output, 0o700)
    end
  end

  # One real `mix ptc repl` OS process (~2.2 s). In-process JSONL cases in
  # ReplFrontendTest cover session records; this pins the Mix task's stdout.
  @tag :tmp_dir
  @tag :nightly
  test "profile JSONL works through an actual Mix subprocess", %{tmp_dir: directory} do
    source = Path.join(directory, "source")
    output_directory = Path.join(directory, "output")
    File.mkdir!(source)
    File.mkdir!(output_directory)
    seed_trace(source, "seed")

    {output, 0} =
      System.cmd(
        "mix",
        [
          "ptc",
          "repl",
          "--profile",
          "run-analysis-v1",
          "--resource",
          "traces=#{source}",
          "--session-trace-dir",
          output_directory,
          "--format",
          "jsonl",
          "-e",
          "(count (get (analysis/runs {}) \"items\"))"
        ],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}, {"MIX_QUIET", "1"}]
      )

    records = decode_mix_jsonl(output)
    assert Enum.map(records, & &1["type"]) == ["session-started", "evaluation", "session-closed"]
    assert Enum.at(records, 1)["result"]["value"] == 1
    assert File.regular?(List.last(records)["trace_path"])
  end

  # Writing forty sealed fixtures through the production inspection sink takes
  # ~7 s of this case's ~10 s on an idle machine. In a loaded async phase the
  # case ran past the 60 s timeout, so it runs alone.
  @tag :tmp_dir
  test "catalog discovery pages forty safe rows into two independent selected sessions", %{
    tmp_dir: directory
  } do
    cohort = build_private_cohort!(directory, 40)

    catalog_output =
      capture_io(fn ->
        run_repl([
          "--profile",
          "private-run-catalog-v1",
          "--resource",
          "traces=#{cohort.traces}",
          "--resource",
          "inspection=#{cohort.inspection}",
          "--session-trace-dir",
          cohort.catalog_output,
          "--private-unattended",
          "--format",
          "jsonl",
          "-e",
          ~S|(def first-page (analysis/catalog {"state" "admissible" "limit" 20}))|,
          "-e",
          "first-page",
          "-e",
          ~S|(analysis/catalog {"state" "admissible" "limit" 20 "cursor" (get first-page "next_cursor")})|
        ])
      end)

    catalog_records = decode_jsonl(catalog_output)
    evaluations = Enum.filter(catalog_records, &(&1["type"] == "evaluation"))
    first_page = Enum.at(evaluations, 1)["result"]["value"]
    second_page = Enum.at(evaluations, 2)["result"]["value"]

    assert length(first_page["items"]) == 20
    assert length(second_page["items"]) == 20
    assert first_page["truncated"]
    refute second_page["truncated"]
    assert is_binary(first_page["next_cursor"])
    assert second_page["next_cursor"] == nil
    assert first_page["catalog_digest"] == second_page["catalog_digest"]
    assert Enum.all?(first_page["items"] ++ second_page["items"], &(&1["state"] == "admissible"))
    refute catalog_output =~ "private-prompt-"
    refute catalog_output =~ "private-answer-"
    refute catalog_output =~ "private-tool-result-"

    first_batch = first_page["items"] |> Enum.take(16) |> Enum.map(& &1["run_id"])
    later_batch = second_page["items"] |> Enum.take(16) |> Enum.map(& &1["run_id"])

    first_session = run_selected_cohort!(cohort, first_batch, cohort.first_output)
    later_session = run_selected_cohort!(cohort, later_batch, cohort.later_output)

    assert Enum.sort(first_session.run_ids) == Enum.sort(first_batch)
    assert Enum.sort(later_session.run_ids) == Enum.sort(later_batch)
    assert MapSet.disjoint?(MapSet.new(first_session.run_ids), MapSet.new(later_session.run_ids))
    assert first_session.session_id != later_session.session_id

    assert first_session.capture == %{
             "inspection" => %{"file_count" => 16, "run_count" => 16},
             "traces" => %{"file_count" => 16, "run_count" => 16}
           }

    assert later_session.capture == first_session.capture
    refute first_session.output =~ "catalog_digest"
    refute later_session.output =~ "catalog_digest"
    refute first_session.output =~ first_page["catalog_digest"]
    refute later_session.output =~ first_page["catalog_digest"]
  end

  # Active preflight starts the VM-global :req_llm application before it finds the
  # credential missing, and a concurrent command-VM run refuses a prestarted one.
  @tag :tmp_dir
  test "a missing provider credential retains the run diagnostic and remedy", %{
    tmp_dir: directory
  } do
    {manifest_path, host_path} = write_missing_credential_repl(directory)

    for {mission_args, expected_subject} <- [
          {[], "alpha"},
          {["--mission", "review"], "workspace-alpha"}
        ] do
      error =
        assert_raise Mix.Error, fn ->
          run_repl(
            [
              "--manifest",
              manifest_path,
              "--host-config",
              host_path,
              "-e",
              "(+ 1 2)"
            ] ++ mission_args
          )
        end

      assert error.message =~
               "error: repl/command_failed: active_preflight/credential_unavailable: " <>
                 "provider/#{expected_subject}/credentials: a required provider credential is unavailable; " <>
                 "export it, pass --env-file PATH, or use a host file credential; " <>
                 "for credential-free source and helper evaluation, rerun with only " <>
                 "--project PROJECT (or --manifest MANIFEST), optional --mission MISSION, " <>
                 "--inspect-only, and -e EXPR"

      refute error.message =~ "PTC_REPL_ABSENT"
    end
  end

  defp log_analysis_session_pids do
    Process.list()
    |> Enum.filter(fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} ->
          dictionary[:"$initial_call"] == {PtcRunner.Kernel.AnalysisSession, :init, 1}

        nil ->
          false
      end
    end)
    |> Enum.sort()
  end

  defp decode_mix_jsonl(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "==> "))
    |> Enum.map(&Jason.decode!/1)
  end

  defp build_private_cohort!(directory, count) do
    File.chmod!(directory, 0o700)
    seed_root = prepare_private_fixture_root!(Path.join(directory, "cohort-seed"))

    cohort =
      PrivateInspectionFixture.create!(seed_root, command_run_ref(1))

    File.mkdir!(Path.join(directory, "catalog-output"))
    File.mkdir!(Path.join(directory, "first-output"))
    File.mkdir!(Path.join(directory, "later-output"))

    Enum.each(2..count, fn seed ->
      fixture_root = prepare_private_fixture_root!(Path.join(directory, "cohort-#{seed}"))

      fixture =
        PrivateInspectionFixture.create!(
          fixture_root,
          command_run_ref(seed)
        )

      File.cp!(
        Path.join(fixture.traces, "#{fixture.run_id}.jsonl"),
        Path.join(cohort.traces, "#{fixture.run_id}.jsonl")
      )

      File.cp!(
        Path.join(fixture.inspection, "#{fixture.run_id}.ptcins"),
        Path.join(cohort.inspection, "#{fixture.run_id}.ptcins")
      )
    end)

    Map.merge(cohort, %{
      catalog_output: Path.join(directory, "catalog-output"),
      first_output: Path.join(directory, "first-output"),
      later_output: Path.join(directory, "later-output")
    })
  end

  defp prepare_private_fixture_root!(root) do
    directories = [
      root,
      Path.join(root, "traces"),
      Path.join(root, "inspection"),
      Path.join(root, "analysis-traces")
    ]

    Enum.each(directories, fn directory ->
      File.mkdir_p!(directory)
      File.chmod!(directory, 0o700)
    end)

    root
  end

  defp run_selected_cohort!(cohort, run_ids, output_directory) do
    selection = Enum.flat_map(run_ids, &["--run", &1])

    output =
      capture_io(fn ->
        run_repl(
          [
            "--profile",
            "private-run-analysis-v2",
            "--resource",
            "traces=#{cohort.traces}",
            "--resource",
            "inspection=#{cohort.inspection}",
            "--session-trace-dir",
            output_directory,
            "--private-unattended",
            "--format",
            "jsonl",
            "-e",
            ~S|(analysis/runs {"limit" 100})|
          ] ++ selection
        )
      end)

    [started, evaluated, closed] = decode_jsonl(output)

    %{
      output: output,
      session_id: started["session_id"],
      capture: started["capture"],
      run_ids: evaluated["result"]["value"]["items"] |> Enum.map(& &1["run_id"]),
      trace_path: closed["trace_path"]
    }
  end

  defp command_run_ref(seed), do: PrivateInspectionFixture.command_run_ref(10_000 + seed)
end
