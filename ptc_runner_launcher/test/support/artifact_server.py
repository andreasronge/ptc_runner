#!/usr/bin/env python3
"""Serve a release-artifact directory on an ephemeral loopback port."""

import functools
import http.server
import pathlib
import signal
import sys


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: artifact_server.py DIRECTORY ADDRESS_FILE")

    directory = pathlib.Path(sys.argv[1]).resolve(strict=True)
    address_file = pathlib.Path(sys.argv[2])
    handler = functools.partial(
        http.server.SimpleHTTPRequestHandler,
        directory=str(directory),
    )
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)

    def stop(_signal: int, _frame: object) -> None:
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    address_file.write_text(
        f"http://127.0.0.1:{server.server_address[1]}\n",
        encoding="utf-8",
    )

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
