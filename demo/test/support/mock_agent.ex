defmodule PtcDemo.MockAgent do
  @moduledoc """
  Mock agent for testing test runners without real LLM calls.

  Implements the same public API as PtcDemo.Agent but returns predetermined responses.
  Instead of making LLM calls, it uses a mock LLM callback that returns pre-configured
  programs based on the query.

  `programs/0` returns a list of {program, result} tuples matching the real agent format.
  """

  use GenServer

  alias PtcDemo.SampleData

  defstruct [:responses, :last_result, :last_program, :program_results, :memory]

  # --- Public API ---

  def start_link(responses) when is_map(responses) do
    GenServer.start_link(__MODULE__, responses, name: __MODULE__)
  end

  def ask(question) do
    GenServer.call(__MODULE__, {:ask, question}, 30_000)
  end

  def ask(question, _opts) do
    # Options like max_turns are ignored in mock
    GenServer.call(__MODULE__, {:ask, question}, 30_000)
  end

  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  def last_program do
    GenServer.call(__MODULE__, :last_program)
  end

  def last_result do
    GenServer.call(__MODULE__, :last_result)
  end

  def programs do
    GenServer.call(__MODULE__, :programs)
  end

  def list_datasets do
    SampleData.available_datasets()
  end

  def model do
    "mock:test-model"
  end

  def stats do
    %{
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      system_prompt_tokens: 0,
      total_runs: 0,
      total_cost: 0.0,
      requests: 0
    }
  end

  def data_mode do
    :schema
  end

  def system_prompt do
    "Mock agent system prompt"
  end

  def set_data_mode(_mode) do
    :ok
  end

  def set_model(_model) do
    :ok
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(responses) do
    {:ok,
     %__MODULE__{
       responses: responses,
       last_result: nil,
       last_program: nil,
       program_results: [],
       memory: %{}
     }}
  end

  @impl true
  def handle_call({:ask, question}, _from, state) do
    case Map.get(state.responses, question) do
      nil ->
        # Unknown query - return error with query text
        error = "Unknown query: #{question}"
        program_entry = {question, {:error, error}}
        new_program_results = state.program_results ++ [program_entry]

        {:reply, {:error, error}, %{state | program_results: new_program_results}}

      response ->
        # Response format: {:ok, answer, program, result} or {:error, reason}
        case response do
          {:ok, answer, program, result} ->
            program_str = program || "(return #{inspect(result)})"
            program_entry = {program_str, result}
            new_program_results = state.program_results ++ [program_entry]

            {:reply, {:ok, answer},
             %{
               state
               | last_result: result,
                 last_program: program_str,
                 program_results: new_program_results
             }}

          {:error, reason} ->
            program_entry = {question, {:error, reason}}
            new_program_results = state.program_results ++ [program_entry]

            {:reply, {:error, reason}, %{state | program_results: new_program_results}}

          answer when is_binary(answer) ->
            # Simple response - treat as answer with no specific program
            program_entry = {question, answer}
            new_program_results = state.program_results ++ [program_entry]

            {:reply, {:ok, answer},
             %{
               state
               | last_result: answer,
                 last_program: nil,
                 program_results: new_program_results
             }}

          result ->
            # Non-binary answer - convert to string for answer
            program_entry = {question, result}
            new_program_results = state.program_results ++ [program_entry]

            {:reply, {:ok, inspect(result)},
             %{
               state
               | last_result: result,
                 last_program: nil,
                 program_results: new_program_results
             }}
        end
    end
  end

  @impl true
  def handle_call(:reset, _from, state) do
    {:reply, :ok,
     %{
       state
       | last_result: nil,
         last_program: nil,
         program_results: [],
         memory: %{}
     }}
  end

  @impl true
  def handle_call(:last_program, _from, state) do
    {:reply, state.last_program, state}
  end

  @impl true
  def handle_call(:last_result, _from, state) do
    {:reply, state.last_result, state}
  end

  @impl true
  def handle_call(:programs, _from, state) do
    {:reply, state.program_results, state}
  end
end
