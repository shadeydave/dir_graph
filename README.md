# DirGraph

A Code Property Graph (CPG) engine for surgical LLM context injection.

Instead of dumping entire files into an LLM prompt, DirGraph parses your codebase into a queryable graph, extracts a compact **semantic slice** — only the nodes and edges relevant to the concept you care about — and hands that to the model instead.

---

## The Problem

When you ask an LLM to modify a specific function, you don't need to send it 5,000 lines of surrounding code. You need the function, its direct dependencies, and the things that call it. Everything else is noise that costs tokens and increases the chance of the model touching something it shouldn't.

A typical project might be 500,000+ tokens. A semantic slice of one feature is rarely more than 2,000. That's a 99%+ reduction in context cost per query, with better results because the model only sees what's relevant.

```
Raw source files:   52,000 bytes  (~13,000 tokens)
Slice (depth 2):       608 bytes  (~   152 tokens)
Token savings:           ~99% fewer tokens
```

---

## How It Works

```
Source files
     │
     ▼
  Indexer  ──── parses AST / regex ────► Code Property Graph (in-memory)
                                               │
                                               ▼
                               Optional: Embeddings backend
                                               │
                                               ▼
                                        VectorStore (ETS)
                                               │
                        ┌──────────────────────┘
                        │
                        ▼
              query_code_graph("login")
                        │
              ┌─────────┴─────────┐
              │                   │
         Text search         Semantic search
         (exact / fuzzy)     (cosine similarity)
              │                   │
              └─────────┬─────────┘
                        │
                        ▼
                   BFS traversal
                   (bidirectional, depth-capped)
                        │
                        ▼
                  Semantic slice
          {node_count, edge_count, nodes, edges}
          each node: id, type, name, file, line
                        │
                        ▼
              LLM gets only what it needs
```

1. **Index** — DirGraph parses your source files (Elixir via the real AST, JS/TS via targeted regex) and builds an in-memory graph. Nodes represent files, modules, functions, classes, and call sites. Edges represent structural relationships: `CONTAINS`, `DEFINES`, `CALLS`, `IMPORTS`, `USES`, `REQUIRES`.

2. **Embed** — Optionally, each node is embedded via Ollama or OpenAI and stored in an ETS-backed VectorStore. This powers semantic search: "find me everything related to authentication" without knowing the exact function name.

3. **Search** — You name a concept. DirGraph finds the best matching node via exact/substring match, Jaro-Winkler fuzzy fallback, or cosine similarity against the vector store.

4. **Slice** — BFS traversal in both directions from the matched node, up to a configurable depth (hard cap: 3), extracts a subgraph of everything structurally connected to that concept.

5. **Format** — The slice is serialized as a compact JSON payload. Every node includes its file path and line number, so the LLM (or you) can issue targeted `Read` calls at exact offsets rather than loading whole files. Optionally embed the source lines directly in the payload.

---

## Graph Model

```
File:"lib/auth.ex"
  └─CONTAINS──► Module:"MyApp.Auth"
                   ├─DEFINES──► Function:"login/2:L45:lib/auth.ex"
                   │                 └─CALLS──► Call:"Repo.get/2:L48:lib/auth.ex"
                   └─DEFINES──► Function:"hash/1:L60:lib/auth.ex"

BusinessRule:"payment_approval"
  └─IMPLEMENTS──► Function:"authorize_payment/2:L22:lib/billing.ex"
```

### Code node types

| Type | Description |
|---|---|
| `File` | Source file |
| `Module` | Module or class container |
| `Function` | Named function or method |
| `Class` | Class declaration (JS/TS) |
| `Call` | Remote call site |

### Content node types

Non-code nodes that attach business meaning to the graph. They survive index rebuilds (persisted to `.dir_graph/content_nodes.json`).

| Type | Description |
|---|---|
| `BusinessRule` | Business logic rule or constraint |
| `Copy` | User-facing text, microcopy, or messaging |
| `Contract` | API contract, schema, or interface agreement |
| `Domain` | Domain concept or bounded context |

### Edge types

| Edge | Meaning |
|---|---|
| `CONTAINS` | File contains a module or top-level function |
| `DEFINES` | Module defines a function |
| `CALLS` | Function makes a remote call |
| `IMPORTS` | File imports another file or module |
| `USES` | File uses a module (Elixir `use`) |
| `REQUIRES` | File requires a module (Elixir `require`) |
| `IMPLEMENTS` | Content node is implemented by a code node |

---

## Language Support

| Language | Parser | Extracts |
|---|---|---|
| Elixir `.ex` / `.exs` | `Code.string_to_quoted/1` (real AST) | modules, public/private functions, macros, aliases, imports, uses, requires, remote calls |
| JavaScript / TypeScript `.js .ts .jsx .tsx` | Targeted regex | imports, `require()`, function declarations, arrow functions, class declarations |

---

## Installation

Requires Elixir 1.15+.

```bash
git clone <repo>
cd dir_graph
mix deps.get
mix escript.build
```

This produces a `./dir_graph` executable.

---

## CLI Usage

### Build an index

```bash
./dir_graph --index-dir /path/to/project --export project.bin
```

Recursively indexes all supported files, skipping `node_modules`, `_build`, `deps`, and `.git`. Serializes the graph to a binary file for fast reuse.

### Query the index

```bash
# JSON output (for piping to an LLM or other tools)
./dir_graph --db project.bin --search verify_token

# Human-readable summary
./dir_graph --db project.bin --search verify_token --summary

# Wider slice (default depth is 2)
./dir_graph --db project.bin --search login --depth 3

# Index a single file on the fly
./dir_graph --file lib/auth.ex --search login
```

### All options

```
-f, --file       <path>   Index a single file (JIT, no export needed)
-s, --search     <term>   Concept / node name to find (required for queries)
-d, --depth      <int>    BFS hops from matched node (default: 2)
-i, --index-dir  <path>   Recursively index a directory
-e, --export     <path>   Save index to a .bin file
    --db         <path>   Load a pre-compiled graph binary
    --summary             Print a human-readable summary instead of JSON
-h, --help                Show help
```

### JSON output format

```json
{
  "node_count": 6,
  "edge_count": 7,
  "nodes": [
    {
      "id": "Function:login/2:L45:lib/auth.ex",
      "type": "Function",
      "name": "login",
      "file": "/abs/path/lib/auth.ex",
      "line": 45,
      "end_line": 52,
      "label": "login/2",
      "visibility": "public"
    }
  ],
  "edges": [
    { "source": "Module:MyApp.Auth", "target": "Function:login/2:L45:lib/auth.ex", "rel": "DEFINES" }
  ]
}
```

If the search term was fuzzy-matched, the payload includes a `_fuzzy_match` key noting what was requested vs. what was matched.

---

## MCP Server

DirGraph ships with a Model Context Protocol (MCP) server so Claude Code (or any MCP-compatible client) can query the graph directly during a session.

### Start the server

```bash
mix mcp.server
```

Communicates over stdio using newline-delimited JSON-RPC 2.0.

### Connect from Claude Code

Add this to `~/.claude/settings.json`:

```json
{
  "mcpServers": {
    "dir_graph": {
      "command": "mix",
      "args": ["mcp.server"],
      "cwd": "/path/to/dir_graph"
    }
  }
}
```

### MCP Tool Reference

#### Graph query tools

| Tool | Description |
|---|---|
| `query_code_graph` | Search for a concept by name. Returns a semantic slice with file + line per node. |
| `affected_by` | Find everything that would break if a given node changes (inbound BFS). |
| `semantic_search` | Find nodes by meaning, not name. Requires embeddings backend. |
| `workspace_stats` | Returns node count, edge count, embeddings status, and content node count. |

#### Graph management tools

| Tool | Description |
|---|---|
| `index_directory` | Index a directory into the in-memory graph. |
| `index_file` | Index a single file into the in-memory graph. |
| `load_graph` | Load a pre-compiled `.bin` graph (fast — use this at session start). |
| `save_graph` | Persist the current in-memory graph to a `.bin` file. |
| `remove_file` | Remove a file's nodes from the graph (e.g. after deletion). |

#### Content node tools

Non-code nodes that survive graph rebuilds. Use these to attach business rules, copy, contracts, or domain concepts directly to implementation nodes.

| Tool | Description |
|---|---|
| `add_content_node` | Create a BusinessRule, Copy, Contract, or Domain node. |
| `update_content_node` | Update content or metadata of an existing content node. |
| `delete_content_node` | Remove a content node permanently. |
| `find_implementations` | Find code nodes that implement a given content node. |
| `list_content_nodes` | List all content nodes, optionally filtered by type. |

#### Mutation tools

| Tool | Description |
|---|---|
| `apply_diff` | Apply an LLM-generated diff (node-level replacements) back to source files. Validates syntax before writing. |

#### Planning tools

| Tool | Description |
|---|---|
| `propose_session_plan` | Declare the minimum tools and paths needed for a task. Writes a draft for human review. |
| `approve_session_plan` | Activate the approved draft, restricting the session to declared scope. |
| `revoke_session_plan` | Clear the active plan and restore the full static allowlist. |

### Recommended workflow for Claude Code

At the start of any session on a project with a pre-built graph:

```
1. load_graph("/path/to/project.bin")
2. workspace_stats()                     ← confirms what's loaded
3. query_code_graph("login")             ← before reading any file
4. Read file at returned file + line     ← targeted, not whole file
```

For exploratory queries where you don't know the exact name:

```
1. semantic_search("user authentication flow")   ← finds relevant entry nodes
2. query_code_graph("<returned node id>")        ← BFS from there
```

---

## GraphRAG: Semantic Search

Traditional graph search requires knowing a name. GraphRAG lets you describe what you're looking for in plain language, and the system finds the closest matching nodes by meaning.

### How it works

1. When `index_directory` or `index_file` runs, each node's text (`"Function login/2\n<source lines>"`) is embedded and stored in the VectorStore.
2. `semantic_search("user authentication")` embeds the query and runs cosine similarity against all stored vectors.
3. The top-K matching node IDs are returned as seeds.
4. Each seed can be passed to `query_code_graph` for BFS expansion.

### Embedding backends

Configure in `.dir_graph/mcp_config.json`:

```json
{
  "embeddings": {
    "backend": "ollama",
    "url": "http://localhost:11434",
    "model": "nomic-embed-text"
  }
}
```

Or with OpenAI:

```json
{
  "embeddings": {
    "backend": "openai",
    "api_key": "sk-...",
    "model": "text-embedding-3-small"
  }
}
```

If no embeddings backend is configured, `semantic_search` returns a helpful error and all other tools function normally. Embeddings are optional — the graph works without them.

### VectorStore

The VectorStore uses an ETS table (`:protected`, named `:dir_graph_vectors`) for concurrent reads without going through the GenServer. Writes are serialized. Cosine similarity is computed inline in a single `Enum.reduce` pass over zipped vectors.

---

## Content Nodes

Code graphs represent structure. Content nodes let you attach intent.

```bash
# Add a business rule linked to its implementation
add_content_node(
  type: "BusinessRule",
  name: "payment_approval_required",
  content: "All payments over $500 must be approved by a manager before processing.",
  implements: ["Function:authorize_payment/2:L22:lib/billing.ex"]
)
```

Once added, the content node appears in any slice that includes `authorize_payment`. When the function changes, `affected_by` surfaces the linked rule. When you ask the LLM to modify payment logic, it can see the business constraint directly in context — no separate documentation lookup needed.

Content nodes are persisted to `.dir_graph/content_nodes.json` and reloaded automatically after every `index_directory` or `load_graph`, so they survive full graph rebuilds.

---

## Configuration

Create `.dir_graph/mcp_config.json` in the project root:

```json
{
  "allowed_tools": [
    "query_code_graph",
    "affected_by",
    "semantic_search",
    "workspace_stats",
    "load_graph",
    "index_directory",
    "index_file",
    "save_graph",
    "add_content_node",
    "update_content_node",
    "delete_content_node",
    "find_implementations",
    "list_content_nodes",
    "propose_session_plan",
    "approve_session_plan",
    "revoke_session_plan"
  ],
  "allowed_paths": [
    "/path/to/your/project"
  ],
  "max_search_depth": 3,
  "embeddings": {
    "backend": "ollama",
    "url": "http://localhost:11434",
    "model": "nomic-embed-text"
  }
}
```

If this file is absent, all tools are allowed and the current working directory is the approved path.

### Path guards

Every tool call that touches the filesystem checks the `allowed_paths` list. Requests for paths outside any approved prefix are rejected with an error before any disk access occurs.

---

## Session Plans

The session plan system is a two-layer security model for MCP sessions:

- **Static allowlist** (`.dir_graph/mcp_config.json`) — the ceiling. Claude can never access more than this allows.
- **Session plan** (`.dir_graph/session_plan.json`) — an optional overlay that can only *restrict* the static allowlist, never expand it.

```
Claude calls propose_session_plan("task": "Fix auth bug", "tools": [...], "paths": [...])
  → Draft written to .dir_graph/session_plan.draft.json

User reviews and approves
  → Draft promoted to .dir_graph/session_plan.json, restrictions take effect immediately

... Claude does the task within declared scope ...

User or Claude calls revoke_session_plan
  → Plan deleted, full static allowlist restored
```

The allowlist is reloaded from disk on every tool call — plan changes take effect immediately with no server restart.

---

## Architecture

```
dir_graph/
  lib/
    dir_graph/
      graph.ex          — libgraph wrapper; vertices = string IDs, metadata in labels
      indexer.ex        — Parses source files into the CPG (Elixir AST + JS regex)
      analyzer.ex       — find_node, extract_slice (BFS), affected_by, format_for_llm
      server.ex         — GenServer: holds graph, routes all tool calls
      cli.ex            — Escript CLI entry point
      manifest.ex       — File mtime/size tracking for incremental re-indexing
      watcher.ex        — FileSystem watcher for live graph updates
      weaver.ex         — Applies LLM-generated diffs back to source files (w/ syntax check)
      planner.ex        — Scaffolds new graphs from JSON plan definitions
      embeddings.ex     — HTTP client for Ollama / OpenAI embedding backends
      vector_store.ex   — ETS-backed cosine similarity store
      rag.ex            — GraphRAG orchestration: index nodes, semantic search
      content_store.ex  — Persists content nodes to JSON, survives graph rebuilds
      attempt_ledger.ex — Tracks repeated LLM mutation attempts to detect flip-flop loops
      process_monitor.ex — Monitors indexer/watcher processes
      lsp/
        client.ex       — LSP client (go-to-definition, hover) with dead port recovery
        indexer.ex      — Drives LSP-based deep import extraction
        import_extractor.ex — Parses LSP responses into graph edges
        server_registry.ex  — Manages per-language LSP server processes
        symbol_mapper.ex    — Maps LSP symbols to CPG node types
      mcp/
        server.ex       — stdio JSON-RPC 2.0 loop
        handler.ex      — Tool dispatch, schema definitions, error formatting
        allowlist.ex    — Two-layer config/plan enforcement (27 operational tools)
  bench/
    graph_bench.exs     — BFS and token-savings benchmarks
    vector_bench.exs    — Vector search latency and correctness benchmarks
  test/
    dir_graph/
      analyzer_test.exs
      content_store_test.exs
      attempt_ledger_test.exs
      indexer_test.exs
      manifest_test.exs
      vector_store_test.exs
      weaver_test.exs
      graph_test.exs
```

**Runtime dependencies:** `jason`, `libgraph`, `the_fuzz`, `req`

---

## Performance

Measured on a 500-node synthetic CPG with 768-dimensional embeddings (nomic-embed-text).

### BFS slice extraction

| Operation | Time |
|---|---|
| `extract_slice` depth=1 (500 nodes) | 2.57 μs |
| `extract_slice` depth=2 (500 nodes) | 142 μs |
| `extract_slice` depth=3 (500 nodes) | 478 μs |
| `extract_slice` depth=2 (2,000 nodes) | ~600 μs |
| `find_node` exact match (500 nodes) | < 5 μs |
| `find_node` fuzzy (500 nodes) | ~2,100 μs |

BFS is fast enough that depth capping is a correctness concern (token explosion), not a latency one.

### Token savings

| Payload | Tokens |
|---|---|
| `format_for_llm` depth=1 (4 nodes) | 152 |
| `format_for_llm` depth=2 (9 nodes) | ~620 |
| `format_for_llm` depth=3 (13 nodes) | ~3,300 |
| Full raw source (same codebase) | 13,000+ |

### Vector search (cosine similarity)

| Corpus | Time per query |
|---|---|
| 100 vectors (768-dim) | ~680 ms |
| 1,000 vectors (768-dim) | ~690 ms |
| 10,000 vectors (768-dim) | ~750 ms |

The current VectorStore is a pure-Elixir linear scan. The bottleneck is list operations per vector, not corpus size — the times are nearly flat. For corpora under ~1,000 nodes this is acceptable at < 1 second. For large codebases, see the roadmap below.

---

## Design Considerations

**Why not just use an embedding database (Qdrant, Pinecone, etc.)?**

For most codebases, the graph is the right primary index. Structural relationships (this function calls that one; this module defines those functions) are exact, deterministic, and zero-latency. Embeddings are a fallback for when you don't know the exact name. Keeping both in-process means no external services to stand up, and the graph BFS is the thing that produces the final context — semantic search only supplies entry points.

**Why a hard depth cap of 3?**

At depth 3 on a typical codebase, a single function can pull in dozens of modules. The token count explodes exponentially. Depth 2 covers the function, its direct dependencies, and their immediate callers — which is enough for the LLM to understand intent and make a safe edit. Depth 3 is available for exploration. Going deeper without filtering produces context that's worse than reading the raw file.

**Why content nodes instead of just comments/docs?**

Documentation drifts from code. A `BusinessRule` node attached to a function is explicit, queryable, and shows up in every slice that includes that function — without requiring the LLM to parse prose. It's also writable: you can add a constraint discovered mid-task without touching source files.

**Why Elixir?**

The CPG lives in a GenServer so multiple MCP tool calls share state without re-parsing. The BEAM scheduler handles concurrent embedding workers naturally. `libgraph` gives BFS/subgraph extraction without an external graph database. And Elixir's pattern matching makes AST traversal concise.

**Why not use the LSP for everything?**

LSP gives richer type information and go-to-definition across files, but requires a running language server per language, introduces latency, and can crash or hang. The AST-based indexer is the fast, reliable primary path. LSP is an optional enrichment layer for when you need cross-file resolution that regex can't give you.

**Weaver's two-phase safety model**

`apply_diff` validates every mutation against the graph before touching the file, then verifies the resulting Elixir source parses cleanly before writing. No mutation reaches disk if the node doesn't exist in the graph or if the resulting file is syntactically invalid. This prevents the common failure mode of an LLM generating a diff that's structurally plausible but references the wrong line offsets.

**The AttemptLedger**

LLMs sometimes flip-flop: "add error handling" → "remove error handling" → "add error handling". The `AttemptLedger` tracks mutation attempts per node per session, detects recurrence patterns, and issues graduated warnings before blocking further mutations on a node that appears stuck in a loop.

---

## Areas for Improvement

These are known limitations that would need to be addressed for production use at scale.

### Vector search performance

The linear cosine scan (768-dim, pure Elixir) takes ~700 ms regardless of corpus size. For codebases over ~5,000 functions, this becomes noticeable. Options:

- **Nx + EXLA**: Batch matrix multiply for cosine similarity (BLAS-accelerated, 10-100x faster)
- **HNSWlib NIF**: Approximate nearest neighbor index (sub-millisecond at millions of vectors)
- **External ANN service**: Qdrant or Weaviate as sidecar (adds ops complexity)

### Language coverage

Currently Elixir (full AST) and JS/TS (regex). Missing:

- **Python**: The regex approach works but misses decorators, type annotations, and comprehension-heavy patterns. A tree-sitter grammar would fix this.
- **Ruby, Go, Rust**: Adding tree-sitter grammars is straightforward once the JS/TS regex path is treated as a template.
- **CSS/HTML**: Different node model needed — selectors, component boundaries, not functions.

### Incremental indexing

The manifest tracks mtime/size changes but full re-indexing on change is the current behavior. True incremental indexing would:

1. Remove only the nodes belonging to the changed file
2. Re-parse and re-insert just that file's nodes
3. Re-resolve cross-file edges

This would make the watcher practical for large codebases where full re-index takes seconds.

### Embedding freshness

Embeddings are generated at index time and not re-generated when a function's body changes. A dirty-embedding flag per node, checked by the watcher, would keep the vector store consistent with the current source.

### Multi-project graphs

Currently one graph per server instance. A workspace with multiple repos (a monorepo or a microservices mesh) would benefit from a federated graph where cross-service `CALLS` edges are tracked across graph boundaries. The string-ID vertex model already supports this — it just needs a loader that can merge graphs without collision.

### LLM-native output formats

`format_for_llm` currently produces generic JSON. Adapter layers for specific LLM APIs (Anthropic tool results, OpenAI function call returns) would let the server speak each model's native schema, reducing prompt engineering on the consumer side.

### Authentication for MCP

The MCP server runs over stdio with no authentication. For shared team use (e.g. a server shared across a development team), an auth layer and per-user session plans would be needed.

---

## Running Tests

```bash
mix test
```

115 tests, 0 failures. Test coverage includes graph construction, BFS correctness, fuzzy matching, Weaver diff application, manifest diffing, vector store cosine correctness, content node CRUD, and the attempt ledger's loop detection.

```bash
# Performance benchmarks
mix run bench/graph_bench.exs
mix run bench/vector_bench.exs
```

---

## Background

> Treat an LLM not as a "developer reading your repo," but as a highly specialized surgeon. Your local machine acts as the surgical team: it preps the patient, isolates the exact organ (the sub-graph), covers the rest of the body, and hands the surgeon the scalpel. The surgeon makes the cut, and your local team sews it back up.

By treating the codebase as a queryable database rather than a stack of text files, you eliminate context bloat entirely. You don't send a 5,000-line file because a variable is buried on line 4,012 — you send a surgically extracted subgraph of only what touches that variable.

The LLM sees less, understands more, and touches only what it should.
