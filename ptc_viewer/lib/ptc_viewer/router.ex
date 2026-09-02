defmodule PtcViewer.Router do
  use Plug.Router

  alias PtcViewer.LiveLaunch
  alias PtcViewer.LiveProject
  alias PtcViewer.LiveSecurity
  alias PtcViewer.LiveStore
  alias PtcViewer.ReplError
  alias PtcViewer.ReplStore

  @id_pattern ~r/\A[A-Za-z0-9_-]{43}\z/
  @repl_paths ["/api/repl", "/api/repl/evaluations", "/api/repl/templates", "/api/repl/reset"]
  @body_limit 70_000
  @live_launch_body_limit 2_000_010

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

  post "/api/kernel/refresh" do
    refresh_snapshot(conn)
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
    send_analysis(conn, PtcViewer.Api.conversation(viewer_config(conn), run_id))
  end

  get "/api/analysis/runs/:run_id/result" do
    send_analysis(conn, PtcViewer.Api.result(viewer_config(conn), run_id))
  end

  get "/api/analysis/runs/:run_id/preludes" do
    send_analysis(conn, PtcViewer.Api.preludes(viewer_config(conn), run_id))
  end

  get "/api/analysis/runs/:run_id/execution-errors" do
    send_analysis(conn, PtcViewer.Api.execution_errors(viewer_config(conn), run_id))
  end

  get "/api/analysis/runs/:run_id/explicit-failure-values" do
    send_analysis(conn, PtcViewer.Api.explicit_failure_values(viewer_config(conn), run_id))
  end

  post "/api/live/runs/:run_id" do
    with :ok <- valid_reporter_security(conn),
         {:ok, store} <- live_store(conn),
         {:ok, body, conn} <- json_body(conn),
         :ok <- LiveStore.put_frame(store, run_id, body) do
      send_live_json(conn, 200, %{"status" => "ok"})
    else
      {:error, :forbidden_request} -> send_live_forbidden(conn)
      {:error, :live_disabled} -> send_live_json(conn, 503, %{"error" => "live_disabled"})
      {:error, reason, conn} -> send_live_json(conn, 400, %{"error" => to_string(reason)})
      {:error, reason} -> send_live_json(conn, 400, %{"error" => to_string(reason)})
    end
  end

  get "/api/live/runs" do
    with :ok <- valid_live_browser_request(conn),
         {:ok, store} <- live_store(conn) do
      send_live_json(conn, 200, %{"runs" => LiveStore.snapshot(store)})
    else
      {:error, :forbidden_request} -> send_live_forbidden(conn)
      {:error, :live_disabled} -> send_live_json(conn, 503, %{"error" => "live_disabled"})
    end
  end

  delete "/api/live/runs/:run_id" do
    with :ok <- valid_live_browser_mutation(conn),
         {:ok, store} <- live_store(conn),
         :ok <- LiveStore.delete_run(store, run_id) do
      send_live_json(conn, 200, %{"status" => "ok"})
    else
      {:error, :forbidden_request} -> send_live_forbidden(conn)
      {:error, :live_disabled} -> send_live_json(conn, 503, %{"error" => "live_disabled"})
      {:error, :unknown_run} -> send_live_json(conn, 404, %{"error" => "unknown_run"})
    end
  end

  post "/api/live/runs/:run_id/inspect" do
    with :ok <- valid_live_browser_mutation(conn),
         :ok <- refresh_live_trace(conn, run_id) do
      send_live_json(conn, 200, %{"status" => "ok"})
    else
      {:error, :forbidden_request} ->
        send_live_forbidden(conn)

      {:error, :not_found} ->
        send_live_json(conn, 404, %{"error" => "run_not_found"})

      {:error, :refresh_unavailable} ->
        send_live_json(conn, 503, %{"error" => "refresh_unavailable"})

      {:error, _reason} ->
        send_live_json(conn, 500, %{"error" => "refresh_failed"})
    end
  end

  get "/api/live/stream" do
    case valid_live_browser_request(conn) do
      {:error, :forbidden_request} ->
        send_live_forbidden(conn)

      :ok ->
        stream_live_runs(conn)
    end
  end

  defp stream_live_runs(conn) do
    case live_store(conn) do
      {:ok, store} ->
        {:ok, snapshot} = LiveStore.subscribe(store, self())

        conn =
          conn
          |> put_resp_header("content-type", "text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> send_chunked(200)

        case send_live_frames(conn, snapshot) do
          {:ok, conn} -> live_stream_loop(conn)
          {:error, conn} -> conn
        end

      {:error, :live_disabled} ->
        send_live_json(conn, 503, %{"error" => "live_disabled"})
    end
  end

  get "/api/live/project" do
    with :ok <- valid_live_browser_request(conn),
         {:ok, _store} <- live_store(conn) do
      send_live_json(conn, 200, LiveProject.describe(live_project(conn)))
    else
      {:error, :forbidden_request} -> send_live_forbidden(conn)
      {:error, :live_disabled} -> send_live_json(conn, 503, %{"error" => "live_disabled"})
    end
  end

  get "/api/live/launch" do
    with :ok <- valid_live_browser_request(conn),
         {:ok, store} <- live_store(conn),
         {:ok, launch} <- live_launch(conn) do
      send_live_json(conn, 200, LiveLaunch.describe(launch, LiveStore.launch_status(store)))
    else
      {:error, :forbidden_request} -> send_live_forbidden(conn)
      {:error, :live_disabled} -> send_live_json(conn, 503, %{"error" => "live_disabled"})
      {:error, :launch_not_configured} -> send_live_json(conn, 200, %{"enabled" => false})
    end
  end

  post "/api/live/launch" do
    with :ok <- valid_live_browser_mutation(conn),
         {:ok, store} <- live_store(conn),
         {:ok, launch} <- live_launch(conn),
         {:ok, body, conn} <- json_body(conn, @live_launch_body_limit),
         {:ok, run_fun} <- prepare_launch(launch, body, store),
         :ok <- LiveStore.begin_launch(store, run_fun) do
      send_live_json(conn, 202, %{"status" => "launched"})
    else
      {:error, :forbidden_request} -> send_live_forbidden(conn)
      {:error, :live_disabled} -> send_live_json(conn, 503, %{"error" => "live_disabled"})
      {:error, :launch_running} -> send_live_json(conn, 409, %{"error" => "launch_running"})
      {:error, reason, conn} -> send_live_json(conn, 400, %{"error" => to_string(reason)})
      {:error, reason} -> send_live_json(conn, 400, %{"error" => to_string(reason)})
    end
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

  get "/" do
    send_entry_document(conn)
  end

  get "/run/:run_id" do
    if valid_browser_run_id?(run_id) do
      encoded = URI.encode(run_id, &URI.char_unreserved?/1)

      conn
      |> security_headers()
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("location", "/#/run/" <> encoded)
      |> send_resp(302, "")
      |> scrub_bandit_response()
    else
      send_resp(conn, 404, "Not found")
    end
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  defp repl_store(conn) do
    case Keyword.get(viewer_config(conn), :repl_store) do
      store when is_pid(store) -> {:ok, store}
      _none -> {:error, :repl_not_configured}
    end
  end

  defp live_store(conn) do
    case Keyword.get(viewer_config(conn), :live_store) do
      store when is_pid(store) -> {:ok, store}
      _none -> {:error, :live_disabled}
    end
  end

  defp live_launch(conn) do
    case Keyword.get(viewer_config(conn), :live_launch) do
      %{manifest: _manifest} = launch -> {:ok, launch}
      _none -> {:error, :launch_not_configured}
    end
  end

  defp live_project(conn), do: Keyword.get(viewer_config(conn), :live_project)

  defp refresh_live_trace(conn, run_id) when byte_size(run_id) in 1..256 do
    case Keyword.get(viewer_config(conn), :live_trace_refresh) do
      callback when is_function(callback, 1) -> invoke_trace_refresh(callback, run_id)
      _none -> {:error, :refresh_unavailable}
    end
  end

  defp refresh_live_trace(_conn, _run_id), do: {:error, :not_found}

  defp refresh_snapshot(conn) do
    case Keyword.get(viewer_config(conn), :live_trace_refresh) do
      callback when is_function(callback, 1) ->
        case invoke_trace_refresh(callback, nil) do
          :ok -> send_json(conn, %{"status" => "ok"})
          {:error, :not_found} -> send_resp(conn, 404, "Not found")
          {:error, :refresh_unavailable} -> send_resp(conn, 503, "Trace refresh unavailable")
          {:error, _reason} -> send_resp(conn, 500, "Trace refresh failed")
        end

      _none ->
        send_resp(conn, 503, "Trace refresh unavailable")
    end
  end

  defp invoke_trace_refresh(callback, run_id) do
    case callback.(run_id) do
      :ok -> :ok
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _invalid -> {:error, :refresh_failed}
    end
  rescue
    _exception -> {:error, :refresh_failed}
  catch
    _kind, _reason -> {:error, :refresh_failed}
  end

  defp valid_reporter_security(conn) do
    if LiveSecurity.reporter_request?(
         conn,
         Keyword.get(viewer_config(conn), :live_token_digest)
       ),
       do: :ok,
       else: {:error, :forbidden_request}
  end

  defp valid_live_browser_request(conn) do
    if LiveSecurity.browser_control_request?(
         conn,
         Keyword.get(viewer_config(conn), :live_token_digest)
       ),
       do: :ok,
       else: {:error, :forbidden_request}
  end

  defp valid_live_browser_mutation(conn) do
    nonce = Keyword.get(viewer_config(conn), :live_mutation_nonce)
    token_digest = Keyword.get(viewer_config(conn), :live_token_digest)

    if LiveSecurity.browser_mutation?(conn, nonce, token_digest),
      do: :ok,
      else: {:error, :forbidden_request}
  end

  # The browser picks one of two shapes: an edited input object for a workflow
  # run, or a mission plus the expression to evaluate in it.
  defp prepare_launch(launch, %{"mission" => mission, "expression" => expression}, store),
    do: LiveLaunch.prepare_mission(launch, mission, expression, store)

  defp prepare_launch(launch, body, store) do
    with {:ok, input} <- launch_input(body), do: LiveLaunch.prepare(launch, input, store)
  end

  defp launch_input(%{"input" => input}) when is_map(input), do: {:ok, input}
  defp launch_input(_body), do: {:error, :invalid_input}

  defp send_live_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp send_live_forbidden(conn),
    do: send_live_json(conn, 403, %{"error" => "forbidden_request"})

  defp send_live_frames(conn, jsons) do
    Enum.reduce_while(jsons, {:ok, conn}, fn json, {:ok, conn} ->
      case chunk(conn, "data: " <> json <> "\n\n") do
        {:ok, conn} -> {:cont, {:ok, conn}}
        {:error, _reason} -> {:halt, {:error, conn}}
      end
    end)
  end

  # One process per connection under Bandit; blocking in receive is the
  # intended shape for SSE. Heartbeat comments keep proxies from timing out.
  defp live_stream_loop(conn) do
    receive do
      {:live_frame, json} ->
        case chunk(conn, "data: " <> json <> "\n\n") do
          {:ok, conn} -> live_stream_loop(conn)
          {:error, _reason} -> conn
        end
    after
      15_000 ->
        case chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} -> live_stream_loop(conn)
          {:error, _reason} -> conn
        end
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

  defp json_body(conn, limit \\ @body_limit) do
    with :ok <- json_content_type(conn),
         {:ok, raw, conn} <- read_limited_body(conn, limit),
         {:ok, body} when is_map(body) <- Jason.decode(raw) do
      {:ok, body, conn}
    else
      {:error, :body_too_large, conn} -> {:error, :body_too_large, conn}
      {:error, :unsupported_media_type} -> {:error, :unsupported_media_type, conn}
      _invalid -> {:error, :invalid_json, conn}
    end
  end

  defp bodyless(conn) do
    case read_limited_body(conn, @body_limit) do
      {:ok, "", conn} -> {:ok, conn}
      {:ok, _body, conn} -> {:error, :delete_body_not_allowed, conn}
      {:error, :body_too_large, conn} -> {:error, :body_too_large, conn}
    end
  end

  defp read_limited_body(conn, limit) do
    case read_body(conn, length: limit, read_length: limit + 1) do
      {:ok, body, conn} when byte_size(body) <= limit -> {:ok, body, conn}
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
        repl_enabled = Keyword.get(viewer_config(conn), :repl_enabled, false)
        live_nonce = Keyword.get(viewer_config(conn), :live_mutation_nonce)
        live_token_digest = Keyword.get(viewer_config(conn), :live_token_digest)

        live_enabled =
          is_binary(live_nonce) and
            LiveSecurity.browser_control_request?(conn, live_token_digest)

        config =
          if repl_enabled do
            store = Keyword.fetch!(viewer_config(conn), :repl_store)
            {:ok, nonce} = ReplStore.page_bootstrap_nonce(store)
            %{"repl_enabled" => true, "page_bootstrap_nonce" => nonce}
          else
            %{"repl_enabled" => false}
          end

        config =
          if live_enabled do
            Map.merge(config, %{
              "live_enabled" => true,
              "live_mutation_nonce" => live_nonce
            })
          else
            Map.put(config, "live_enabled", false)
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

  defp valid_browser_run_id?(run_id),
    do: is_binary(run_id) and String.valid?(run_id) and byte_size(run_id) in 1..512

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

      {:error, :source_retained_limit_exceeded} ->
        send_resp(conn, 413, "Trace source retained size exceeded")

      {:error, :run_isolated} ->
        send_resp(conn, 422, "run_isolated")

      {:error, reason} when reason in [:malformed_source, :unsupported_version] ->
        send_resp(conn, 422, "Unsupported trace source")

      {:error, _reason} ->
        send_resp(conn, 400, "Invalid trace query")
    end
  end

  defp send_analysis(conn, result) do
    case result do
      {:ok, result} ->
        send_private_json(conn, result)

      # Not a transport status: private evidence is withheld by a decision, and
      # each of these four is a different decision with a different next action.
      # The body is the reason code the browser renders as the change that would
      # produce the evidence, so they answer separately rather than as one 404.
      # The first two are about the run, the last two about the project.
      {:error, :not_found} ->
        send_resp(conn, 404, "inspection_run_not_recorded")

      {:error, :result_not_found} ->
        send_resp(conn, 404, "inspection_result_not_recorded")

      {:error, :inspection_run_mismatch} ->
        send_resp(conn, 404, "inspection_run_mismatch")

      {:error, :inspection_not_configured} ->
        send_resp(conn, 404, "inspection_not_configured")

      {:error, :inspection_not_private} ->
        send_resp(conn, 404, "inspection_not_private")

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
