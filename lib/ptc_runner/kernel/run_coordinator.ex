defmodule PtcRunner.Kernel.RunCoordinator do
  @moduledoc """
  Path-free, provider-inert phases 4 and 5 of command preparation.

  Bundle compilation and public-entry validation run before provider
  declarations. Provider declaration checks inspect only installed aliases;
  they never invoke a builder, credential resolver, preflight callback, OAuth
  context, store, process, or network operation.
  """

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.ApplicationSource
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandSource
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunRequest

  @spec prepare(RunRequest.t(), ProviderRegistry.t()) ::
          {:ok, PreparedRun.t()} | {:error, CommandDiagnostic.t()}
  def prepare(%RunRequest{} = request, %ProviderRegistry{} = registry) do
    with true <- RunRequest.valid?(request),
         true <- ProviderRegistry.valid?(registry),
         {:ok, workflow_bundle} <- compile_required(request.package.workflow_components),
         {:ok, mission_bundle} <- compile_optional(request.package.mission_components),
         :ok <- validate_entry(workflow_bundle, request.package.entry),
         :ok <- validate_providers(request.package.providers, registry),
         {:ok, prepared} <-
           ProviderActivity.start_owned(fn activity ->
             PreparedRun.new(
               request,
               workflow_bundle,
               mission_bundle,
               "(#{request.package.entry} data/input)",
               activity
             )
           end) do
      {:ok, prepared}
    else
      false -> {:error, diagnostic(:internal, :internal_error)}
      {:error, %CommandDiagnostic{} = diagnostic} -> {:error, diagnostic}
      {:error, _reason} -> {:error, diagnostic(:internal, :internal_error)}
    end
  rescue
    _exception -> {:error, diagnostic(:internal, :internal_error)}
  catch
    _kind, _reason -> {:error, diagnostic(:internal, :internal_error)}
  end

  def prepare(_request, _registry),
    do: {:error, diagnostic(:internal, :internal_error)}

  defp compile_required(components) do
    case Kernel.compile_bundle(components) do
      {:ok, bundle} -> {:ok, bundle}
      {:error, reason} -> {:error, bundle_diagnostic(reason, components)}
    end
  end

  defp compile_optional([]), do: {:ok, nil}

  defp compile_optional(components) do
    case Kernel.compile_bundle(components) do
      {:ok, bundle} -> {:ok, bundle}
      {:error, reason} -> {:error, bundle_diagnostic(reason, components)}
    end
  end

  defp bundle_diagnostic(%{reason: reason} = failure, components)
       when reason in [
              :bundle_limit_exceeded,
              :bundle_artifact_exceeded,
              :bundle_diagnostic_exceeded,
              :bundle_compile_heap_exceeded,
              :bundle_compile_timeout
            ],
       do: diagnostic(:bundle, :bundle_limit_exceeded, source_opts(failure, components))

  defp bundle_diagnostic(%{reason: reason} = failure, components)
       when reason in [:component_compile_error, :bundle_compile_error, :bundle_compile_failed],
       do: diagnostic(:bundle, :compile_failed, source_opts(failure, components))

  defp bundle_diagnostic(failure, components),
    do: diagnostic(:bundle, :bundle_invalid, source_opts(failure, components))

  defp source_opts(%{id: id}, components) when is_binary(id) do
    case Enum.find(components, &match?(%Component{id: ^id}, &1)) do
      %Component{} = component -> component_source_opts(component)
      nil -> []
    end
  end

  defp source_opts(_failure, _components), do: []

  defp component_source_opts(%Component{id: id, origin: origin}) do
    name =
      cond do
        ApplicationSource.valid_name?(origin) -> origin
        ApplicationSource.valid_name?(id) -> id
        true -> nil
      end

    case name do
      nil ->
        []

      safe_name ->
        {:ok, source} = CommandSource.new(:component, safe_name)
        [source: source]
    end
  end

  @doc false
  @spec validate_entry(PtcRunner.Kernel.FrozenBundle.t(), binary()) ::
          :ok | {:error, CommandDiagnostic.t()}
  def validate_entry(workflow_bundle, entry) do
    if PreparedRun.entry_callable?(workflow_bundle, entry),
      do: :ok,
      else: {:error, diagnostic(:bundle, :entry_invalid)}
  end

  defp validate_providers(providers, registry) do
    [:workflow, :mission]
    |> Enum.reduce_while(:ok, fn destination, :ok ->
      providers
      |> Map.fetch!(destination)
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {selection, index}, :ok ->
        name = selection["name"]
        occurrence = %{destination: destination, index: index}

        if Map.has_key?(registry.builders, name) do
          {:ok, subject} = CommandSubject.provider(name, :selection, occurrence)

          {:halt,
           {:error, diagnostic(:provider_declaration, :selection_unverifiable, subject: subject)}}
        else
          {:ok, subject} = CommandSubject.provider(name, :declaration, occurrence)

          {:halt,
           {:error, diagnostic(:provider_declaration, :provider_unknown, subject: subject)}}
        end
      end)
      |> case do
        :ok -> {:cont, :ok}
        {:error, _diagnostic} = error -> {:halt, error}
      end
    end)
  end

  defp diagnostic(phase, code, opts \\ []),
    do: CommandDiagnostic.new!(phase, code, opts)
end
