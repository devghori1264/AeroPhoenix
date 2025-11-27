# Build stage
FROM elixir:1.15-alpine AS builder

RUN apk add --no-cache build-base git

WORKDIR /app

RUN mix local.hex --force && \
    mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config

ENV MIX_ENV=prod
RUN mix deps.get --only prod
RUN mix deps.compile

COPY lib lib
COPY priv priv

RUN mix compile
RUN mix release

FROM alpine:3.18

RUN apk add --no-cache \
    ncurses-libs \
    openssl \
    libstdc++ \
    libgcc

RUN addgroup -S orchestrator && adduser -S orchestrator -G orchestrator

WORKDIR /app

COPY --from=builder --chown=orchestrator:orchestrator /app/_build/prod/rel/orchestrator ./

USER orchestrator

EXPOSE 4000

ENV HOME=/app

CMD ["bin/orchestrator", "start"]
