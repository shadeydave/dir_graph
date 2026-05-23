# Build Stage
FROM hexpm/elixir:1.15.7-erlang-26.1.2-alpine-3.18.4 AS builder

# Install basic build dependencies
RUN apk update && \
    apk add --no-cache \
    build-base \
    make \
    git

# Prepare build dir
WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy project configuration
COPY mix.exs mix.exs
COPY mix.lock mix.lock

# Fetch dependencies
RUN mix deps.get --only prod

# Copy application code
COPY lib lib

# Build the execution binary via escript
RUN mix escript.build

# Final Stage (Minimal Runtime)
FROM hexpm/elixir:1.15.7-erlang-26.1.2-alpine-3.18.4

# Install basic runtime utilities
RUN apk add --no-cache bash

WORKDIR /app

# Copy the generated binary from the build stage
COPY --from=builder /app/dir_graph ./dir_graph

# The workspace will mount the user's codebase into /workspace
# when calling this container so it has access to the files.
VOLUME /workspace

ENTRYPOINT ["./dir_graph"]
CMD ["--help"]
