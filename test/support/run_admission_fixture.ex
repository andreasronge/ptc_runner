defmodule PtcRunner.TestSupport.RunAdmissionFixture do
  @moduledoc false
  import PtcRunner.TestSupport.ProviderExecutionFixture
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.RunAdmission

  def fixture(opts \\ []) do
    parent = self()
    block? = Keyword.get(opts, :block, false)

    opts =
      Keyword.put_new(
        opts,
        :body,
        if(block?, do: "(return (tool/fixture {}))", else: "(return {\"answer\" 42})")
      )

    acquire = fn context ->
      scoped_root(parent, context)

      {:ok, capability} =
        Capability.new(
          name: "fixture",
          input_schema: %{"type" => "object", "additionalProperties" => false},
          callback: fn _ ->
            if block? do
              send(parent, {:running, self()})
              receive do: (:finish -> :ok)
            end

            {:ok, %{}}
          end
        )

      {:ok, %{capabilities: [capability], close: Keyword.get(opts, :close, fn -> :ok end)}}
    end

    provider_fixture(Keyword.put(opts, :acquire, acquire))
  end

  def execute(host, fixture),
    do:
      RunAdmission.execute(
        host,
        fixture.prepared,
        fixture.authority,
        fixture.catalog,
        fixture.execution.services
      )
end
