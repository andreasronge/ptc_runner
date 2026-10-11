defmodule PtcRunner.LiveStatus do
  @moduledoc """
  Opt-in live status reporting for one Kernel run.

  Frontends translate explicit targets or `PTC_VIEWER_URL` into a callback
  consumed by `PtcRunner.Kernel.Progress`. `PTC_VIEWER_TOKEN` authenticates HTTP
  delivery. Embedders attach the callback explicitly with `configure/2`.
  Labels, environment settings and target composition stay in this frontend.
  A slow, dead or rejecting Viewer is isolated by the kernel's progress port.
  """

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.Progress
  alias PtcRunner.LiveStatus.Config
  alias PtcRunner.LiveStatus.HTTP
  alias PtcRunner.LiveStatus.Target
  alias PtcRunner.Utf8

  @doc false
  @spec external_target(binary() | nil) :: Target.t() | nil
  def external_target(""), do: external_target(nil)

  def external_target(label) do
    %{url: url, token: token} = Config.read()

    case url do
      url when is_binary(url) and url != "" ->
        case Target.new(
               fn run_id, frame -> HTTP.report_http(url, run_id, frame, token) end,
               label: label
             ) do
          {:ok, target} -> target
          _error -> nil
        end

      _absent ->
        nil
    end
  end

  @doc false
  @spec application_label_for(ApplicationPackage.t(), binary()) :: binary()
  def application_label_for(%ApplicationPackage{} = package, application)
      when is_binary(application) do
    name = get_in(package.manifest, ["labels", "name"]) || Path.basename(application)
    application_label(name, package.entry)
  end

  @doc false
  @spec application_label(binary(), binary()) :: binary()
  def application_label(name, entry) when is_binary(name) and is_binary(entry),
    do: Utf8.truncate_valid("#{name} · #{entry}", 256)

  @doc "Builds a frontend sink with label and optional external Viewer delivery."
  @spec sink(Target.t() | binary() | nil) :: Progress.sink() | nil
  @spec sink(Target.t() | binary() | nil, binary() | nil) :: Progress.sink() | nil
  def sink(target, fallback_label \\ nil)
  def sink(nil, _fallback_label), do: nil

  def sink(url, fallback_label) when is_binary(url) do
    token = Config.read().token

    fn run_id, frame ->
      HTTP.report_http(url, run_id, Map.put(frame, :label, fallback_label), token)
    end
  end

  def sink(%Target{} = target, fallback_label) do
    fn run_id, frame ->
      Target.report(
        target,
        run_id,
        Map.put(frame, :label, Target.label(target) || fallback_label)
      )
    end
  end

  @doc "Attaches explicit frontend progress to a run configuration."
  def configure(config, target \\ nil) do
    configured_label = config_label(config)

    label =
      case System.get_env("PTC_VIEWER_LABEL") do
        value when is_binary(value) and value != "" -> value
        _absent -> configured_label
      end

    target = target || external_target(label)
    %{config | progress_sink: sink(target, configured_label)}
  end

  defp config_label(config) do
    case config.labels do
      %{"name" => "sha256:" <> _hash} -> nil
      %{"name" => name} when is_binary(name) and name != "" -> Utf8.truncate_valid(name, 256)
      _absent -> nil
    end
  end

  @doc false
  def attach_runtime(runtime, opts) do
    case Keyword.fetch(opts, :live_status) do
      {:ok, %Target{} = target} -> attach_target(runtime, target)
      {:ok, _invalid} -> {:error, :invalid_command_runtime}
      :error -> attach_target(runtime, nil)
    end
  end

  def attach_target(runtime, target) do
    if is_nil(target) or Target.valid?(target),
      do: attach_valid_target(runtime, target),
      else: {:error, :invalid_command_runtime}
  end

  defp attach_valid_target(runtime, target) do
    setup = fn package, application ->
      label = application_label_for(package, application)
      external = external_target(label)

      selected =
        case {target, external} do
          {nil, external} ->
            external

          {local, nil} ->
            local

          {local, external} ->
            if Target.append_external?(local),
              do: elem(Target.compose([local, external]), 1),
              else: local
        end

      sink(selected)
    end

    CommandRuntime.with_progress(runtime, setup)
  end
end
