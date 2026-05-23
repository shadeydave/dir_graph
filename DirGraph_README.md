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
| `query_code_graph` | Search for a concept by name. Returns a semantic slice with file + line per node. Supports `node_type` filter and `include_code` to embed source lines directly. |
| `affected_by` | Find everything that would break if a given node changes (inbound BFS). |
| `semantic_search` | Natural-language search via vector embeddings. Default `detail="pointer"` returns compact routing nodes (~200 tokens). Use `detail="full"` only when you need the expanded subgraph. |
| `workspace_stats` | Graph topology overview: node/edge counts by type, most-connected modules, embeddings coverage, watched dirs, and `capability_gaps` (missing LSP servers with install commands). |

#### Source read tools

These give surgical access to source lines without loading whole files. Use after `query_code_graph` identifies the node of interest.

| Tool | Description |
|---|---|
| `get_node_source` | Return the exact source lines (`line`–`end_line`) for a single graph node. Far cheaper than `Read` on the whole file. |
| `get_call_chain_source` | BFS-follow `CALLS` edges from a root node (up to `depth` hops), fetch source for each reachable project Function. Returns functions in BFS order. Skips stdlib and external stubs. |

#### Code mutation tools

| Tool | Description |
|---|---|
| `apply_diff` | Surgically mutate source files using graph node IDs as anchors. Actions: `replace` (single line), `replace_node` (full `line`–`end_line` range), `delete`, `insert_after`. Elixir files are syntax-checked before writing; graph is re-indexed on success. |

#### Graph management tools

| Tool | Description |
|---|---|
| `index_directory` | Index all source files in a directory recursively. Run once at session start. |
| `index_file` | Index a single source file into the current graph. |
| `load_graph` | Load a pre-compiled `.bin` graph (fast — use this at session start when a binary exists). |
| `save_graph` | Persist the current in-memory graph to a `.bin` file. |
| `sync_graph` | Diff the manifest against current disk state and re-index only changed files. Use after `load_graph` on a stale binary. |
| `watch_directory` | Start a filesystem watcher that keeps the graph live as files are saved. |
| `unwatch_directory` | Stop the watcher for a directory. |

#### Content node tools

Non-code nodes that survive graph rebuilds. Use these to attach business rules, copy, contracts, or domain concepts directly to implementation nodes.

| Tool | Description |
|---|---|
| `add_content_node` | Create a `BusinessRule`, `Copy`, `Contract`, or `Domain` node and link it via `IMPLEMENTS` edges. |
| `update_content_node` | Update content text and/or `IMPLEMENTS` links. All fields optional — only provided fields change. |
| `delete_content_node` | Remove a content node from the graph and persistent store. |
| `find_implementations` | Given a content node, return all code nodes it governs via `IMPLEMENTS` edges. |
| `list_content_nodes` | List all content nodes, optionally filtered by type. |

#### Process tools

Spawn and monitor long-running OS processes (build servers, test runners, dev servers) from within an MCP session.

| Tool | Description |
|---|---|
| `spawn_process` | Start a named OS process and begin buffering its output. Accepts `cwd` and `label` (shown in Activity Monitor). |
| `list_processes` | List all monitored processes with status and last output line. |
| `read_output` | Read the last N lines from a named process (ring buffer, max 500 lines). |
| `tail_output` | Return only lines produced since `cursor`. Use the returned `next_cursor` on each call to receive only new output — cost proportional to new lines only. |
| `stop_process` | Stop a managed process and remove it from the registry. |

⚠️ **Self-recompile caveat**: if DirGraph is the target project (i.e. you run `mix test` on the DirGraph repo itself via `spawn_process`), the test run recompiles and restarts the MCP server, closing the stdio connection. Use `mix test` directly for the DirGraph repo; `spawn_process` is safe for all other projects.

#### Attempt ledger tools

Tracks LLM mutation attempts per problem key to detect flip-flop loops and diagnostic regressions.

| Tool | Description |
|---|---|
| `record_attempt` | Record a fix attempt before each change. Accepts `diagnostic` (test output, error message) — fingerprinted against the previous attempt to detect "different code, same error" early. |
| `resolve_problem` | Mark a problem resolved. If it recurs later, `record_attempt` flags it as a regression. |
| `list_problems` | List all open problems sorted by attempt count — spot what is stuck. |
| `reset_ledger` | Clear all attempt history for the session. |

#### Test selection tools

| Tool | Description |
|---|---|
| `find_tests` | Inbound BFS (`affected_by`) filtered to test/spec directories. Returns each test's file, line, and a ready-to-run shell command (ExUnit, RSpec, Jest, pytest, PHPUnit, Go test). Note: tests that call the target via an intermediate public API (e.g. `Server.function_name`) are not surfaced — use depth=3 and query the intermediate node if needed. |

#### Dream tools

Dream is a background LLM enrichment engine that annotates every node in the graph with semantic metadata (summary, domain, tags, complexity) using a local LLM (default: Ollama).

| Tool | Description |
|---|---|
| `dream_status` | Check enrichment progress: queue depth, enriched count, errors, paused state. |
| `dream_enrich` | Force-enrich a specific node immediately, bypassing the queue. Returns: `summary`, `domain`, `tags`, `complexity`. Useful before `semantic_search` or when you need to understand a specific node right now. |

#### Visual collaboration tools

The DirGraph viewer is a React + XYFlow graph editor for negotiating architectural changes visually. Start it with `cd viewer && npm run dev`.

| Tool | Description |
|---|---|
| `export_to_viewer` | Export the current in-memory graph as JSON to `~/sites/diffs/{project}/` and open the viewer in the browser. Run `index_directory` first. |
| `submit_viewer_diff` | Append an AI-authored diff to the viewer's diff ledger. Viewer polls every 2 s — diff appears automatically with a notification badge. Supports `added_nodes`, `removed_nodes`, `added_edges`, `removed_edges`, `annotations`. |

#### Neo4j / cross-project tools

DirGraph can sync graphs to a dedicated Neo4j 5 container for persistent storage and cross-project semantic search. Start it with `docker compose up -d`.

| Tool | Description |
|---|---|
| `neo4j_health` | Check whether the DirGraph Neo4j container is running. Returns version, edition, and the exact `docker compose` command if unreachable. |
| `neo4j_setup_schema` | Initialize Neo4j schema: project constraints, AST node/edge indexes, and vector index. Idempotent — safe to run multiple times. Run once after starting a fresh container. |
| `cross_project_search` | Semantic search across **all** projects stored in Neo4j by vector similarity. Each result includes project name, node type/name, file, line, and similarity score. Use to find prior solutions across repos. |

#### Planning tools

| Tool | Description |
|---|---|
| `propose_session_plan` | Declare the minimum tools and paths needed for a task. Writes a draft for user review. The plan can only restrict the static allowlist, never expand it. |
| `approve_session_plan` | Activate the draft, restricting the session to declared scope. |
| `revoke_session_plan` | Clear the active plan and restore the full static allowlist. |

### Recommended workflow for Claude Code

At the start of any session on a project with a pre-built graph:

```
1. load_graph("/path/to/project.bin")       or   index_directory("/path/to/project")
2. workspace_stats()                     ← check calls_edges and capability_gaps first
3. dream_status()                        ← how many nodes are enriched (optional)
4. query_code_graph("login")             ← before reading any file
5. get_node_source("<node_id>")          ← read only that node's lines, not the whole file
```

If `workspace_stats` shows `calls_edges: 0` alongside Function nodes, call hierarchy
was not extracted. Check `capability_gaps` for the install command and offer to run it
via `spawn_process`. After installation, call `sync_graph` to rebuild with call data.

For exploratory queries where you don't know the exact name:

```
1. semantic_search("user authentication flow", top_k: 2)   ← keep top_k small (≤3)
2. query_code_graph("<returned node id>")                  ← BFS from the best seed
```

⚠️ `semantic_search` with `top_k ≥ 5` and `depth=2` can return 10,000+ tokens on a
real codebase — BFS from each seed multiplies the output. Prefer `top_k=2` for an
initial pass and follow up with `query_code_graph` on the best result.

When editing a function and wanting surgical regression coverage:

```
1. find_tests("function_name")                  ← get the minimal test set
2. spawn_process("tests", command)              ← run the targeted tests
3. tail_output("tests", cursor: 0)             ← stream output as it arrives
4. record_attempt("function_name", <output>)    ← fingerprint-tracked attempt
```

If `record_attempt` returns a `same_error` warning, the diagnostic fingerprint matched
the previous attempt — the root cause analysis is likely wrong. Re-read the `affected_by`
slice and reconsider before trying again.

When making a targeted code change:

```
1. query_code_graph("function_name")           ← get the node ID
2. get_node_source("<node_id>")               ← read current source (~50 tokens vs 10k+ for full file)
3. apply_diff(file_path, mutations)            ← mutate using node ID as anchor
4. index_file(file_path)                      ← re-index after the edit
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

## Dream — Background LLM Enrichment

Dream is a GenServer that runs in the background after every `index_directory` or `index_file`, annotating each graph node with semantic metadata using a local LLM.

For each node, Dream asks the LLM for:
- **`summary`** — one sentence describing what this function/module does
- **`domain`** — the business domain it belongs to (e.g. `"authentication"`, `"billing"`)
- **`tags`** — free-form semantic labels (`["validation", "idempotent", "side-effect-free"]`)
- **`complexity`** — an assessment of the implementation complexity

This metadata improves `semantic_search` quality: nodes with enriched summaries produce better embeddings, and the domain/tag fields allow future filtered search (e.g. "find all nodes tagged `rate-limiting`").

```
dream_status()
→ { dreaming: true, queue_depth: 601, enriched: 0, errors: 0, paused: false }

dream_enrich("Function:authenticate/2:L45:lib/auth.ex")
→ { summary: "Validates credentials and returns a session token or error.",
    domain: "authentication", tags: ["session", "security"], complexity: "low" }
```

Dream runs at low priority in the background — it does not block indexing or queries. The queue drains over the lifetime of a session. Check `workspace_stats` for `embeddings_ready` to see how many nodes have been embedded so far.

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
    "get_node_source",
    "get_call_chain_source",
    "apply_diff",
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
    "revoke_session_plan",
    "find_tests",
    "dream_status",
    "dream_enrich",
    "export_to_viewer",
    "submit_viewer_diff",
    "neo4j_health",
    "neo4j_setup_schema",
    "cross_project_search"
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
      dream.ex          — Background LLM enrichment engine: annotates nodes with summary,
                          domain, tags, complexity via local LLM (Ollama). Runs as a
                          GenServer; processes queue in the background after indexing.
      planner.ex        — Scaffolds new graphs from JSON plan definitions
      embeddings.ex     — HTTP client for Ollama / OpenAI embedding backends
      vector_store.ex   — ETS-backed cosine similarity store
      rag.ex            — GraphRAG orchestration: index nodes, semantic search
      neo4j.ex          — Neo4j 5 Bolt client: dual-writes graph nodes/edges on index,
                          stores embeddings as vector properties, exposes semantic_search
                          across all persisted projects (cross_project_search)
      content_store.ex  — Persists content nodes to JSON, survives graph rebuilds
      attempt_ledger.ex — Tracks repeated LLM mutation attempts to detect flip-flop loops
      process_monitor.ex — Spawns and monitors OS processes; ring-buffers stdout/stderr;
                           tail_output implements a cursor-based poll for streaming output
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

### DirGraph vs stock Claude Code tools — token usage

Measured against the DirGraph codebase itself (2,194 nodes, 2,181 edges, `analyzer.ex` at ~10,000 tokens):

| Query | Tool | Output (chars) | Est. tokens | Notes |
|---|---|---|---|---|
| Known function — structural context | `query_code_graph("extract_slice", depth=2)` | ~6,200 | ~1,550 | 24 nodes, full call graph, one call |
| Known function — source only | `get_node_source("<node_id>")` | ~300 | ~75 | Exact lines only, no call graph |
| Known function — call chain source | `get_call_chain_source("<node_id>", depth=2)` | ~2,000–4,000 | ~500–1,000 | Source for root + all callees |
| Known function — stock approach | Grep on specific file + `Read` with offset | ~200 | ~50 | Surgical, but no call graph context |
| Impact analysis | `affected_by("index_directory")` | ~1,100 | ~275 | 3 nodes for single-caller case |
| Full file | `Read("analyzer.ex")` | >40,000 | >10,000 | Hit token limit; not possible |
| Unknown concept — pointer (new default) | `semantic_search("authentication", top_k=5)` | **~800** | **~200** | Routing pointers + Dream summaries; follow up with query_code_graph |
| Unknown concept — full (explicit) | `semantic_search("authentication", top_k=3, detail="full")` | 121,377 | ~30,000 | BFS expansion; use only when you need the whole subgraph |
| Unknown concept — stock approach | Grep project + Read (3–5 calls) | ~3,000–8,000 | ~750–2,000 | Multiple calls; no graph structure |

**Key takeaways:**

- `semantic_search` (pointer mode) is now the cheapest entry point for unknown-concept queries — ~200 tokens to get routing nodes, then follow up with `query_code_graph` or `get_node_source` on the best match.
- `get_node_source` is the most token-efficient way to read code when you have a node ID — ~75 tokens vs >10,000 for a full file `Read`. Always prefer it over `Read` once you have a node ID.
- `query_code_graph` is the right default for "I need structural context on X" — one call gives you the call graph, callers, and file/line for every related node.
- `affected_by` is naturally bounded — its size reflects the real blast radius. A small return means low blast radius, not a missing result.
- `semantic_search detail="full"` can still exceed 120,000 chars — it's now an explicit opt-in, not the default. See the [Call node noise](#call-node-noise-in-slice-output-next-priority) improvement for why full-mode slices are still larger than they need to be.

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

Ranked by impact on "works well regardless of codebase size."

### ✅ `semantic_search` output explosion — resolved 2026-03-24

**Was:** default `semantic_search(top_k=3, depth=2)` → 89,000–121,000 chars (~22,000–30,000 tokens). BFS expansion from K seeds was uncapped.

**Fix:** tiered `detail` parameter. `"pointer"` (new default) skips BFS entirely and returns compact routing nodes with Dream summaries — ~800 chars / ~200 tokens. `"full"` preserves the original BFS behavior for cases where you explicitly want the expanded subgraph.

**Remaining:** `detail="full"` still produces 120,000+ chars with `top_k=3`. Cap `top_k ≤ 2` if using full mode.

---

### ✅ Call node noise in slice output — resolved 2026-03-24

**Was:** Call nodes were **70% of the graph** (1,548 of 2,211 on the DirGraph codebase). They represent call *sites* — the specific line where a function is invoked. Example: `Call:Keyword.get:L336:lib/neo4j.ex`. They are not actionable and their information is already present on the parent Function node via the `calls: []` onion-skin array. At depth=2 on a large codebase, hundreds of Call stubs could appear in a single slice.

**Fix:** `filter_calls: true` default in `format_for_llm`. Call nodes are dropped and edges where either endpoint is a Call node are filtered. Expose `include_calls: true` opt-in via `query_code_graph` for cases where exact call-site line numbers matter.

**Measured impact:** `query_code_graph("extract_slice")` dropped from 26 nodes → 23 nodes. `DirGraph.Server` module query: 0 Call nodes in 63-node result. Verified live 2026-03-24.

---

### ✅ Absolute paths in formatted output — resolved 2026-03-24

**Was:** every node in `format_for_llm` output carried the full absolute file path in the `file` field. In a 24-node slice with 23 edges, the cwd prefix repeated ~47 times = ~3,100 chars of pure overhead.

**Fix:** `Path.relative_to_cwd/1` applied to the `file` field in `format_for_llm`. Node IDs remain absolute (stable keys for `get_node_source`, `apply_diff`). Output now shows `lib/dir_graph/analyzer.ex` instead of `/Users/codesquid/sites/squid_tools/dir_graph/lib/dir_graph/analyzer.ex`.

**Measured impact:** ~20–25% reduction on typical slice output. Verified live 2026-03-24.

---

### ✅ Hub node BFS explosion — resolved 2026-03-24

**Was:** no degree check before BFS expansion. A hub node (`DirGraph.Server`, degree 62) at depth=2 would pull in essentially the entire graph.

**Fix:** `@hub_degree_threshold 30` guard in `Server.extract_slice`. If seed degree > 30 and requested depth > 1, auto-caps to depth=1 and adds `_hub_warning` to the payload. Verified live: `query_code_graph("DirGraph.Server")` triggers the guard (degree 65 > 30), returns 63 nodes with warning instead of thousands. Threshold is a module attribute — move to `mcp_config.json` if tuning is needed.

---

### Vector search performance ceiling

**Impact: critical above ~10k nodes. Effort: medium.**

The VectorStore is a pure-Elixir linear scan — cosine similarity computed sequentially across every stored vector. Measured at ~700ms for 2,191 vectors (768-dim). This is nearly flat up to ~5k vectors, then climbs:

| Corpus size | Estimated query time |
|---|---|
| 2,000 nodes | ~700 ms (measured) |
| 10,000 nodes | ~3.5 s |
| 50,000 nodes | ~18 s |
| 200,000 nodes | ~70 s |

At 50k nodes (a mid-size production monorepo), `semantic_search` becomes unusable.

**Fix options:**
- **Nx + EXLA**: batch matrix multiply for cosine similarity — BLAS-accelerated, ~10–100x faster. Keeps everything in-process.
- **HNSWlib NIF**: approximate nearest neighbor index — sub-millisecond at millions of vectors.
- **External ANN service**: Qdrant or Weaviate as sidecar (adds ops complexity but supports billion-scale).

---

### ✅ `semantic_search` pointer quality without Dream enrichment — resolved 2026-03-24

**Was:** when Dream had not yet enriched a node, the pointer response carried only `name`, `type`, `file`, `line`, and `score`. No content signal — just names and similarity scores.

**Fix:** when `EnrichmentStore.get(node_id)` returns `nil` in pointer mode, fall back to the first ~100 chars of the function's source as a `preview` field (`source_preview/2` in `Server`). Costs one `File.read` slice per pointer. Gives the LLM routing signal without requiring Dream enrichment.

---

### Dream enrichment queue priority

**Impact: medium. Effort: low.**

Dream processes the enrichment queue in FIFO order. On a large codebase (50k+ nodes), the most-queried functions may be near the end of the queue and remain unenriched for hours. The semantic search pointer quality stays poor until those nodes are covered.

**Fix:** weight the queue by query frequency. Every `query_code_graph` or `get_node_source` call on a node increments a hot-counter in the Server state. Dream's tick callback sorts its batch by hot-counter descending before dispatching. Nodes you actually touch get enriched first; background nodes fill in later.

---

### Incremental LSP indexing

**Impact: medium at scale. Effort: high.**

`watch_directory` re-indexes the entire file on any change. For large files and slow LSP servers this is noticeable. True incremental indexing would:

1. Remove only the nodes belonging to the changed file
2. Re-parse and re-insert just that file's nodes
3. Re-resolve cross-file edges (the hard part)

This would make the watcher practical for large codebases where a full re-index takes seconds. The manifest + CONTAINS edge structure already supports step 1; the difficulty is step 3, since other files may hold CALLS edges into the changed file's nodes.

---

### Multi-project federated graph

Currently one graph per server instance. A workspace with multiple repos (monorepo or microservices mesh) would benefit from a federated graph where cross-service CALLS edges are tracked across graph boundaries. The string-ID vertex model already supports this — it just needs a loader that can merge graphs without collision. Neo4j persistence is already multi-project; the in-memory graph layer is not.

---

### Language coverage

Currently supported out of the box: Elixir (full AST), JavaScript, TypeScript, JSX, TSX, Python, PHP, Ruby, Go, Rust, C, and C++ (all via LSP). Any language with an LSP server can be added via `.dir_graph/lsp_servers.json` with no code changes.

Known gaps:

- **CSS/HTML**: Different node model needed — selectors, component boundaries, not functions. A `Selector` node type with `STYLES` edges would require a separate indexer path.
- **CALLS edges for callers (incoming)**: `callHierarchy/incomingCalls` is not queried at index time because it requires a fully-resolved workspace view that single-file indexing can't reliably provide. Incoming callers are instead derived at query time from the accumulated outgoing CALLS edges across all indexed files — which is accurate once all files are indexed, but incomplete during partial indexing.
- **Type-level edges**: LSP `textDocument/typeDefinition` and `textDocument/implementation` could add richer type relationship edges for statically-typed languages (e.g. `IMPLEMENTS` edges from concrete types to interfaces in Go or TypeScript).


### Multi-project graphs

Currently one graph per server instance. A workspace with multiple repos (a monorepo or a microservices mesh) would benefit from a federated graph where cross-service `CALLS` edges are tracked across graph boundaries. The string-ID vertex model already supports this — it just needs a loader that can merge graphs without collision.

### LLM-native output formats

`format_for_llm` currently produces generic JSON. Adapter layers for specific LLM APIs (Anthropic tool results, OpenAI function call returns) would let the server speak each model's native schema, reducing prompt engineering on the consumer side.

### Authentication for MCP

The MCP server runs over stdio with no authentication. For shared team use (e.g. a server shared across a development team), an auth layer and per-user session plans would be needed.

---

## Development Workflow

### Picking up code changes in the MCP server

The MCP server is a long-running BEAM process. After editing source files, `mix compile` updates the `.beam` files on disk but the running process has old module code in memory. Use `reload_code` to hot-load the changes without restarting:

```bash
# 1. Edit source files
# 2. Compile (in a separate terminal — NOT via spawn_process on this repo)
mix compile

# 3. Hot-reload into the running server (via MCP tool call)
reload_code   # reloads Analyzer, Server, Handler, Allowlist

# 4. Re-index so new indexer/graph logic takes effect
index_directory /path/to/project
```

> **Warning:** do not use `spawn_process("mix test")` or `spawn_process("mix compile")` on the DirGraph repo itself. Recompiling Elixir code in the same OS process that owns the stdio MCP connection will kill the server. Run `mix test` and `mix compile` in a separate terminal.

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
