#!/usr/bin/env python3
"""Private project PLT snapshots. Cache failure must never bypass Dialyzer."""

import contextlib
import fcntl
import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile


# Shared with worktree seeding: reject torn terms and trailing bytes. Dialyzer
# still owns semantic validation (module checksums, dependencies, OTP format).
def valid_plt(path, source=None, destination=None):
    expression = '''
      {ok, Bin} = file:read_file(os:getenv("PTC_SEED_PLT")),
      R = try binary_to_term(Bin, [used]) of
        {T, Used} when is_tuple(T), element(1, T) =:= file_plt,
                       Used =:= byte_size(Bin) ->
          case os:getenv("PTC_PLT_SOURCE") of
            false -> 0;
            Source ->
              %% OTP's classic file_plt record: only relocate file_md5_list.
              %% Reject unknown layouts; never rewrite inferred term fields.
              10 = tuple_size(T),
              Files = element(3, T),
              true = is_list(Files),
              Target = os:getenv("PTC_PLT_TARGET"),
              Move = fun({File, Hash}) when is_list(File), is_binary(Hash),
                                           byte_size(Hash) =:= 16 ->
                case lists:prefix(Source, File) of
                  true -> {Target ++ lists:nthtail(length(Source), File), Hash};
                  false -> {File, Hash}
                end
              end,
              Moved = lists:keysort(1, lists:map(Move, Files)),
              Updated = setelement(3, T, Moved),
              ok = file:write_file(os:getenv("PTC_SEED_PLT"),
                                   term_to_binary(Updated, [compressed])),
              0
          end;
        _ -> 1
      catch _:_ -> 1 end,
      halt(R).'''
    environment = {**os.environ, "PTC_SEED_PLT": str(path)}
    environment.pop("PTC_PLT_SOURCE", None)
    environment.pop("PTC_PLT_TARGET", None)
    if source is not None:
        environment.update(PTC_PLT_SOURCE=source + "/", PTC_PLT_TARGET=destination + "/")
    result = subprocess.run(
        ["erl", "-noshell", "-eval", expression],
        env=environment,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60,
    )
    return result.returncode == 0


def digest(*parts):
    return hashlib.sha256(b"\0".join(parts)).hexdigest()


def cache_directory():
    # Actual runtime versions, not just mise pins: also safe for manual gates.
    expression = '''
      otp = :erlang.system_info(:otp_release)
      version = File.read!(Path.join([:code.root_dir(), "releases", otp, "OTP_VERSION"]))
      IO.write(Enum.join([System.version(), version, :erlang.system_info(:version)], "|"))
    '''
    runtime = subprocess.check_output(["elixir", "-e", expression], timeout=60)
    # Conservatively hash all of mix.exs so changing plt_add_apps or other
    # project options cannot reuse a fallback built with different settings.
    compatibility = digest(
        b"v2", runtime, platform.system().encode(), platform.machine().encode(),
        Path("mix.exs").read_bytes(), b"test",
    )
    root = Path(os.environ.get(
        "PTC_PROJECT_PLT_CACHE", "~/.cache/ptc_runner/project_plts"
    )).expanduser()
    return root / compatibility, digest(Path("mix.lock").read_bytes())


@contextlib.contextmanager
def snapshot(directory):
    fd, name = tempfile.mkstemp(prefix=".snapshot-", dir=directory)
    os.close(fd)
    path = Path(name)
    try:
        yield path
    finally:
        path.unlink(missing_ok=True)


@contextlib.contextmanager
def locked(directory):
    # Kernel-owned advisory lock: a killed publisher cannot leave a stale
    # lock. Never queue an agent behind optional cache work.
    with (directory / ".lock").open("a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def restore(directory, key, local):
    local.parent.mkdir(parents=True, exist_ok=True)
    with snapshot(local.parent) as staged:
        with locked(directory):
            exact = directory / f"{key}.plt"
            candidates = sorted(directory.glob("*.plt"), key=lambda p: p.stat().st_mtime_ns,
                                reverse=True)
            if exact in candidates:
                candidates.remove(exact)
                candidates.insert(0, exact)
            if not candidates:
                print("Project PLT cache: miss")
                return
            source = candidates[0]
            shutil.copyfile(source, staged)
        if not valid_plt(staged, "/__ptc_project_plt_root__", os.getcwd()):
            print("Project PLT cache: invalid snapshot ignored")
            return
        # Do not carry Dialyxir's shortcut hash: every restored PLT must be
        # checked against this checkout's modules. The hard link is an atomic
        # no-replace promotion of our PRIVATE copy, never of the cache inode.
        if os.path.lexists(local):
            return
        Path(str(local) + ".hash").unlink(missing_ok=True)
        os.link(staged, local)
        kind = "exact" if source == exact else "compatible dependency fallback"
        print(f"Project PLT cache: restored ({kind})")


def publish(directory, key, local):
    with snapshot(directory) as staged:
        shutil.copyfile(local, staged)
        if not valid_plt(staged, os.getcwd(), "/__ptc_project_plt_root__"):
            print("Project PLT cache: invalid publication ignored")
            return
        with locked(directory):
            os.replace(staged, directory / f"{key}.plt")
        print("Project PLT cache: published")


def main():
    action = sys.argv[1]
    if action == "validate":
        return 0 if valid_plt(Path(sys.argv[2]), *sys.argv[3:]) else 1
    if action not in ("restore", "publish"):
        raise ValueError("expected restore, publish, or validate")
    # GitHub Actions owns its own PLT cache. This cache serves local/Herdr
    # test-environment gates only; other Mix environments never publish here.
    if os.environ.get("CI") or os.environ.get("MIX_ENV", "test") != "test":
        return 0
    local = Path("priv/plts/project.plt")
    if action == "restore" and os.path.lexists(local):
        return 0
    if action == "publish" and (not local.is_file() or local.is_symlink()):
        return 0
    directory, key = cache_directory()
    directory.mkdir(parents=True, exist_ok=True)
    if action == "restore":
        restore(directory, key, local)
    else:
        publish(directory, key, local)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, subprocess.SubprocessError) as error:
        print(f"Project PLT cache: skipped ({error})", file=sys.stderr)
        sys.exit(1 if len(sys.argv) > 1 and sys.argv[1] == "validate" else 0)
