defmodule PtcViewer.Router do
  use Plug.Router

  alias PtcViewer.ReplError
  alias PtcViewer.ReplStore

  @id_pattern ~r/\A[A-Za-z0-9_-]{43}\z/
  @repl_paths ["/api/repl", "/api/repl/evaluations", "/api/repl/templates", "/api/repl/reset"]
  @body_limit 70_000

  plug(Plug.Static,
    at: "/",
    from: {:ptc_viewer, "priv/static"},
    only: ~w(css js)
  )

  plug(:match)
  plug(:dispatch)

  @impl Plug
  def call(conn, config) do
    conn
    |> assign(:viewer_config, config)
    |> super(config)
  end

  get "/api/repl" do
    with {:ok, store} <- repl_store(conn),
         :ok <- valid_host(conn),
         :ok <- valid_bootstrap_security(conn),
         {:ok, body} <- ReplStore.bootstrap(store) do
      send_repl_success(conn, body)
    else
      {:error, reason} -> send_repl_error(conn, reason)
    end
  end

  post "/api/repl/evaluations" do
    with {:ok, store} <- repl_store(conn),
         :ok <- valid_mutation_security(conn),
         {:ok, session_id} <- session_precondition(conn),
         {:ok, body, conn} <- json_body(conn),
         {:ok, source} <- evaluation_body(body),
         {:ok, response} <- ReplStore.evaluate(store, session_id, source) do
      send_repl_success(conn, response)
    else
      {:error, reason} -> send_repl_error(conn, reason)
      {:error, reason, conn} -> send_repl_error(conn, reason)
    end
  end

  post "/api/repl/templates" do
    with {:ok, store} <- repl_store(conn),
         :ok <- valid_mutation_security(conn),
         {:ok, session_id} <- session_precondition(conn),
         {:ok, body, conn} <- json_body(conn),
         {:ok, kind, run_id} <- template_body(body),
         {:ok, response} <- ReplStore.template(store, session_id, kind, run_id) do
      send_repl_success(conn, response)
    else
      {:error, reason} -> send_repl_error(conn, reason)
      {:error, reason, conn} -> send_repl_error(conn, reason)
    end
  end

  post "/api/repl/reset" do
    with {:ok, store} <- repl_store(conn),
         :ok <- valid_mutation_security(conn),
         {:ok, session_id} <- session_precondition(conn),
         {:ok, body, conn} <- json_body(conn),
         true <- map_size(body) == 0,
         {:ok, response} <- ReplStore.reset(store, session_id) do
      send_repl_success(conn, response)
    else
      false -> send_repl_error(conn, :invalid_request)
      {:error, reason} -> send_repl_error(conn, reason)
      {:error, reason, conn} -> send_repl_error(conn, reason)
    end
  end

  delete "/api/repl" do
    with {:ok, store} <- repl_store(conn),
         :ok <- valid_mutation_security(conn),
         {:ok, session_id} <- session_precondition(conn),
         {:ok, conn} <- bodyless(conn),
         {:ok, response} <- ReplStore.close(store, session_id) do
      send_repl_success(conn, response)
    else
      {:error, reason} -> send_repl_error(conn, reason)
      {:error, reason, conn} -> send_repl_error(conn, reason)
    end
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

  get "/api/analysis/runs/:run_id/conversation" do
    send_conversation(conn, run_id)
  end

  match "/api/*path" do
    if conn.request_path in @repl_paths do
      case repl_store(conn) do
        {:ok, _store} ->
          case valid_host(conn) do
            :ok ->
              conn
              |> put_resp_header("allow", allowed_methods(conn.request_path))
              |> send_repl_error(:method_not_allowed)

            {:error, reason} ->
              send_repl_error(conn, reason)
          end

        {:error, reason} ->
          send_repl_error(conn, reason)
      end
    else
      send_resp(conn, 404, "Not found")
    end
  end

  match _ do
    send_entry_document(conn)
  end

  defp repl_store(conn) do
    case Keyword.get(viewer_config(conn), :repl_store) do
      store when is_pid(store) -> {:ok, store}
      _none -> {:error, :repl_not_configured}
    end
  end

  defp valid_bootstrap_security(conn) do
    with "same-origin" <- exact_header(conn, "sec-fetch-site"),
         nonce when is_binary(nonce) <- exact_header(conn, "x-ptc-viewer-page-nonce"),
         true <- valid_id?(nonce),
         {:ok, store} <- repl_store(conn),
         :ok <- ReplStore.authorize_bootstrap(store, nonce) do
      :ok
    else
      _invalid -> {:error, :forbidden_request}
    end
  end

  defp valid_mutation_security(conn) do
    with :ok <- valid_host(conn),
         :ok <- valid_origin(conn),
         nonce when is_binary(nonce) <- exact_header(conn, "x-ptc-viewer-nonce"),
         {:ok, store} <- repl_store(conn),
         true <- valid_id?(nonce),
         :ok <- ReplStore.authorize_mutation(store, nonce) do
      :ok
    else
      _invalid -> {:error, :forbidden_request}
    end
  end

  defp valid_host(conn) do
    expected_port = expected_port(conn)

    if conn.host in ["localhost", "127.0.0.1"] and conn.port == expected_port,
      do: :ok,
      else: {:error, :forbidden_request}
  end

  defp valid_origin(conn) do
    with origin when is_binary(origin) <- exact_header(conn, "origin"),
         %URI{scheme: "http", host: host} = uri <- URI.parse(origin),
         true <-
           host == conn.host and origin_port(uri) == conn.port and uri.path in [nil, ""] and
             is_nil(uri.query) and is_nil(uri.fragment) do
      :ok
    else
      _invalid -> {:error, :forbidden_request}
    end
  end

  defp expected_port(conn) do
    config = viewer_config(conn)

    case Keyword.get(config, :expected_port) do
      port when is_integer(port) -> port
      _none -> PtcViewer.Server.expected_port(Keyword.fetch!(config, :viewer_server))
    end
  catch
    :exit, _reason -> -1
  end

  defp session_precondition(conn) do
    case get_req_header(conn, "x-ptc-viewer-session") do
      [value] when is_binary(value) ->
        if valid_id?(value), do: {:ok, value}, else: {:error, :session_precondition_required}

      _invalid ->
        {:error, :session_precondition_required}
    end
  end

  defp json_body(conn) do
    with :ok <- json_content_type(conn),
         {:ok, raw, conn} <- read_limited_body(conn),
         {:ok, body} when is_map(body) <- Jason.decode(raw) do
      {:ok, body, conn}
    else
      {:error, :body_too_large, conn} -> {:error, :body_too_large, conn}
      {:error, :unsupported_media_type} -> {:error, :unsupported_media_type, conn}
      _invalid -> {:error, :invalid_json, conn}
    end
  end

  defp bodyless(conn) do
    case read_limited_body(conn) do
      {:ok, "", conn} -> {:ok, conn}
      {:ok, _body, conn} -> {:error, :delete_body_not_allowed, conn}
      {:error, :body_too_large, conn} -> {:error, :body_too_large, conn}
    end
  end

  defp read_limited_body(conn) do
    case read_body(conn, length: @body_limit, read_length: @body_limit + 1) do
      {:ok, body, conn} when byte_size(body) <= @body_limit -> {:ok, body, conn}
      {:more, _body, conn} -> {:error, :body_too_large, conn}
      {:error, _reason} -> {:error, :invalid_json, conn}
    end
  end

  defp json_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [value] ->
        case Plug.Conn.Utils.media_type(value) do
          {:ok, "application", "json", _params} -> :ok
          _invalid -> {:error, :unsupported_media_type}
        end

      _invalid ->
        {:error, :unsupported_media_type}
    end
  end

  defp evaluation_body(%{"source" => source} = body)
       when map_size(body) == 1 and is_binary(source),
       do: {:ok, source}

  defp evaluation_body(_body), do: {:error, :invalid_request}

  defp template_body(%{"kind" => kind, "run_id" => run_id} = body)
       when map_size(body) == 2 and kind in ["run", "turns"] and is_binary(run_id),
       do: {:ok, String.to_existing_atom(kind), run_id}

  defp template_body(_body), do: {:error, :invalid_request}

  defp exact_header(conn, name) do
    case get_req_header(conn, name) do
      [value] -> value
      _invalid -> nil
    end
  end

  defp origin_port(%URI{port: port}) when is_integer(port), do: port
  defp origin_port(%URI{scheme: "http"}), do: 80
  defp origin_port(_uri), do: -1

  defp valid_id?(id), do: is_binary(id) and Regex.match?(@id_pattern, id)

  defp send_repl_success(conn, %{"session_id" => session_id} = body) do
    if valid_id?(session_id) do
      conn
      |> put_resp_header("x-ptc-viewer-session", session_id)
      |> send_repl_json(200, body)
    else
      send_repl_error(conn, :adapter_failure)
    end
  end

  defp send_repl_success(conn, _body), do: send_repl_error(conn, :adapter_failure)

  defp send_repl_error(conn, reason) do
    code = public_error(reason)
    {status, body} = ReplError.response(code)
    send_repl_json(conn, status, body)
  end

  defp public_error(reason)
       when reason in [
              :invalid_json,
              :invalid_request,
              :delete_body_not_allowed,
              :forbidden_request,
              :repl_not_configured,
              :method_not_allowed,
              :operation_active,
              :session_terminal,
              :session_closed,
              :trace_changed,
              :session_changed,
              :body_too_large,
              :source_too_large,
              :trace_source_too_large,
              :unsupported_media_type,
              :unsupported_trace,
              :session_precondition_required,
              :adapter_failure,
              :repl_start_failed,
              :persistence_failed,
              :trace_unavailable
            ],
       do: reason

  defp public_error(_reason), do: :adapter_failure

  defp send_repl_json(conn, status, body) do
    conn
    |> security_headers()
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> scrub_bandit_response()
  end

  defp send_entry_document(conn) do
    index_path = Application.app_dir(:ptc_viewer, "priv/static/index.html")

    case File.read(index_path) do
      {:ok, content} ->
        enabled = Keyword.get(viewer_config(conn), :repl_enabled, false)

        config =
          if enabled do
            store = Keyword.fetch!(viewer_config(conn), :repl_store)
            {:ok, nonce} = ReplStore.page_bootstrap_nonce(store)
            %{"repl_enabled" => true, "page_bootstrap_nonce" => nonce}
          else
            %{"repl_enabled" => false}
          end

        encoded = config |> Jason.encode!() |> Base.url_encode64(padding: false)
        meta = ~s(<meta name="ptc-viewer-config" content="#{encoded}">)
        content = String.replace(content, "</head>", "  #{meta}\n</head>")

        conn
        |> security_headers()
        |> put_resp_header("cache-control", "no-store")
        |> delete_resp_header("etag")
        |> put_resp_content_type("text/html")
        |> send_resp(200, content)
        |> scrub_bandit_response()

      {:error, _reason} ->
        send_resp(conn, 404, "Not found")
    end
  end

  defp security_headers(conn) do
    conn
    |> put_resp_header(
      "content-security-policy",
      "default-src 'self'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; object-src 'none'; base-uri 'none'"
    )
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
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

  defp send_conversation(conn, run_id) do
    case PtcViewer.Api.conversation(viewer_config(conn), run_id) do
      {:ok, result} ->
        send_private_json(conn, result)

      {:error, :not_found} ->
        send_resp(conn, 404, "Not found")

      {:error, :inspection_run_mismatch} ->
        send_resp(conn, 404, "Inspection run mismatch")

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

  defp send_private_json(conn, data) do
    conn =
      conn
      |> security_headers()
      |> put_resp_header("cache-control", "no-store")
      |> send_json(data)

    scrub_bandit_response(conn)
  end

  defp viewer_config(conn), do: conn.assigns.viewer_config

  defp allowed_methods("/api/repl"), do: "GET, DELETE"
  defp allowed_methods(_path), do: "POST"

  defp scrub_bandit_response(%{adapter: {Bandit.Adapter, _adapter}} = conn) do
    resp_headers =
      Enum.reject(conn.resp_headers, fn {name, _value} -> name == "x-ptc-viewer-session" end)

    %{conn | resp_body: nil, req_headers: [], resp_headers: resp_headers}
  end

  defp scrub_bandit_response(conn), do: conn

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
