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
    npm \
    nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV="prod"
ENV ERL_FLAGS="+JMsingle true"

COPY apps/orchestrator/mix.exs apps/orchestrator/mix.lock ./apps/orchestrator/
COPY apps/orchestrator/config ./apps/orchestrator/config/

COPY apps/phoenix_ui/mix.exs apps/phoenix_ui/mix.lock ./apps/phoenix_ui/

WORKDIR /app/apps/phoenix_ui

RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

COPY apps/phoenix_ui/config config/
COPY apps/phoenix_ui/priv priv/
COPY apps/phoenix_ui/lib lib/
COPY apps/phoenix_ui/assets assets/
COPY apps/phoenix_ui/rel rel/

COPY apps/orchestrator/lib /app/apps/orchestrator/lib/
COPY apps/orchestrator/priv /app/apps/orchestrator/priv/

WORKDIR /app/apps/phoenix_ui/assets
RUN npm ci --include=dev 2>/dev/null || npm install

WORKDIR /app/apps/phoenix_ui
RUN mix assets.deploy

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
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

RUN groupadd --gid 1000 phoenix && \
    useradd --uid 1000 --gid phoenix --shell /bin/bash --create-home phoenix

COPY --from=builder --chown=phoenix:phoenix /app/apps/phoenix_ui/_build/prod/rel/phoenix_ui ./

ENV MIX_ENV="prod"
ENV PHX_SERVER="true"
ENV PORT="4000"
ENV HOME="/app"

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:4000/health || exit 1

USER phoenix

EXPOSE 4000

CMD ["/app/bin/phoenix_ui", "start"]
