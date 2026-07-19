defmodule PtcViewer.ReplRouterTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias PtcViewer.ReplStore
  alias PtcViewer.TestReplAdapter

  @page_nonce "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

  test "disabled Viewer exposes fixed REPL errors and no bootstrap nonce" do
    opts = [trace_dir: System.tmp_dir!(), repl_enabled: false, repl_store: nil]

    Enum.each(
      [
        conn(:get, "/api/repl"),
        conn(:post, "/api/repl/evaluations", "{}"),
        conn(:post, "/api/repl/templates", "{}"),
        conn(:post, "/api/repl/reset", "{}"),
        conn(:delete, "/api/repl")
      ],
      fn request ->
        response = call_router(request, opts)
        assert response.status == 404
        assert error_code(response) == "repl_not_configured"
      end
    )

    html = conn(:get, "/") |> call_router(opts)
    assert html.status == 200
    assert get_resp_header(html, "cache-control") == ["no-store"]
    refute html.resp_body =~ @page_nonce
    refute html.resp_body =~ "page_bootstrap_nonce"
  end

  test "bootstrap requires the loopback authority, page nonce, and fetch metadata" do
    %{opts: opts, backend: backend} = start_repl()

    assert forbidden(conn(:get, "http://evil.example/api/repl"), opts)

    assert forbidden(
             conn(:get, "http://localhost/api/repl")
             |> put_req_header("x-ptc-viewer-page-nonce", @page_nonce),
             opts
           )

    assert forbidden(
             conn(:get, "http://localhost/api/repl")
             |> put_req_header("sec-fetch-site", "cross-site")
             |> put_req_header("x-ptc-viewer-page-nonce", @page_nonce),
             opts
           )

    assert is_nil(TestReplAdapter.state(backend).session)

    response = bootstrap(opts)
    assert response.status == 200
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert [session_id] = get_resp_header(response, "x-ptc-viewer-session")
    assert byte_size(session_id) == 43
    assert Jason.decode!(response.resp_body)["session_id"] == session_id
  end

  test "evaluation uses strict JSON, nonce, Origin, and atomic session preconditions" do
    %{opts: opts} = start_repl()
    bootstrap = bootstrap(opts)
    body = Jason.decode!(bootstrap.resp_body)
    session_id = body["session_id"]
    nonce = body["mutation_nonce"]

    assert error_status(
             mutation(:post, "/api/repl/evaluations", %{"source" => "1"}, session_id, nonce,
               origin: "http://evil.example"
             ),
             opts
           ) == {403, "forbidden_request"}

    assert error_status(
             mutation(
               :post,
               "/api/repl/evaluations",
               %{"source" => "1"},
               session_id,
               random_id()
             ),
             opts
           ) == {403, "forbidden_request"}

    malformed =
      conn(:post, "http://localhost/api/repl/evaluations", Jason.encode!(%{"source" => "1"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", "http://localhost")
      |> put_req_header("x-ptc-viewer-nonce", nonce)
      |> call_router(opts)

    assert {428, "session_precondition_required"} ==
             {malformed.status, error_code(malformed)}

    wrong_shape =
      mutation(
        :post,
        "/api/repl/evaluations",
        %{"source" => "1", "profile" => "other"},
        session_id,
        nonce
      )
      |> call_router(opts)

    assert {400, "invalid_request"} == {wrong_shape.status, error_code(wrong_shape)}

    evaluated =
      mutation(:post, "/api/repl/evaluations", %{"source" => "(+ 1 2)"}, session_id, nonce)
      |> call_router(opts)

    assert evaluated.status == 200
    decoded = Jason.decode!(evaluated.resp_body)
    assert decoded["evaluation"]["status"] == "ok"
    assert hd(decoded["transcript"])["source_preview"] == "(+ 1 2)"

    stale = mutation(:post, "/api/repl/reset", %{}, random_id(), nonce) |> call_router(opts)
    assert {412, "session_changed"} == {stale.status, error_code(stale)}

    extra_reset =
      mutation(:post, "/api/repl/reset", %{"unexpected" => true}, session_id, nonce)
      |> call_router(opts)

    assert {400, "invalid_request"} == {extra_reset.status, error_code(extra_reset)}
  end

  test "template, reset, and close return ordered generation envelopes" do
    %{opts: opts} = start_repl()
    first = bootstrap(opts) |> response_body()
    session_id = first["session_id"]
    nonce = first["mutation_nonce"]

    template =
      mutation(
        :post,
        "/api/repl/templates",
        %{"kind" => "turns", "run_id" => "run-1"},
        session_id,
        nonce
      )
      |> call_router(opts)
      |> response_body()

    assert template["template"]["source"] == ~s[(log/turns "run-1" {})]

    reset = mutation(:post, "/api/repl/reset", %{}, session_id, nonce) |> call_router(opts)
    reset_body = response_body(reset)
    replacement = reset_body["session_id"]
    assert replacement != session_id
    assert reset_body["generation_sequence"] == 2
    assert get_resp_header(reset, "x-ptc-viewer-session") == [replacement]

    closed =
      mutation(:delete, "/api/repl", nil, replacement, nonce)
      |> call_router(opts)

    assert closed.status == 200
    assert response_body(closed)["lifecycle"] == "closed"
    assert response_body(bootstrap(opts))["session_id"] == replacement
  end

  test "known REPL paths reject every wrong method without CORS" do
    %{opts: opts} = start_repl()

    response = conn(:options, "http://localhost/api/repl") |> call_router(opts)
    assert {405, "method_not_allowed"} == {response.status, error_code(response)}
    assert get_resp_header(response, "allow") == ["GET, DELETE"]
    assert get_resp_header(response, "access-control-allow-origin") == []

    hostile = conn(:options, "http://example.test/api/repl/reset") |> call_router(opts)
    assert {403, "forbidden_request"} == {hostile.status, error_code(hostile)}

    unknown = conn(:options, "http://localhost/api/unknown") |> call_router(opts)
    assert unknown.status == 404
    assert unknown.resp_body == "Not found"

    evaluation = conn(:get, "http://localhost/api/repl/evaluations") |> call_router(opts)
    assert get_resp_header(evaluation, "allow") == ["POST"]
  end

  test "enabled entry documents contain only the public bootstrap configuration" do
    %{opts: opts} = start_repl()
    html = conn(:get, "/anything") |> call_router(opts)

    assert html.status == 200
    assert html.resp_body =~ "ptc-viewer-config"
    refute html.resp_body =~ "log-analysis-v1"
    refute html.resp_body =~ "source_limit_bytes"
    refute html.resp_body =~ "test_pid"

    [encoded] =
      Regex.run(~r/name="ptc-viewer-config" content="([^"]+)"/, html.resp_body,
        capture: :all_but_first
      )

    config = encoded |> Base.url_decode64!(padding: false) |> Jason.decode!()
    assert config == %{"repl_enabled" => true, "page_bootstrap_nonce" => @page_nonce}
  end

  defp start_repl do
    {:ok, backend, features} = TestReplAdapter.connect(%{test_pid: self()})
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    {:ok, store} =
      ReplStore.start_link(
        owner: self(),
        task_supervisor: task_supervisor,
        adapter: TestReplAdapter,
        backend: backend,
        features: features,
        page_bootstrap_nonce: @page_nonce
      )

    on_exit(fn ->
      safe_stop(store, &GenServer.stop/1)
      safe_stop(task_supervisor, &Supervisor.stop/1)
      safe_stop(backend, &Agent.stop/1)
    end)

    opts = [
      trace_dir: System.tmp_dir!(),
      repl_enabled: true,
      repl_store: store,
      expected_port: 80
    ]

    %{opts: opts, store: store, backend: backend}
  end

  defp bootstrap(opts) do
    conn(:get, "http://localhost/api/repl")
    |> put_req_header("sec-fetch-site", "same-origin")
    |> put_req_header("x-ptc-viewer-page-nonce", @page_nonce)
    |> call_router(opts)
  end

  defp mutation(method, path, body, session_id, nonce, options \\ []) do
    encoded = if is_nil(body), do: "", else: Jason.encode!(body)

    conn(method, "http://localhost#{path}", encoded)
    |> maybe_json(body)
    |> put_req_header("origin", Keyword.get(options, :origin, "http://localhost"))
    |> put_req_header("x-ptc-viewer-nonce", nonce)
    |> put_req_header("x-ptc-viewer-session", session_id)
  end

  defp maybe_json(conn, nil), do: conn
  defp maybe_json(conn, _body), do: put_req_header(conn, "content-type", "application/json")

  defp forbidden(conn, opts) do
    response = call_router(conn, opts)
    response.status == 403 and error_code(response) == "forbidden_request"
  end

  defp error_status(conn, opts) do
    response = call_router(conn, opts)
    {response.status, error_code(response)}
  end

  defp error_code(conn), do: Jason.decode!(conn.resp_body)["error"]["code"]
  defp response_body(conn), do: Jason.decode!(conn.resp_body)
  defp call_router(conn, opts), do: PtcViewer.Router.call(conn, PtcViewer.Router.init(opts))
  defp random_id, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp safe_stop(pid, stop) do
    if Process.alive?(pid), do: stop.(pid)
  catch
    :exit, _reason -> :ok
  end
end
