# Build Stage
FROM hexpm/elixir:1.15.7-erlang-26.1.2-alpine-3.18.4 AS builder

# Install build dependencies required to compile C# Install build dependencies
RUN apk update && \
    apk add --no-cache \
    build-base \
    gcc \
    g++ \
    make \
    git \
    cmake \
    unzip \
    clang \
    nodejs \
    npm \
    python3 \
    tree-sitter \
    tree-sitter-cli

# Fetch Language Grammars and Build Them
RUN mkdir -p /root/parsers && \
    cd /root/parsers && \
    git clone https://github.com/tree-sitter/tree-sitter-javascript.git && \
    cd tree-sitter-javascript && npm install && cd .. && \
    git clone https://github.com/tree-sitter/tree-sitter-typescript.git && \
    cd tree-sitter-typescript/tsx && npm install && cd ../.. && \
    cd tree-sitter-typescript/typescript && npm install && cd ../.. && \
    git clone https://github.com/elixir-lang/tree-sitter-elixir.git && \
    cd tree-sitter-elixir && npm install && cd ..

# Configure Tree-Sitter
RUN mkdir -p /root/.config/tree-sitter && \
    echo '{"parser-directories": ["/root/parsers"]}' > /root/.config/tree-sitter/config.json

# Prepare build dir
WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Instruct git to use HTTPS for all GitHub clones
RUN git config --global url.https://github.com/.insteadOf git://github.com/ && \
    git config --global url."https://".insteadOf git:// && \
    git config --global url."https://github.com/".insteadOf git@github.com:

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

# We still need Erlang/Elixir runtime for the escript to run, though ideally
# we would use `mix release` to make it completely standalone, but escript
# is simpler for the CLI prototype.
# 1. Install Tree-Sitter runtime natively via Alpine
RUN apk add --no-cache bash tree-sitter tree-sitter-cli gcc g++

# 2. Add grammar directories and configs
COPY --from=builder /root/parsers /root/parsers
COPY --from=builder /root/.config /root/.config

WORKDIR /app

# Copy the generated binary from the build stage
COPY --from=builder /app/dir_graph ./dir_graph

# The AntiGravity orchestrator will mount the user's codebase into /workspace
# when calling this container so it has access to the files.
VOLUME /workspace

ENTRYPOINT ["./dir_graph"]
CMD ["--help"]
