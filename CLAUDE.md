# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Session start — pending diff check

At the start of every session, run this check before anything else:

```bash
ls ~/sites/diffs/
```

For each project directory found, read `diff_ledger.json`. If the **last entry** has `"author": "user"`, that project has a pending user-submitted graph diff awaiting an AI response. Notify the user:

> "Found pending graph diff for **{project}** (diff #{id}: "{label}"). Want me to review it?"

If yes: read `~/sites/diffs/{project}/full_ast.json` and `diff_ledger.json`, apply the diffs in order to understand the full proposed graph state, then respond with your analysis and (if appropriate) propose an AI counter-diff by appending to the ledger via the viewer's POST API at `http://localhost:5173/api/diffs/{project}/submit`.

## Neo4j (persistent graph + vector store)

DirGraph uses a dedicated Neo4j 5 container — separate from any existing Neo4j instance.

```bash
# Start (from project root — requires Docker running)
docker compose up -d

# Stop
docker compose down

# Browser UI: http://localhost:7475  (neo4j / dirgraph)
# Bolt port:  localhost:7688
```

**First-time setup** — after starting the container for the first time, call the `neo4j_setup_schema` MCP tool to create indexes and the vector index. If the container is not running, `neo4j_health` returns the exact `docker compose` command to start it.

**Ports** — chosen to avoid conflicts with the user's existing services:
- 7475 (HTTP) and 7688 (Bolt). Existing Neo4j occupies 7474/7687. MySQL on 3306/3307. Ollama on 11434.

## Commands

```bash
# Dependencies & build
mix deps.get
mix escript.build          # Compiles ./dir_graph CLI executable

# Testing
mix test                   # Run all 115 tests
mix test test/dir_graph/analyzer_test.exs          # Run a single test file
mix test test/dir_graph/analyzer_test.exs:42       # Run a single test by line

# Formatting
mix format

# Benchmarks
mix run bench/graph_bench.exs
mix run bench/vector_bench.exs

# MCP server (stdin/stdout JSON-RPC 2.0)
mix mcp.server

# CLI usage
./dir_graph --index-dir /path/to/project --export project.bin
./dir_graph --db project.bin --search login --depth 3
./dir_graph --file lib/auth.ex --search login --summary

# Viewer (React UI)
cd viewer && npm install && npm run dev    # http://localhost:5173
cd viewer && npm run build
```

## Architecture

DirGraph is a **Code Property Graph (CPG) engine** — it parses codebases into an in-memory graph and extracts targeted semantic slices for LLM consumption instead of dumping entire files.

### Data Flow

```
Source Files → [Indexer] → [Graph (libgraph)] → [Analyzer] → Output
                  ↑                                              ↓
              [LSP Clients]                        CLI / MCP Server / Viewer
```

### Core Components

**`DirGraph.Server`** (`lib/dir_graph/server.ex`) — GenServer holding the in-memory graph, manifest, and LSP client pool. All tool calls route through here. The single source of truth for session state.

**`DirGraph.Indexer`** (`lib/dir_graph/indexer.ex`) — Dispatches by file extension: Elixir files use `Code.string_to_quoted/1` (native AST), all other languages delegate to LSP clients. Returns unresolved refs for later cross-file resolution.

**`DirGraph.Analyzer`** (`lib/dir_graph/analyzer.ex`) — Graph traversal: exact → substring → fuzzy (Jaro-Winkler, 0.75 threshold) search; BFS depth-capped slicing (`extract_slice`/`affected_by`); formats results as compact JSON with file/line metadata. The "onion-skin" pattern computes `calls`/`callers` from the full graph so the LLM knows what's beyond the slice boundary.

**`DirGraph.LSP.Client`** (`lib/dir_graph/lsp/client.ex`) — Synchronous LSP client over stdio. Opens documents, fetches `documentSymbol`, calls `callHierarchy/outgoingCalls`. Clients are cached per language and restarted transparently.

**`DirGraph.MCP.Handler`** (`lib/dir_graph/mcp/handler.ex`) — 27 MCP tools dispatched via JSON-RPC 2.0. Enforces a two-layer allowlist: static config in `.dir_graph/mcp_config.json` + optional session plan (draft → approve → live → revoke). Reloaded on every request.

**`DirGraph.RAG`** (`lib/dir_graph/rag.ex`) — Optional semantic search via embeddings (Ollama or OpenAI). Embeds node text, stores in ETS (`VectorStore`), queries by cosine similarity, then BFS from top-K seeds.

**`DirGraph.ContentStore`** (`lib/dir_graph/content_store.ex`) — Persists user-created nodes (BusinessRule, Copy, Contract, Domain) to `.dir_graph/content_nodes.json`. Survives graph rebuilds; reloaded after every `index_directory` or `load_graph`.

**`DirGraph.AttemptLedger`** (`lib/dir_graph/attempt_ledger.ex`) — Tracks LLM fix attempts; detects flip-flop patterns (same diagnostic fingerprint after code changes), excessive attempts (≥5), and regressions.

### Graph Model

Every vertex is a string ID; metadata lives in libgraph vertex labels (maps).

**Node types:** `File`, `Module`, `Function`, `Class`, `Call` (code); `BusinessRule`, `Copy`, `Contract`, `Domain` (content — user-created, survives rebuilds)

**Edge types:** `CONTAINS`, `DEFINES`, `CALLS`, `IMPORTS`, `USES`, `REQUIRES`, `IMPLEMENTS`

### Configuration

- `.dir_graph/mcp_config.json` — allowlist, path restrictions, max_search_depth, embeddings backend
- `.dir_graph/lsp_servers.json` — maps file extensions to language server commands (js/ts → `typescript-language-server`, py → `pyright-langserver`, etc.)
- `.dir_graph/content_nodes.json` — persisted content node data

### Viewer — Visual Diff Collaboration

React 19 + TypeScript + XYFlow + Dagre layout in `viewer/`. The viewer is a visual collaborative editing layer for negotiating architectural changes between user and AI.

**Workflow:**
1. AI runs `export_to_viewer` MCP tool → writes `~/sites/diffs/{project}/full_ast.json` + empty `diff_ledger.json`, opens browser
2. User edits the graph (drag edges, delete nodes, add new nodes via + Node), hits **Submit**
3. Viewer computes a diff vs committed state, POSTs to the Vite dev server API, appends to `diff_ledger.json`
4. AI reads the diff, responds by appending its own diff entry to the ledger (via a future MCP tool)
5. Viewer polls every 2 s — new AI diffs trigger a notification badge; canvas auto-updates if user has no uncommitted edits
6. Diff dropdown navigates history with red/green overlay (added nodes = green border, removed = red ghost)
7. **Publish Changes** appears after the first AI diff — marks the session ready for code generation

**Diff schema** (`diff_ledger.json` entries):
```json
{ "diff_id": 2, "parent_diff_id": 1, "author": "user"|"ai",
  "label": "human-readable label",
  "added_nodes": [...], "removed_nodes": ["id1"],
  "added_edges": [...], "removed_edges": [...], "annotations": [...] }
```

**API** (served by Vite dev server middleware, reads/writes `~/sites/diffs/`):
- `GET /api/projects` — list project directories
- `GET /api/diffs/:project/ast` — serve `full_ast.json`
- `GET /api/diffs/:project/ledger` — serve `diff_ledger.json`
- `POST /api/diffs/:project/submit` — append a diff to the ledger

**Key files:**
- `vite.config.ts` — defines the API middleware plugin
- `src/types.ts` — shared TypeScript types (ASTNode, ASTEdge, Diff, DiffLedger)
- `src/App.tsx` — orchestration: project picker, diff navigation, submit/publish
- `src/utils/layout.ts` — Dagre layout (creates a fresh graph per call — no singleton)
- `src/components/GraphNode.tsx` — renders all node types including Annotation and diff overlay states
