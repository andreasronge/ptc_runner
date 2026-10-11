defmodule PtcRunner.LiveStatus.HTTP do
  @moduledoc false

  @doc false
  def report_http(viewer_url, run_id, frame, viewer_token)
      when is_binary(viewer_url) and is_binary(run_id) and is_map(frame) do
    {:ok, endpoint} = PtcRunner.HTTPEndpoint.validate(viewer_url, viewer_token)
    encoded_run_id = URI.encode(run_id, &URI.char_unreserved?/1)
    url = PtcRunner.HTTPEndpoint.append_path(endpoint, "/api/live/runs/" <> encoded_run_id)

    case Req.post(url,
           json: frame,
           headers: authorization_headers(viewer_token),
           retry: false,
           redirect: false,
           connect_options: [timeout: 500],
           receive_timeout: 1_000
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      _other -> :error
    end
  rescue
    _exception -> :error
  end

  defp authorization_headers(token) when is_binary(token),
    do: [{"authorization", "Bearer " <> token}]

  defp authorization_headers(_token), do: []
end
