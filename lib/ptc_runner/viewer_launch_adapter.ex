defmodule PtcRunner.ViewerLaunchAdapter do
  @moduledoc false

  alias PtcRunner.Dotenv
  alias PtcRunner.Kernel.CommandPresentation
  alias PtcRunner.LiveStatus.Target
  alias PtcRunner.MixCommandAdapter
  alias PtcRunner.StandaloneCLI

  @type config :: %{
          required(:project) => binary(),
          required(:frontend) => :mix | :standalone,
          optional(:env_file) => binary() | nil,
          optional(:workflow_label) => binary()
        }
  @type request ::
          {:workflow, %{required(:input) => binary()}}
          | {:mission, %{required(:name) => binary(), required(:expression) => binary()}}

  @doc false
  @spec launch(config(), request(), (binary(), map() -> term())) ::
          {non_neg_integer(), binary()}
  def launch(%{project: project, frontend: frontend} = config, request, report)
      when is_binary(project) and frontend in [:mix, :standalone] and is_function(report, 2) do
    with {:ok, argv} <- arguments(project, request),
         {:ok, argv} <- attach_env_file(argv, config),
         {:ok, target} <- Target.new(report, label: launch_label(config, request)),
         {%CommandPresentation{} = presentation, captured} <-
           execute_scoped(config, fn ->
             capture_output(fn -> execute(frontend, argv, target) end)
           end) do
      output = presentation_output(presentation, captured)
      {presentation.exit_status, output}
    else
      _invalid -> {1, "viewer launch failed: invalid launch request"}
    end
  rescue
    exception -> {1, "viewer launch failed: " <> Exception.message(exception)}
  catch
    _kind, reason -> {1, "viewer launch failed: " <> inspect(reason)}
  end

  def launch(_config, _request, _report),
    do: {1, "viewer launch failed: invalid launch request"}

  defp arguments(project, {:workflow, %{input: input}}) when is_binary(input),
    do: {:ok, ["run", project, "--input", input]}

  defp arguments(project, {:mission, %{name: name, expression: expression}})
       when is_binary(name) and is_binary(expression),
       do: {:ok, ["repl", "--project", project, "--mission", name, "-e", expression]}

  defp arguments(_project, _request), do: {:error, :invalid_launch_request}

  defp attach_env_file(argv, %{env_file: env_file}) when is_binary(env_file) and env_file != "",
    do: {:ok, argv ++ ["--env-file", env_file]}

  defp attach_env_file(argv, %{env_file: nil}), do: {:ok, argv}
  defp attach_env_file(argv, config) when not is_map_key(config, :env_file), do: {:ok, argv}
  defp attach_env_file(_argv, _config), do: {:error, :invalid_launch_request}

  defp execute_scoped(%{env_file: env_file}, fun) when is_binary(env_file),
    do: Dotenv.with_file_scope(env_file, fun)

  defp execute_scoped(_config, fun), do: fun.()

  defp launch_label(%{workflow_label: label}, {:workflow, _request})
       when is_binary(label) and byte_size(label) in 1..256,
       do: label

  defp launch_label(_config, {:workflow, _request}), do: "workflow"

  defp launch_label(_config, {:mission, %{name: name}}) when is_binary(name),
    do: String.slice("mission · " <> name, 0, 256)

  defp execute(:mix, argv, target),
    do: MixCommandAdapter.execute(argv, live_status: target, terminal_attached: false)

  defp execute(:standalone, argv, target),
    do: StandaloneCLI.execute(argv, live_status: target, terminal_attached: false)

  defp capture_output(fun) do
    {:ok, device} = StringIO.open("")
    original = Process.group_leader()
    true = Process.group_leader(self(), device)

    try do
      result = fun.()
      {_input, output} = StringIO.contents(device)
      {result, output}
    after
      Process.group_leader(self(), original)
      StringIO.close(device)
    end
  end

  defp presentation_output(presentation, captured) do
    [captured, presentation.stdout, presentation.stderr]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join()
  end
end
