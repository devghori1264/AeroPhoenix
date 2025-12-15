ARG ELIXIR_VERSION=1.15.7
ARG OTP_VERSION=26.2.1
ARG DEBIAN_VERSION=bookworm-20240130-slim
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && apt-get install -y \
    build-essential \
    git \
    curl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV="prod"

COPY apps/orchestrator/mix.exs apps/orchestrator/mix.lock ./

RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

COPY apps/orchestrator/config config/
COPY apps/orchestrator/lib lib/
COPY apps/orchestrator/priv priv/
COPY apps/orchestrator/rel rel/

COPY proto /app/proto/

RUN mix compile --warnings-as-errors

RUN mix release

FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
    libstdc++6 \
    openssl \
    libncurses5 \
    locales \
    ca-certificates \
    curl \
    libsqlite3-0 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

RUN groupadd --gid 1000 orchestrator && \
    useradd --uid 1000 --gid orchestrator --shell /bin/bash --create-home orchestrator

RUN mkdir -p /app/data/machines && chown -R orchestrator:orchestrator /app/data

COPY --from=builder --chown=orchestrator:orchestrator /app/_build/prod/rel/orchestrator ./

ENV MIX_ENV="prod"
ENV PHX_SERVER="true"
ENV PORT="4001"
ENV HOME="/app"

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:4001/api/v1/ping || exit 1

USER orchestrator

EXPOSE 4001 9569

CMD ["/app/bin/orchestrator", "start"]
