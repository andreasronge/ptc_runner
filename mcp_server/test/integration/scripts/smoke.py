#!/usr/bin/env python3
# Phase 6a — cross-language smoke test for the `ptc_runner_mcp`
# Mix release. Drives the release binary as a subprocess from Python
# (no Elixir, no MCP SDK) using only the standard library, exchanges
# NDJSON-framed JSON-RPC frames, and prints pass/fail per case.
#
# Required by `Plans/ptc-runner-mcp-server.md` § 15 Phase 6:
#
#   "Send one full round-trip from a non-Elixir language ... to prove
#    the server is consumable from outside the BEAM."
#
# Usage:
#
#     python3 smoke.py /absolute/path/to/_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp
#
# Exit code 0 = all cases passed; non-zero = at least one failed.
#
# This script is invoked by
# `test/integration/cross_language_test.exs` from ExUnit, but it is
# self-contained and can also be run by hand.

import json
import os
import subprocess
import sys
import tempfile

PROTOCOL_VERSION = "2025-11-25"


def init_frame(id_):
    return {
        "jsonrpc": "2.0",
        "id": id_,
        "method": "initialize",
        "params": {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "phase6a-cross-language-smoke", "version": "1"},
        },
    }


def initialized_notif():
    return {"jsonrpc": "2.0", "method": "notifications/initialized"}


def tools_list_frame(id_):
    return {"jsonrpc": "2.0", "id": id_, "method": "tools/list"}


def tools_call_frame(id_, name, arguments):
    return {
        "jsonrpc": "2.0",
        "id": id_,
        "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    }


def exit_notif():
    return {"jsonrpc": "2.0", "method": "exit"}


def run_session(release_bin, frames, timeout_s=15):
    """Pipe frames through the release; return (replies, exit_code, stderr)."""
    payload = "\n".join(json.dumps(f) for f in frames) + "\n"

    with tempfile.NamedTemporaryFile(
        mode="w", delete=False, suffix=".ndjson"
    ) as stdin_file:
        stdin_file.write(payload)
        stdin_file.flush()
        stdin_path = stdin_file.name

    env = os.environ.copy()
    env["RELEASE_DISTRIBUTION"] = "none"

    try:
        with open(stdin_path, "rb") as stdin_fh:
            result = subprocess.run(
                [release_bin, "start"],
                stdin=stdin_fh,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
                timeout=timeout_s,
            )
    finally:
        os.unlink(stdin_path)

    replies = []
    for line in result.stdout.decode("utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("jsonrpc") == "2.0":
            replies.append(obj)

    return replies, result.returncode, result.stderr.decode("utf-8", errors="replace")


def case_handshake(release_bin):
    """initialize + tools/list — must report exactly one tool: ptc_lisp_execute."""
    replies, code, _stderr = run_session(
        release_bin,
        [
            init_frame(1),
            initialized_notif(),
            tools_list_frame(2),
            exit_notif(),
        ],
    )
    if code != 0:
        return False, f"exit code {code}"

    init = next((r for r in replies if r.get("id") == 1), None)
    lst = next((r for r in replies if r.get("id") == 2), None)
    if not init or not lst:
        return False, f"missing replies (got ids {[r.get('id') for r in replies]})"

    if init["result"]["protocolVersion"] != PROTOCOL_VERSION:
        return False, f"bad protocolVersion: {init['result']['protocolVersion']}"

    tools = lst["result"]["tools"]
    if len(tools) != 1:
        return False, f"expected 1 tool, got {len(tools)}"
    if tools[0]["name"] != "ptc_lisp_execute":
        return False, f"wrong tool name: {tools[0]['name']}"

    return True, "ok"


def case_unknown_tool_d1(release_bin):
    """§ 7.4 D1 deviation gate: unknown tool must yield isError tool result, not -32601."""
    replies, code, _stderr = run_session(
        release_bin,
        [
            init_frame(1),
            initialized_notif(),
            tools_call_frame(7, "no_such_tool_xyz", {}),
            exit_notif(),
        ],
    )
    if code != 0:
        return False, f"exit code {code}"

    reply = next((r for r in replies if r.get("id") == 7), None)
    if not reply:
        return False, "no reply for id 7"

    # D1: NOT a JSON-RPC error envelope.
    if "error" in reply:
        return (
            False,
            f"D1 violation: unknown_tool returned JSON-RPC error: {reply['error']}",
        )

    sc = reply.get("result", {}).get("structuredContent", {})
    if reply.get("result", {}).get("isError") is not True:
        return False, f"isError must be true, got {reply['result'].get('isError')}"
    if sc.get("reason") != "unknown_tool":
        return False, f"reason must be unknown_tool, got {sc.get('reason')}"

    return True, "ok"


def case_args_error(release_bin):
    """tools/call with no `program` argument: reason=args_error envelope."""
    replies, code, _stderr = run_session(
        release_bin,
        [
            init_frame(1),
            initialized_notif(),
            tools_call_frame(8, "ptc_lisp_execute", {}),
            exit_notif(),
        ],
    )
    if code != 0:
        return False, f"exit code {code}"

    reply = next((r for r in replies if r.get("id") == 8), None)
    if not reply:
        return False, "no reply for id 8"

    sc = reply.get("result", {}).get("structuredContent", {})
    if reply.get("result", {}).get("isError") is not True:
        return False, "isError must be true"
    if sc.get("reason") != "args_error":
        return False, f"reason must be args_error, got {sc.get('reason')}"

    return True, "ok"


CASES = [
    ("handshake (initialize + tools/list)", case_handshake),
    ("unknown_tool D1 deviation gate", case_unknown_tool_d1),
    ("tools/call args_error", case_args_error),
]


def main(argv):
    if len(argv) != 2:
        print("usage: smoke.py /path/to/ptc_runner_mcp/bin/ptc_runner_mcp", file=sys.stderr)
        return 2

    release_bin = argv[1]
    if not os.path.isfile(release_bin) or not os.access(release_bin, os.X_OK):
        print(f"release not built or not executable: {release_bin}", file=sys.stderr)
        return 2

    failures = 0
    for name, fn in CASES:
        try:
            ok, msg = fn(release_bin)
        except Exception as e:  # pragma: no cover — defensive
            ok, msg = False, f"raised: {type(e).__name__}: {e}"

        marker = "PASS" if ok else "FAIL"
        print(f"[{marker}] {name}: {msg}")
        if not ok:
            failures += 1

    print(f"---\n{len(CASES) - failures}/{len(CASES)} passed")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
