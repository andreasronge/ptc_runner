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
    source = "(ns app) (defn run {:effect :read} [x] (return x))"
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

  defp traced_calls(pid, calls) do
    receive do
      {:trace, traced_pid, :call, call} when pid == :all or pid == traced_pid ->
        traced_calls(pid, [call | calls])
    after
      0 -> calls
    end
  end
end
