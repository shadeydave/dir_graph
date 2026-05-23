# 🌲 DirGraph

### *A Code Property Graph (CPG) & Semantic Slicing Engine for AI Collaboration*

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Elixir Version](https://img.shields.io/badge/Elixir-%7E%3E%201.15-purple.svg)](https://elixir-lang.org/)
[![Node Version](https://img.shields.io/badge/Node-%3E%3D%2018-green.svg)](https://nodejs.org/)
[![Docker Compose](https://img.shields.io/badge/Docker%20Compose-Supported-blue.svg)](https://www.docker.com/)

**DirGraph** is a high-performance Code Property Graph (CPG) indexer and traversal engine designed specifically for AI-assisted software engineering. Instead of dumping raw, verbose source files into an LLM's context window, DirGraph parses your codebase into a rich semantic graph—extracting precise slices of code, call hierarchies, and cross-file dependencies on demand.

It ships with a **Model Context Protocol (MCP) server**, a powerful **interactive CLI**, and a **collaborative React 19/XYFlow visualization canvas** that lets developers and AI negotiate architectural changes through visual graph diffs.

---

## 🚀 Key Features

*   **Native AST & LSP Parsing**: Native Elixir AST analysis combined with seamless Language Server Protocol (LSP) integrations for JavaScript, TypeScript, Python, Ruby, Go, Rust, and C/C++.
*   **"Onion-Skin" Traversal**: Cap-depth Breadth-First Search (BFS) that extracts call-graphs and callers, providing context beyond functional boundaries.
*   **Persistent Neo4j Graph & Vector RAG**: Fully persistent database storage with integrated semantic concept searches (Ollama / OpenAI).
*   **Visual Diff Negotiation Canvas**: Drag edges, add notes, and delete nodes on a React 19 visual canvas to generate architectural change ledgers (`diff_ledger.json`) that LLMs can parse to generate safe code.
*   **Monitored Background Processes**: Start and watch tests or servers concurrently inside the MCP context, polling outputs via incremental cursors.

---

## 📦 Quick Installation in 1 Command

DirGraph includes an interactive setup utility that checks your system tools, fetches dependencies, compiles the binary, provisions database servers, and validates everything.

Simply run:

```bash
chmod +x setup.sh
./setup.sh
```

---

## 🛠️ Usage

### 1. The Command Line Interface (CLI)

Compile the standalone escript, then index and slice codebases:

```bash
# Compile CLI binary (executable is './dir_graph')
mix escript.build

# Index your project and export the graph to a file
./dir_graph --index-dir /path/to/project --export project.bin

# Retrieve a semantic slice (2 hops deep) around a function
./dir_graph --db project.bin --search get_user_by_email --depth 2

# Output a clean human-readable summary
./dir_graph --db project.bin --search get_user_by_email --summary
```

### 2. The Model Context Protocol (MCP) Server

Connect your favorite LLM client (like Claude Code) to the DirGraph MCP backend over standard input/output:

```bash
mix mcp.server
```

*For tool allowlists and path limitations, customize [.dir_graph/mcp_config.json](.dir_graph/mcp_config.json).*

### 3. The Visual Collaboration Canvas (Viewer)

Start the React-based XYFlow/Dagre graph visualizer in developer mode:

```bash
cd viewer
npm install
npm run dev
```

Open `http://localhost:5173` in your browser. When you run the `export_to_viewer` tool via MCP, the visualizer automatically populates your codebase graph and highlights proposed modifications.

---

## 🏛️ Project Directory Structure

```
├── .dir_graph/            # Local configuration allows, lists, and session drafts
├── config/                # Elixir environment configurations
├── lib/                   # Elixir core graph engine & MCP handler
│   └── dir_graph/
│       ├── lsp/           # LSP client registers and symbol extraction
│       └── mcp/           # MCP JSON-RPC 2.0 tool handlers
├── viewer/                # React 19 + TypeScript XYFlow visualizer canvas
├── test/                  # Full suite of 115 unit tests
├── docker-compose.yml     # Managed Neo4j 5 database container
├── Dockerfile             # Multi-stage production container build
├── setup.sh               # System setup & verification utility
└── DirGraph_README.md     # Deep-dive architectural documentation
```

---

## 📖 Deep-Dive Documentation

For exhaustive information on graph models, vertex properties, advanced RAG architectures, and custom tool schemas, please consult the core **[DirGraph_README.md](DirGraph_README.md)** guide.

---

## ⚖️ License

Distributed under the MIT License. See [LICENSE](LICENSE) for more information.
