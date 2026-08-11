defmodule PtcRunner.Kernel.CandidatePromotion do
  @moduledoc """
  Decides whether a verified candidate is fit to be promoted by a human.

  Promotion is an explicit human decision. This module does not make it; it
  makes it cheap to reach and well evidenced, by answering questions an
  operator would otherwise answer by reading diffs: does the candidate compile,
  is it usable by the next run's model, and does it reach further than the
  component it replaces.

  Every criterion is either **intrinsic** to the candidate or **relative** to
  its base. Nothing here checks capability grants, and the report says so. Real
  `%Capability{}` values — and therefore capability names — exist only after
  provider acquisition, and no static substitute exists:
  `ProviderDescriptor.provides` lists inter-provider service atoms disjoint
  from `requires`, not capability names, and a dynamic provider discovers its
  tool names at acquisition. Comparing the two would compare an atom against an
  unrelated string. A candidate naming a capability no provider grants
  therefore passes this gate and fails at run-time environment assembly, which
  remains authoritative. The gate narrows the distance to that failure; it does
  not remove it.

  Criteria report `:pass`, `:fail`, or `:blocked`. `:blocked` is not a
  softened failure — it means the criterion could not run at all, because a
  candidate that does not compile has no export table for G2 and G3 to inspect,
  and reporting that as a failure would misattribute the cause.
  """

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Export

  @effect_rank %{read: 0, unknown: 1, write: 2}

  @type status :: :pass | :fail | :blocked
  @type criterion :: %{id: binary(), status: status(), summary: binary(), detail: map()}
  @type report :: %{
          outcome: status(),
          environment: binary() | nil,
          criteria: [criterion()]
        }

  @doc """
  Evaluates one candidate against the base it replaces.

  `base` is the package acquired without an override; `candidate` is the same
  application acquired with the verified descriptor applied. Both are required:
  the widening criterion is relative, so there is nothing to compare against
  without the installed base.

  `:accept_widened_effect` records that an operator acknowledged a widening. It
  turns G3 from a failure into a pass whose detail still lists every widening,
  because acknowledging a risk is not the same as hiding it.
  """
  @spec evaluate(ApplicationPackage.t(), ApplicationPackage.t(), keyword()) :: report()
  def evaluate(%ApplicationPackage{} = base, %ApplicationPackage{} = candidate, opts \\ []) do
    accepted? = Keyword.get(opts, :accept_widened_effect, false)

    case override_target(candidate) do
      {:ok, environment, component_id} ->
        evaluate_environment(base, candidate, {environment, component_id}, accepted?)

      :error ->
        %{
          outcome: :blocked,
          environment: nil,
          criteria: [
            blocked("G1", "no verified override is applied to this package", %{})
            | blocked_dependents()
          ]
        }
    end
  end

  defp evaluate_environment(base, candidate, {environment, component_id}, accepted?) do
    with {:ok, base_bundle} <- compile(base, environment),
         {:ok, candidate_bundle} <- compile(candidate, environment) do
      # Criteria judge the promoted component, not the whole environment. A
      # neighbouring component that already shipped without a signature is not
      # this candidate's fault, and failing promotion for it would make the
      # gate unusable in any real application.
      owned = namespaces(candidate_bundle, component_id)
      base_exports = exports(base_bundle)
      candidate_exports = exports(candidate_bundle)
      comparison = compare(base_exports, candidate_exports, owned)

      criteria = [
        compiles(candidate, candidate_bundle, environment, component_id),
        signatures(candidate_exports, owned),
        widening(comparison, accepted?),
        dependencies()
      ]

      %{outcome: outcome(criteria), environment: environment, criteria: criteria}
    else
      {:error, reason} ->
        criteria = [
          fail("G1", "candidate does not compile", %{"reason" => inspect(reason)})
          | blocked_dependents()
        ]

        %{outcome: :fail, environment: environment, criteria: criteria}
    end
  end

  # G1. Compiling is not enough when the promoted component owns the workflow
  # entry: a candidate can drop or rename that function, compile cleanly, and
  # leave every later run failing at entry validation. The gate checks the same
  # callability the coordinator does, so that failure surfaces here instead.
  defp compiles(package, bundle, "workflow" = environment, component_id) do
    detail = %{"environment" => environment, "component_id" => component_id}

    if PreparedRun.entry_callable?(bundle, package.entry) do
      pass("G1", "candidate compiles and keeps the workflow entry callable", detail)
    else
      fail(
        "G1",
        "candidate compiles but no longer offers the workflow entry",
        Map.put(detail, "entry", package.entry)
      )
    end
  end

  defp compiles(_package, _bundle, environment, component_id) do
    pass("G1", "candidate compiles in the #{environment} environment", %{
      "environment" => environment,
      "component_id" => component_id
    })
  end

  # G2. An export without a signature and a docstring compiles and ships, but
  # has no export-meta for the next run's model to read, so promoting it
  # produces a component that is present and unusable. The runtime tolerates
  # this -- the inventory projects nil contracts and docs without objection --
  # which is exactly why promotion has to impose it.
  defp signatures(exports, owned) do
    incomplete =
      exports
      |> Enum.filter(fn export ->
        export.namespace in owned and export.visibility == :prompt and
          (missing_contract?(export) or missing_doc?(export))
      end)
      |> Enum.map(fn export ->
        %{
          "ref" => export.ref,
          "missing" =>
            if(missing_contract?(export), do: ["signature"], else: []) ++
              if(missing_doc?(export), do: ["doc"], else: [])
        }
      end)

    if incomplete == [] do
      pass("G2", "every prompt-visible export declares a signature and docstring", %{})
    else
      fail("G2", "#{length(incomplete)} prompt-visible export(s) are model-invisible", %{
        "exports" => incomplete
      })
    end
  end

  defp missing_contract?(%Export{signature: nil, type: nil}), do: true
  defp missing_contract?(%Export{}), do: false

  defp missing_doc?(%Export{doc: nil}), do: true
  defp missing_doc?(%Export{doc: doc}), do: String.trim(doc) == ""

  # G3. Comparison is per export ref, never against an application-wide union
  # of capability names: if base export A uses read-tool and B uses write-tool,
  # A gaining write-tool adds no name outside the union while materially
  # widening A.
  defp compare(base_exports, candidate_exports, owned) do
    base_by_ref = Map.new(base_exports, &{&1.ref, &1})
    candidate_by_ref = Map.new(candidate_exports, &{&1.ref, &1})
    {owned_exports, other_exports} = Enum.split_with(candidate_exports, &(&1.namespace in owned))

    # A consumer of the promoted component inherits its requirements
    # transitively. That is a real consequence and is reported, but it is not a
    # separate decision: the widening it inherited is already judged at source.
    transitive =
      other_exports
      |> Enum.filter(fn export ->
        case Map.fetch(base_by_ref, export.ref) do
          {:ok, installed} -> widened_against(installed, export) != nil
          :error -> false
        end
      end)
      |> Enum.map(& &1.ref)
      |> Enum.sort()

    {widened, indeterminate} =
      Enum.reduce(owned_exports, {[], []}, fn export, {widened, indeterminate} ->
        case Map.fetch(base_by_ref, export.ref) do
          {:ok, installed} ->
            case widened_against(installed, export) do
              nil -> {widened, indeterminate}
              entry -> {[entry | widened], indeterminate}
            end

          :error ->
            case added(export) do
              :widened ->
                {[added_entry(export) | widened], indeterminate}

              :indeterminate ->
                {widened, [%{"ref" => export.ref, "effect" => "unknown"} | indeterminate]}

              :ok ->
                {widened, indeterminate}
            end
        end
      end)

    removed =
      base_exports
      |> Enum.reject(&Map.has_key?(candidate_by_ref, &1.ref))
      |> Enum.map(& &1.ref)
      |> Enum.sort()

    %{
      widened: Enum.reverse(widened),
      indeterminate: Enum.reverse(indeterminate),
      removed: removed,
      transitive: transitive
    }
  end

  defp widened_against(installed, candidate) do
    gained = requirements(candidate) -- requirements(installed)
    effect_widened? = rank(candidate.effect) > rank(installed.effect)

    if gained == [] and not effect_widened? do
      nil
    else
      %{
        "ref" => candidate.ref,
        "gained_requirements" => Enum.sort(gained),
        "effect" => %{
          "base" => Atom.to_string(installed.effect),
          "candidate" => Atom.to_string(candidate.effect)
        }
      }
    end
  end

  # An added export has no base to compare against. Requiring anything, or
  # declaring :write, is a widening. An export that requires nothing and
  # resolves to :unknown is reported as indeterminate rather than failed:
  # join_effects([]) returns :unknown, so an ordinary pure helper lands there,
  # and failing on it would make every added helper a widening and train
  # operators to pass --accept-widened-effect reflexively.
  defp added(%Export{effect: :write}), do: :widened

  defp added(%Export{} = export),
    do: if(requirements(export) == [], do: indeterminate(export), else: :widened)

  defp indeterminate(%Export{effect: :unknown}), do: :indeterminate
  defp indeterminate(%Export{}), do: :ok

  defp added_entry(export) do
    %{
      "ref" => export.ref,
      "gained_requirements" => Enum.sort(requirements(export)),
      "effect" => %{"base" => nil, "candidate" => Atom.to_string(export.effect)}
    }
  end

  defp widening(%{widened: []} = comparison, _accepted?) do
    pass("G3", "no export widens its effect or requirements", detail(comparison))
  end

  defp widening(%{widened: widened} = comparison, true) do
    pass(
      "G3",
      "#{length(widened)} widening(s) acknowledged by the operator",
      Map.merge(detail(comparison), %{"widened" => widened, "accepted" => true})
    )
  end

  defp widening(%{widened: widened} = comparison, false) do
    fail(
      "G3",
      "#{length(widened)} export(s) reach further than the base",
      Map.merge(detail(comparison), %{"widened" => widened, "accepted" => false})
    )
  end

  defp detail(%{indeterminate: indeterminate, removed: removed, transitive: transitive}) do
    %{
      "indeterminate" => indeterminate,
      "surface_changes" => %{"removed" => removed},
      "transitive" => transitive
    }
  end

  # G4. A candidate supplies source only; apply/2 copies the installed
  # component's dependencies onto the replacement, so this cannot fail. It is
  # reported rather than dropped so the report answers the question an operator
  # actually asks -- "could this have pulled in something new?" -- instead of
  # leaving it unaddressed.
  defp dependencies do
    pass("G4", "declared dependencies are preserved by construction", %{})
  end

  defp requirements(%Export{requires: requires, tool_refs: tool_refs}) do
    requires
    |> Enum.map(fn
      "tool:" <> name -> name
      requirement -> requirement
    end)
    |> Kernel.++(tool_refs)
    |> Enum.uniq()
  end

  defp rank(effect), do: Map.get(@effect_rank, effect, 1)

  defp compile(package, environment),
    do: PtcRunner.Kernel.compile_bundle(components(package, environment))

  defp exports(%FrozenBundle{prelude: %Prelude{exports: exports}}), do: exports

  # The compiled bundle records each contributing component's declared
  # namespaces, which is what scopes the criteria to the promoted component.
  defp namespaces(%FrozenBundle{components: components}, component_id) do
    components
    |> Enum.find(&(Map.get(&1, :id) == component_id))
    |> case do
      nil -> []
      component -> Map.get(component, :namespaces, [])
    end
  end

  defp components(%ApplicationPackage{} = package, "workflow"), do: package.workflow_components

  defp components(%ApplicationPackage{} = package, "mission/" <> name),
    do: package.missions |> Map.fetch!(name) |> Map.fetch!(:components)

  defp override_target(%ApplicationPackage{component_overrides: [override | _rest]}) do
    with {:ok, target} when is_map(target) <- Map.fetch(override, "target"),
         {:ok, environment} <- target_environment(target),
         {:ok, component_id} when is_binary(component_id) <-
           Map.fetch(override, "component_id") do
      {:ok, environment, component_id}
    else
      _other -> :error
    end
  end

  defp override_target(%ApplicationPackage{}), do: :error

  defp target_environment(%{"environment" => "workflow"}), do: {:ok, "workflow"}

  defp target_environment(%{"environment" => "mission", "mission" => name}) when is_binary(name),
    do: {:ok, "mission/" <> name}

  defp target_environment(_target), do: :error

  defp outcome(criteria) do
    cond do
      Enum.any?(criteria, &(&1.status == :fail)) -> :fail
      Enum.any?(criteria, &(&1.status == :blocked)) -> :blocked
      true -> :pass
    end
  end

  defp blocked_dependents do
    [
      blocked("G2", "no export table to inspect", %{}),
      blocked("G3", "no export table to compare", %{}),
      dependencies()
    ]
  end

  defp pass(id, summary, detail),
    do: %{id: id, status: :pass, summary: summary, detail: detail}

  defp fail(id, summary, detail),
    do: %{id: id, status: :fail, summary: summary, detail: detail}

  defp blocked(id, summary, detail),
    do: %{id: id, status: :blocked, summary: summary, detail: detail}

  @doc false
  @spec component_source(ApplicationPackage.t(), binary() | {:mission, binary()}, binary()) ::
          {:ok, binary()} | :error
  def component_source(%ApplicationPackage{} = package, target, component_id) do
    components =
      case target do
        "workflow" -> package.workflow_components
        {:mission, name} -> get_in(package.missions, [name, :components]) || []
        _ -> []
      end

    components
    |> Enum.find(&(&1.id == component_id))
    |> case do
      %Component{source: source} -> {:ok, source}
      nil -> :error
    end
  end
end
