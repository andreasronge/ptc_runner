defmodule PtcRunner.Kernel.ServingRequestTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.{
    PreparedRun,
    ProviderExecution,
    RunBuilder,
    RunCoordinator,
    ServingRequest
  }

  import PtcRunner.TestSupport.ProviderExecutionFixture

  test "input-free preparation is sealed but every evaluator entry refuses it" do
    fixture = provider_fixture()
    request = fixture.prepared.request
    assert {:ok, serving} = ServingRequest.new(request.package, request.policy)
    assert {:ok, prepared} = RunCoordinator.prepare(serving, fixture.catalog)
    assert PreparedRun.valid?(prepared)

    assert {:error, :invalid_prepared_run} =
             RunBuilder.open_prepared_sinks(prepared, nil, self())

    assert {:error, :invalid_prepared_run} =
             RunBuilder.open_prepared_sinks(prepared, nil, self(), nil)

    assert {:error, :invalid_prepared_run} =
             RunBuilder.build_borrowed_owned(prepared, nil, nil, %{}, nil)

    assert {:error, :invalid_prepared_run} = RunBuilder.build(prepared, nil, [])
    assert {:error, :invalid_prepared_run} = RunBuilder.build_prepared(prepared, nil, [])

    assert {:error, :invalid_prepared_run} =
             RunBuilder.build_prepared_owned(prepared, nil, nil, %{})

    assert {:error, :invalid_prepared_run} =
             RunBuilder.build_active_owned(prepared, nil, nil, nil, nil, %{}, %{})

    assert {:error, :invalid_prepared_run} =
             RunBuilder.build_mission_repl_owned(prepared, nil, nil, %{}, nil)

    assert {:error, :invalid_prepared_run} =
             RunBuilder.build_mission_repl_active_owned(
               prepared,
               nil,
               nil,
               nil,
               nil,
               %{},
               %{},
               nil
             )

    assert {:error, :invalid_prepared_run} =
             ProviderExecution.execute(prepared, nil, %{}, nil, nil, nil, self(), :run)

    assert {:error, :invalid_prepared_run} =
             ProviderExecution.open_repl(prepared, nil, %{}, nil, nil, self())

    assert {:error, :invalid_prepared_run} =
             ProviderExecution.open_repl(prepared, nil, %{}, nil, nil, nil, self())

    PreparedRun.close(prepared)
    PreparedRun.close(fixture.prepared)
  end

  test "selected private data refuses input-free serving preparation" do
    fixture =
      provider_fixture(
        descriptor_data_class: :private_inspection,
        descriptor_accepts_data: [:normal, :private_inspection]
      )

    request = fixture.prepared.request
    {:ok, serving} = ServingRequest.new(request.package, request.policy)
    assert {:error, :private_result_unservable} = RunCoordinator.prepare(serving, fixture.catalog)
    PreparedRun.close(fixture.prepared)
  end
end
