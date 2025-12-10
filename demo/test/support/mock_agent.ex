defmodule PtcDemo.MockAgent do
  @moduledoc """
  Mock agent for testing test runners without real LLM calls.

  Implements the same public API as PtcDemo.Agent but returns predetermined responses.
  """

  use GenServer

  defstruct [:responses, :call_count, :last_result, :last_program, :calls]

  # --- Public API ---

  def start_link(responses) when is_map(responses) do
    GenServer.start_link(__MODULE__, responses, name: __MODULE__)
  end

  def ask(question) do
    GenServer.call(__MODULE__, {:ask, question})
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
    PtcDemo.SampleData.available_datasets()
  end

  def model do
    "mock:test-model"
  end

  def stats do
    %{
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      total_cost: 0.0,
      requests: 0
    }
  end

  def data_mode do
    :schema
  end

  def context do
    []
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
       call_count: 0,
       last_result: nil,
       last_program: nil,
       calls: []
     }}
  end

  @impl true
  def handle_call({:ask, question}, _from, state) do
    # Record the call
    new_calls = [question | state.calls]

    case Map.get(state.responses, question) do
      nil ->
        # Unknown query - return error with query text
        error = "Unknown query: #{question}"
        {:reply, {:error, error}, %{state | calls: new_calls}}

      response ->
        # Response can be a tuple {status, answer} or just the answer value
        {status, answer, last_program, last_result} =
          case response do
            {:ok, ans, prog, res} ->
              {:ok, ans, prog, res}

            {:error, reason} ->
              {:error, reason, nil, nil}

            ans when is_binary(ans) ->
              # Default to simple response with answer as both result and program
              {:ok, ans, nil, ans}

            ans ->
              # Convert non-binary answer to string
              {:ok, inspect(ans), nil, ans}
          end

        new_state = %{
          state
          | call_count: state.call_count + 1,
            last_result: last_result,
            last_program: last_program,
            calls: new_calls
        }

        {:reply, {status, answer}, new_state}
    end
  end

  @impl true
  def handle_call(:reset, _from, state) do
    {:reply, :ok,
     %{
       state
       | call_count: 0,
         last_result: nil,
         last_program: nil,
         calls: []
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
    # Return list of {program, result} tuples
    programs =
      state.calls
      |> Enum.reverse()
      |> Enum.filter(&is_binary/1)

    {:reply, programs, state}
  end
end
