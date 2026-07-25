#!/usr/bin/env python3
"""Accept one mock Hex package publication and verify its exact bytes."""

import http.server
import pathlib
import sys


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(
            "usage: hex_publish_server.py PACKAGE_TARBALL ADDRESS_FILE RECEIPT_FILE"
        )

    package = pathlib.Path(sys.argv[1]).read_bytes()
    address_file = pathlib.Path(sys.argv[2])
    receipt_file = pathlib.Path(sys.argv[3])

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self) -> None:
            length = int(self.headers["content-length"])
            body = self.rfile.read(length)

            if self.path != "/api/packages/ptc_runner_launcher/releases?replace=false":
                self.send_error(404)
                return

            if self.headers.get("authorization") != "test-api-key":
                self.send_error(401)
                return

            if self.headers.get("content-type") != "application/octet-stream":
                self.send_error(415)
                return

            if body != package:
                self.send_error(422)
                return

            receipt_file.write_text("accepted\n", encoding="utf-8")
            self.send_response(201)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"url":"https://hex.pm/packages/ptc_runner_launcher"}')

        def log_message(self, format_string: str, *args: object) -> None:
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    address_file.write_text(
        f"http://127.0.0.1:{server.server_address[1]}/api\n",
        encoding="utf-8",
    )
    server.handle_request()
    server.server_close()


if __name__ == "__main__":
    main()
