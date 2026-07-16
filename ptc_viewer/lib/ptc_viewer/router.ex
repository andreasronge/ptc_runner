defmodule PtcViewer.Router do
  use Plug.Router

  plug(Plug.Static,
    at: "/",
    from: {:ptc_viewer, "priv/static"},
    only: ~w(index.html css js)
  )

  plug(:match)
  plug(:dispatch)

  @impl Plug
  def call(conn, config) do
    conn
    |> assign(:viewer_config, config)
    |> super(config)
  end

  get "/api/kernel/runs" do
    send_kernel_query(conn, :list_runs, query_arguments(conn))
  end

  get "/api/kernel/runs/:run_id" do
    send_kernel_query(conn, :get_run, %{"run_id" => run_id})
  end

  get "/api/kernel/runs/:run_id/turns" do
    arguments = Map.put(query_arguments(conn), "run_id", run_id)
    send_kernel_query(conn, :list_turns, arguments)
  end

  get "/api/kernel/counters" do
    send_kernel_query(conn, :counters, query_arguments(conn))
  end

  get "/api/inspection/runs/:run_id" do
    send_inspection(conn, run_id)
  end

  match "/api/*path" do
    send_resp(conn, 404, "Not found")
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

  defp send_kernel_query(conn, operation, arguments) do
    case PtcViewer.Api.kernel_query(viewer_config(conn), operation, arguments) do
      {:ok, result} ->
        send_json(conn, result)

      {:error, :not_found} ->
        send_resp(conn, 404, "Not found")

      {:error, :unavailable} ->
        send_resp(conn, 503, "Kernel trace adapter unavailable")

      {:error, :adapter_failure} ->
        send_resp(conn, 500, "Kernel trace adapter failed")

      {:error, :source_unavailable} ->
        send_resp(conn, 503, "Trace source unavailable")

      {:error, :source_changed} ->
        send_resp(conn, 409, "Trace source changed")

      {:error, :source_limit_exceeded} ->
        send_resp(conn, 413, "Trace source too large")

      {:error, reason} when reason in [:malformed_source, :unsupported_version] ->
        send_resp(conn, 422, "Unsupported trace source")

      {:error, _reason} ->
        send_resp(conn, 400, "Invalid trace query")
    end
  end

  defp send_inspection(conn, run_id) do
    case PtcViewer.Api.inspection(viewer_config(conn), run_id) do
      {:ok, result} ->
        send_json(conn, result)

      {:error, :not_found} ->
        send_resp(conn, 404, "Not found")

      {:error, :unavailable} ->
        send_resp(conn, 503, "Inspection artifact unavailable")

      {:error, :adapter_failure} ->
        send_resp(conn, 500, "Inspection adapter failed")

      {:error, :inspection_source_unavailable} ->
        send_resp(conn, 503, "Inspection source unavailable")

      {:error, :inspection_source_changed} ->
        send_resp(conn, 409, "Inspection source changed")

      {:error, :inspection_source_limit_exceeded} ->
        send_resp(conn, 413, "Inspection source too large")

      {:error, reason}
      when reason in [:malformed_inspection_artifact, :invalid_inspection_artifact] ->
        send_resp(conn, 422, "Unsupported inspection artifact")

      {:error, _reason} ->
        send_resp(conn, 400, "Invalid inspection query")
    end
  end

  defp viewer_config(conn), do: conn.assigns.viewer_config

  defp query_arguments(conn) do
    conn
    |> fetch_query_params()
    |> Map.fetch!(:query_params)
    |> Map.new(fn
      {"limit", value} -> {"limit", integer_or_value(value)}
      {"tags", value} -> {"tags", json_map_or_value(value)}
      pair -> pair
    end)
  end

  defp integer_or_value(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _invalid -> value
    end
  end

  defp json_map_or_value(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _invalid -> value
    end
  end
end
