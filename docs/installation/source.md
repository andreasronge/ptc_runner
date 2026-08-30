# Source installation

Build PtcRunner from a repository checkout when changing the runtime,
validating an unreleased revision, or producing a standalone artifact.

The
ordinary product interface is the installed `ptc` executable.

Tool versions are pinned in `mise.toml`:

```console
mise install
mix deps.get
mix compile
```

Run the command frontend from the checkout:

```console
mix ptc init hello-ptc
mix ptc run hello-ptc/ptc-project.json
```

Build the local runtime-included release:

```console
MIX_ENV=prod mix release ptc_runner --overwrite
_build/prod/rel/ptc_runner/bin/ptc --version
```

Version output includes the application version, the producing checkout's
short commit SHA, and whether tracked or untracked source changes were present,
for example `0.14.0 (0a4d062b, clean)`. For a machine-readable record, publish
the version command envelope:

```console
mix ptc version --envelope version.json
ptc version --envelope version.json
```

Hermetic builds without `.git` must set the full lowercase commit SHA in
`PTC_SOURCE_REVISION` and set `PTC_SOURCE_DIRTY` to `true` or `false`.

That assembled tree is tied to the build host's linked libraries. On macOS,
build the relocatable archive instead:

```console
scripts/package_standalone_release.sh
```

The packaging script closes the runtime library set, carries required licenses,
rewrites loader paths, re-signs modified files, verifies the resulting tree,
and writes the archive and checksum under `_build/artifacts/`.

See the checkout's
[development setup](https://github.com/andreasronge/ptc_runner/blob/main/docs/maintainers/development-setup.md)
for the complete repository toolchain, worktree seeding, hooks, and local gates. See
[Standalone installation](standalone.md) for the target-machine contract.
