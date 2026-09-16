defmodule PtcGateway.ConformanceProxy do
  @moduledoc false
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    {:ok, body, conn} = read_body(conn, length: 2_097_153)
    incoming_host = get_req_header(conn, "host") |> List.first()
    proxy_authority = opts[:proxy_authority]
    target_authority = opts[:target_authority]

    forwarded_host =
      if incoming_host == proxy_authority, do: target_authority, else: incoming_host

    headers =
      conn.req_headers
      |> Enum.reject(fn {name, _value} ->
        name in ["host", "content-length", "authorization"]
      end)
      |> Kernel.++([{"host", forwarded_host}, {"authorization", "Bearer " <> opts[:token]}])

    response =
      Req.request!(
        method: conn.method,
        url: opts[:target] <> conn.request_path,
        headers: headers,
        body: body,
        retry: false,
        decode_body: false
      )

    conn =
      response.headers
      |> Map.drop(["connection", "content-length", "transfer-encoding"])
      |> Enum.reduce(conn, fn {name, values}, acc ->
        Enum.reduce(values, acc, &put_resp_header(&2, name, &1))
      end)

    send_resp(conn, response.status, response.body)
  end
end
