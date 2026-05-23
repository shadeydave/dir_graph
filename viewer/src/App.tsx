import { useCallback, useEffect, useRef, useState, useMemo } from 'react';
import {
  ReactFlow,
  Controls,
  Background,
  useNodesState,
  useEdgesState,
  addEdge,
  reconnectEdge,
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
import { computeDiffLayout } from './utils/diffLayout';
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

// Group nodes are always visible (they're background containers, not detail nodes)
const ALWAYS_VISIBLE = new Set(['Group']);

const LOD: Array<{ minZoom: number; types: Set<string> }> = [
  { minZoom: 0,    types: new Set(['File',                                                                           ...ALWAYS_VISIBLE]) },
  { minZoom: 0.15, types: new Set(['File', 'Module',                                                                 ...ALWAYS_VISIBLE]) },
  { minZoom: 0.35, types: new Set(['File', 'Module', 'Class', 'BusinessRule', 'Copy', 'Contract', 'Domain',         ...ALWAYS_VISIBLE]) },
];

function lodTypesForZoom(zoom: number): Set<string> {
  let result = LOD[0].types;
  for (const level of LOD) { if (zoom >= level.minZoom) result = level.types; }
  return result;
}

const nodeTypes = { custom: GraphNode };

// Normalize legacy single `group` field to `groups` array
function nodeGroups(n: ASTNode): string[] {
  return n.groups ?? (n.group ? [n.group] : []);
}

// ─── layout + graph persistence ──────────────────────────────────────────────

type SavedLayout = Record<string, { x: number; y: number; w?: number; h?: number }>;

function layoutKey(project: string) { return `dirgraph-layout:${project}`; }

function loadLayout(project: string): SavedLayout {
  try { return JSON.parse(localStorage.getItem(layoutKey(project)) ?? '{}'); }
  catch { return {}; }
}

function saveLayout(project: string, nodes: FlowNode[]) {
  const layout: SavedLayout = {};
  for (const n of nodes) {
    if (!n.position) continue;
    const entry: SavedLayout[string] = { x: Math.round(n.position.x), y: Math.round(n.position.y) };
    const w = n.style?.width as number | undefined;
    const h = n.style?.height as number | undefined;
    if (w) entry.w = Math.round(w);
    if (h) entry.h = Math.round(h);
    layout[n.id] = entry;
  }
  localStorage.setItem(layoutKey(project), JSON.stringify(layout));
}

function applyStoredLayout(flowNodes: FlowNode[], layout: SavedLayout): FlowNode[] {
  return flowNodes.map(n => {
    const saved = layout[n.id];
    if (!saved) return n;
    return {
      ...n,
      position: { x: saved.x, y: saved.y },
      ...(saved.w ? { style: { ...n.style, width: saved.w, height: saved.h } } : {}),
    };
  });
}

// Full graph snapshot — topology + positions, for session restore
interface GraphSnapshot {
  savedAt: string;
  nodes: Array<{ id: string; data: ASTNode; x: number; y: number; w?: number; h?: number }>;
  edges: Array<{ id: string; source: string; target: string; label: string }>;
}

function graphKey(project: string) { return `dirgraph-graph:${project}`; }

function saveGraph(project: string, nodes: FlowNode[], edges: FlowEdge[]) {
  const snap: GraphSnapshot = {
    savedAt: new Date().toISOString(),
    nodes: nodes
      .filter(n => n.position)
      .map(n => {
        const entry: GraphSnapshot['nodes'][0] = {
          id: n.id,
          data: n.data as unknown as ASTNode,
          x: Math.round(n.position.x),
          y: Math.round(n.position.y),
        };
        const w = n.style?.width as number | undefined;
        if (w) { entry.w = Math.round(w); entry.h = Math.round(n.style?.height as number); }
        return entry;
      }),
    edges: edges.map(e => ({
      id: e.id,
      source: e.source,
      target: e.target,
      label: (e.label as string) ?? 'CALLS',
    })),
  };
  localStorage.setItem(graphKey(project), JSON.stringify(snap));
  // Keep layout store in sync too (for Dagre overrides on new-node arrival)
  saveLayout(project, nodes);
}

function loadSavedGraph(project: string): GraphSnapshot | null {
  try {
    const raw = localStorage.getItem(graphKey(project));
    return raw ? JSON.parse(raw) : null;
  } catch { return null; }
}

function restoreSnapshot(snap: GraphSnapshot): { flowNodes: FlowNode[]; flowEdges: FlowEdge[] } {
  const flowNodes: FlowNode[] = snap.nodes.map(n => ({
    id: n.id,
    type: 'custom' as const,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    data: n.data as unknown as Record<string, any>,
    position: { x: n.x, y: n.y },
    hidden: false,
    zIndex: (n.data as ASTNode).type === 'Group' ? -1 : 0,
    ...(n.w ? { style: { width: n.w, height: n.h } } : {}),
  }));

  const flowEdges: FlowEdge[] = snap.edges.map(e => {
    const s = EDGE_STYLES[e.label] ?? FALLBACK_EDGE;
    return {
      id: e.id,
      source: e.source,
      target: e.target,
      label: e.label,
      type: 'smoothstep',
      animated: s.animated,
      style: { stroke: s.color, strokeWidth: s.weight, strokeDasharray: s.dash },
      labelStyle: { fill: s.color, fontWeight: 600, fontSize: 11, fontFamily: 'Fira Code' },
      labelBgStyle: { fill: '#0d1117' },
      labelBgBorderRadius: 4,
      markerEnd: { type: MarkerType.ArrowClosed, color: s.color },
    };
  });

  return { flowNodes, flowEdges };
}

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
  return nodes.map(n => {
    const isGroup = n.type === 'Group';
    return {
      id: n.id,
      type: 'custom',
      data: { ...n, diffStatus: overlay?.get(n.id) },
      position: { x: 0, y: 0 },
      hidden: false,
      zIndex: isGroup ? -1 : 0,
      // Groups need explicit size so NodeResizer has a baseline to work from
      ...(isGroup ? { style: { width: n.nodeWidth ?? 480, height: n.nodeHeight ?? 360 } } : {}),
    };
  });
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
  const [edgeMenu,   setEdgeMenu]   = useState<{ edgeId: string; x: number; y: number } | null>(null);
  const [nodeMenu,   setNodeMenu]   = useState<{ nodeId: string; x: number; y: number } | null>(null);
  const [metaNodeId, setMetaNodeId] = useState<string | null>(null);
  const [metaTitle,  setMetaTitle]  = useState('');
  const [metaDesc,   setMetaDesc]   = useState('');
  const [metaRef,    setMetaRef]    = useState('');
  const [metaGroups,     setMetaGroups]     = useState<string[]>([]);
  const [metaGroupInput, setMetaGroupInput] = useState('');
  const [focusGroup,     setFocusGroup]     = useState<string>('');
  const [savedAt,        setSavedAt]        = useState<Date | null>(null);

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

  // ── auto-save: persist full graph state on every mutation ─────────────────
  useEffect(() => {
    if (!project || !baseAST) return; // not yet loaded
    const timer = setTimeout(() => {
      saveGraph(project, nodes, edges);
      setSavedAt(new Date());
    }, 600);
    return () => clearTimeout(timer);
  }, [nodes, edges, project, baseAST]); // eslint-disable-line react-hooks/exhaustive-deps

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
  // resetLayout=true skips position restoration (used by the Reset button).
  const applyLayout = useCallback((
    astNodes: ASTNode[],
    astEdges: ASTEdge[],
    overlay?: Map<string, 'added' | 'removed'>,
    resetLayout = false,
  ) => {
    const gen = ++layoutGenRef.current;
    setLoading(true);
    setTimeout(() => {
      if (gen !== layoutGenRef.current) return; // superseded
      const { flowNodes, flowEdges } = runLayout(astNodes, astEdges, overlay);
      const positioned = resetLayout ? flowNodes : applyStoredLayout(flowNodes, loadLayout(project));
      allNodesRef.current = positioned;
      allEdgesRef.current = flowEdges;
      applyVisibility();
      setLoading(false);
    }, 0);
  }, [applyVisibility, project]);

  // ── applyDiffLayout — smart incremental placement for AI diffs ───────────
  // Runs Dagre only on new nodes, then pushes existing nodes aside.
  const applyDiffLayout = useCallback((
    prevNodes: ASTNode[],
    newCommitted: { nodes: ASTNode[]; edges: ASTEdge[] },
  ) => {
    const prevIds = new Set(prevNodes.map(n => n.id));
    const removedIds = new Set(
      prevNodes.filter(n => !newCommitted.nodes.some(nc => nc.id === n.id)).map(n => n.id),
    );
    const newASTNodes = newCommitted.nodes.filter(n => !prevIds.has(n.id));

    const newFlowEdges = toFlowEdges(newCommitted.edges);
    allEdgesRef.current = newFlowEdges;

    // Remove nodes dropped by the diff
    let base = allNodesRef.current.filter(n => !removedIds.has(n.id));

    if (!newASTNodes.length) {
      // Only removals / edge changes — refresh visibility
      allNodesRef.current = base;
      applyVisibility();
      return;
    }

    const newNodeIds = new Set(newASTNodes.map(n => n.id));
    const { newPositions, updatedExisting } = computeDiffLayout(
      newNodeIds,
      newFlowEdges,
      base,
    );

    // Build flow nodes for the new nodes (mark as 'added' for diff overlay)
    const addedOverlay = new Map<string, 'added' | 'removed'>(
      newASTNodes.map(n => [n.id, 'added']),
    );
    const newFlowNodes = toFlowNodes(newASTNodes, addedOverlay).map(fn => ({
      ...fn,
      position: newPositions.get(fn.id) ?? { x: 0, y: 0 },
    }));

    allNodesRef.current = [...updatedExisting, ...newFlowNodes];
    if (project) saveLayout(project, allNodesRef.current);
    applyVisibility();
  }, [applyVisibility, project]);

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

        // Restore saved working state if one exists; otherwise run Dagre
        const snap = loadSavedGraph(project);
        if (snap) {
          const { flowNodes, flowEdges } = restoreSnapshot(snap);
          allNodesRef.current = flowNodes;
          allEdgesRef.current = flowEdges;
          isDirtyRef.current = true; // working state may differ from committed
          applyVisibility();
          setSavedAt(new Date(snap.savedAt));
        } else {
          applyLayout(committed.nodes, committed.edges);
        }
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
          const prevCommitted = committedRef.current;
          committedRef.current = applyDiffs(baseAST, ldgr.diffs, null);
          if (newDiffs.some(d => d.author === 'ai')) {
            setHasNewAIDiff(true);
            if (!isDirtyRef.current && !isHistoryMode) {
              // Keep existing layout — only place the new nodes incrementally
              applyDiffLayout(prevCommitted.nodes, committedRef.current);
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
    const dirty = changes.some(c => c.type === 'remove' || c.type === 'dimensions');
    if (dirty) isDirtyRef.current = true;
    // Persist resize changes back to allNodesRef so submit captures correct size
    for (const c of changes) {
      if (c.type === 'dimensions') {
        allNodesRef.current = allNodesRef.current.map(n => {
          if (n.id !== c.id) return n;
          const { width = n.style?.width, height = n.style?.height } = c.dimensions ?? {};
          return { ...n, style: { ...n.style, width, height }, data: { ...n.data, nodeWidth: width, nodeHeight: height } };
        });
        // Save layout after resize settles
        if (project) saveLayout(project, allNodesRef.current);
      }
    }
    onNodesChange(changes);
  }, [onNodesChange, project]);

  const handleNodeDragStop = useCallback((_: React.MouseEvent, _node: FlowNode, currentNodes: FlowNode[]) => {
    if (project) saveLayout(project, currentNodes);
  }, [project]);

  const handleEdgesChange = useCallback((changes: EdgeChange[]) => {
    if (changes.some(c => c.type !== 'select')) isDirtyRef.current = true;
    onEdgesChange(changes);
  }, [onEdgesChange]);

  const onConnect = useCallback((params: Connection | FlowEdge) => {
    isDirtyRef.current = true;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    setEdges(eds => addEdge({ ...params, label: 'CALLS' } as any, eds));
  }, [setEdges]);

  // ── edge reconnection (drag endpoint to new anchor) ───────────────────────
  const reconnectSuccessful = useRef(false);

  const onReconnectStart = useCallback(() => {
    reconnectSuccessful.current = false;
  }, []);

  const onReconnect = useCallback((oldEdge: FlowEdge, newConnection: Connection) => {
    reconnectSuccessful.current = true;
    setEdges(eds => reconnectEdge(oldEdge, newConnection, eds));
    isDirtyRef.current = true;
  }, [setEdges]);

  const onReconnectEnd = useCallback((_: MouseEvent | TouchEvent, edge: FlowEdge) => {
    if (!reconnectSuccessful.current) {
      setEdges(eds => eds.filter(e => e.id !== edge.id));
      isDirtyRef.current = true;
    }
  }, [setEdges]);

  // ── edge context menu ─────────────────────────────────────────────────────
  const handleEdgeContextMenu = useCallback((event: React.MouseEvent, edge: FlowEdge) => {
    event.preventDefault();
    setEdgeMenu({ edgeId: edge.id, x: event.clientX, y: event.clientY });
  }, []);

  const handleEdgeTypeChange = useCallback((rel: string) => {
    if (!edgeMenu) return;
    const s = EDGE_STYLES[rel] ?? FALLBACK_EDGE;
    setEdges(eds => eds.map(e => {
      if (e.id !== edgeMenu.edgeId) return e;
      return {
        ...e,
        label: rel,
        animated: s.animated,
        style: { stroke: s.color, strokeWidth: s.weight, strokeDasharray: s.dash },
        labelStyle: { fill: s.color, fontWeight: 600, fontSize: 11, fontFamily: 'Fira Code' },
        labelBgStyle: { fill: '#0d1117' },
        labelBgBorderRadius: 4,
        markerEnd: { type: MarkerType.ArrowClosed, color: s.color },
      };
    }));
    isDirtyRef.current = true;
    setEdgeMenu(null);
  }, [edgeMenu, setEdges]);

  const dismissEdgeMenu = useCallback(() => setEdgeMenu(null), []);

  // ── node context menu ─────────────────────────────────────────────────────
  const handleNodeContextMenu = useCallback((event: React.MouseEvent, node: FlowNode) => {
    event.preventDefault();
    setNodeMenu({ nodeId: node.id, x: event.clientX, y: event.clientY });
  }, []);

  const dismissNodeMenu = useCallback(() => setNodeMenu(null), []);

  const openMetaPanel = useCallback((nodeId: string) => {
    const node = allNodesRef.current.find(n => n.id === nodeId);
    if (!node) return;
    const d = node.data as unknown as import('./types').ASTNode;
    setMetaNodeId(nodeId);
    setMetaTitle(d.title ?? d.name ?? '');
    setMetaDesc(d.description ?? '');
    setMetaRef(d.ref ?? '');
    setMetaGroups(nodeGroups(d));
    setMetaGroupInput('');
    setNodeMenu(null);
  }, []);

  const saveMetadata = useCallback(() => {
    if (!metaNodeId) return;
    const update = (n: FlowNode) => {
      if (n.id !== metaNodeId) return n;
      return { ...n, data: { ...n.data, title: metaTitle, description: metaDesc, ref: metaRef, groups: metaGroups } };
    };
    allNodesRef.current = allNodesRef.current.map(update);
    setNodes(nds => nds.map(update));
    isDirtyRef.current = true;
    setMetaNodeId(null);
  }, [metaNodeId, metaTitle, metaDesc, metaRef, metaGroups, setNodes]);

  // ── derive group names from current nodes ─────────────────────────────────
  const groupNames = useMemo(() => {
    const names = new Set<string>();
    allNodesRef.current.forEach(n => {
      const d = n.data as unknown as import('./types').ASTNode;
      if (d.type === 'Group') names.add(d.name);
      nodeGroups(d).forEach(g => names.add(g));
    });
    return [...names].sort();
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [nodes]); // recompute when nodes change

  // ── version info from ledger ──────────────────────────────────────────────
  const getVersionInfo = useCallback((nodeId: string): string => {
    if (!ledger) return 'Base graph';
    for (const diff of ledger.diffs) {
      if (diff.added_nodes.some(n => n.id === nodeId)) {
        const ts = new Date(diff.timestamp).toLocaleDateString();
        return `Added in diff #${diff.diff_id} by ${diff.author} — ${ts}`;
      }
    }
    return 'Base graph';
  }, [ledger]);

  // ── focus group filter ────────────────────────────────────────────────────
  useEffect(() => {
    if (!allNodesRef.current.length) return;
    if (!focusGroup) {
      applyVisibility();
      return;
    }
    const lod = lodLevelRef.current;
    const visNodes = allNodesRef.current.map(n => {
      const d = n.data as unknown as import('./types').ASTNode;
      const inGroup = d.type === 'Group'
        ? d.name === focusGroup
        : nodeGroups(d).includes(focusGroup);
      return { ...n, hidden: !inGroup || !lod.has(d.type === 'Group' ? 'Group' : d.type) };
    });
    const visIds = new Set(visNodes.filter(n => !n.hidden).map(n => n.id));
    const visEdges = allEdgesRef.current.map(e => ({
      ...e,
      hidden: !visIds.has(e.source) || !visIds.has(e.target),
    }));
    setNodes(visNodes);
    setEdges(visEdges);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [focusGroup]);

  // ── add node ──────────────────────────────────────────────────────────────
  const handleAddNode = useCallback(() => {
    if (!newNodeName.trim()) return;
    const isGroup = newNodeType === 'Group';
    const id = `Scratch:${newNodeType}:${newNodeName.trim()}`;
    const newNode: FlowNode = {
      id,
      type: 'custom',
      data: { id, type: newNodeType, name: newNodeName.trim(), file: '', line: 0,
              ...(isGroup ? { nodeWidth: 480, nodeHeight: 360 } : {}) },
      position: { x: 100 + Math.random() * 300, y: 100 + Math.random() * 300 },
      zIndex: isGroup ? -1 : 0,
      ...(isGroup ? { style: { width: 480, height: 360 } } : {}),
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

    const committedNodeIds  = new Set(committed.nodes.map(n => n.id));
    const committedNodeMap  = new Map(committed.nodes.map(n => [n.id, n]));
    const currentNodeIds    = new Set(nodes.map(n => n.id));

    // Newly added nodes
    const brandNewNodes: ASTNode[] = nodes
      .filter(n => !committedNodeIds.has(n.id))
      .map(n => n.data as unknown as ASTNode);

    // Nodes with metadata changes (exist in both, but data differs)
    const modifiedNodes: ASTNode[] = nodes
      .filter(n => {
        if (!committedNodeIds.has(n.id)) return false;
        const old = committedNodeMap.get(n.id)!;
        const cur = n.data as unknown as ASTNode;
        return cur.title !== old.title || cur.description !== old.description ||
               cur.ref !== old.ref ||
               JSON.stringify([...nodeGroups(cur)].sort()) !== JSON.stringify([...nodeGroups(old)].sort()) ||
               cur.nodeWidth !== old.nodeWidth || cur.nodeHeight !== old.nodeHeight;
      })
      .map(n => n.data as unknown as ASTNode);

    const addedNodes = [...brandNewNodes, ...modifiedNodes];
    // Modified nodes must be removed first so applyDiffs can upsert them cleanly
    const modifiedIds = new Set(modifiedNodes.map(n => n.id));

    const removedNodeIds = [
      ...committed.nodes.filter(n => !currentNodeIds.has(n.id)).map(n => n.id),
      ...modifiedIds,
    ];

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
    // Sync allNodesRef positions from XYFlow state (drag positions live there)
    // then reapply visibility — no Dagre, no position reset.
    const posMap = new Map(nodes.map(n => [n.id, { position: n.position, style: n.style }]));
    allNodesRef.current = allNodesRef.current.map(n => {
      const cur = posMap.get(n.id);
      return cur ? { ...n, position: cur.position, ...(cur.style ? { style: cur.style } : {}) } : n;
    });
    applyVisibility();
  }, [project, ledger, baseAST, nodes, edges, applyVisibility]);

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

        {groupNames.length > 0 && (
          <select
            className="select"
            value={focusGroup}
            onChange={e => setFocusGroup(e.target.value)}
            title="Focus on a group"
          >
            <option value="">All groups</option>
            {groupNames.map(g => <option key={g} value={g}>{g}</option>)}
          </select>
        )}

        {savedAt && !isHistoryMode && (
          <span className="saved-indicator" title={savedAt.toLocaleTimeString()}>
            Saved {savedAt.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
          </span>
        )}

        {!isHistoryMode && (
          <>
            {baseAST && (
              <button
                className="btn btn--ghost"
                title="Clear saved positions and re-run auto-layout"
                onClick={() => {
                  if (project) { localStorage.removeItem(layoutKey(project)); localStorage.removeItem(graphKey(project)); }
                  applyLayout(committedRef.current.nodes, committedRef.current.edges, undefined, true);
                }}
              >Reset Layout</button>
            )}
            <button className="btn btn--ghost" onClick={() => setShowAddNode(true)}>+ Node</button>
            <button
              className="btn btn--primary"
              onClick={handleSubmit}
              disabled={!baseAST}
              title="Package current changes as a diff and send to chat"
            >Send to Chat</button>
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
          onReconnect={isHistoryMode ? undefined : onReconnect}
          onReconnectStart={isHistoryMode ? undefined : onReconnectStart}
          onReconnectEnd={isHistoryMode ? undefined : onReconnectEnd}
          reconnectRadius={20}
          onEdgeContextMenu={isHistoryMode ? undefined : handleEdgeContextMenu}
          onNodeDragStop={isHistoryMode ? undefined : handleNodeDragStop}
          onNodeContextMenu={isHistoryMode ? undefined : handleNodeContextMenu}
          onPaneClick={() => { dismissEdgeMenu(); dismissNodeMenu(); }}
          onNodeClick={dismissEdgeMenu}
          onEdgeClick={() => { dismissEdgeMenu(); dismissNodeMenu(); }}
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

      {edgeMenu && !isHistoryMode && (
        <div
          className="edge-context-menu"
          style={{ left: edgeMenu.x, top: edgeMenu.y }}
          onClick={e => e.stopPropagation()}
          onContextMenu={e => e.preventDefault()}
        >
          <div className="edge-context-menu-title">Edge type</div>
          {Object.entries(EDGE_STYLES).map(([rel, s]) => {
            const isActive = edges.find(e => e.id === edgeMenu.edgeId)?.label === rel;
            return (
              <button
                key={rel}
                className={`edge-context-item${isActive ? ' edge-context-item--active' : ''}`}
                onClick={() => handleEdgeTypeChange(rel)}
              >
                <span className="edge-context-dot" style={{ background: s.color }} />
                {rel}
                {s.animated && <span className="edge-context-anim">~</span>}
              </button>
            );
          })}
        </div>
      )}

      {nodeMenu && !isHistoryMode && (
        <div
          className="node-context-menu"
          style={{ left: nodeMenu.x, top: nodeMenu.y }}
          onClick={e => e.stopPropagation()}
          onContextMenu={e => e.preventDefault()}
        >
          <button className="node-context-item" onClick={() => openMetaPanel(nodeMenu.nodeId)}>
            Edit metadata
          </button>
          <button className="node-context-item node-context-item--danger" onClick={() => {
            setNodes(nds => nds.filter(n => n.id !== nodeMenu.nodeId));
            isDirtyRef.current = true;
            setNodeMenu(null);
          }}>
            Delete node
          </button>
        </div>
      )}

      {metaNodeId && (
        <div className="meta-panel">
          <div className="meta-panel-header">
            <span>Node metadata</span>
            <button className="meta-panel-close" onClick={() => setMetaNodeId(null)}>×</button>
          </div>
          <div className="meta-panel-body">
            <label className="meta-label">Title</label>
            <input
              className="input"
              value={metaTitle}
              onChange={e => setMetaTitle(e.target.value)}
              placeholder="Display name"
            />
            <label className="meta-label">Description</label>
            <textarea
              className="input meta-textarea"
              value={metaDesc}
              onChange={e => setMetaDesc(e.target.value)}
              placeholder="Purpose, intent, implementation notes…"
              rows={4}
            />
            <label className="meta-label">Reference</label>
            <input
              className="input"
              value={metaRef}
              onChange={e => setMetaRef(e.target.value)}
              placeholder="https://… or path/to/file"
            />
            {metaRef && (
              <a href={metaRef} target="_blank" rel="noreferrer" className="meta-ref-link">
                Open reference ↗
              </a>
            )}
            <label className="meta-label">Groups</label>
            <div className="meta-tags">
              {metaGroups.map(g => (
                <span key={g} className="meta-tag">
                  {g}
                  <button
                    className="meta-tag-remove"
                    onClick={() => setMetaGroups(metaGroups.filter(x => x !== g))}
                  >×</button>
                </span>
              ))}
              <input
                className="meta-tag-input"
                value={metaGroupInput}
                onChange={e => setMetaGroupInput(e.target.value)}
                onKeyDown={e => {
                  const val = metaGroupInput.trim();
                  if ((e.key === 'Enter' || e.key === ',') && val) {
                    e.preventDefault();
                    if (!metaGroups.includes(val)) setMetaGroups([...metaGroups, val]);
                    setMetaGroupInput('');
                  }
                  if (e.key === 'Backspace' && !metaGroupInput && metaGroups.length) {
                    setMetaGroups(metaGroups.slice(0, -1));
                  }
                }}
                placeholder={metaGroups.length ? '' : 'Type and press Enter…'}
                list="meta-group-list"
              />
            </div>
            <datalist id="meta-group-list">
              {groupNames.filter(g => !metaGroups.includes(g)).map(g => <option key={g} value={g} />)}
            </datalist>
            <div className="meta-version">{getVersionInfo(metaNodeId)}</div>
          </div>
          <div className="meta-panel-footer">
            <button className="btn btn--ghost" onClick={() => setMetaNodeId(null)}>Cancel</button>
            <button className="btn btn--primary" onClick={saveMetadata}>Save</button>
          </div>
        </div>
      )}

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
