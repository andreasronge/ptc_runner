ARG ELIXIR_IMAGE=hexpm/elixir:1.20-erlang-28.5.0.1-debian-bookworm-20260518@sha256:281fb303214b516c58e7d2882bb58f56bd5e479027afc285f609264b28f348c4
ARG RUNTIME_IMAGE=debian:bookworm-slim

FROM ${ELIXIR_IMAGE} AS builder

ENV MIX_ENV=prod \
    HEX_SPONSOR=false

WORKDIR /app

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git ca-certificates \
  && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config ./config
COPY lib ./lib
COPY priv ./priv

COPY mcp_server/mix.exs mcp_server/mix.lock ./mcp_server/
WORKDIR /app/mcp_server
RUN mix deps.get --only prod

WORKDIR /app
COPY mcp_server/config ./mcp_server/config
COPY mcp_server/lib ./mcp_server/lib
COPY mcp_server/priv ./mcp_server/priv
COPY mcp_server/rel ./mcp_server/rel

WORKDIR /app/mcp_server
RUN mix compile --warnings-as-errors \
  && mix release --overwrite

FROM ${RUNTIME_IMAGE} AS runtime

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates openssl libstdc++6 libncurses6 locales \
  && rm -rf /var/lib/apt/lists/* \
  && groupadd --gid 10001 ptc_runner_mcp \
  && useradd --uid 10001 --gid ptc_runner_mcp --home-dir /opt/ptc_runner_mcp --shell /usr/sbin/nologin ptc_runner_mcp

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    RELEASE_DISTRIBUTION=none

WORKDIR /opt/ptc_runner_mcp
COPY --from=builder /app/mcp_server/_build/prod/rel/ptc_runner_mcp ./
RUN chown -R ptc_runner_mcp:ptc_runner_mcp /opt/ptc_runner_mcp

USER ptc_runner_mcp

EXPOSE 7332

ENTRYPOINT ["/opt/ptc_runner_mcp/bin/ptc_runner_mcp"]
CMD ["start", "--http", "--http-host", "0.0.0.0"]
