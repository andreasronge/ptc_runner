defmodule PtcRunner.Kernel.CommandResults do
  @moduledoc "Internal builders for command result payloads."

  alias PtcRunner.Kernel.CommandDeclaration
  alias PtcRunner.Kernel.DocumentationLibrary

  @doctor_notice "doctor --connect may perform one or more real provider requests and may incur provider cost"
  @run_notice "set PTC_VIEWER_URL; it reports an externally started run to a Viewer Live tab"
  @viewer_notice "for an externally started run, use the Viewer URL printed at startup as PTC_VIEWER_URL when it is loopback; otherwise use an address that reaches the Viewer"
  @init_notices [
    "DIRECTORY must not already exist",
    "init assembles the complete scaffold or selected example tree and publishes it atomically without replacing anything",
    "to add PtcRunner to an existing repository, initialize a new sibling or subdirectory and deliberately copy or move the generated files the repository wants"
  ]
  @doc "Builds readiness from the provider checks in a doctor report."
  @spec doctor_readiness([map()]) :: String.t()
  def doctor_readiness([]), do: "not_applicable"

  def doctor_readiness(provider_checks) when is_list(provider_checks) do
    if Enum.any?(provider_checks, &(&1["status"] == "skipped")),
      do: "unverified",
      else: "ready"
  end

  @doc "Builds the declared help topic for the selected frontend."
  @spec help_result(atom(), :standalone | :mix) :: map()
  def help_result(topic, frontend \\ :standalone) do
    if topic in CommandDeclaration.topics() and frontend in [:standalone, :mix] do
      %{
        "topic" => Atom.to_string(topic),
        "usage" => CommandDeclaration.usage(topic),
        "options" => CommandDeclaration.help_options(topic, frontend),
        "notices" => help_notices(topic)
      }
    else
      raise ArgumentError, "invalid help topic"
    end
  end

  defp help_notices(:doctor), do: [@doctor_notice]
  defp help_notices(:init), do: @init_notices
  defp help_notices(:run), do: [@run_notice]
  defp help_notices(:viewer), do: [@viewer_notice]
  defp help_notices(_topic), do: []

  @doc "Builds the current release identity."
  @spec version_result() :: map()
  def version_result do
    identity = PtcRunner.BuildIdentity.current()

    %{
      "version" => identity.version,
      "source_revision" => identity.source_revision,
      "source_dirty" => identity.source_dirty
    }
  end

  @doc """
  Builds the `docs` result: the served listing, or one embedded page.
  """
  @spec docs_result(binary() | nil | {:search, binary()}) :: map()
  def docs_result(nil), do: %{"pages" => DocumentationLibrary.listing()}

  def docs_result({:search, term}) when is_binary(term), do: DocumentationLibrary.search(term)

  def docs_result(page) when is_binary(page) do
    case DocumentationLibrary.fetch(page) do
      {:ok, content} -> %{"page" => page, "content" => content}
      :error -> raise ArgumentError, "invalid docs page"
    end
  end
end
