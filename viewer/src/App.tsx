import { useCallback, useEffect, useRef, useState, useMemo } from 'react';
import {
  ReactFlow,
  Controls,
  Background,
  useNodesState,
  useEdgesState,
  addEdge,
  MarkerType,
  type Connection,
  type Edge as FlowEdge,
  type Node as FlowNode,
  type NodeChange,
  type EdgeChange,
} from '@xyflow/react';
import '@xyflow/react/dist/style.css';
import './index.css';

import { getLayoutedElements } from './utils/layout';
import GraphNode from './components/GraphNode';
import type { ASTData, ASTNode, ASTEdge, Diff, DiffLedger } from './types';

// ─── constants ───────────────────────────────────────────────────────────────

const EDGE_DEFAULTS = {
  animated: true,
  style: { stroke: '#58a6ff', strokeWidth: 2 },
  labelStyle: { fill: '#8b949e', fontWeight: 600, fontSize: 12, fontFamily: 'Fira Code' },
  labelBgStyle: { fill: '#0d1117' },
  labelBgBorderRadius: 4,
  markerEnd: { type: MarkerType.ArrowClosed, color: '#58a6ff' },
};

const nodeTypes = { custom: GraphNode };

// ─── diff helpers ─────────────────────────────────────────────────────────────

function edgeKey(e: ASTEdge): string {
  return `${e.source}→${e.target}:${e.rel}`;
}

function applyDiffs(
  base: ASTData,
  diffs: Diff[],
  upToDiffId: number | null,
): { nodes: ASTNode[]; edges: ASTEdge[] } {
  let nodes = [...base.nodes];
  let edges = [...base.edges];
  const toApply = upToDiffId === null ? diffs : diffs.filter(d => d.diff_id <= upToDiffId);

  for (const diff of toApply) {
    const removedNodeSet = new Set(diff.removed_nodes);
    nodes = nodes.filter(n => !removedNodeSet.has(n.id)).concat(diff.added_nodes);

    const removedEdgeSet = new Set(diff.removed_edges.map(edgeKey));
    edges = edges.filter(e => !removedEdgeSet.has(edgeKey(e))).concat(diff.added_edges);
  }

  return { nodes, edges };
}

// Computes which node IDs were added/removed between two diff states.
function diffOverlay(
  prev: { nodes: ASTNode[] },
  curr: { nodes: ASTNode[] },
): Map<string, 'added' | 'removed'> {
  const overlay = new Map<string, 'added' | 'removed'>();
  const prevIds = new Set(prev.nodes.map(n => n.id));
  const currIds = new Set(curr.nodes.map(n => n.id));
  curr.nodes.forEach(n => { if (!prevIds.has(n.id)) overlay.set(n.id, 'added'); });
  prev.nodes.forEach(n => { if (!currIds.has(n.id)) overlay.set(n.id, 'removed'); });
  return overlay;
}

// ─── XYFlow conversion ────────────────────────────────────────────────────────

function toFlowNodes(
  nodes: ASTNode[],
  overlay?: Map<string, 'added' | 'removed'>,
): FlowNode[] {
  return nodes.map(n => ({
    id: n.id,
    type: 'custom',
    data: { ...n, diffStatus: overlay?.get(n.id) },
    position: { x: 0, y: 0 },
  }));
}

function toFlowEdges(edges: ASTEdge[]): FlowEdge[] {
  return edges.map((e, i) => ({
    id: `e${i}-${e.source}-${e.target}-${e.rel}`,
    source: e.source,
    target: e.target,
    label: e.rel,
    ...EDGE_DEFAULTS,
  }));
}

function layoutGraph(nodes: ASTNode[], edges: ASTEdge[], overlay?: Map<string, 'added' | 'removed'>) {
  const { nodes: ln, edges: le } = getLayoutedElements(
    toFlowNodes(nodes, overlay),
    toFlowEdges(edges),
  );
  return { flowNodes: ln, flowEdges: le };
}

// ─── component ───────────────────────────────────────────────────────────────

export default function App() {
  const initialProject = new URLSearchParams(window.location.search).get('project') ?? '';

  const [projects, setProjects]       = useState<string[]>([]);
  const [project,  setProject]        = useState(initialProject);
  const [baseAST,  setBaseAST]        = useState<ASTData | null>(null);
  const [ledger,   setLedger]         = useState<DiffLedger | null>(null);
  const [viewDiffId, setViewDiffId]   = useState<number | null>(null); // null = latest
  const [hasNewAIDiff, setHasNewAIDiff] = useState(false);

  // Add-node modal state
  const [showAddNode,  setShowAddNode]  = useState(false);
  const [newNodeType,  setNewNodeType]  = useState('Function');
  const [newNodeName,  setNewNodeName]  = useState('');

  const [nodes, setNodes, onNodesChange] = useNodesState<FlowNode>([]);
  const [edges, setEdges, onEdgesChange] = useEdgesState<FlowEdge>([]);

  // Tracks the last-committed graph state so submit can compute a clean diff.
  const committedRef   = useRef<{ nodes: ASTNode[]; edges: ASTEdge[] }>({ nodes: [], edges: [] });
  // Tracks whether the canvas has uncommitted user changes.
  const isDirtyRef     = useRef(false);
  const lastDiffCount  = useRef(0);

  const isHistoryMode = viewDiffId !== null;
  const showPublish   = ledger !== null && ledger.diffs.some(d => d.author === 'ai');

  // ── fetch project list ────────────────────────────────────────────────────
  useEffect(() => {
    fetch('/api/projects')
      .then(r => r.json())
      .then(setProjects)
      .catch(() => {});
  }, []);

  // ── load AST + ledger when project changes ────────────────────────────────
  useEffect(() => {
    if (!project) return;
    isDirtyRef.current = false;
    setViewDiffId(null);
    setHasNewAIDiff(false);

    Promise.all([
      fetch(`/api/diffs/${project}/ast`).then(r => r.json()),
      fetch(`/api/diffs/${project}/ledger`).then(r => r.json()),
    ])
      .then(([ast, ldgr]: [ASTData, DiffLedger]) => {
        setBaseAST(ast);
        setLedger(ldgr);
        lastDiffCount.current = ldgr.diffs.length;

        const committed = applyDiffs(ast, ldgr.diffs, null);
        committedRef.current = committed;

        const { flowNodes, flowEdges } = layoutGraph(committed.nodes, committed.edges);
        setNodes(flowNodes);
        setEdges(flowEdges);
      })
      .catch(() => {});
  }, [project]); // eslint-disable-line react-hooks/exhaustive-deps

  // ── poll for new diffs every 2 s ─────────────────────────────────────────
  useEffect(() => {
    if (!project || !baseAST) return;

    const interval = setInterval(() => {
      fetch(`/api/diffs/${project}/ledger`, { headers: { 'Cache-Control': 'no-cache' } })
        .then(r => r.json())
        .then((ldgr: DiffLedger) => {
          if (ldgr.diffs.length <= lastDiffCount.current) return;

          const newDiffs = ldgr.diffs.slice(lastDiffCount.current);
          lastDiffCount.current = ldgr.diffs.length;
          setLedger(ldgr);

          // Update committed ref silently so submit diff is always clean.
          committedRef.current = applyDiffs(baseAST, ldgr.diffs, null);

          if (newDiffs.some(d => d.author === 'ai')) {
            setHasNewAIDiff(true);

            // Auto-update canvas only when user hasn't made uncommitted edits.
            if (!isDirtyRef.current && !isHistoryMode) {
              const { flowNodes, flowEdges } = layoutGraph(committedRef.current.nodes, committedRef.current.edges);
              setNodes(flowNodes);
              setEdges(flowEdges);
            }
          }
        })
        .catch(() => {});
    }, 2000);

    return () => clearInterval(interval);
  }, [project, baseAST, isHistoryMode]); // eslint-disable-line react-hooks/exhaustive-deps

  // ── diff navigation ───────────────────────────────────────────────────────
  const handleDiffSelect = useCallback((value: string) => {
    if (!baseAST || !ledger) return;

    const diffId = value === 'latest' ? null : Number(value);
    setViewDiffId(diffId);
    setHasNewAIDiff(false);

    if (diffId === null) {
      // Back to latest committed state — refresh canvas
      const committed = applyDiffs(baseAST, ledger.diffs, null);
      committedRef.current = committed;
      isDirtyRef.current = false;
      const { flowNodes, flowEdges } = layoutGraph(committed.nodes, committed.edges);
      setNodes(flowNodes);
      setEdges(flowEdges);
    } else {
      // Historical view with red/green overlay vs parent diff
      const currState = applyDiffs(baseAST, ledger.diffs, diffId);
      const diff = ledger.diffs.find(d => d.diff_id === diffId);
      let overlay: Map<string, 'added' | 'removed'> | undefined;
      let displayNodes = currState.nodes;

      if (diff) {
        const prevState = applyDiffs(baseAST, ledger.diffs, diff.parent_diff_id);
        overlay = diffOverlay(prevState, currState);
        // Show ghost nodes for items removed in this diff
        const ghosts = prevState.nodes.filter(n => overlay!.get(n.id) === 'removed');
        displayNodes = [...currState.nodes, ...ghosts];
      }

      const { flowNodes, flowEdges } = layoutGraph(displayNodes, currState.edges, overlay);
      setNodes(flowNodes);
      setEdges(flowEdges);
    }
  }, [baseAST, ledger, setNodes, setEdges]);

  // ── dirty tracking ────────────────────────────────────────────────────────
  const handleNodesChange = useCallback((changes: NodeChange[]) => {
    if (changes.some(c => c.type === 'remove')) isDirtyRef.current = true;
    onNodesChange(changes);
  }, [onNodesChange]);

  const handleEdgesChange = useCallback((changes: EdgeChange[]) => {
    if (changes.some(c => c.type !== 'select')) isDirtyRef.current = true;
    onEdgesChange(changes);
  }, [onEdgesChange]);

  const onConnect = useCallback((params: Connection | FlowEdge) => {
    isDirtyRef.current = true;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    setEdges(eds => addEdge({ ...params, label: 'CALLS', ...EDGE_DEFAULTS } as any, eds));
  }, [setEdges]);

  // ── add node ──────────────────────────────────────────────────────────────
  const handleAddNode = useCallback(() => {
    if (!newNodeName.trim()) return;
    const id = `Scratch:${newNodeType}:${newNodeName.trim()}`;
    const newNode: FlowNode = {
      id,
      type: 'custom',
      data: { id, type: newNodeType, name: newNodeName.trim(), file: '', line: 0 },
      position: { x: 200 + Math.random() * 200, y: 200 + Math.random() * 200 },
    };
    isDirtyRef.current = true;
    setNodes(nds => [...nds, newNode]);
    setNewNodeName('');
    setShowAddNode(false);
  }, [newNodeType, newNodeName, setNodes]);

  // ── submit diff ───────────────────────────────────────────────────────────
  const handleSubmit = useCallback(async () => {
    if (!project || !ledger || !baseAST) return;

    const committed = committedRef.current;
    const latestDiff = ledger.diffs[ledger.diffs.length - 1];
    const nextId = (latestDiff?.diff_id ?? 0) + 1;

    const committedNodeIds = new Set(committed.nodes.map(n => n.id));
    const currentNodeIds   = new Set(nodes.map(n => n.id));

    const addedNodes: ASTNode[] = nodes
      .filter(n => !committedNodeIds.has(n.id))
      .map(n => n.data as unknown as ASTNode);

    const removedNodeIds = committed.nodes
      .filter(n => !currentNodeIds.has(n.id))
      .map(n => n.id);

    const currentEdgesAST: ASTEdge[] = edges.map(e => ({
      source: e.source,
      target: e.target,
      rel: (e.label ?? 'CALLS') as string,
    }));

    const committedEdgeKeys = new Set(committed.edges.map(edgeKey));
    const currentEdgeKeys   = new Set(currentEdgesAST.map(edgeKey));

    const addedEdges   = currentEdgesAST.filter(e => !committedEdgeKeys.has(edgeKey(e)));
    const removedEdges = committed.edges.filter(e => !currentEdgeKeys.has(edgeKey(e)));

    const diff: Diff = {
      diff_id:        nextId,
      parent_diff_id: latestDiff?.diff_id ?? null,
      author:         'user',
      timestamp:      new Date().toISOString(),
      label:          `User edit #${nextId}`,
      added_nodes:    addedNodes,
      removed_nodes:  removedNodeIds,
      added_edges:    addedEdges,
      removed_edges:  removedEdges,
      annotations:    [],
    };

    await fetch(`/api/diffs/${project}/submit`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(diff),
    });

    // Reload ledger and reset canvas to new committed state
    const ldgr: DiffLedger = await fetch(`/api/diffs/${project}/ledger`).then(r => r.json());
    setLedger(ldgr);
    lastDiffCount.current = ldgr.diffs.length;
    setViewDiffId(null);
    setHasNewAIDiff(false);
    isDirtyRef.current = false;

    const newCommitted = applyDiffs(baseAST, ldgr.diffs, null);
    committedRef.current = newCommitted;
    const { flowNodes, flowEdges } = layoutGraph(newCommitted.nodes, newCommitted.edges);
    setNodes(flowNodes);
    setEdges(flowEdges);
  }, [project, ledger, baseAST, nodes, edges, setNodes, setEdges]);

  // ── publish ───────────────────────────────────────────────────────────────
  const handlePublish = useCallback(async () => {
    if (!project || !ledger) return;
    const latestDiff = ledger.diffs[ledger.diffs.length - 1];
    const publishDiff: Diff = {
      diff_id:        (latestDiff?.diff_id ?? 0) + 1,
      parent_diff_id: latestDiff?.diff_id ?? null,
      author:         'user',
      timestamp:      new Date().toISOString(),
      label:          'Publish',
      added_nodes:    [],
      removed_nodes:  [],
      added_edges:    [],
      removed_edges:  [],
      annotations:    [{ id: 'publish', body: 'Publish: generate code from this graph state.', targets: [], diff_id: 0 }],
    };
    await fetch(`/api/diffs/${project}/submit`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(publishDiff),
    });
  }, [project, ledger]);

  // ── diff label helper ─────────────────────────────────────────────────────
  const diffLabel = useMemo(() => (d: { author: string; label: string }) =>
    `${d.author === 'ai' ? '🤖' : '👤'} ${d.label}`,
  []);

  // ─────────────────────────────────────────────────────────────────────────

  return (
    <div className="app-root">
      {/* ── toolbar ── */}
      <div className="toolbar">
        <span className="app-title">DirGraph Viewer</span>

        <select
          className="select"
          value={project}
          onChange={e => setProject(e.target.value)}
        >
          <option value="">— select project —</option>
          {projects.map(p => <option key={p} value={p}>{p}</option>)}
        </select>

        {ledger && (
          <select
            className={`select${hasNewAIDiff ? ' select--pulse' : ''}`}
            value={viewDiffId ?? 'latest'}
            onChange={e => handleDiffSelect(e.target.value)}
          >
            <option value="latest">
              Latest{hasNewAIDiff ? ' 🔵' : ''}
            </option>
            {ledger.diffs.map(d => (
              <option key={d.diff_id} value={d.diff_id}>
                #{d.diff_id} {diffLabel(d)}
              </option>
            ))}
          </select>
        )}

        {isHistoryMode && (
          <button className="btn btn--ghost" onClick={() => handleDiffSelect('latest')}>
            ← Latest
          </button>
        )}

        <div style={{ flex: 1 }} />

        {!isHistoryMode && (
          <>
            <button className="btn btn--ghost" onClick={() => setShowAddNode(true)}>
              + Node
            </button>
            <button
              className="btn btn--primary"
              onClick={handleSubmit}
              disabled={!baseAST}
            >
              Submit
            </button>
            {showPublish && (
              <button className="btn btn--publish" onClick={handlePublish}>
                Publish Changes
              </button>
            )}
          </>
        )}

        {isHistoryMode && (
          <span className="toolbar-badge">Viewing diff #{viewDiffId} — read only</span>
        )}
      </div>

      {/* ── canvas ── */}
      <div className="canvas-wrap">
        <ReactFlow
          nodes={nodes}
          edges={edges}
          onNodesChange={isHistoryMode ? undefined : handleNodesChange}
          onEdgesChange={isHistoryMode ? undefined : handleEdgesChange}
          onConnect={isHistoryMode ? undefined : onConnect}
          nodesDraggable={!isHistoryMode}
          nodesConnectable={!isHistoryMode}
          elementsSelectable={!isHistoryMode}
          nodeTypes={nodeTypes}
          deleteKeyCode={['Backspace', 'Delete']}
          fitView
          colorMode="dark"
          minZoom={0.05}
        >
          <Controls />
          <Background color="#30363d" gap={20} size={2} />
        </ReactFlow>
      </div>

      {/* ── add node modal ── */}
      {showAddNode && (
        <div className="modal-overlay" onClick={() => setShowAddNode(false)}>
          <div className="modal" onClick={e => e.stopPropagation()}>
            <h3 className="modal-title">Add Node</h3>
            <select
              className="select select--full"
              value={newNodeType}
              onChange={e => setNewNodeType(e.target.value)}
            >
              {['Module', 'Function', 'Class', 'File', 'Annotation'].map(t => (
                <option key={t} value={t}>{t}</option>
              ))}
            </select>
            <input
              className="input"
              placeholder="Node name"
              value={newNodeName}
              onChange={e => setNewNodeName(e.target.value)}
              onKeyDown={e => e.key === 'Enter' && handleAddNode()}
              autoFocus
            />
            <div className="modal-actions">
              <button className="btn btn--ghost" onClick={() => setShowAddNode(false)}>Cancel</button>
              <button className="btn btn--primary" onClick={handleAddNode}>Add</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
