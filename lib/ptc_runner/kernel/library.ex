defmodule PtcRunner.Kernel.Library do
  @moduledoc """
  Shipped PTC-Lisp libraries as explicit Kernel components.

  Available component IDs are `kernel`, `runtime`, `cap`, `workflow.event`,
  `llm`, `agent.native`, `agent.core`, `agent.failure`, `agent.feedback`,
  `agent.machine`, `agent.retry`, `agent.prompt`, `agent.main`, `result`,
  `analysis`, `debug.nav`, and `prompt.audit`.

  `agent.main` is a generic entry wrapper: a manifest names `agent.main/run`
  and supplies `task` and `agent` through input, instead of every application
  repeating the same `agent.core` call. It is domain-blind by construction —
  it forwards two input keys and never learns what the task is about. It
  validates each model-authored terminal candidate against the manifest result
  contract while a bounded correction turn can still run, then returns the
  raw application value; callers of `agent.core/run` retain its explicit
  `%{"ok" => true, "value" => value}` success envelope by default.
  `agent.core/run-value` is the composable variant: it returns the same
  model-authored value to its PTC-Lisp caller without terminating the outer
  workflow, allowing an evaluator to judge the answer before returning.

  `analysis` and `debug.nav` are the two navigation surfaces over one immutable
  run-evidence capture, and a mission installs one or the other. `analysis`
  binds the stable `analysis-runs`/`analysis-open`/`analysis-read`/
  `analysis-counters` capability names a REPL analysis profile grants.
  `debug.nav` adds `follow` and binds a manifest-installed snapshot provider,
  which names its operations `<alias>.runs`/`<alias>.open`/`<alias>.read`/
  `<alias>.counters`; the mission must therefore select its correlated
  inspection snapshot provider under the conventional alias `debug.nav`.
  `counters` is a thin unwrap of the captured canonical trace aggregate;
  `follow` takes one typed relationship from an evidence item and reads its
  exact target collection and filters, refusing an unavailable or filterless
  relationship and any caller filter beyond `limit` and `cursor`. Neither adds
  host authority or diagnosis policy: `follow` returns the original
  relationship beside the unchanged native page envelope, so cursors,
  completeness, and relationship state survive the hop.

  `cap` is `:discoverable` rather than `:prompt`. Its envelope and pagination
  helpers compose capabilities for other libraries and stay out of the prompt
  inventory; evaluated code still finds them with `(dir "cap")` and reads them
  with `(doc "cap/fold-pages")`. `unwrap!` fails the program on an error
  envelope rather than returning it. `fold-pages` is the one traversal helper:
  it reduces page items into bounded caller state, preserves a resumable cursor
  at its explicit page bound, and rejects changed snapshots or cursor cycles
  observed within one invocation without retaining source-sized resume history.

  `agent.failure` is also `:discoverable`. It is generated from
  `PtcRunner.Kernel.LLMFailureCatalog` and exports one pure `classify`
  function over the existing bounded LLM envelope. Classification does not add
  a field, tool call, or fail-fast evidence; `kernel-llm-provider-failure`
  remains the consume boundary.

  `agent.machine` is `:discoverable` as well: a pure constructor/advance reducer
  for the shipped agent loop. Visibility is not an authority boundary; the
  exports remain callable. It is not an application customization API.

  Fetching one component with `component/1` does not expand its dependencies,
  and `PtcRunner.Kernel` refuses to compile an incomplete set. Manifests and
  `resolve_components/1` expand installed-library selections transitively;
  direct callers of `compile_bundle/1` must supply the resulting closed set.

  Fetching a component grants no capability. The host still compiles the
  selected closed component set and supplies the capabilities required by its
  exports when assembling an environment.
  """

  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.FrozenBundle

  @kernel_path Path.expand("../../../priv/preludes/kernel/kernel.clj", __DIR__)
  @runtime_path Path.expand("../../../priv/preludes/kernel/runtime.clj", __DIR__)
  @cap_path Path.expand("../../../priv/preludes/kernel/cap.clj", __DIR__)
  @workflow_event_path Path.expand("../../../priv/preludes/kernel/workflow.event.clj", __DIR__)
  @llm_path Path.expand("../../../priv/preludes/kernel/llm.clj", __DIR__)
  @agent_native_path Path.expand("../../../priv/preludes/kernel/agent.native.clj", __DIR__)
  @agent_prompt_path Path.expand("../../../priv/preludes/kernel/agent.prompt.clj", __DIR__)
  @agent_core_path Path.expand("../../../priv/preludes/kernel/agent.core.clj", __DIR__)
  @agent_failure_path Path.expand("../../../priv/preludes/kernel/agent.failure.clj", __DIR__)
  @agent_machine_path Path.expand("../../../priv/preludes/kernel/agent.machine.clj", __DIR__)
  @agent_main_path Path.expand("../../../priv/preludes/kernel/agent.main.clj", __DIR__)
  @agent_feedback_path Path.expand("../../../priv/preludes/kernel/agent.feedback.clj", __DIR__)
  @agent_retry_path Path.expand("../../../priv/preludes/kernel/agent.retry.clj", __DIR__)
  @result_path Path.expand("../../../priv/preludes/kernel/result.clj", __DIR__)
  @analysis_path Path.expand("../../../priv/preludes/kernel/analysis.clj", __DIR__)
  @debug_nav_path Path.expand("../../../priv/preludes/kernel/debug.nav.clj", __DIR__)
  @prompt_audit_path Path.expand("../../../priv/preludes/kernel/prompt.audit.clj", __DIR__)
  @external_resource @kernel_path
  @external_resource @runtime_path
  @external_resource @cap_path
  @external_resource @workflow_event_path
  @external_resource @llm_path
  @external_resource @agent_native_path
  @external_resource @agent_prompt_path
  @external_resource @agent_core_path
  @external_resource @agent_failure_path
  @external_resource @agent_machine_path
  @external_resource @agent_main_path
  @external_resource @agent_feedback_path
  @external_resource @agent_retry_path
  @external_resource @result_path
  @external_resource @analysis_path
  @external_resource @debug_nav_path
  @external_resource @prompt_audit_path
  @sources %{
    "kernel" => File.read!(@kernel_path),
    "runtime" => File.read!(@runtime_path),
    "cap" => File.read!(@cap_path),
    "workflow.event" => File.read!(@workflow_event_path),
    "llm" => File.read!(@llm_path),
    "agent.native" => File.read!(@agent_native_path),
    "agent.prompt" => File.read!(@agent_prompt_path),
    "agent.core" => File.read!(@agent_core_path),
    "agent.failure" => File.read!(@agent_failure_path),
    "agent.machine" => File.read!(@agent_machine_path),
    "agent.main" => File.read!(@agent_main_path),
    "agent.feedback" => File.read!(@agent_feedback_path),
    "agent.retry" => File.read!(@agent_retry_path),
    "result" => File.read!(@result_path),
    "analysis" => File.read!(@analysis_path),
    "debug.nav" => File.read!(@debug_nav_path),
    "prompt.audit" => File.read!(@prompt_audit_path)
  }
  @dependencies %{
    "analysis" => ["cap"],
    "debug.nav" => ["cap"],
    "agent.prompt" => ["kernel"],
    "agent.machine" => [
      "agent.failure",
      "agent.feedback",
      "agent.prompt",
      "agent.retry",
      "result"
    ],
    "agent.core" => [
      "agent.machine",
      "agent.native",
      "agent.prompt",
      "kernel",
      "llm",
      "result",
      "workflow.event"
    ],
    "agent.main" => ["agent.core"]
  }
  @component_ids @sources |> Map.keys() |> Enum.sort()

  @spec component_ids() :: [binary()]
  @doc "Returns every shipped component ID in lexical order."
  def component_ids, do: @component_ids

  @spec component(binary()) :: {:ok, Component.t()} | {:error, :unknown_library}
  @doc "Returns one shipped component by its stable component ID."
  def component(name) when is_binary(name) do
    case Map.fetch(@sources, name) do
      {:ok, source} ->
        Component.new(
          id: name,
          source: source,
          dependencies: Map.get(@dependencies, name, []),
          origin: "priv/preludes/kernel/#{name}.clj"
        )

      :error ->
        {:error, :unknown_library}
    end
  end

  def component(_name), do: {:error, :unknown_library}

  @doc false
  @spec shipped_component?(FrozenBundle.t() | nil, binary()) :: boolean()
  def shipped_component?(%FrozenBundle{} = bundle, id) when is_binary(id) do
    with true <- FrozenBundle.valid?(bundle),
         {:ok, expected} <- component(id),
         %{dependencies: dependencies, origin: origin, source_hash: source_hash} <-
           Enum.find(bundle.components, &(&1.id == id)) do
      dependencies == expected.dependencies and
        origin == expected.origin and
        source_hash == source_hash(expected.source)
    else
      _other -> false
    end
  end

  def shipped_component?(_bundle, _id), do: false

  @doc false
  @spec shipped_or_verified_override_component?(FrozenBundle.t() | nil, binary(), map()) ::
          boolean()
  def shipped_or_verified_override_component?(%FrozenBundle{} = bundle, id, authorization)
      when is_binary(id) and is_map(authorization) do
    authorized_shipped_component?(bundle, id, authorization) or
      verified_override_component?(bundle, id, authorization)
  end

  def shipped_or_verified_override_component?(_bundle, _id, _authorization), do: false

  @spec components([binary()]) :: {:ok, [Component.t()]} | {:error, :unknown_library}
  @doc "Returns shipped components in the requested order."
  def components(names) when is_list(names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, components} ->
      case component(name) do
        {:ok, component} -> {:cont, {:ok, [component | components]}}
        {:error, :unknown_library} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, components} -> {:ok, Enum.reverse(components)}
      error -> error
    end
  end

  def components(_names), do: {:error, :unknown_library}

  defp authorized_shipped_component?(bundle, id, authorization)
       when map_size(authorization) == 0,
       do: shipped_component?(bundle, id)

  defp authorized_shipped_component?(bundle, id, %{component_kinds: component_kinds})
       when is_map(component_kinds),
       do: Map.get(component_kinds, id) == :library and shipped_component?(bundle, id)

  defp authorized_shipped_component?(_bundle, _id, _authorization), do: false

  defp verified_override_component?(bundle, id, %{
         component_kinds: component_kinds,
         component_overrides: component_overrides
       })
       when is_map(component_kinds) and is_list(component_overrides) do
    with true <- FrozenBundle.valid?(bundle),
         :library <- Map.get(component_kinds, id),
         {:ok, expected} <- component(id),
         %{dependencies: dependencies, origin: "component-override", source_hash: source_hash} <-
           Enum.find(bundle.components, &(&1.id == id)),
         true <- dependencies == expected.dependencies do
      Enum.any?(component_overrides, fn
        %{
          "target" => %{"environment" => "workflow"},
          "component_id" => ^id,
          "base_source_hash" => base_source_hash,
          "source_hash" => candidate_source_hash
        } ->
          base_source_hash == qualified_source_hash(expected.source) and
            candidate_source_hash == "sha256:" <> source_hash

        _other ->
          false
      end)
    else
      _other -> false
    end
  end

  defp verified_override_component?(_bundle, _id, _authorization), do: false

  @spec resolve_components([Component.t() | {:library, binary()}]) ::
          {:ok, [Component.t()]}
          | {:error,
             :invalid_component_selection
             | :duplicate_library_selection
             | :duplicate_component_id
             | :unknown_library
             | :missing_component_dependency
             | :component_cycle
             | :local_library_collision
             | :component_limit_exceeded}
  @doc """
  Resolves local components and explicit shipped-library selections.

  Explicit library selections must be unique. Installed dependency closure is
  expanded from this module only, transitive duplicates coalesce, and local
  component IDs may not collide with any installed ID. The result is ordered
  lexically by component ID. Graph validation and dependency ordering belong
  to bounded bundle compilation, so missing local dependencies and cycles
  remain phase-4 bundle failures instead of being flattened into application
  acquisition.
  """
  def resolve_components(selections) when is_list(selections) do
    with {:ok, local, installed_ids} <- split_selections(selections),
         :ok <- unique_explicit_libraries(installed_ids),
         {:ok, installed} <- load_installed(installed_ids),
         {:ok, local_by_id} <- unique_local(local),
         :ok <- no_collisions(local_by_id, installed),
         all = Map.merge(installed, local_by_id),
         true <- map_size(all) <= 128 do
      {:ok, all |> Map.values() |> Enum.sort_by(& &1.id)}
    else
      false -> {:error, :component_limit_exceeded}
      {:error, _reason} = error -> error
    end
  end

  def resolve_components(_selections), do: {:error, :invalid_component_selection}

  defp split_selections(selections) do
    Enum.reduce_while(selections, {:ok, [], []}, fn
      %Component{} = component, {:ok, local, installed} ->
        {:cont, {:ok, [component | local], installed}}

      {:library, id}, {:ok, local, installed} when is_binary(id) ->
        {:cont, {:ok, local, [id | installed]}}

      _selection, _acc ->
        {:halt, {:error, :invalid_component_selection}}
    end)
    |> case do
      {:ok, local, installed} -> {:ok, Enum.reverse(local), Enum.reverse(installed)}
      error -> error
    end
  end

  defp unique_explicit_libraries(ids) do
    if ids == Enum.uniq(ids), do: :ok, else: {:error, :duplicate_library_selection}
  end

  defp load_installed(ids) do
    Enum.reduce_while(Enum.sort(ids), {:ok, %{}}, fn id, {:ok, loaded} ->
      case load_installed_component(id, loaded, %{}, :explicit) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp load_installed_component(id, loaded, visiting, source) do
    cond do
      Map.has_key?(loaded, id) ->
        {:ok, loaded}

      Map.has_key?(visiting, id) ->
        {:error, :component_cycle}

      true ->
        load_new_installed_component(id, loaded, visiting, source)
    end
  end

  defp load_new_installed_component(id, loaded, visiting, source) do
    case component(id) do
      {:ok, component} ->
        visiting = Map.put(visiting, id, true)

        Enum.reduce_while(component.dependencies, {:ok, loaded}, fn dependency, {:ok, acc} ->
          case load_installed_component(dependency, acc, visiting, :dependency) do
            {:ok, next} -> {:cont, {:ok, next}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, dependencies} -> {:ok, Map.put(dependencies, id, component)}
          error -> error
        end

      {:error, :unknown_library} when source == :explicit ->
        {:error, :unknown_library}

      {:error, :unknown_library} ->
        {:error, :missing_component_dependency}
    end
  end

  defp unique_local(components) do
    Enum.reduce_while(components, {:ok, %{}}, fn %Component{id: id} = component, {:ok, by_id} ->
      if Map.has_key?(by_id, id),
        do: {:halt, {:error, :duplicate_component_id}},
        else: {:cont, {:ok, Map.put(by_id, id, component)}}
    end)
  end

  defp no_collisions(local, installed) do
    if Enum.any?(Map.keys(local), &Map.has_key?(installed, &1)),
      do: {:error, :local_library_collision},
      else: :ok
  end

  defp source_hash(source),
    do: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

  defp qualified_source_hash(source), do: "sha256:" <> source_hash(source)
end
