port = 4017

{:ok, listen_socket} =
  :gen_tcp.listen(port, [
    :binary,
    packet: :raw,
    active: false,
    reuseaddr: true,
    ip: {127, 0, 0, 1}
  ])

IO.puts("dummy upstream listening on http://127.0.0.1:#{port}")
IO.puts("try: GET /echo?message=hello")

read_request = fn socket ->
  case :gen_tcp.recv(socket, 0, 5_000) do
    {:ok, request} -> request
    {:error, _reason} -> ""
  end
end

send_json = fn socket, status, body ->
  encoded = Jason.encode!(body)
  reason = if status == 200, do: "OK", else: "Not Found"

  :gen_tcp.send(socket, [
    "HTTP/1.1 #{status} #{reason}\r\n",
    "content-type: application/json\r\n",
    "content-length: #{byte_size(encoded)}\r\n",
    "connection: close\r\n",
    "\r\n",
    encoded
  ])
end

handle_request = fn socket, request ->
  with [request_line | _headers] <- String.split(request, "\r\n"),
       [_method, target, _version] <- String.split(request_line, " "),
       %{path: "/echo"} = uri <- URI.parse(target) do
    params = URI.decode_query(uri.query || "")
    message = Map.get(params, "message", "")
    send_json.(socket, 200, %{"echo" => message, "path" => uri.path})
  else
    _ ->
      send_json.(socket, 404, %{"error" => "not_found"})
  end
end

accept = fn accept ->
  {:ok, socket} = :gen_tcp.accept(listen_socket)
  request = read_request.(socket)
  handle_request.(socket, request)
  :gen_tcp.close(socket)
  accept.(accept)
end

accept.(accept)
