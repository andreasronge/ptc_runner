defmodule PtcRunner.TestSupport.PtcLlmHttpColdHostname do
  @moduledoc false

  # Probe used by a fresh OS/BEAM process so resolver state cannot already be
  # warm. A public HTTPS hostname is required: hosts-file names such as
  # localhost are rejected as loopback before the DNS-role CA store load that
  # exhausts the 0.1.0 partition (ptc_llm_http#16).

  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.LLM
  alias PtcRunner.LLM.PtcLlmHttpAdapter
  alias PtcRunner.LLM.PtcLlmHttpRuntime

  @selector "openai-compat:https://example.com/v1|local-model"

  @spec probe() :: atom()
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
      {:error, %ProviderError{kind: kind}} -> kind
      {:ok, _response} -> :unexpected_success
      _other -> :unexpected_result
    end
  end
end
