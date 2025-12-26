defmodule PtcDemo.LispAgent do
  @moduledoc """
  PTC-Lisp Agent that uses LLM to generate Lisp programs and PtcRunner.Lisp to execute them.
  Uses PtcDemo.AgenticLoop for the agentic reasoning loop.
  """

  use GenServer

  import ReqLLM.Context
  alias PtcDemo.SampleData
  alias PtcDemo.AgenticLoop

  @model_env "PTC_DEMO_MODEL"
  @max_iterations 5
  @genserver_timeout @max_iterations * 60_000 + 30_000

  # --- State ---
  defstruct [:model, :context, :datasets, :last_program, :last_result, :data_mode, :usage, :memory, :trace]

  # --- Public API ---
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def ask(question, opts \\ []), do: GenServer.call(__MODULE__, {:ask, question, opts}, @genserver_timeout)
  def reset, do: GenServer.call(__MODULE__, :reset)
  def last_program, do: GenServer.call(__MODULE__, :last_program)
  def last_result, do: GenServer.call(__MODULE__, :last_result)
  def programs, do: GenServer.call(__MODULE__, :programs)
  def stats, do: GenServer.call(__MODULE__, :stats)
  def trace, do: GenServer.call(__MODULE__, :trace)
  def data_mode, do: GenServer.call(__MODULE__, :data_mode)
  def context, do: GenServer.call(__MODULE__, :context)
  def system_prompt, do: GenServer.call(__MODULE__, :system_prompt)
  def set_data_mode(mode) when mode in [:schema, :explore], do: GenServer.call(__MODULE__, {:set_data_mode, mode})
  def set_model(model), do: GenServer.call(__MODULE__, {:set_model, model})
  def preset_models, do: PtcDemo.ModelRegistry.preset_models()
  def detect_model, do: PtcDemo.ModelRegistry.default_model()

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    model = opts[:model] || System.get_env(@model_env) || detect_model()
    data_mode = Keyword.get(opts, :data_mode, :schema)
    datasets = %{
      products: SampleData.products(),
      orders: SampleData.orders(),
      employees: SampleData.employees(),
      expenses: SampleData.expenses()
    }

    context = ReqLLM.Context.new([system(system_prompt_content(data_mode))])
    {:ok, %__MODULE__{model: model, context: context, datasets: datasets, data_mode: data_mode,
                     usage: empty_usage(), memory: %{}, last_program: nil, last_result: nil, trace: []}}
  end

  @impl true
  def handle_call({:ask, question, opts}, _from, state) do
    context = ReqLLM.Context.append(state.context, user(question))
    stop_on_success = Keyword.get(opts, :stop_on_success, false)
    IO.puts("   [Debug] state.model: #{state.model}")
    model = PtcDemo.ModelRegistry.resolve!(state.model)
    IO.puts("   [Debug] resolved model: #{model}")

    # Merge with custom tools from opts
    custom_tools = opts[:tools] || %{}

    # Spike: Provide the 'delegate' tool and specialized sub-agents as tools
    tools = Map.merge(custom_tools, %{
      "delegate" => fn %{"task" => task, "type" => type} ->
        # Simulate registry lookup... (keep for backwards compatibility in spike)
        case type do
          "customer-finder" ->
             PtcDemo.SubAgent.delegate(task,
               tools: %{"search_customers" => fn _ -> [%{id: 501, name: "Top Client"}] end},
               refs: %{customer_id: [Access.at(0), :id]})
          _ -> {:error, "unknown type"}
        end
      end,

      "customer-finder" => PtcDemo.SubAgent.as_tool(
        model: state.model,
        description: "Find top customers by revenue",
        tools: %{"search_customers" => fn _ -> [%{id: 501, name: "Top Client", revenue: 1000000}] end},
        refs: %{customer_id: [Access.at(0), :id]}
      ),

      "order-fetcher" => PtcDemo.SubAgent.as_tool(
        model: state.model,
        description: "Fetch orders for a customer",
        tools: %{
          "list_orders" => fn args ->
            cid = args[:customer_id] || args["customer_id"]
            [%{id: 901, customer_id: cid, total: 500}, %{id: 902, customer_id: cid, total: 1200}]
          end
        }
      )
    })

    case AgenticLoop.run(model, context, state.datasets,
           memory: state.memory, usage: state.usage, max_iterations: @max_iterations,
           timeout: 30000,
           stop_on_success: stop_on_success, tools: tools) do
      {:ok, answer, final_context, new_usage, last_program, last_result, new_memory, trace} ->
        {:reply, {:ok, answer}, %{state | context: final_context, last_program: last_program,
                                  last_result: last_result, usage: new_usage, memory: new_memory, trace: trace}}
      {:error, reason, final_context, new_usage, trace} ->
        {:reply, {:error, reason}, %{state | context: final_context, usage: new_usage, trace: trace}}
    end
  end

  @impl true
  def handle_call(:reset, _from, state) do
    new_context = ReqLLM.Context.new([system(system_prompt_content(:schema))])
    {:reply, :ok, %{state | context: new_context, last_program: nil, last_result: nil,
                    data_mode: :schema, usage: empty_usage(), memory: %{}, trace: []}}
  end

  @impl true
  def handle_call(:last_program, _from, state), do: {:reply, state.last_program, state}
  @impl true
  def handle_call(:last_result, _from, state), do: {:reply, state.last_result, state}
  @impl true
  def handle_call(:programs, _from, state), do: {:reply, extract_all_programs(state.context), state}
  @impl true
  def handle_call(:model, _from, state), do: {:reply, state.model, state}
  @impl true
  def handle_call(:stats, _from, state), do: {:reply, state.usage, state}
  @impl true
  def handle_call(:trace, _from, state), do: {:reply, state.trace, state}
  @impl true
  def handle_call(:data_mode, _from, state), do: {:reply, state.data_mode, state}
  @impl true
  def handle_call(:context, _from, state) do
    msgs = Enum.reject(state.context.messages, &(&1.role == :system))
    {:reply, msgs, state}
  end
  @impl true
  def handle_call(:system_prompt, _from, state) do
    sys = Enum.find(state.context.messages, &(&1.role == :system))
    {:reply, (if sys, do: extract_text_content(sys.content), else: ""), state}
  end
  @impl true
  def handle_call({:set_data_mode, mode}, _from, state) do
    new_context = ReqLLM.Context.new([system(system_prompt_content(mode))])
    {:reply, :ok, %{state | data_mode: mode, context: new_context, memory: %{}}}
  end
  @impl true
  def handle_call({:set_model, model}, _from, state), do: {:reply, :ok, %{state | model: model}}

  # --- Helpers ---

  defp system_prompt_content(:schema) do
    data_schema = SampleData.schema_prompt()
    lisp_ref = PtcRunner.Lisp.Schema.to_prompt()
    """
    You are a data analyst. Answer questions by querying datasets.
    Query using ```clojure code blocks.
    Format: (call "tool-name" {:arg1 "val1"})
    Memory persists via memory/key.

    Available specialized tools:
    - (call "customer-finder" {:task "..."})
    - (call "order-fetcher" {:task "..." :customer_id CID})

    NOTE: Specialized tools return a map: {:result [...] :summary "..." :refs {...}}
    Use (get result :result) to access raw data.

    #{data_schema}
    #{lisp_ref}
    """
  end

  defp system_prompt_content(:explore), do: system_prompt_content(:schema) # Simplified for spike

  defp extract_text_content(content) when is_binary(content), do: content
  defp extract_text_content(content) when is_list(content), do: Enum.map_join(content, &extract_text_content/1)
  defp extract_text_content(%{text: text}), do: text
  defp extract_text_content(_), do: ""

  defp extract_all_programs(text) when is_binary(text) do
    Regex.scan(~r/```(?:lisp|clojure)?\s*([\s\S]+?)```/, text)
    |> Enum.map(fn [_, p] -> String.trim(p) end)
  end

  defp empty_usage, do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, total_runs: 0, total_cost: 0.0, requests: 0}
end
