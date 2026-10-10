defmodule Mix.Tasks.Ptc.CheckLayers do
  use Mix.Task

  import Mix.Compilers.Elixir, only: [read_manifest: 1, source: 2]

  @shortdoc "Rejects new or stale forbidden layer dependencies"
  @moduledoc """
  Checks the compile, export and runtime references used by `mix xref graph`.

  Run `mix ptc.check_layers`. `--baseline PATH` selects an exact directed-pair
  JSON baseline (default: `.layer-baseline.json`). Each entry has `from`, `to`
  and a removal `issue`. The gate has no baseline write or blessing mode.

  Classification uses module names, including protocol implementations, rather
  than source directories. Unclassified modules fail closed. Infrastructure is
  enumerated below; every outgoing edge must remain neutral, which enforces
  transitive neutrality without allowing a namespace exemption.
  """

  @infrastructure ~w(PtcRunner.BuildIdentity PtcRunner.ChildEnvironment PtcRunner.HTTPEndpoint PtcRunner.Utf8)
  @kernel ~w(PtcRunner PtcRunner.Kernel PtcRunner.LLM PtcRunner.Sandbox)
  @frontend ~w(PtcRunner.Application PtcRunner.CLILogger PtcRunner.CLIProgress PtcRunner.Dotenv PtcRunner.LiveStatus PtcRunner.MixCommandAdapter PtcRunner.MixCommandRuntime PtcRunner.ProfileDiagnosticCatalog PtcRunner.ReplError PtcRunner.ReplFrontend PtcRunner.ReplLineEditor PtcRunner.ReplProfileRunner PtcRunner.ReplSessionRunner PtcRunner.ReplSupport PtcRunner.StandaloneCLI PtcRunner.StandaloneCommandRuntime PtcRunner.TranscriptFrontend PtcRunner.ViewerFrontend PtcRunner.ViewerLaunchAdapter PtcRunner.ViewerSnapshotStore)
  @elixir_apps [:elixir, :logger]
  @approved_external_apps []
  @removal_issues [2230, 2231, 2232, 2233, 2234]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [baseline: :string])
    if rest != [] or invalid != [], do: Mix.raise("Usage: mix ptc.check_layers [--baseline PATH]")
    Mix.Task.run("compile")

    {modules, sources} = read_manifest(Path.join(Mix.Project.manifest_path(), "compile.elixir"))
    if Enum.empty?(modules), do: Mix.raise("layer gate: empty compiler manifest")

    sources = Enum.filter(sources, fn {path, _} -> String.starts_with?(path, "lib/") end)

    layers =
      for {_, entry} <- sources,
          module <- source(entry, :modules),
          into: %{},
          do: {module, classify(inspect(module))}

    unknown = for {module, nil} <- layers, do: "unclassified module: #{inspect(module)}"

    edges =
      for {path, entry} <- sources,
          String.starts_with?(path, "lib/"),
          from <- source(entry, :modules),
          to <- references(entry),
          from != to,
          forbidden?(layers[from], layers[to], to),
          into: MapSet.new(),
          do: {inspect(from), inspect(to)}

    baseline = read_baseline(Keyword.get(opts, :baseline, ".layer-baseline.json"))

    errors =
      unknown ++
        differences(edges, baseline, "new forbidden edge") ++
        differences(baseline, edges, "stale baseline edge")

    if errors != [], do: Mix.raise(Enum.join(Enum.sort(errors), "\n"))

    Mix.shell().info(
      "layer gate: #{map_size(layers)} modules classified; #{MapSet.size(edges)} baselined edges"
    )
  end

  defp references(entry) do
    source(entry, :compile_references) ++
      source(entry, :export_references) ++
      source(entry, :runtime_references)
  end

  defp classify("Jason.Encoder." <> module), do: classify(module)
  defp classify("PtcRunner.SiteGuides." <> _), do: :frontend
  defp classify("Inspect." <> module), do: classify(module)
  defp classify("String.Chars." <> module), do: classify(module)
  defp classify(module) when module in @infrastructure, do: :infrastructure
  defp classify(module) when module in @kernel, do: :kernel
  defp classify("PtcRunner.Lisp"), do: :lisp
  defp classify("PtcRunner.Lisp." <> _), do: :lisp
  defp classify("PtcRunner.Kernel." <> _), do: :kernel
  defp classify("PtcRunner.LLM." <> _), do: :kernel
  defp classify("Mix.Tasks." <> _), do: :frontend
  defp classify("PtcRunner.Bench." <> _), do: :frontend

  defp classify(module) do
    if Enum.any?(@frontend, &(module == &1 or String.starts_with?(module, &1 <> "."))),
      do: :frontend
  end

  defp forbidden?(:lisp, layer, _), do: layer in [:kernel, :frontend]
  defp forbidden?(:kernel, :frontend, _), do: true
  defp forbidden?(:infrastructure, :infrastructure, _), do: false

  defp forbidden?(:infrastructure, nil, module) do
    not (otp_module?(module) or approved_application?(module))
  end

  defp forbidden?(:infrastructure, _, _), do: true
  defp forbidden?(_, _, _), do: false

  defp otp_module?(module) do
    case :code.which(module) do
      :preloaded ->
        true

      path when is_list(path) ->
        otp_lib = Path.join(List.to_string(:code.root_dir()), "lib") <> "/"
        String.starts_with?(Path.expand(List.to_string(path)), otp_lib)

      _ ->
        false
    end
  end

  defp approved_application?(module) do
    case :application.get_application(module) do
      {:ok, app} -> app in (@elixir_apps ++ @approved_external_apps)
      :undefined -> false
    end
  end

  defp read_baseline(path) do
    entries = path |> File.read!() |> Jason.decode!()
    unless is_list(entries), do: Mix.raise("layer baseline must be a list")

    pairs =
      Enum.map(entries, fn
        %{"from" => from, "to" => to, "issue" => issue} = entry
        when is_binary(from) and is_binary(to) and issue in @removal_issues and
               map_size(entry) == 3 ->
          unless forbidden?(classify(from), classify(to), nil),
            do: Mix.raise("baseline pair is not forbidden: #{from} -> #{to}")

          {from, to}

        entry ->
          Mix.raise("invalid layer baseline entry: #{inspect(entry)}")
      end)

    if length(pairs) != MapSet.size(MapSet.new(pairs)),
      do: Mix.raise("duplicate layer baseline pair")

    MapSet.new(pairs)
  end

  defp differences(left, right, label) do
    left
    |> MapSet.difference(right)
    |> Enum.map(fn {from, to} -> "#{label}: #{from} -> #{to}" end)
  end
end
