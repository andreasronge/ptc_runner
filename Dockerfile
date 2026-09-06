# syntax=docker/dockerfile:1
#
# Linux container image for the standalone `ptc` command.
#
# The tag-triggered container-release workflow verifies the finished image on
# native AMD64 and ARM64 runners before publishing a multi-platform manifest.
# `scripts/build_container_image.sh` provides the same finished-image probes
# for a local single-platform build.
#
# Both bases are pinned by digest, so a rebuild resolves the same runtime
# library set rather than whatever the tag points at today.

FROM hexpm/elixir:1.20.2-erlang-29.0.3-debian-bookworm-20260713@sha256:5bdf8591eca58dfa040719b032961f8b738a6174b5d02a8c2b81289d2face884 AS builder

ARG PTC_SOURCE_REVISION
ARG PTC_SOURCE_DIRTY=false

ENV MIX_ENV=prod \
    LANG=C.UTF-8 \
    PTC_SOURCE_REVISION=$PTC_SOURCE_REVISION \
    PTC_SOURCE_DIRTY=$PTC_SOURCE_DIRTY

WORKDIR /src

# `expect` drives the interactive REPL check inside the verify stage; the
# optional launcher companion compiles a small C program from source.
RUN apt-get update \
  && apt-get install --yes --no-install-recommends build-essential expect \
  && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

COPY . .

# One `mix do` invocation, deliberately: `mix.exs` treats the launcher
# companion as a path dependency only when the environment is dev/test or
# `release` appears in the arguments, so a separate `deps.get` in prod would
# resolve it against Hex, where the companion is not published.
RUN mix do deps.get --only prod + release ptc_runner --overwrite --path /opt/ptc

FROM debian:bookworm-20260713-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818 AS runtime

# `libssl3` is what the runtime's crypto NIF links against. `libsctp1` is not
# optional either, however unused SCTP is here: without it the socket layer
# writes a warning to *standard output* at startup, which lands in front of the
# JSON that `run`, `validate`, and `doctor` promise their callers. The Erlang
# runtime also needs a UTF-8 locale for terminal and filename handling, and
# glibc provides C.UTF-8 without the `locales` package.
RUN apt-get update \
  && apt-get install --yes --no-install-recommends ca-certificates libssl3 libsctp1 \
  && rm -rf /var/lib/apt/lists/*

# `TERM` decides whether the REPL gets line editing: the Erlang reader falls
# back to a dumb terminal without it, and `docker run` without `-t` supplies
# none.
ENV LANG=C.UTF-8 \
    TERM=xterm \
    HOME=/home/ptc

RUN useradd --create-home --home-dir /home/ptc --uid 10001 --user-group ptc

COPY --from=builder /opt/ptc /opt/ptc

USER ptc
WORKDIR /work

ENTRYPOINT ["/opt/ptc/bin/ptc"]
CMD ["help"]

# The gate runs against the image that ships, not against the builder it came
# from: a missing runtime library or locale in the slim base is invisible from
# a stage that still has the whole toolchain. `expect` and `diffutils` are
# installed in this throwaway stage only.
FROM runtime AS verify

USER root

RUN apt-get update \
  && apt-get install --yes --no-install-recommends diffutils expect python3 \
  && rm -rf /var/lib/apt/lists/*

# `verify_standalone_release.sh` derives its project root from its own parent
# directory and compares four checked-in files against the packaged tree, so
# `/verify` has to mirror their repository layout and not just carry the
# scripts. Copying only `scripts` left every one of those comparisons reading a
# path that does not exist -- the first, `THIRD_PARTY_NOTICES.md`, failed the
# stage with `cmp: /verify/THIRD_PARTY_NOTICES.md: No such file or directory`.
COPY --from=builder /src/scripts /verify/scripts
COPY --from=builder /src/THIRD_PARTY_NOTICES.md /verify/THIRD_PARTY_NOTICES.md
COPY --from=builder /src/LICENSES /verify/LICENSES
COPY --from=builder /src/site/schemas /verify/site/schemas

RUN PTC_RELEASE_ROOT=/opt/ptc /verify/scripts/verify_standalone_release.sh \
  && touch /verify/passed

# The shipped image, plus proof that the gate above ran for these exact bytes.
# Building any earlier stage on its own skips the gate; building the default
# target cannot.
FROM runtime AS released

COPY --from=verify /verify/passed /opt/ptc/.verified
