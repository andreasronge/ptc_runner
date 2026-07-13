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
end
