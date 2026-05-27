#!/usr/bin/env python3
# Local response-profile payload benchmark — no external auth required.
#
# Companion to bench/real_mcp_payload_bench.exs (which targets a real
# Gmail MCP server and needs OAuth). This one drives a stdio
# @modelcontextprotocol/server-filesystem upstream, so anyone with
# `npx` available can reproduce it.
#
# It measures *client-visible JSON-RPC frame bytes* — the thing an MCP
# client actually pays context tokens for — across four paths:
#
#   native_fs       — call the filesystem server's tool directly.
#   ptc_slim        — lisp_eval, --response-profile slim (default).
#   ptc_structured  — lisp_eval, --response-profile structured.
#   lisp_debug       — lisp_eval, --debug-tool (verbose: mirrored
#                     structuredContent + ptc_metrics + upstream_calls).
#
# Reported per case: response-frame bytes and ~tokens (ceil(bytes/4)),
# plus the one-time "cold" cost (tools/list). Token counts are a
# deterministic wire-cost estimate, NOT a measure of LLM authoring
# overhead — see README "Response profiles" / "Payload reduction" for
# the honest framing.
#
# Usage (from repo root or mcp_server/):
#
#   # ensure mcp_server is compiled first:
#   (cd mcp_server && mix compile)
#   python3 mcp_server/bench/local_payload_bench.py [--sandbox DIR] [--runs N]
#
# --sandbox defaults to a temp dir seeded with three small fixture
# files; pass an existing dir to use your own fixtures (the first three
# *.txt / *.md files found are used).

import argparse
import json
import os
import subprocess
import sys
import tempfile
import threading
import time

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MCP_DIR = os.path.join(REPO_ROOT, "mcp_server")
MIX = os.environ.get("MIX_BIN", "mix")


def run_server(cmd, frames, cwd=None, settle=3.0, read_secs=10.0):
    """Spawn an MCP stdio server, send JSON-RPC frames, return raw stdout lines (bytes)."""
    p = subprocess.Popen(
        cmd, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, bufsize=0,
    )
    out_lines = []
    t = threading.Thread(target=lambda: out_lines.extend(p.stdout), daemon=True)
    t.start()
    time.sleep(settle)
    for f in frames:
        p.stdin.write((json.dumps(f) + "\n").encode())
        p.stdin.flush()
        time.sleep(0.4)
    time.sleep(read_secs)
    try:
        p.stdin.close()
    except Exception:
        pass
    try:
        p.wait(timeout=5)
    except Exception:
        p.kill()
    return out_lines


def by_id(lines):
    """{response id -> (frame_byte_len, parsed_obj)}; log/notification lines ignored."""
    m = {}
    for ln in lines:
        s = ln.strip()
        if not s.startswith(b"{"):
            continue
        try:
            o = json.loads(s)
        except Exception:
            continue
        if "id" in o:
            m[o["id"]] = (len(ln.rstrip(b"\n")), o)
    return m


def toks(b):
    return (b + 3) // 4


def require_ok(m, label, tools_list_id, call_ids):
    """Fail fast unless every expected id is present and every tools/call result is non-error.

    Without this guard a stuck server, an upstream sandboxing issue (e.g. macOS
    /var/folders symlink against an unresolved allowed-dir), or a missed tool
    name would silently get recorded as a tiny "valid" measurement, polluting
    the reported byte/token ratios.
    """
    if tools_list_id not in m:
        raise SystemExit(f"{label}: tools/list response (id {tools_list_id}) missing")
    tools = (m[tools_list_id][1] or {}).get("result", {}).get("tools")
    if not isinstance(tools, list) or not tools:
        raise SystemExit(f"{label}: tools/list returned no tools: {m[tools_list_id][1]}")
    for i in call_ids:
        if i not in m:
            raise SystemExit(f"{label}: tools/call response (id {i}) missing")
        result = (m[i][1] or {}).get("result")
        if not isinstance(result, dict):
            raise SystemExit(f"{label}: tools/call id={i} has no result: {m[i][1]}")
        if result.get("isError") is True:
            text = ""
            for item in result.get("content", []):
                if isinstance(item, dict) and item.get("type") == "text":
                    text = item.get("text", "")
                    break
            raise SystemExit(
                f"{label}: tools/call id={i} returned isError=true: "
                f"{text[:400] or json.dumps(result)[:400]}"
            )


def init_frames():
    return [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                    "clientInfo": {"name": "bench", "version": "0"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
    ]


def call_frame(i, name, args):
    return {"jsonrpc": "2.0", "id": i, "method": "tools/call",
            "params": {"name": name, "arguments": args}}


def seed_sandbox():
    # realpath: on macOS tempfile dirs live under /var/folders -> /private/var/folders,
    # and @modelcontextprotocol/server-filesystem resolves symlinks before its
    # allowed-dir check, so an unresolved path makes every read fail.
    d = os.path.realpath(tempfile.mkdtemp(prefix="ptc-payload-bench-"))
    open(os.path.join(d, "notes.txt"), "w").write(
        "Project Phoenix\nStatus: in progress\nLead: alice\nDeadline: 2026-06-01\n\n"
        "Tasks:\n- [x] design review\n- [ ] implementation\n- [ ] testing\n- [ ] launch\n")
    open(os.path.join(d, "todo.md"), "w").write(
        "# TODO\n- ship the thing\n- write the docs\n- fix the bug\n- review the PR\n"
        "- merge\n- celebrate\n- repeat\n- sleep\n- coffee\n")
    open(os.path.join(d, "readme.txt"), "w").write(
        "readme\nthis is a fixture file\nused by the payload benchmark\n"
        "nothing to see here\nmove along\nok bye\nseriously\nbye\n")
    return d


def pick_fixtures(d):
    names = [f for f in sorted(os.listdir(d)) if f.endswith((".txt", ".md"))]
    if len(names) < 3:
        raise SystemExit(f"need >=3 .txt/.md files in {d}, found {names}")
    return [os.path.join(d, n) for n in names[:3]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sandbox", default=None)
    ap.add_argument("--runs", type=int, default=1)
    args = ap.parse_args()

    sandbox = os.path.realpath(args.sandbox) if args.sandbox else seed_sandbox()
    f1, f2, f3 = pick_fixtures(sandbox)

    ups = os.path.join(sandbox, "upstreams.json")
    json.dump({"upstreams": {"fs": {
        "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", sandbox],
        "handshake_timeout_ms": 60000,
    }}}, open(ups, "w"))

    # PTC-Lisp programs, and the native fs calls they're compared against.
    ptc_programs = {
        "read_one_file":
            f'(:value (tool/call {{:server "fs" :tool "read_text_file" :args {{:path "{f1}"}}}}))',
        "first_line_of_3":
            ('(map (fn [p] (first (clojure.string/split-lines '
             '(:value (tool/call {:server "fs" :tool "read_text_file" :args {:path p}})))))'
             f' ["{f1}" "{f2}" "{f3}"])'),
        "one_line_grep":
            (f'(->> (:value (tool/call {{:server "fs" :tool "read_text_file" :args {{:path "{f1}"}}}}))'
             ' clojure.string/split-lines (filter #(clojure.string/starts-with? % "Lead")) first)'),
    }
    native_cases = {
        "read_one_file": [("read_text_file", {"path": f1})],
        "first_line_of_3": [("read_text_file", {"path": p}) for p in (f1, f2, f3)],
        "one_line_grep": [("read_text_file", {"path": f1})],  # native dumps the whole file
    }

    profiles = {
        "ptc_slim": [MIX, "run", "--no-halt", "--no-compile", "--",
                     "--upstreams-config", ups, "--response-profile", "slim"],
        "ptc_structured": [MIX, "run", "--no-halt", "--no-compile", "--",
                           "--upstreams-config", ups, "--response-profile", "structured"],
        "lisp_debug": [MIX, "run", "--no-halt", "--no-compile", "--",
                      "--upstreams-config", ups, "--debug-tool"],
    }

    # avg over N runs
    acc = {}  # (case_or_cold, col) -> [bytes...]

    def add(key, col, val):
        acc.setdefault((key, col), []).append(val)

    for _ in range(args.runs):
        for prof, cmd in profiles.items():
            frames = init_frames()
            ids = {}
            cid = 100
            for cname, prog in ptc_programs.items():
                ids[cname] = cid
                frames.append(call_frame(cid, "lisp_eval", {"program": prog}))
                cid += 1
            print(f"  running {prof} ...", file=sys.stderr)
            m = by_id(run_server(cmd, frames, cwd=MCP_DIR, settle=4.0, read_secs=12.0))
            require_ok(m, prof, tools_list_id=2, call_ids=list(ids.values()))
            add("_cold", prof, m[2][0])
            for cname, i in ids.items():
                add(cname, prof, m[i][0])

        frames = init_frames()
        cid = 200
        native_ids = {}
        for cname, calls in native_cases.items():
            native_ids[cname] = []
            for (tn, ar) in calls:
                frames.append(call_frame(cid, tn, ar))
                native_ids[cname].append(cid)
                cid += 1
        print("  running native fs ...", file=sys.stderr)
        m = by_id(run_server(["npx", "-y", "@modelcontextprotocol/server-filesystem", sandbox],
                             frames, settle=3.0, read_secs=10.0))
        all_native_ids = [i for idl in native_ids.values() for i in idl]
        require_ok(m, "native_fs", tools_list_id=2, call_ids=all_native_ids)
        add("_cold", "native_fs", m[2][0])
        for cname, idl in native_ids.items():
            add(cname, "native_fs", sum(m[i][0] for i in idl))

    def avg(key, col):
        v = acc.get((key, col), [0])
        return round(sum(v) / len(v))

    cols = ["native_fs", "ptc_slim", "ptc_structured", "lisp_debug"]
    print(f"\nResponse-frame bytes (~tokens) — avg of {args.runs} run(s), sandbox={sandbox}\n")
    print(f"{'':<18}| " + " | ".join(f"{c:>16}" for c in cols))
    print("-" * 92)

    def line(label, getter):
        cells = " | ".join(f"{getter(c):>7d} (~{toks(getter(c)):>4d}t)" for c in cols)
        print(f"{label:<18}| {cells}")

    line("COLD tools/list", lambda c: avg("_cold", c))
    for cname in ptc_programs:
        line(cname, lambda c, n=cname: avg(n, c))

    print("\nWarm response, relative to ptc_slim:")
    for cname in ptc_programs:
        s = avg(cname, "ptc_slim")
        if not s:
            continue
        for c in ("lisp_debug", "ptc_structured", "native_fs"):
            x = avg(cname, c)
            if not x:
                continue
            print(f"  {cname:<16} {c:<15}: {x:>6d}b vs {s:>5d}b  =>  {x / s:5.2f}x"
                  f"  ({x - s:+6d}b, ~{toks(x) - toks(s):+5d}t)")


if __name__ == "__main__":
    main()
