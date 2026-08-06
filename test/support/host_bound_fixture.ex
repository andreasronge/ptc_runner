defmodule PtcRunner.TestSupport.HostBoundFixture do
  @moduledoc false

  # Real host-bound runtime services for tests that need a catalog phase 7 will
  # accept. An `:audited_local` declaration requires a runtime binding, and
  # `ProviderRuntimeServices.bound_to?/2` compares the sealed host payload
  # rather than the binding alone, so the binding cannot be invented — it has to
  # come from a sealed host document.

  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation

  @doc """
  Seals runtime services from a minimal host document.

  `revision` distinguishes two hosts, so a test can prove that services sealed
  from one document cannot check a catalog bound to another.
  """
  @spec runtime_services(binary()) :: PtcRunner.Kernel.ProviderRuntimeServices.t()
  def runtime_services(revision \\ "history-v1") when is_binary(revision) do
    document = %{
      "install" => %{
        "history" => %{
          "source" => "ptc_trace_snapshot",
          "installation_revision" => revision,
          "directory" => "traces"
        }
      }
    }

    {:ok, decoded} = HostConfig.decode(document, "/tmp")

    host =
      struct!(HostConfig,
        path: "/tmp/ptc-host.json",
        directory: "/tmp",
        runtime: decoded.runtime,
        limits: decoded.limits,
        credentials: decoded.credentials,
        install: decoded.install
      )

    {:ok, services} = HostInstallation.runtime_services(host)
    services
  end
end
