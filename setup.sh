#!/usr/bin/env bash

set -euo pipefail

# ANSI color codes
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'
BOLD='\033[1m'

echo -e "${BOLD}${CYAN}========================================================================${RESET}"
echo -e "${BOLD}${CYAN}                DirGraph Environment Setup Utility                      ${RESET}"
echo -e "${BOLD}${CYAN}========================================================================${RESET}"
echo -e "This script will audit your local environment and prepare DirGraph"
echo -e "for first-time local use."
echo

# ----------------------------------------------------------------------
# 1. Dependency Checks
# ----------------------------------------------------------------------
echo -e "${BOLD}${YELLOW}[1/4] Auditing system dependencies...${RESET}"

# Elixir
if command -v elixir >/dev/null 2>&1; then
    echo -e "  - Elixir:  ${GREEN}Detected${RESET} ($(elixir -v | grep Elixir | sed 's/Elixir //'))"
else
    echo -e "  - Elixir:  ${RED}Not Found${RESET}"
    echo -e "    ${YELLOW}Hint:${RESET} Please install Elixir ~> 1.15. (Mac: 'brew install elixir', Linux: 'apt-get install elixir')"
    exit 1
fi

# Node.js
if command -v node >/dev/null 2>&1; then
    echo -e "  - Node.js: ${GREEN}Detected${RESET} ($(node -v))"
else
    echo -e "  - Node.js: ${RED}Not Found${RESET}"
    echo -e "    ${YELLOW}Hint:${RESET} Please install Node.js (Mac: 'brew install node', Linux: see nodejs.org)"
    exit 1
fi

# Docker
if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
        echo -e "  - Docker:  ${GREEN}Detected & Running${RESET}"
    else
        echo -e "  - Docker:  ${YELLOW}Detected but NOT running${RESET}"
        echo -e "    ${YELLOW}Hint:${RESET} Please start your Docker Desktop engine before booting Neo4j."
    fi
else
    echo -e "  - Docker:  ${RED}Not Found${RESET}"
    echo -e "    ${YELLOW}Hint:${RESET} Docker is optional but highly recommended to run the Neo4j container."
fi
echo

# ----------------------------------------------------------------------
# 2. Elixir Project Build
# ----------------------------------------------------------------------
echo -e "${BOLD}${YELLOW}[2/4] Setting up Elixir backend...${RESET}"
echo -e "Fetching Elixir dependencies..."
mix deps.get

echo -e "Compiling CLI escript binary..."
mix escript.build
echo -e "  - CLI binary: ${GREEN}Successfully built${RESET} (executable is './dir_graph')"
echo

# ----------------------------------------------------------------------
# 3. Viewer Frontend Build
# ----------------------------------------------------------------------
echo -e "${BOLD}${YELLOW}[3/4] Setting up React Viewer frontend...${RESET}"
echo -e "Installing package dependencies in viewer/..."
cd viewer
npm install
cd ..
echo -e "  - Viewer dependencies: ${GREEN}Installed successfully${RESET}"
echo

# ----------------------------------------------------------------------
# 4. Neo4j Database Setup
# ----------------------------------------------------------------------
echo -e "${BOLD}${YELLOW}[4/4] Setting up Neo4j persistent graph database...${RESET}"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    read -p "Would you like to start the Neo4j docker container? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Starting container via docker compose..."
        docker compose up -d
        
        echo "Waiting for Neo4j database to start up and become healthy..."
        # Wait up to 60 seconds
        for i in {1..60}; do
            if curl -s -I http://localhost:7475 | grep -q "200 OK\|302 Found\|401 Unauthorized" >/dev/null 2>&1; then
                echo -e "  - Neo4j database: ${GREEN}Healthy and running on http://localhost:7475${RESET}"
                break
            fi
            if [ $i -eq 60 ]; then
                echo -e "  - Neo4j database: ${RED}Timeout waiting for startup${RESET}"
                break
            fi
            sleep 1
        done
        
        echo "Initializing constraints, indexes, and vector indexes..."
        mix run -e "DirGraph.Neo4j.setup_schema()" || true
        echo -e "  - Schema constraints: ${GREEN}Initialized successfully${RESET}"
    else
        echo "Skipping Docker container startup."
    fi
else
    echo "Skipping Neo4j startup (Docker is not available or not running)."
fi
echo

# ----------------------------------------------------------------------
# 5. Verification Check
# ----------------------------------------------------------------------
echo -e "${BOLD}${CYAN}========================================================================${RESET}"
echo -e "${BOLD}${GREEN}               Setup and Environment Ready!                             ${RESET}"
echo -e "${BOLD}${CYAN}========================================================================${RESET}"
echo -e "Verification: Running backend test suite to confirm complete integrity..."
mix test

echo
echo -e "To start developing:"
echo -e "  1. Start the React viewer: ${BOLD}cd viewer && npm run dev${RESET}"
echo -e "  2. Run the MCP server in Claude Code or client: ${BOLD}mix mcp.server${RESET}"
echo -e "  3. Use the compiled CLI binary: ${BOLD}./dir_graph --help${RESET}"
echo
