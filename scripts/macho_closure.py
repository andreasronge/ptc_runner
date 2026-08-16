#!/usr/bin/env python3
"""Prove that a packaged macOS release links only to itself and to macOS.

`otool -L` output alone cannot answer this. A `@rpath/...` reference resolves
through the file's `LC_RPATH` entries, and one of those can be an absolute path
into the build host's package manager; a `@loader_path/...` reference can climb
out of the release with enough `..` segments. Both look loader-relative and
would pass a check that treats every `@`-prefixed reference as contained.

Reads NUL-separated Mach-O paths on standard input, writes one line per
unresolved dependency, and exits non-zero when any exist.
"""

import os
import subprocess
import sys

# Paths macOS itself guarantees. Everything else has to travel with the
# artifact or be reported here.
SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/")


class Uninspectable(Exception):
    """`otool` could not read a file that `file` called Mach-O."""


def otool(flag, path):
    result = subprocess.run(
        ["otool", flag, path], capture_output=True, text=True, check=False
    )

    # Returning empty output here would make an uninspectable binary look
    # dependency-free, which is the one answer this checker must never give by
    # accident.
    if result.returncode != 0:
        raise Uninspectable(f"otool {flag} failed: {result.stderr.strip()}")

    return result.stdout


def dependencies(path):
    lines = otool("-L", path).splitlines()[1:]
    return [line.split()[0] for line in lines if line.strip()]


def rpaths(path):
    found, expecting = [], False

    for line in otool("-l", path).splitlines():
        fields = line.split()

        if fields[:2] == ["cmd", "LC_RPATH"]:
            expecting = True
        elif expecting and fields[:1] == ["path"]:
            found.append(fields[1])
            expecting = False

    return found


def expand(reference, loader_dir, executable_dir):
    return reference.replace("@loader_path", loader_dir).replace(
        "@executable_path", executable_dir
    )


def contained(candidate, release_root):
    resolved = os.path.realpath(candidate)
    return (
        os.path.commonpath([resolved, release_root]) == release_root
        and os.path.exists(resolved)
    )


def resolve(reference, path, release_root):
    """Return True when `reference` can only resolve inside the release."""
    if reference.startswith(SYSTEM_PREFIXES):
        return True

    loader_dir = os.path.dirname(path)
    # `@executable_path` is the launching binary's directory, which is not
    # knowable from a library alone. The release launches from `bin`, and
    # treating anything else as unresolved errs toward reporting.
    executable_dir = os.path.join(release_root, "bin")

    if reference.startswith(("@loader_path", "@executable_path")):
        return contained(expand(reference, loader_dir, executable_dir), release_root)

    if reference.startswith("@rpath/"):
        suffix = reference[len("@rpath/") :]
        candidates = [
            os.path.join(expand(entry, loader_dir, executable_dir), suffix)
            for entry in rpaths(path)
        ]
        return bool(candidates) and all(
            contained(candidate, release_root) for candidate in candidates
        )

    return False


def main():
    if len(sys.argv) != 2:
        print("usage: macho_closure.py RELEASE_ROOT", file=sys.stderr)
        return 64

    release_root = os.path.realpath(sys.argv[1])
    unresolved = []

    for path in sys.stdin.read().split("\0"):
        if not path:
            continue

        try:
            for reference in dependencies(path):
                if not resolve(reference, path, release_root):
                    unresolved.append(f"{path} -> {reference}")

            # An absolute rpath is a standing invitation for a later runtime
            # bump to link against the build host and still pass every check
            # above.
            for entry in rpaths(path):
                if entry.startswith("/") and not contained(entry, release_root):
                    unresolved.append(f"{path} -> LC_RPATH {entry}")
        except Uninspectable as failure:
            unresolved.append(f"{path} -> {failure}")

    for line in unresolved:
        print(line)

    return 1 if unresolved else 0


if __name__ == "__main__":
    sys.exit(main())
