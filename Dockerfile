# syntax=docker/dockerfile:1
#
# Local container scaffolding for the standalone `ptc` command.
#
# This image is NOT a published distribution route: the container contract in
# `docs/plans/lisp-kernel/stable-cli-contract.md` also requires the launcher
# companion and per-architecture evidence, and neither is in place. Build it to
# exercise the assembled release on Linux; do not tag, push, or document it as
# an install path until that contract is met.
#
# Both bases are pinned by digest, so a rebuild resolves the same runtime
# library set rather than whatever the tag points at today.

FROM hexpm/elixir:1.20.2-erlang-29.0.3-debian-bookworm-20260713@sha256:5bdf8591eca58dfa040719b032961f8b738a6174b5d02a8c2b81289d2face884 AS builder

ENV MIX_ENV=prod \
    LANG=C.UTF-8

WORKDIR /src

RUN apt-get update \
  && apt-get install --yes --no-install-recommends expect \
  && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

COPY . .

RUN mix deps.get --only prod \
  && mix release ptc_runner --overwrite --path /opt/ptc

# The gate runs against the assembled release this image will carry, not a
# rebuild of it. It includes the pseudo-terminal check for the interactive
# REPL, which `expect` supplies its own terminal for.
FROM builder AS verify

RUN PTC_RELEASE_ROOT=/opt/ptc scripts/verify_standalone_release.sh

FROM debian:bookworm-20260713-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818 AS runtime

# `libssl3` is what the runtime's crypto NIF links against; the Erlang runtime
# needs a UTF-8 locale for terminal and filename handling, and glibc provides
# C.UTF-8 without the `locales` package.
RUN apt-get update \
  && apt-get install --yes --no-install-recommends ca-certificates libssl3 \
  && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 \
    HOME=/home/ptc

RUN useradd --create-home --home-dir /home/ptc --uid 10001 --user-group ptc

COPY --from=verify /opt/ptc /opt/ptc

USER ptc
WORKDIR /work

ENTRYPOINT ["/opt/ptc/bin/ptc"]
CMD ["help"]
