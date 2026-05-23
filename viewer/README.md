# DirGraph Visualizer & Collaboration Canvas

The **DirGraph Viewer** is a visual collaborative editing layer for negotiating architectural and code property changes between you and an agentic AI. Built with React 19, TypeScript, XYFlow, and Dagre layouts, it provides a beautiful, interactive node graph representation of your codebase.

---

## 🎨 Key Features

1. **Interactive Architectural Views**: View files, modules, classes, and business rules as nodes in a rich, hierarchical, force-directed graph.
2. **Automated Layouts**: Automatically positions nodes cleanly using the Dagre layout engine.
3. **Architectural Diff Negotiator**:
   - Drag edges, delete nodes, or insert new nodes directly onto the canvas.
   - Click **Submit** to compile a delta diff between your workspace state and your proposed modifications.
   - The diff is recorded to a local ledger (`diff_ledger.json`) that can be consumed directly by LLMs to drive safe code generation.
4. **Real-time Synchronization**:
   - Canvas is automatically updated and colored (added nodes = green border, removed nodes = red ghost node).
   - Polls every 2 seconds for incoming AI revisions or reviews, displaying notification badges.
5. **Standalone Electron App Wrapper**: Ships with optional Electron bundling configurations so it can be packaged and run as a standalone desktop utility on macOS, Windows, or Linux.

---

## 🏗️ Architecture

```
                  ┌──────────────────────┐
                  │   Elixir Indexer     │
                  └──────────┬───────────┘
                             │ (export_to_viewer)
                             ▼
                  ┌──────────────────────┐
                  │    full_ast.json     │
                  └──────────┬───────────┘
                             │
                             ▼
  ┌──────────────────────────────────────────────────────┐
  │                   Vite Dev Server                    │
  │     (Custom middleware API serving /api/diffs/*)     │
  └──────────────────────────┬───────────────────────────┘
                             │
                             ▼
  ┌──────────────────────────────────────────────────────┐
  │                 XYFlow Canvas UI                     │
  │           (React 19 + Dagre Layouts)                 │
  └──────────────────────────────────────────────────────┘
```

The viewer operates as a local static-site client that communicates with custom middleware injected into the Vite Dev Server (defined in `vite.config.ts`).
- **`GET /api/projects`**: Lists available indexed directories.
- **`GET /api/diffs/:project/ast`**: Serves the exported static graph `full_ast.json`.
- **`GET /api/diffs/:project/ledger`**: Serves the collaborative history ledger `diff_ledger.json`.
- **`POST /api/diffs/:project/submit`**: Appends a user/AI architectural graph diff to the ledger.

---

## ⚙️ Environment Configuration

By default, the Vite server and the Elixir backend look for project AST files under `~/sites/diffs/`. You can customize this directory globally by defining the environment variable `DIRGRAPH_DIFFS_DIR` before running the servers:

```bash
export DIRGRAPH_DIFFS_DIR="/path/to/your/custom/diffs/folder"
```

---

## 🚀 Getting Started

### 1. Installation

Ensure you have Node.js and npm installed, then fetch package dependencies:

```bash
npm install
```

### 2. Launch Local Dev Server

Start the interactive developer visualizer (accessible at `http://localhost:5173`):

```bash
npm run dev
```

### 3. Build & Compile

To build a minimized, production-ready bundle of the static visualizer client:

```bash
npm run build
```

---

## 🖥️ Standalone Desktop App (Electron)

If you prefer to run the visualizer as a native desktop application, use the concurrently configured Electron dev/builder commands:

```bash
# Run Electron and Vite in simultaneous dev mode
npm run electron:dev

# Pack and bundle installers for your current platform
npm run electron:build

# Target specific operating systems
npm run electron:build:mac
npm run electron:build:win
npm run electron:build:linux
```
