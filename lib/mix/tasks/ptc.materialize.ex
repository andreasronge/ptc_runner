defmodule Mix.Tasks.Ptc.Materialize do
  @shortdoc "Exports installed component source or materializes a gated candidate"
  @moduledoc """
  Exports installed effective source, or turns authored source into
  `{candidate.clj, descriptor.json}` and reports whether it is fit to promote.

      mix ptc.materialize MANIFEST --workflow --component ID --source-out PATH
      mix ptc.materialize MANIFEST --workflow --component ID --out DIR --source authored.clj
      mix ptc.materialize MANIFEST --target-mission NAME --component ID --out DIR \\
        --from-result results/run.json --result-pointer /value/source
      mix ptc.materialize MANIFEST --workflow --component ID --out DIR --source authored.clj \\
        --origin-run-id run-2026-08-03-0001 --accept-widened-effect

  `--source-out` writes the currently installed effective bytes for later
  editing. `--source`/`--out` (or `--from-result`) is a separate candidate-gate
  step; the two modes are mutually exclusive because a descriptor hashes the
  exact candidate published beside it. The standalone `ptc materialize`
  command also accepts a project document and applies its project-selected
  host limit ceilings. This source-checkout Mix task accepts an application
  manifest directly.

  A model can author a working library inside a run, but a runtime `defn` dies
  at end of run: it is not in the frozen bundle, not covered by a component
  source hash, and absent from the mission inventory. Candidate mode closes that
  loop by making the authored bytes a real component candidate, which a later
  run can evaluate through `mix ptc run --component-override-descriptor`.

  Promotion stays an explicit human decision. This task does not promote
  anything; it makes the decision cheap to reach and well evidenced.

  ## Source acquisition

  `--source-out` reads interned package bytes for the selected environment.
  `--source` reads raw candidate bytes. `--from-result` reads a result artifact
  written by `mix ptc run --output`/`--private-output` and resolves one RFC 6901
  JSON pointer to one string, because a result artifact is JSON, not raw Lisp.
  A non-string or absent target is refused rather than coerced.

  `--workflow` targets the selected workflow occurrence. `--target-mission
  NAME` targets exactly that declared mission; supplying neither or both is
  invalid. The target is written into the closed override descriptor.

  ## Publication

  `--source-out` must not exist. It is created exclusively at mode 0600.
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
  who authored the candidate. These are **unverified claims**: a run id is a
  claim about origin, not evidence of it. There is no
  model-id option, because a descriptor is a published artifact and the raw
  model selector must not be published; the authoring model is reachable
  through the run id.
  """

  use Mix.Task

  alias PtcRunner.Kernel.Materialize

  @usage "usage: mix ptc.materialize MANIFEST (--workflow | --target-mission NAME) --component ID " <>
           "(--source-out PATH | --out DIR (--source PATH | --from-result PATH --result-pointer POINTER)) " <>
           "[--origin-run-id ID] [--origin-prompt-hash sha256:...] " <>
           "[--origin-authored-at RFC3339] [--accept-widened-effect]"

  @impl Mix.Task
  def run(argv) do
    start_core_application!()

    case OptionParser.parse(argv,
           strict: [
             component: :string,
             workflow: :boolean,
             target_mission: :string,
             out: :string,
             source_out: :string,
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
        manifest |> Materialize.run(opts) |> report()

      {_opts, _arguments, invalid} when invalid != [] ->
        Mix.raise("invalid ptc.materialize options: #{inspect(invalid)}")

      _other ->
        Mix.raise(@usage)
    end
  end

  defp report({:ok, {:source_out, path}}) do
    Mix.shell().info("source written: #{path}")
  end

  defp report({:ok, {:candidate, report, published}}) do
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
