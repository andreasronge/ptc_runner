defmodule PtcRunner.TestSupport.PtcLlmHttpColdHostname do
  @moduledoc false

  # Probe used by a fresh OS/BEAM process so resolver state cannot already be
  # warm. A hosts-file-backed hostname is enough: public-policy rejection after
  # DNS is acceptable; exhausting the process budget during DNS is not.

  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.LLM
  alias PtcRunner.LLM.PtcLlmHttpAdapter
  alias PtcRunner.LLM.PtcLlmHttpRuntime

  @selector "openai-compat:https://localhost/v1|local-model"

  @spec probe() :: {:error, atom()} | {:ok, :unexpected_success} | {:other, String.t()}
  def probe do
    Logger.configure(level: :critical)
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, _pid} = PtcLlmHttpRuntime.start_link([])
    Application.put_env(:ptc_runner, :llm_adapter, PtcLlmHttpAdapter)

    result =
      case LLM.callback(@selector, adapter: PtcLlmHttpAdapter) do
        {:ok, requester} ->
          requester.(%{
            messages: [%{role: :user, content: "ping"}],
            receive_timeout: 5_000
          })

        error ->
          error
      end

    case result do
      {:error, %ProviderError{kind: kind}} -> {:error, kind}
      {:ok, _response} -> {:ok, :unexpected_success}
      other -> {:other, inspect(other)}
    end
  end
end
