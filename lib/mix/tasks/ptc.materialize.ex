defmodule Mix.Tasks.Ptc.Materialize do
  @shortdoc "Materializes model-authored source as a gated candidate component"
  @moduledoc """
  Turns model-authored source into `{candidate.clj, descriptor.json}` and
  reports whether it is fit to promote.

      mix ptc.materialize MANIFEST --workflow --component ID --out DIR --source authored.clj
      mix ptc.materialize MANIFEST --target-mission NAME --component ID --out DIR \\
        --from-result results/run.json --result-pointer /value/source
      mix ptc.materialize MANIFEST --workflow --component ID --out DIR --source authored.clj \\
        --origin-run-id run-2026-08-03-0001 --accept-widened-effect

  A model can author a working library inside a run, but a runtime `defn` dies
  at end of run: it is not in the frozen bundle, not covered by a component
  source hash, and absent from the mission inventory. This task closes that
  loop by making the authored bytes a real component candidate, which a later
  run can evaluate through `mix ptc run --component-override-descriptor`.

  Promotion stays an explicit human decision. This task does not promote
  anything; it makes the decision cheap to reach and well evidenced.

  ## Source acquisition

  `--source` reads raw candidate bytes. `--from-result` reads a result artifact
  written by `mix ptc run --output`/`--private-output` and resolves one RFC 6901
  JSON pointer to one string, because a result artifact is JSON, not raw Lisp.
  A non-string or absent target is refused rather than coerced.

  `--workflow` targets the selected workflow occurrence. `--target-mission
  NAME` targets exactly that declared mission; supplying neither or both is
  invalid. The target is written into the closed override descriptor.

  ## Publication

  `--out` must not exist. It is created exclusively at mode 0700 with both
  files restricted to 0600 before content is written, because a candidate
  extracted from a private artifact must not be declassified by publishing it.
  A refused candidate leaves nothing behind.

  ## The gate

  The candidate is re-acquired through the descriptor just written — the exact
  path a run takes — and judged on whether it compiles, whether its
  prompt-visible exports declare a signature and docstring, and whether any
  export reaches further than the base it replaces.

  Every criterion is intrinsic to the candidate or relative to its base. The
  gate does **not** check capability grants: real capability names exist only
  after provider acquisition, so a candidate naming a capability no provider
  grants passes here and fails at run-time assembly. The gate narrows the
  distance to that failure; it does not remove it.

  A widening is refused unless `--accept-widened-effect` is given, which is
  recorded in the report and in the descriptor's provenance. An override
  changes which source compiles, never what compilation permits, so a widening
  is not a security hole — but it is a different risk profile and must not pass
  silently.

  ## Provenance

  `--origin-run-id`, `--origin-prompt-hash`, and `--origin-authored-at` record
  who authored the candidate. These are **operator-asserted and verified by
  nothing**: a run id is a claim about origin, not evidence of it. There is no
  model-id option, because a descriptor is a published artifact and the raw
  model selector must not be published; the authoring model is reachable
  through the run id.
  """

  use Mix.Task

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CandidateArtifact
  alias PtcRunner.Kernel.CandidatePromotion
  alias PtcRunner.Kernel.ComponentOverride
  alias PtcRunner.Kernel.StrictJSON

  @usage "usage: mix ptc.materialize MANIFEST (--workflow | --target-mission NAME) --component ID --out DIR " <>
           "(--source PATH | --from-result PATH --result-pointer POINTER) " <>
           "[--origin-run-id ID] [--origin-prompt-hash sha256:...] " <>
           "[--origin-authored-at RFC3339] [--accept-widened-effect]"

  @max_result_bytes 1_048_576
  @max_source_bytes 1_048_576

  @impl Mix.Task
  def run(argv) do
    start_core_application!()

    case OptionParser.parse(argv,
           strict: [
             component: :string,
             workflow: :boolean,
             target_mission: :string,
             out: :string,
             source: :string,
             from_result: :string,
             result_pointer: :string,
             origin_run_id: :string,
             origin_prompt_hash: :string,
             origin_authored_at: :string,
             accept_widened_effect: :boolean
           ]
         ) do
      {opts, [manifest], []} ->
        opts |> materialize(manifest) |> report()

      {_opts, _arguments, invalid} when invalid != [] ->
        Mix.raise("invalid ptc.materialize options: #{inspect(invalid)}")

      _other ->
        Mix.raise(@usage)
    end
  end

  defp materialize(opts, manifest) do
    with {:ok, component_id} <- required(opts, :component),
         {:ok, target} <- target(opts),
         {:ok, out} <- required(opts, :out),
         {:ok, source} <- candidate_source(opts),
         {:ok, base} <- acquire(manifest, []),
         {:ok, base_source} <- installed_source(base, target, component_id),
         {:ok, published} <-
           publish(out, source, descriptor(target, component_id, base_source, opts)),
         {:ok, candidate} <- gate_acquire(manifest, published),
         report <- evaluate(base, candidate, opts) do
      finish(report, published)
    end
  end

  defp finish(%{outcome: :pass} = report, published), do: {:ok, report, published}

  defp finish(report, published) do
    case CandidateArtifact.discard(published) do
      :ok -> {:refused, report}
      {:error, :candidate_cleanup_failed} -> {:error, :candidate_cleanup_failed}
    end
  end

  defp evaluate(base, candidate, opts) do
    CandidatePromotion.evaluate(base, candidate,
      accept_widened_effect: Keyword.get(opts, :accept_widened_effect, false)
    )
  end

  defp gate_acquire(manifest, published) do
    case acquire(manifest, component_override_descriptor: published.descriptor) do
      {:ok, package} ->
        {:ok, package}

      {:error, reason} ->
        case CandidateArtifact.discard(published) do
          :ok -> {:error, reason}
          {:error, :candidate_cleanup_failed} -> {:error, :candidate_cleanup_failed}
        end
    end
  end

  defp acquire(manifest, opts) do
    case ApplicationPackage.request_directory(manifest, [result_projection: :native] ++ opts) do
      {:ok, request} -> {:ok, request.package}
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish(out, source, descriptor), do: CandidateArtifact.publish(out, source, descriptor)

  defp descriptor(target, component_id, base_source, opts) do
    # source_hash and path are derived by CandidateArtifact from the bytes it
    # actually writes, so a descriptor cannot name source published beside it.
    %{
      "target" => target,
      "component_id" => component_id,
      "base_source_hash" => ComponentOverride.hash(base_source)
    }
    |> maybe_put_provenance(opts)
  end

  defp maybe_put_provenance(descriptor, opts) do
    provenance =
      %{}
      |> put_present("run_id", Keyword.get(opts, :origin_run_id))
      |> put_present("prompt_hash", Keyword.get(opts, :origin_prompt_hash))
      |> put_present("authored_at", Keyword.get(opts, :origin_authored_at))
      |> put_acceptance(Keyword.get(opts, :accept_widened_effect, false))

    if provenance == %{},
      do: descriptor,
      else: Map.put(descriptor, "provenance", provenance)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_acceptance(map, false), do: map
  defp put_acceptance(map, true), do: Map.put(map, "accept_widened_effect", true)

  defp installed_source(package, %{"environment" => "workflow"}, component_id) do
    case CandidatePromotion.component_source(package, "workflow", component_id) do
      {:ok, source} -> {:ok, source}
      :error -> {:error, :override_component_not_selected}
    end
  end

  defp installed_source(package, %{"environment" => "mission", "mission" => name}, component_id) do
    case CandidatePromotion.component_source(package, {:mission, name}, component_id) do
      {:ok, source} -> {:ok, source}
      :error -> {:error, :override_component_not_selected}
    end
  end

  defp target(opts) do
    case {Keyword.get(opts, :workflow, false), Keyword.get(opts, :target_mission)} do
      {true, nil} ->
        {:ok, %{"environment" => "workflow"}}

      {false, name} when is_binary(name) ->
        {:ok, %{"environment" => "mission", "mission" => name}}

      _ ->
        {:error, :invalid_override_target}
    end
  end

  defp candidate_source(opts) do
    case {Keyword.get(opts, :source), Keyword.get(opts, :from_result)} do
      {nil, nil} ->
        {:error, :missing_candidate_source}

      {source, nil} ->
        read_bounded_source(
          source,
          @max_source_bytes,
          :candidate_source_too_large,
          :unreadable_candidate_source
        )

      {nil, result} ->
        extract_source(result, Keyword.get(opts, :result_pointer))

      {_source, _result} ->
        {:error, :conflicting_candidate_source}
    end
  end

  # Read at most the applicable limit plus one byte. Reading the whole file and
  # checking its size afterwards lets an oversized input exhaust the VM before
  # the documented size error is ever returned, and a stat-then-read pair races
  # against a file that grows in between.
  defp read_bounded_source(path, limit, too_large, unreadable) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        try do
          case IO.binread(device, limit + 1) do
            data when is_binary(data) and byte_size(data) > limit -> {:error, too_large}
            data when is_binary(data) -> {:ok, data}
            :eof -> {:ok, ""}
            _other -> {:error, unreadable}
          end
        after
          File.close(device)
        end

      {:error, _reason} ->
        {:error, unreadable}
    end
  end

  # A result artifact is JSON, so extraction is explicit and bounded: one
  # pointer, one string, no search for something source-shaped.
  defp extract_source(_path, nil), do: {:error, :missing_result_pointer}

  defp extract_source(path, pointer) do
    with {:ok, raw} <- read_bounded(path),
         {:ok, decoded} <- StrictJSON.decode(raw),
         {:ok, segments} <- pointer_segments(pointer),
         {:ok, value} <- resolve(decoded, segments) do
      if is_binary(value), do: {:ok, value}, else: {:error, :result_pointer_not_a_string}
    end
  end

  defp read_bounded(path) do
    read_bounded_source(
      path,
      @max_result_bytes,
      :result_artifact_too_large,
      :unreadable_result_artifact
    )
  end

  # RFC 6901: the empty string points at the whole document.
  defp pointer_segments(""), do: {:ok, []}

  defp pointer_segments("/" <> rest) do
    segments =
      rest
      |> String.split("/")
      |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))

    {:ok, segments}
  end

  defp pointer_segments(_pointer), do: {:error, :invalid_result_pointer}

  defp resolve(value, []), do: {:ok, value}

  defp resolve(value, [segment | rest]) when is_map(value) do
    case Map.fetch(value, segment) do
      {:ok, child} -> resolve(child, rest)
      :error -> {:error, :result_pointer_missing}
    end
  end

  # Array indices are part of RFC 6901 evaluation, so a result whose source sits
  # under a list is reachable.
  defp resolve(value, [segment | rest]) when is_list(value) do
    case Integer.parse(segment) do
      {index, ""} when index >= 0 ->
        case Enum.fetch(value, index) do
          {:ok, child} -> resolve(child, rest)
          :error -> {:error, :result_pointer_missing}
        end

      _other ->
        {:error, :result_pointer_missing}
    end
  end

  defp resolve(_value, _segments), do: {:error, :result_pointer_missing}

  defp required(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, {:missing_option, key}}
      value -> {:ok, value}
    end
  end

  defp report({:ok, report, published}) do
    Mix.shell().info("candidate ready: #{published.directory}")
    print_criteria(report)

    Mix.shell().info(
      "promotion is a human decision: review the candidate, then run it with " <>
        "mix ptc run MANIFEST --component-override-descriptor #{published.descriptor}"
    )
  end

  defp report({:refused, report}) do
    print_criteria(report)
    Mix.raise("candidate refused: #{failing(report)}")
  end

  defp report({:error, reason}), do: Mix.raise("ptc.materialize failed: #{inspect(reason)}")

  defp print_criteria(%{criteria: criteria, environment: environment}) do
    Mix.shell().info("environment: #{environment || "unresolved"}")

    Enum.each(criteria, fn criterion ->
      Mix.shell().info("  #{criterion.id} #{criterion.status}: #{criterion.summary}")
      print_detail(criterion.detail)
    end)
  end

  defp print_detail(detail) when detail == %{}, do: :ok

  defp print_detail(detail) do
    detail
    |> Enum.reject(fn {_key, value} -> value in [[], %{}, nil] end)
    |> Enum.each(fn {key, value} ->
      Mix.shell().info("      #{key}: #{inspect(value, limit: :infinity)}")
    end)
  end

  defp failing(%{criteria: criteria}) do
    criteria
    |> Enum.filter(&(&1.status == :fail))
    |> Enum.map_join(", ", & &1.id)
  end

  defp start_core_application! do
    case Application.ensure_all_started(:ptc_runner) do
      {:ok, _started} -> :ok
      {:error, reason} -> Mix.raise("could not start PtcRunner: #{inspect(reason)}")
    end
  end
end
