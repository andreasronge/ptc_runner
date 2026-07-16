defmodule PtcRunner.Kernel.Library do
  @moduledoc """
  Shipped PTC-Lisp libraries as explicit Kernel components.

  Available component IDs are `kernel`, `runtime`, `cap`, `workflow.event`,
  `fs`, `llm`, `agent.native`, `agent.core`, `agent.feedback`, `agent.retry`,
  `result`, and `log.core`.

  Fetching a component grants no capability. The host still compiles the
  selected closed component set and supplies the capabilities required by its
  exports when assembling an environment.
  """

  alias PtcRunner.Kernel.Component

  @kernel_path Path.expand("../../../priv/preludes/kernel/kernel.lisp", __DIR__)
  @runtime_path Path.expand("../../../priv/preludes/kernel/runtime.lisp", __DIR__)
  @cap_path Path.expand("../../../priv/preludes/kernel/cap.lisp", __DIR__)
  @workflow_event_path Path.expand("../../../priv/preludes/kernel/workflow.event.lisp", __DIR__)
  @fs_path Path.expand("../../../priv/preludes/kernel/fs.lisp", __DIR__)
  @llm_path Path.expand("../../../priv/preludes/kernel/llm.lisp", __DIR__)
  @agent_native_path Path.expand("../../../priv/preludes/kernel/agent.native.lisp", __DIR__)
  @agent_core_path Path.expand("../../../priv/preludes/kernel/agent.core.lisp", __DIR__)
  @agent_feedback_path Path.expand("../../../priv/preludes/kernel/agent.feedback.lisp", __DIR__)
  @agent_retry_path Path.expand("../../../priv/preludes/kernel/agent.retry.lisp", __DIR__)
  @result_path Path.expand("../../../priv/preludes/kernel/result.lisp", __DIR__)
  @log_core_path Path.expand("../../../priv/preludes/kernel/log.core.lisp", __DIR__)
  @external_resource @kernel_path
  @external_resource @runtime_path
  @external_resource @cap_path
  @external_resource @workflow_event_path
  @external_resource @fs_path
  @external_resource @llm_path
  @external_resource @agent_native_path
  @external_resource @agent_core_path
  @external_resource @agent_feedback_path
  @external_resource @agent_retry_path
  @external_resource @result_path
  @external_resource @log_core_path
  @sources %{
    "kernel" => File.read!(@kernel_path),
    "runtime" => File.read!(@runtime_path),
    "cap" => File.read!(@cap_path),
    "workflow.event" => File.read!(@workflow_event_path),
    "fs" => File.read!(@fs_path),
    "llm" => File.read!(@llm_path),
    "agent.native" => File.read!(@agent_native_path),
    "agent.core" => File.read!(@agent_core_path),
    "agent.feedback" => File.read!(@agent_feedback_path),
    "agent.retry" => File.read!(@agent_retry_path),
    "result" => File.read!(@result_path),
    "log.core" => File.read!(@log_core_path)
  }
  @dependencies %{
    "agent.core" => [
      "agent.feedback",
      "agent.native",
      "agent.retry",
      "kernel",
      "llm",
      "result",
      "workflow.event"
    ]
  }

  @spec component(binary()) :: {:ok, Component.t()} | {:error, :unknown_library}
  @doc "Returns one shipped component by its stable component ID."
  def component(name) when is_binary(name) do
    case Map.fetch(@sources, name) do
      {:ok, source} ->
        Component.new(
          id: name,
          source: source,
          dependencies: Map.get(@dependencies, name, []),
          origin: "priv/preludes/kernel/#{name}.lisp"
        )

      :error ->
        {:error, :unknown_library}
    end
  end

  def component(_name), do: {:error, :unknown_library}

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
  with dependencies before dependants and lexical component-ID tie breaking.
  Missing dependencies and cycles fail before bundle compilation.
  """
  def resolve_components(selections) when is_list(selections) do
    with {:ok, local, installed_ids} <- split_selections(selections),
         :ok <- unique_explicit_libraries(installed_ids),
         {:ok, installed} <- load_installed(installed_ids),
         {:ok, local_by_id} <- unique_local(local),
         :ok <- no_collisions(local_by_id, installed),
         all = Map.merge(installed, local_by_id),
         true <- map_size(all) <= 128,
         :ok <- dependencies_exist(all),
         {:ok, ordered} <- topological_order(all) do
      {:ok, ordered}
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
      case load_installed_component(id, loaded, MapSet.new(), :explicit) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp load_installed_component(id, loaded, visiting, source) do
    cond do
      Map.has_key?(loaded, id) ->
        {:ok, loaded}

      MapSet.member?(visiting, id) ->
        {:error, :component_cycle}

      true ->
        load_new_installed_component(id, loaded, visiting, source)
    end
  end

  defp load_new_installed_component(id, loaded, visiting, source) do
    case component(id) do
      {:ok, component} ->
        visiting = MapSet.put(visiting, id)

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

  defp dependencies_exist(by_id) do
    if Enum.any?(by_id, fn {_id, component} ->
         Enum.any?(component.dependencies, &(not Map.has_key?(by_id, &1)))
       end),
       do: {:error, :missing_component_dependency},
       else: :ok
  end

  defp topological_order(by_id), do: topological_order(by_id, MapSet.new(), [])

  defp topological_order(by_id, resolved, ordered) do
    if map_size(by_id) == MapSet.size(resolved) do
      {:ok, Enum.reverse(ordered)}
    else
      next =
        by_id
        |> Map.values()
        |> Enum.reject(&MapSet.member?(resolved, &1.id))
        |> Enum.filter(fn component ->
          Enum.all?(component.dependencies, &MapSet.member?(resolved, &1))
        end)
        |> Enum.min_by(& &1.id, fn -> nil end)

      case next do
        nil ->
          {:error, :component_cycle}

        component ->
          topological_order(by_id, MapSet.put(resolved, component.id), [component | ordered])
      end
    end
  end
end
