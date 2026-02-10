defmodule PtcViewer.Router do
  use Plug.Router

  plug(Plug.Static,
    at: "/",
    from: {:ptc_viewer, "priv/static"},
    only: ~w(index.html css js)
  )

  plug(:match)
  plug(:dispatch)

  get "/api/traces" do
    traces = PtcViewer.Api.list_traces()
    send_json(conn, traces)
  end

  get "/api/traces/:filename" do
    case PtcViewer.Api.get_trace(filename) do
      {:ok, content} ->
        conn
        |> put_resp_content_type("application/x-ndjson")
        |> send_resp(200, content)

      {:error, :not_found} ->
        send_resp(conn, 404, "Not found")
    end
  end

  get "/api/plans" do
    plans = PtcViewer.Api.list_plans()
    send_json(conn, plans)
  end

  get "/api/plans/:filename" do
    case PtcViewer.Api.get_plan(filename) do
      {:ok, content} -> send_json_raw(conn, content)
      {:error, :not_found} -> send_resp(conn, 404, "Not found")
    end
  end

  match _ do
    # SPA fallback - serve index.html
    index_path = Application.app_dir(:ptc_viewer, "priv/static/index.html")

    case File.read(index_path) do
      {:ok, content} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, content)

      {:error, _} ->
        send_resp(conn, 404, "Not found")
    end
  end

  defp send_json(conn, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(data))
  end

  defp send_json_raw(conn, content) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, content)
  end
end
