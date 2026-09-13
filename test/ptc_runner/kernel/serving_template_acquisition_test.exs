defmodule PtcRunner.Kernel.ServingTemplateAcquisitionTest do
  # Global trace patterns require a serial case.
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.ApplicationSource
  alias PtcRunner.Kernel.BundleCompiler
  alias PtcRunner.Kernel.ExecutionInput
  alias PtcRunner.Kernel.ExecutionPolicy
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunAdmission
  alias PtcRunner.Kernel.ServingOutcome
  alias PtcRunner.Kernel.ServingTemplate
  alias PtcRunner.Kernel.ValueContract

  @tag :tmp_dir
  test "construction acquires and compiles once and closes the source before sharing", %{
    tmp_dir: dir
  } do
    schema = %{"type" => "object", "additionalProperties" => false}
    path = fixture(dir)

    patterns = [
      {ApplicationPackage, :acquire_directory, 2},
      {ApplicationSource, :open_directory, 1},
      {ApplicationSource, :close, 1},
      {BundleCompiler, :compile, 2},
      {ValueContract, :compile, 1},
      {ExecutionInput, :new, 3},
      {ExecutionPolicy, :new, 1},
      {PublicationAuthority, :new, 1}
    ]

    Enum.each(patterns, fn {module, _, _} = pattern ->
      Code.ensure_loaded!(module)
      :erlang.trace_pattern(pattern, true, [:local])
    end)

    on_exit(fn -> Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:local])) end)
    parent = self()
    host = start_supervised!({RunAdmission, max_concurrent_runs: 16})

    {pid, monitor} =
      spawn_monitor(fn ->
        receive do: (:build -> :ok)
        result = ServingTemplate.from_directory(path, Limits.installed_defaults())
        send(parent, {:constructed, result})
        {:ok, template} = result
        receive do: (:call -> :ok)

        {:ok, unused} = ServingTemplate.reserve(template, %{}, host)
        :ok = ServingTemplate.close(unused)

        outcomes =
          1..16
          |> Task.async_stream(
            fn _ ->
              ServingTemplate.call(template, %{}, host)
            end,
            max_concurrency: 16
          )
          |> Enum.to_list()

        send(parent, {:called, outcomes})
        receive do: (:stop -> :ok)
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    :erlang.trace(pid, true, [:call, :set_on_spawn, {:tracer, self()}])
    send(pid, :build)
    assert_receive {:constructed, {:ok, template}}, 10_000
    delivered = :erlang.trace_delivered(pid)
    assert_receive {:trace_delivered, ^pid, ^delivered}
    calls = traced_calls(pid, [])
    assert Enum.count(calls, &match?({ApplicationPackage, :acquire_directory, _}, &1)) == 1
    assert Enum.count(calls, &match?({ApplicationSource, :open_directory, _}, &1)) == 1
    assert Enum.count(calls, &match?({ApplicationSource, :close, _}, &1)) == 1
    assert Enum.count(calls, &match?({BundleCompiler, :compile, _}, &1)) == 1
    assert Enum.count(calls, &match?({ValueContract, :compile, _}, &1)) == 2
    File.rm_rf!(dir)
    send(pid, :call)
    assert_receive {:called, outcomes}, 10_000
    assert Enum.all?(outcomes, fn {:ok, result} -> ServingOutcome.code(result) == :success end)
    delivered = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^delivered}
    calls = traced_calls(:all, [])

    refute Enum.any?(calls, fn {module, function, _} ->
             module in [ApplicationPackage, ApplicationSource, BundleCompiler] or
               function == :compile
           end)

    for module <- [ExecutionInput, ExecutionPolicy, PublicationAuthority] do
      assert Enum.count(calls, fn
               {m, :new, _} -> m == module
               _ -> false
             end) == 16
    end

    policies = for {ExecutionPolicy, :new, [opts]} <- calls, do: opts

    for key <- [:run_id, :trace_id] do
      assert policies |> Enum.map(&Keyword.fetch!(&1, key)) |> Enum.uniq() |> length() == 16
    end

    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    File.rm_rf!(dir)

    assert Enum.all?(
             1..16
             |> Task.async_stream(fn _ ->
               ValueContract.valid?(template.package.contracts.input, %{}) and
                 ServingTemplate.input_schema(template) == schema and
                 ServingTemplate.close(template) == :ok
             end)
             |> Enum.to_list(),
             &(&1 == {:ok, true})
           )
  end

  @tag :tmp_dir
  test "remaining closed build failures release acquisition without dispatch", %{tmp_dir: dir} do
    patterns = [
      {ApplicationSource, :close, 1},
      {PtcRunner.Kernel.ExecutionSessionOwner, :start, :_},
      {PtcRunner.Kernel.ExecutionSessionOwner, :start_reserved, :_},
      {PtcRunner.Kernel.Dispatcher, :dispatch, :_},
      {PtcRunner.Kernel.EventSink, :start, :_},
      {ExecutionInput, :new, 3},
      {ExecutionPolicy, :new, 1},
      {PublicationAuthority, :new, 1}
    ]

    Enum.each(patterns, fn {module, _, _} = pattern ->
      Code.ensure_loaded!(module)
      :erlang.trace_pattern(pattern, true, [:local])
    end)

    on_exit(fn -> Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:local])) end)

    private = "private-path-payload-credential"

    path =
      fixture(
        dir,
        ~s|(ns app) (defn run {:effect :read :requires ["tool:#{private}"]} [x] (return x))|
      )

    assert_closed_build(path, :environment_invalid)

    path = fixture(dir)
    module = PtcRunner.Kernel.EffectiveApplication
    {^module, original, filename} = :code.get_object_code(module)

    # Replace only the identity builder's module in this serial case. The public
    # constructor still performs real acquisition, compilation and assembly.
    # Restore the original BEAM even when an assertion fails; no production hook.
    for fault <- [:error, :throw, :exit, :identity_error] do
      expression =
        if fault == :identity_error do
          {:tuple, 1, [{:atom, 1, :error}, {:atom, 1, :invalid_effective_application}]}
        else
          {:call, 1, {:remote, 1, {:atom, 1, :erlang}, {:atom, 1, fault}},
           [erl_literal({private, path, %{credential: private}})]}
        end

      forms = [
        {:attribute, 1, :module, module},
        {:attribute, 1, :export, [build_package: 5]},
        {:function, 1, :build_package, 5,
         [{:clause, 1, List.duplicate({:var, 1, :_}, 5), [], [expression]}]}
      ]

      {:ok, ^module, injected} = :compile.forms(forms, [:binary])

      try do
        :code.purge(module)
        assert {:module, ^module} = :code.load_binary(module, filename, injected)
        assert_closed_build(path, :internal_error)
      after
        :code.purge(module)
        {:module, ^module} = :code.load_binary(module, filename, original)
        :code.purge(module)
      end
    end

    assert {:ok, _template} = ServingTemplate.from_directory(path, Limits.installed_defaults())
  end

  defp erl_literal(value), do: :erl_parse.abstract(value)

  defp assert_closed_build(path, code) do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        receive do: (:build -> :ok)

        send(
          parent,
          {:failed_build, ServingTemplate.from_directory(path, Limits.installed_defaults())}
        )

        receive do: (:stop -> :ok)
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    :erlang.trace(pid, true, [:call, :set_on_spawn, {:tracer, parent}])
    send(pid, :build)
    assert_receive {:failed_build, {:error, ^code}}, 10_000
    delivered = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^delivered}
    calls = traced_calls(:all, [])

    assert [{ApplicationSource, :close, [source]}] =
             Enum.filter(calls, &match?({ApplicationSource, :close, _}, &1))

    refute Process.alive?(source.pid)
    # Omit-input acquisition creates only its resource-free empty placeholder.
    assert calls == [
             {ApplicationSource, :close, [source]},
             {ExecutionInput, :new, [%{}, :normal, nil]}
           ]

    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end

  defp fixture(dir, source \\ "(ns app) (defn run {:effect :read} [x] (return x))") do
    schema = %{"type" => "object", "additionalProperties" => false}
    path = Path.join(dir, "app.json")
    File.write!(Path.join(dir, "app.clj"), source)
    File.write!(Path.join(dir, "schema.json"), Jason.encode!(schema))

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "app", "path" => "app.clj"}],
          "entry" => "app/run"
        },
        "missions" => %{"same" => %{"components" => [%{"id" => "app", "path" => "app.clj"}]}},
        "input" => %{"path" => "never-opened.json"},
        "contracts" => %{
          "input_schema" => %{"path" => "schema.json"},
          "result_schema" => %{"path" => "schema.json"}
        }
      })
    )

    path
  end

  defp traced_calls(pid, calls) do
    receive do
      {:trace, traced_pid, :call, call} when pid == :all or pid == traced_pid ->
        traced_calls(pid, [call | calls])
    after
      0 -> calls
    end
  end
end
