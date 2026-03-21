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
  Indexer  ── Elixir: real AST ────────► Code Property Graph (in-memory)
             ── others: LSP ──────────►
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

1. **Index** — DirGraph parses your source files and builds an in-memory graph. Elixir files use the real AST (`Code.string_to_quoted/1`). All other languages (JS, TS, Python, Ruby, Go, Rust, and any language with an LSP server) are indexed via `textDocument/documentSymbol` through the appropriate language server. Nodes represent files, modules, functions, classes, and call sites. Edges represent structural relationships: `CONTAINS`, `DEFINES`, `CALLS`, `IMPORTS`, `USES`, `REQUIRES`.

2. **Embed** — Optionally, each node is embedded via Ollama or OpenAI and stored in an ETS-backed VectorStore. This powers semantic search: "find me everything related to authentication" without knowing the exact function name.

3. **Search** — You name a concept. DirGraph finds the best matching node via exact/substring match, Jaro-Winkler fuzzy fallback, or cosine similarity against the vector store.

4. **Slice** — BFS traversal in both directions from the matched node, up to a configurable depth (hard cap: 3), extracts a subgraph of everything structurally connected to that concept.

5. **Format** — The slice is serialized as a compact JSON payload. Every node includes its file path and line number, so the LLM (or you) can issue targeted `Read` calls at exact offsets rather than loading whole files. Optionally embed the source lines directly in the payload. Each node also carries `calls` and `callers` fields — pre-computed from the full call graph — so even nodes at the boundary of a slice announce what lies beyond them without requiring a deeper traversal.

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
| Elixir `.ex` / `.exs` | `Code.string_to_quoted/1` (real AST) | modules, public/private functions, macros, aliases, imports, uses, requires, remote calls, CALLS edges |
| JavaScript / TypeScript `.js .ts .jsx .tsx` | LSP via `typescript-language-server` | files, modules, functions, arrow functions, classes, methods, import paths, CALLS edges |
| Python `.py` | LSP via `pyright-langserver` | files, classes, functions, methods, import paths, CALLS edges |
| PHP `.php` | LSP via `intelephense` | files, classes, functions, methods, import paths, CALLS edges |
| Ruby `.rb` | LSP via `solargraph` | files, modules, classes, methods, import paths, CALLS edges |
| Go `.go` | LSP via `gopls` | files, packages, functions, methods, import paths, CALLS edges |
| Rust `.rs` | LSP via `rust-analyzer` | files, modules, functions, structs, impl methods, import paths, CALLS edges |
| C / C++ `.c .h .cpp .cc .cxx .hpp` | LSP via `clangd` | files, functions, classes, structs, methods, import paths, CALLS edges |
| Any other language | LSP via user-configured server | whatever `textDocument/documentSymbol` + `callHierarchy/outgoingCalls` returns |

LSP servers ship with built-in defaults for the languages above but require the server executable to be on `PATH`. Add or override entries in `.dir_graph/lsp_servers.json` to support additional languages without any code changes.

### Installing language servers

DirGraph detects which servers are installed at startup and reports the gaps in `workspace_stats`. Each missing entry includes the exact install command. See [Capability Gap Reporting](#capability-gap-reporting--self-improvement) for the full workflow.

| Server | Covers | Install |
|---|---|---|
| `typescript-language-server` | JS, TS, JSX, TSX | `npm install -g typescript-language-server typescript` |
| `pyright-langserver` | Python | `npm install -g pyright` |
| `intelephense` | PHP | `npm install -g intelephense` |
| `solargraph` | Ruby | `gem install solargraph` |
| `gopls` | Go | `go install golang.org/x/tools/gopls@latest` |
| `rust-analyzer` | Rust | `rustup component add rust-analyzer` |
| `clangd` | C, C++ | bundled with Xcode CLT on macOS; `brew install llvm` for a newer version |

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
      "visibility": "public",
      "calls": ["get_user", "verify_password", "audit_log"],
      "callers": ["handle_request", "session_refresh"],
      "callers_total": 2
    }
  ],
  "edges": [
    { "source": "Module:MyApp.Auth", "target": "Function:login/2:L45:lib/auth.ex", "rel": "DEFINES" }
  ]
}
```

**Node fields:**
- `calls` — names of functions this node directly calls (derived from CALLS edges in the full graph; absent if no outgoing calls)
- `callers` — names of functions that call this node, capped at 10 (absent if no callers)
- `callers_total` — total caller count when it exceeds the display cap; signals hub nodes
- `code` — source lines for this node, present only when `include_code: true` is passed
- `visibility` — `"public"` or `"private"` for Elixir functions; absent for other languages

**Payload-level fields:**
- `_fuzzy_match` — present when the search term was fuzzy-matched; shows what was requested vs. what was matched
- `_note` — present when call hierarchy data is absent from the graph (e.g. language server not installed); instructs the LLM not to make assertions about call flows

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
| `workspace_stats` | Returns node/edge counts, `calls_edges` count, embeddings status, and `capability_gaps` (missing language servers with install commands). |

#### Graph management tools

| Tool | Description |
|---|---|
| `index_directory` | Index a directory into the in-memory graph. |
| `index_file` | Index a single file into the in-memory graph. |
| `load_graph` | Load a pre-compiled `.bin` graph (fast — use this at session start). |
| `save_graph` | Persist the current in-memory graph to a `.bin` file. |
| `sync_graph` | Diff the manifest against current disk state and re-index only changed files. |
| `watch_directory` | Start a file-system watcher that keeps the graph live as files change. |
| `unwatch_directory` | Stop the watcher for a directory. |

#### Content node tools

Non-code nodes that survive graph rebuilds. Use these to attach business rules, copy, contracts, or domain concepts directly to implementation nodes.

| Tool | Description |
|---|---|
| `add_content_node` | Create a BusinessRule, Copy, Contract, or Domain node. |
| `update_content_node` | Update content or metadata of an existing content node. |
| `delete_content_node` | Remove a content node permanently. |
| `find_implementations` | Find code nodes that implement a given content node. |
| `list_content_nodes` | List all content nodes, optionally filtered by type. |

#### Process tools

Spawn and monitor long-running OS processes (build servers, test runners, dev servers) from within an MCP session.

| Tool | Description |
|---|---|
| `spawn_process` | Start a named OS process and begin buffering its output. |
| `list_processes` | List all running managed processes and their status. |
| `read_output` | Read buffered output from a process (ring buffer, last 500 lines). |
| `tail_output` | Stream new output lines from a process since a given cursor. |
| `stop_process` | Stop a managed process by name. |

#### Attempt ledger tools

Tracks LLM mutation attempts per problem key to detect flip-flop loops and diagnostic regressions.

| Tool | Description |
|---|---|
| `record_attempt` | Record a fix attempt for a problem key. Accepts an optional `diagnostic` string (test output, error message) whose fingerprint is compared against the previous attempt — if the same error recurs despite different code, a targeted "wrong mental model" warning fires before the count-based thresholds. |
| `resolve_problem` | Mark a problem as resolved, clearing its active attempt counter while retaining history for recurrence detection. |
| `list_problems` | List all open (unresolved) problem keys sorted by attempt count descending. |
| `reset_ledger` | Clear all attempt history for the session. |

#### Test selection tools

| Tool | Description |
|---|---|
| `find_tests` | Given a function or module name, runs an inbound BFS (`affected_by`) to depth 3 and filters the result to nodes in test/spec directories. Returns each test's name, file, line, and a ready-to-run shell command (supports Elixir/ExUnit, Ruby/RSpec, JS/TS/Jest, Go, Python/pytest, PHP/PHPUnit). |

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
2. workspace_stats()                     ← confirms what's loaded; check calls_edges
                                           and capability_gaps before doing any analysis
3. query_code_graph("login")             ← before reading any file
4. Read file at returned file + line     ← targeted, not whole file
```

If `workspace_stats` shows `calls_edges: 0` alongside Function nodes, call hierarchy
was not extracted. Check `capability_gaps` for the install command and offer to run it
via `spawn_process`. After installation, call `sync_graph` to rebuild with call data.

For exploratory queries where you don't know the exact name:

```
1. semantic_search("user authentication flow")   ← finds relevant entry nodes
2. query_code_graph("<returned node id>")        ← BFS from there
```

When editing a function and wanting surgical regression coverage:

```
1. find_tests("function_name")                  ← get the minimal test set
2. spawn_process("tests", command)              ← run the targeted tests
3. read_output("tests")                         ← capture results
4. record_attempt("function_name", <output>)    ← fingerprint-tracked attempt
```

If `record_attempt` returns a `same_error` warning, the diagnostic fingerprint matched
the previous attempt — the root cause analysis is likely wrong. Re-read the affected_by
slice and reconsider before trying again.

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

## Call Hierarchy & Onion-Skin Metadata

Structural graphs tell you what exists. Call graphs tell you what flows. DirGraph extracts both.

### How call edges are built

For Elixir, remote calls are extracted directly from the AST during the index pass — every `Module.function(args)` expression becomes a `CALLS` edge in the graph.

For all LSP-backed languages (JS, TS, PHP, Python, Ruby, Go, Rust, C/C++), DirGraph uses the LSP call hierarchy protocol (LSP 3.16+):

1. After `textDocument/documentSymbol` builds the symbol tree for a file, the file is kept open.
2. For each callable symbol (Function, Method, Constructor), DirGraph calls `textDocument/prepareCallHierarchy` at the symbol's position to get a `CallHierarchyItem`.
3. `callHierarchy/outgoingCalls` is called on each item, returning every function that symbol calls — with the target's file, line, and name resolved by the language server.
4. A directed `CALLS` edge is added from the caller node to the target. If the target has already been indexed (its node exists in the graph), the edge links directly to it. If the target is external or not yet indexed, a lightweight `Call` placeholder node is created.
5. The file is closed. The process repeats for every callable in the file.

Because the language server resolves call targets, cross-file calls link to the actual target node — not a dangling string. This means `affected_by` works across files for all supported languages, not just Elixir.

### Onion-skin metadata

Every node in a slice carries two additional fields derived from the full graph at query time:

- **`calls`** — the names of functions this node directly calls (outgoing CALLS edges)
- **`callers`** — the names of functions that call this node (incoming CALLS edges), capped at 10 with a `callers_total` count when there are more

These fields are computed from the complete graph, not just the subgraph in the current slice. This means a node at the **boundary** of a slice — one whose neighbors weren't BFS-expanded — still announces what lies beyond it. The LLM doesn't need to request a wider slice to understand the flow topology; the road signs are baked into the nodes it already has.

```json
{
  "id": "Function:authorize_payment/2:L22:lib/billing.ex",
  "type": "Function",
  "name": "authorize_payment",
  "file": "lib/billing.ex",
  "line": 22,
  "calls": ["validate_amount", "fetch_approver", "audit_log"],
  "callers": ["checkout", "retry_job", "admin_override"],
  "callers_total": 3
}
```

Even if `checkout`, `retry_job`, and `admin_override` are not in this slice, the LLM knows they exist and call this function. This is the difference between a node that's opaque at the edge of a slice and one that's self-describing about its position in the call landscape.

### Hub node handling

A utility function called by hundreds of other functions would produce an enormous `callers` list. The display cap (10 entries) prevents this from bloating the payload. When the cap is hit, `callers_total` gives the true count so the LLM knows how widely the function is used without seeing every caller name.

### Call graph integrity signals

Two signals surface in every response to prevent an LLM from reasoning confidently about call flows that were never extracted:

1. **`calls_edges` in `workspace_stats`** — a count of all CALLS edges in the graph. If this is `0` alongside a large number of Function nodes, call hierarchy extraction did not run (language server missing or not supporting `callHierarchy`).

2. **`_note` in slice payloads** — when the server holds a full graph but it contains no CALLS edges, every slice response includes an explicit instruction not to make assertions about call flows or knock-on effects. The LLM is informed, not silently wrong.

---

## Capability Gap Reporting & Self-Improvement

DirGraph checks which LSP servers are installed every time `workspace_stats` is called. The result is a structured `capability_gaps` report:

```json
{
  "capability_gaps": {
    "available": [
      { "server": "typescript-language-server", "extensions": [".js", ".jsx", ".ts", ".tsx"] },
      { "server": "clangd", "extensions": [".c", ".cc", ".cpp", ".cxx", ".h", ".hpp"] }
    ],
    "missing": [
      {
        "server": "intelephense",
        "extensions": [".php"],
        "description": "Symbol extraction and call hierarchy for PHP",
        "install": "npm install -g intelephense",
        "notes": "Free tier covers all DirGraph features."
      }
    ]
  }
}
```

Each missing entry includes everything needed to act on it: the server name, what it enables, the exact install command, and any relevant notes.

### The self-improvement loop

Because DirGraph already has `spawn_process` and `tail_output`, an LLM session can close its own capability gaps without leaving the conversation:

```
1. workspace_stats()
   → capability_gaps.missing contains "intelephense" for PHP files

2. Claude explains the gap to the user and proposes the fix:
   "Your PHP files won't have call graphs. Want me to install intelephense?
    One command: npm install -g intelephense"

3. User approves.

4. spawn_process("install-intelephense", "npm install -g intelephense")
   tail_output("install-intelephense")   ← monitors progress live

5. sync_graph("/path/to/project")
   → Re-indexes changed/new files with the now-available language server

6. workspace_stats()
   → intelephense now in capability_gaps.available
   → calls_edges > 0 for PHP files
```

No manual intervention, no restarting the server, no reconfiguration. The graph improves itself within the session.

This pattern works for any language server in the registry. If a project adds Go files and `gopls` isn't installed, the next `workspace_stats` call surfaces it and the loop runs again.

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
    "sync_graph",
    "watch_directory",
    "unwatch_directory",
    "add_content_node",
    "update_content_node",
    "delete_content_node",
    "find_implementations",
    "list_content_nodes",
    "spawn_process",
    "list_processes",
    "read_output",
    "tail_output",
    "stop_process",
    "record_attempt",
    "resolve_problem",
    "list_problems",
    "reset_ledger",
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
      indexer.ex        — Parses source files into the CPG (Elixir: real AST; all others: LSP)
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
        client.ex       — Synchronous LSP client over stdio; open/fetch/close lifecycle;
                          documentSymbol + callHierarchy/outgoingCalls
        indexer.ex      — Groups files by language, runs documentSymbol + call hierarchy
                          pass per file, builds CALLS edges and placeholder Call nodes
        import_extractor.ex — Narrow regex over raw source for import path strings only
        server_registry.ex  — ext → {cmd, args} defaults; gap_report/0 for capability checks
        symbol_mapper.ex    — LSP SymbolKind integers → CPG node types and DEFINES/CONTAINS edges
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

**Why not use the LSP for Elixir too?**

Elixir is the host language, so `Code.string_to_quoted/1` is always available, zero-latency, and produces the exact AST node types needed for CALLS edge extraction. For every other language, LSP *is* the primary indexing path — the server starts `typescript-language-server`, `gopls`, etc., requests `textDocument/documentSymbol`, and maps the result to graph nodes. The only thing LSP doesn't give is import paths, which are extracted by a narrow regex pass over the raw source (import path strings only, not code structure).

**Why onion-skin metadata instead of always expanding the slice?**

A deeper BFS includes more nodes, which means more tokens. The onion-skin approach inverts this: instead of expanding the slice to show neighbors, it annotates each node with a summary of its neighborhood so the LLM can reason about what's beyond the slice boundary without actually fetching it. A node that calls `payment_processor` and `audit_log` — even when those functions aren't in the current slice — still tells the LLM those downstream effects exist. The LLM can decide whether to request a wider slice for those specific functions, rather than getting everything speculatively. Token cost stays proportional to what the LLM actually needs.

**Why cap callers at 10?**

Hub nodes — shared utilities, loggers, validators — can be called by hundreds of functions. Emitting the full callers list for a node like `Logger.info` would dominate the payload and provide diminishing signal. The cap keeps the output dense with useful information. The `callers_total` count still tells the LLM how widely used a function is, which is itself meaningful signal (a function called 200 times requires more caution to change than one called twice).

**Weaver's two-phase safety model**

`apply_diff` validates every mutation against the graph before touching the file, then verifies the resulting Elixir source parses cleanly before writing. No mutation reaches disk if the node doesn't exist in the graph or if the resulting file is syntactically invalid. This prevents the common failure mode of an LLM generating a diff that's structurally plausible but references the wrong line offsets.

**The AttemptLedger and diagnostic fingerprinting**

LLMs sometimes flip-flop: "add error handling" → "remove error handling" → "add error handling". The `AttemptLedger` tracks fix attempts per problem key, detects recurrence patterns, and issues graduated warnings as the count rises:

| Attempt | Signal |
|---|---|
| 1 | No warning — first try |
| 2 | Soft note: check whether the approach is sound |
| 3–4 | Warning: current approach may be stuck, reconsider root cause |
| 5+ | Hard stop: stop and ask for guidance |
| Regression | Immediate warning: "previously resolved but recurred — likely flip-flop" |
| Same diagnostic fingerprint | Pre-empts count: "different code, same failure — mental model likely wrong" |

The fingerprint signal is the most valuable early warning. `record_attempt(key, diagnostic)` hashes the raw diagnostic (test output, stack trace, error message) with `:erlang.phash2/1`. If the fingerprint matches the previous attempt — meaning a code change produced the exact same error — the AttemptLedger fires the "wrong mental model" warning immediately, before the count-based thresholds kick in. Different code producing the same error is strong evidence the root cause analysis is incorrect, not that the fix needs tweaking.

**Surgical Test Selection via `find_tests`**

When a function changes, the safest regression check isn't running the full suite — it's running the tests that actually exercise that function's callers. `find_tests` makes this precise:

1. Run `find_tests("function_name")` to get the inbound call chain (using `affected_by` BFS)
2. DirGraph filters the chain to nodes located in test/spec directories
3. Each result includes a ready-to-run command: `mix test file:line`, `npx jest --testPathPattern=...`, `pytest file::name`, etc.
4. Pass the command to `spawn_process`, then `read_output` to capture results
5. Feed the test output as the `diagnostic` to `record_attempt` — fingerprinting detects if the same failure recurs

This loop fits comfortably inside 3,000 tokens of LLM context and operates entirely through the MCP tool interface, with no file reads or shell escapes required beyond what DirGraph already manages.

---

## Areas for Improvement

These are known limitations that would need to be addressed for production use at scale.

### Vector search performance

The linear cosine scan (768-dim, pure Elixir) takes ~700 ms regardless of corpus size. For codebases over ~5,000 functions, this becomes noticeable. Options:

- **Nx + EXLA**: Batch matrix multiply for cosine similarity (BLAS-accelerated, 10-100x faster)
- **HNSWlib NIF**: Approximate nearest neighbor index (sub-millisecond at millions of vectors)
- **External ANN service**: Qdrant or Weaviate as sidecar (adds ops complexity)

### Language coverage

Currently supported out of the box: Elixir (full AST), JavaScript, TypeScript, JSX, TSX, Python, PHP, Ruby, Go, Rust, C, and C++ (all via LSP). Any language with an LSP server can be added via `.dir_graph/lsp_servers.json` with no code changes.

Known gaps:

- **CSS/HTML**: Different node model needed — selectors, component boundaries, not functions. A `Selector` node type with `STYLES` edges would require a separate indexer path.
- **CALLS edges for callers (incoming)**: `callHierarchy/incomingCalls` is not queried at index time because it requires a fully-resolved workspace view that single-file indexing can't reliably provide. Incoming callers are instead derived at query time from the accumulated outgoing CALLS edges across all indexed files — which is accurate once all files are indexed, but incomplete during partial indexing.
- **Type-level edges**: LSP `textDocument/typeDefinition` and `textDocument/implementation` could add richer type relationship edges for statically-typed languages (e.g. `IMPLEMENTS` edges from concrete types to interfaces in Go or TypeScript).

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
