defmodule PtcRunner.TestSupport.HTTPTimeoutProbe do
  @moduledoc false

  def run(request) do
    send(self(), {:transport_timeout, request.options[:receive_timeout]})

    body = %{
      "choices" => [
        %{"message" => %{"role" => "assistant", "content" => "ok"}, "finish_reason" => "stop"}
      ],
      "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
    }

    {request, Req.Response.new(status: 200, body: body)}
  end
end
