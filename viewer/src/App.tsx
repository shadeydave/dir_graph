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
  type Viewport,
} from '@xyflow/react';
import '@xyflow/react/dist/style.css';
import './index.css';

import { getLayoutedElements } from './utils/layout';
import GraphNode from './components/GraphNode';
import type { ASTData, ASTNode, ASTEdge, Diff, DiffLedger } from './types';

// ─── edge type visual system ──────────────────────────────────────────────────

type EdgeStyle = { color: string; weight: number; animated: boolean; dash?: string };

const EDGE_STYLES: Record<string, EdgeStyle> = {
  CONTAINS:   { color: '#6e7681', weight: 1,   animated: false },
  DEFINES:    { color: '#58a6ff', weight: 2,   animated: false },
  CALLS:      { color: '#3fb950', weight: 2,   animated: true  },
  IMPORTS:    { color: '#e3b341', weight: 1.5, animated: true  },
  USES:       { color: '#bc8cff', weight: 1.5, animated: false },
  REQUIRES:   { color: '#f85149', weight: 2,   animated: true  },
  IMPLEMENTS: { color: '#39d353', weight: 1.5, animated: false, dash: '6 3' },
};
const FALLBACK_EDGE: EdgeStyle = { color: '#8b949e', weight: 1, animated: false };

// ─── LOD zoom thresholds ──────────────────────────────────────────────────────

const LOD: Array<{ minZoom: number; types: Set<string> }> = [
  { minZoom: 0,    types: new Set(['File']) },
  { minZoom: 0.15, types: new Set(['File', 'Module']) },
  { minZoom: 0.35, types: new Set(['File', 'Module', 'Class', 'BusinessRule', 'Copy', 'Contract', 'Domain']) },
];

function lodTypesForZoom(zoom: number): Set<string> {
  let result = LOD[0].types;
  for (const level of LOD) { if (zoom >= level.minZoom) result = level.types; }
  return result;
}

const nodeTypes = { custom: GraphNode };

// ─── diff helpers ─────────────────────────────────────────────────────────────

function edgeKey(e: ASTEdge): string { return `${e.source}→${e.target}:${e.rel}`; }

function applyDiffs(base: ASTData, diffs: Diff[], upToDiffId: number | null) {
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

function diffOverlay(prev: { nodes: ASTNode[] }, curr: { nodes: ASTNode[] }) {
  const overlay = new Map<string, 'added' | 'removed'>();
  const prevIds = new Set(prev.nodes.map(n => n.id));
  const currIds = new Set(curr.nodes.map(n => n.id));
  curr.nodes.forEach(n => { if (!prevIds.has(n.id)) overlay.set(n.id, 'added'); });
  prev.nodes.forEach(n => { if (!currIds.has(n.id)) overlay.set(n.id, 'removed'); });
  return overlay;
}

// ─── XYFlow conversion ────────────────────────────────────────────────────────
// These run ONCE per topology change (Dagre). Visibility is handled separately.

function toFlowNodes(nodes: ASTNode[], overlay?: Map<string, 'added' | 'removed'>): FlowNode[] {
  return nodes.map(n => ({
    id: n.id,
    type: 'custom',
    data: { ...n, diffStatus: overlay?.get(n.id) },
    position: { x: 0, y: 0 },
    hidden: false,
  }));
}

function toFlowEdges(edges: ASTEdge[]): FlowEdge[] {
  return edges.map((e, i) => {
    const s = EDGE_STYLES[e.rel] ?? FALLBACK_EDGE;
    return {
      id: `e${i}-${e.source}-${e.target}-${e.rel}`,
      source: e.source,
      target: e.target,
      label: e.rel,
      animated: s.animated,
      hidden: false,
      style: { stroke: s.color, strokeWidth: s.weight, strokeDasharray: s.dash },
      labelStyle: { fill: s.color, fontWeight: 600, fontSize: 11, fontFamily: 'Fira Code' },
      labelBgStyle: { fill: '#0d1117' },
      labelBgBorderRadius: 4,
      markerEnd: { type: MarkerType.ArrowClosed, color: s.color },
    };
  });
}

function runLayout(nodes: ASTNode[], edges: ASTEdge[], overlay?: Map<string, 'added' | 'removed'>) {
  const fn = toFlowNodes(nodes, overlay);
  const fe = toFlowEdges(edges);
  const { nodes: ln, edges: le } = getLayoutedElements(fn, fe);
  return { flowNodes: ln, flowEdges: le };
}

// ─── component ────────────────────────────────────────────────────────────────

export default function App() {
  const initialProject = new URLSearchParams(window.location.search).get('project') ?? '';

  const [projects,        setProjects]        = useState<string[]>([]);
  const [project,         setProject]         = useState(initialProject);
  const [baseAST,         setBaseAST]         = useState<ASTData | null>(null);
  const [ledger,          setLedger]          = useState<DiffLedger | null>(null);
  const [viewDiffId,      setViewDiffId]      = useState<number | null>(null);
  const [hasNewAIDiff,    setHasNewAIDiff]    = useState(false);
  const [loading,         setLoading]         = useState(false);
  const [hiddenEdgeTypes, setHiddenEdgeTypes] = useState<Set<string>>(new Set());
  const [zoom,            setZoom]            = useState(0);

  const [showAddNode, setShowAddNode] = useState(false);
  const [newNodeType, setNewNodeType] = useState('Module');
  const [newNodeName, setNewNodeName] = useState('');

  const [nodes, setNodes, onNodesChange] = useNodesState<FlowNode>([]);
  const [edges, setEdges, onEdgesChange] = useEdgesState<FlowEdge>([]);

  const committedRef   = useRef<{ nodes: ASTNode[]; edges: ASTEdge[] }>({ nodes: [], edges: [] });
  const isDirtyRef     = useRef(false);
  const lastDiffCount  = useRef(0);
  const lodLevelRef    = useRef<Set<string>>(LOD[0].types);
  const hiddenTypesRef = useRef<Set<string>>(new Set());
  const layoutGenRef   = useRef(0);

  // The full positioned graph — set once per topology change, never re-layouted.
  const allNodesRef = useRef<FlowNode[]>([]);
  const allEdgesRef = useRef<FlowEdge[]>([]);

  const isHistoryMode = viewDiffId !== null;
  const showPublish   = ledger !== null && ledger.diffs.some(d => d.author === 'ai');

  // ── applyVisibility ───────────────────────────────────────────────────────
  // O(n) pass over already-positioned nodes. No Dagre. Called on LOD/toggle changes.
  const applyVisibility = useCallback(() => {
    const lod    = lodLevelRef.current;
    const hidden = hiddenTypesRef.current;

    const visNodes = allNodesRef.current.map(n => ({
      ...n,
      hidden: !lod.has((n.data as unknown as ASTNode).type),
    }));

    const visIds = new Set(visNodes.filter(n => !n.hidden).map(n => n.id));

    const visEdges = allEdgesRef.current.map(e => ({
      ...e,
      hidden: hidden.has(e.label as string) || !visIds.has(e.source) || !visIds.has(e.target),
    }));

    setNodes(visNodes);
    setEdges(visEdges);
  }, [setNodes, setEdges]);

  // ── applyLayout (Dagre) ───────────────────────────────────────────────────
  // Runs Dagre on the full topology, stores results in refs, then calls
  // applyVisibility. Only called when topology changes — NOT on LOD/toggle.
  const applyLayout = useCallback((
    astNodes: ASTNode[],
    astEdges: ASTEdge[],
    overlay?: Map<string, 'added' | 'removed'>,
  ) => {
    const gen = ++layoutGenRef.current;
    setLoading(true);
    setTimeout(() => {
      if (gen !== layoutGenRef.current) return; // superseded
      const { flowNodes, flowEdges } = runLayout(astNodes, astEdges, overlay);
      allNodesRef.current = flowNodes;
      allEdgesRef.current = flowEdges;
      applyVisibility();
      setLoading(false);
    }, 0);
  }, [applyVisibility]);

  // ── fetch project list ────────────────────────────────────────────────────
  useEffect(() => {
    fetch('/api/projects').then(r => r.json()).then(setProjects).catch(() => {});
  }, []);

  // ── load AST + ledger on project change ───────────────────────────────────
  useEffect(() => {
    if (!project) return;
    isDirtyRef.current = false;
    setViewDiffId(null);
    setHasNewAIDiff(false);
    lodLevelRef.current = LOD[0].types;
    setZoom(0);

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
        applyLayout(committed.nodes, committed.edges);
      })
      .catch(() => {});
  }, [project]); // eslint-disable-line react-hooks/exhaustive-deps

  // ── LOD on zoom — NO Dagre ────────────────────────────────────────────────
  const handleMoveEnd = useCallback((_: MouseEvent | TouchEvent | null, viewport: Viewport) => {
    setZoom(viewport.zoom);
    const newLod = lodTypesForZoom(viewport.zoom);
    if (newLod === lodLevelRef.current) return;
    lodLevelRef.current = newLod;
    if (!isDirtyRef.current && !isHistoryMode) applyVisibility();
  }, [isHistoryMode, applyVisibility]);

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
          committedRef.current = applyDiffs(baseAST, ldgr.diffs, null);
          if (newDiffs.some(d => d.author === 'ai')) {
            setHasNewAIDiff(true);
            if (!isDirtyRef.current && !isHistoryMode) {
              applyLayout(committedRef.current.nodes, committedRef.current.edges);
            }
          }
        })
        .catch(() => {});
    }, 2000);
    return () => clearInterval(interval);
  }, [project, baseAST]); // eslint-disable-line react-hooks/exhaustive-deps

  // ── edge type toggle — NO Dagre ───────────────────────────────────────────
  const toggleEdgeType = useCallback((rel: string) => {
    const next = new Set(hiddenTypesRef.current);
    if (next.has(rel)) next.delete(rel); else next.add(rel);
    hiddenTypesRef.current = next;
    setHiddenEdgeTypes(new Set(next)); // re-render legend only
    applyVisibility();
  }, [applyVisibility]);

  // ── diff navigation ───────────────────────────────────────────────────────
  const handleDiffSelect = useCallback((value: string) => {
    if (!baseAST || !ledger) return;
    const diffId = value === 'latest' ? null : Number(value);
    setViewDiffId(diffId);
    setHasNewAIDiff(false);

    if (diffId === null) {
      const committed = applyDiffs(baseAST, ledger.diffs, null);
      committedRef.current = committed;
      isDirtyRef.current = false;
      applyLayout(committed.nodes, committed.edges);
    } else {
      const currState = applyDiffs(baseAST, ledger.diffs, diffId);
      const diff      = ledger.diffs.find(d => d.diff_id === diffId);
      let overlay: Map<string, 'added' | 'removed'> | undefined;
      let displayNodes = currState.nodes;
      if (diff) {
        const prevState = applyDiffs(baseAST, ledger.diffs, diff.parent_diff_id);
        overlay = diffOverlay(prevState, currState);
        const ghosts = prevState.nodes.filter(n => overlay!.get(n.id) === 'removed');
        displayNodes = [...currState.nodes, ...ghosts];
      }
      applyLayout(displayNodes, currState.edges, overlay);
    }
  }, [baseAST, ledger, applyLayout]);

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
    setEdges(eds => addEdge({ ...params, label: 'CALLS' } as any, eds));
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
    const committed    = committedRef.current;
    const latestDiff   = ledger.diffs[ledger.diffs.length - 1];
    const nextId       = (latestDiff?.diff_id ?? 0) + 1;

    const committedNodeIds = new Set(committed.nodes.map(n => n.id));
    const currentNodeIds   = new Set(nodes.map(n => n.id));

    const addedNodes: ASTNode[] = nodes
      .filter(n => !committedNodeIds.has(n.id))
      .map(n => n.data as unknown as ASTNode);

    const removedNodeIds = committed.nodes
      .filter(n => !currentNodeIds.has(n.id))
      .map(n => n.id);

    const currentEdgesAST: ASTEdge[] = edges.map(e => ({
      source: e.source, target: e.target, rel: (e.label ?? 'CALLS') as string,
    }));

    const committedEdgeKeys = new Set(committed.edges.map(edgeKey));
    const currentEdgeKeys   = new Set(currentEdgesAST.map(edgeKey));
    const addedEdges   = currentEdgesAST.filter(e => !committedEdgeKeys.has(edgeKey(e)));
    const removedEdges = committed.edges.filter(e => !currentEdgeKeys.has(edgeKey(e)));

    const diff: Diff = {
      diff_id: nextId, parent_diff_id: latestDiff?.diff_id ?? null,
      author: 'user', timestamp: new Date().toISOString(),
      label: `User edit #${nextId}`,
      added_nodes: addedNodes, removed_nodes: removedNodeIds,
      added_edges: addedEdges, removed_edges: removedEdges, annotations: [],
    };

    await fetch(`/api/diffs/${project}/submit`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(diff),
    });

    const ldgr: DiffLedger = await fetch(`/api/diffs/${project}/ledger`).then(r => r.json());
    setLedger(ldgr);
    lastDiffCount.current = ldgr.diffs.length;
    setViewDiffId(null);
    setHasNewAIDiff(false);
    isDirtyRef.current = false;
    const newCommitted = applyDiffs(baseAST, ldgr.diffs, null);
    committedRef.current = newCommitted;
    applyLayout(newCommitted.nodes, newCommitted.edges);
  }, [project, ledger, baseAST, nodes, edges, applyLayout]);

  // ── publish ───────────────────────────────────────────────────────────────
  const handlePublish = useCallback(async () => {
    if (!project || !ledger) return;
    const latestDiff = ledger.diffs[ledger.diffs.length - 1];
    const publishDiff: Diff = {
      diff_id: (latestDiff?.diff_id ?? 0) + 1,
      parent_diff_id: latestDiff?.diff_id ?? null,
      author: 'user', timestamp: new Date().toISOString(),
      label: 'Publish', added_nodes: [], removed_nodes: [],
      added_edges: [], removed_edges: [],
      annotations: [{ id: 'publish', body: 'Publish: generate code from this graph state.', targets: [], diff_id: 0 }],
    };
    await fetch(`/api/diffs/${project}/submit`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(publishDiff),
    });
  }, [project, ledger]);

  // ── legend ────────────────────────────────────────────────────────────────
  const activeEdgeTypes = useMemo(
    () => Object.keys(EDGE_STYLES),
    [],
  );

  const diffLabel = (d: { author: string; label: string }) =>
    `${d.author === 'ai' ? '🤖' : '👤'} ${d.label}`;

  const lodLabel = zoom >= 0.35 ? 'Full' : zoom >= 0.15 ? 'Modules' : 'Files';

  // ─────────────────────────────────────────────────────────────────────────

  return (
    <div className="app-root">
      <div className="toolbar">
        <span className="app-title">DirGraph</span>

        <select className="select" value={project} onChange={e => setProject(e.target.value)}>
          <option value="">— project —</option>
          {projects.map(p => <option key={p} value={p}>{p}</option>)}
        </select>

        {ledger && (
          <select
            className={`select${hasNewAIDiff ? ' select--pulse' : ''}`}
            value={viewDiffId ?? 'latest'}
            onChange={e => handleDiffSelect(e.target.value)}
          >
            <option value="latest">Latest{hasNewAIDiff ? ' 🔵' : ''}</option>
            {ledger.diffs.map(d => (
              <option key={d.diff_id} value={d.diff_id}>#{d.diff_id} {diffLabel(d)}</option>
            ))}
          </select>
        )}

        {isHistoryMode && (
          <button className="btn btn--ghost" onClick={() => handleDiffSelect('latest')}>← Latest</button>
        )}

        <div style={{ flex: 1 }} />
        <span className="lod-badge">LOD: {lodLabel}</span>

        {!isHistoryMode && (
          <>
            <button className="btn btn--ghost" onClick={() => setShowAddNode(true)}>+ Node</button>
            <button className="btn btn--primary" onClick={handleSubmit} disabled={!baseAST}>Submit</button>
            {showPublish && (
              <button className="btn btn--publish" onClick={handlePublish}>Publish Changes</button>
            )}
          </>
        )}
        {isHistoryMode && (
          <span className="toolbar-badge">Viewing diff #{viewDiffId} — read only</span>
        )}
      </div>

      <div className="canvas-wrap">
        {loading && <div className="canvas-loading">Computing layout…</div>}

        <ReactFlow
          nodes={nodes}
          edges={edges}
          onNodesChange={isHistoryMode ? undefined : handleNodesChange}
          onEdgesChange={isHistoryMode ? undefined : handleEdgesChange}
          onConnect={isHistoryMode ? undefined : onConnect}
          onMoveEnd={handleMoveEnd}
          nodesDraggable={!isHistoryMode}
          nodesConnectable={!isHistoryMode}
          elementsSelectable={!isHistoryMode}
          nodeTypes={nodeTypes}
          deleteKeyCode={['Backspace', 'Delete']}
          onlyRenderVisibleElements
          fitView
          colorMode="dark"
          minZoom={0.05}
        >
          <Controls />
          <Background color="#30363d" gap={20} size={2} />

          <div className="legend">
            <div className="legend-title">Edge types</div>
            {activeEdgeTypes.map(rel => {
              const s      = EDGE_STYLES[rel];
              const hidden = hiddenEdgeTypes.has(rel);
              return (
                <button
                  key={rel}
                  className={`legend-item${hidden ? ' legend-item--off' : ''}`}
                  onClick={() => toggleEdgeType(rel)}
                  title={hidden ? `Show ${rel}` : `Hide ${rel}`}
                >
                  <span
                    className="legend-line"
                    style={{
                      background: hidden ? '#30363d' : s.color,
                      height: `${Math.max(1, s.weight)}px`,
                    }}
                  />
                  <span className="legend-rel" style={{ color: hidden ? '#484f58' : s.color }}>
                    {rel}
                  </span>
                  {s.animated && !hidden && <span className="legend-flow">~</span>}
                </button>
              );
            })}
          </div>
        </ReactFlow>
      </div>

      {showAddNode && (
        <div className="modal-overlay" onClick={() => setShowAddNode(false)}>
          <div className="modal" onClick={e => e.stopPropagation()}>
            <h3 className="modal-title">Add Node</h3>
            <select className="select select--full" value={newNodeType} onChange={e => setNewNodeType(e.target.value)}>
              {['Module', 'Class', 'File', 'BusinessRule', 'Contract', 'Domain', 'Copy', 'Annotation'].map(t => (
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
