/**
 * Smart diff layout — places only the NEW nodes from an AI diff, then shifts
 * existing nodes to make room. Never re-runs Dagre on the full graph.
 *
 * Algorithm:
 *  1. Run Dagre on the new-node subgraph to get local relative positions.
 *  2. Find the attachment point — centroid of existing neighbors connected to
 *     any new node. If none, stage below the whole canvas.
 *  3. Translate the subgraph so it sits just below the attachment point.
 *  4. Phase 1: axis-aligned vertical push — nudge existing nodes that overlap
 *     the placed subgraph downward.
 *  5. Phase 2: radial cleanup — push any remaining overlapping nodes outward.
 */
import dagre from 'dagre';
import type { Node as FlowNode, Edge as FlowEdge } from '@xyflow/react';

const SUB_NODE_W = 260;
const SUB_NODE_H = 80;
const GAP = 80; // clearance padding around the new subgraph

interface BBox { x: number; y: number; w: number; h: number }

// ── Dagre on a subset of nodes ────────────────────────────────────────────────

function layoutSubgraph(
  nodeIds: Set<string>,
  edges: FlowEdge[],
): Map<string, { x: number; y: number }> {
  const g = new dagre.graphlib.Graph();
  g.setDefaultEdgeLabel(() => ({}));
  g.setGraph({ rankdir: 'TB', ranksep: 100, nodesep: 50, marginx: 30, marginy: 30 });

  for (const id of nodeIds) {
    g.setNode(id, { width: SUB_NODE_W, height: SUB_NODE_H });
  }
  for (const e of edges) {
    if (nodeIds.has(e.source) && nodeIds.has(e.target)) {
      g.setEdge(e.source, e.target);
    }
  }

  dagre.layout(g);

  const positions = new Map<string, { x: number; y: number }>();
  for (const id of nodeIds) {
    const { x, y } = g.node(id);
    // Dagre returns centre coordinates; convert to top-left
    positions.set(id, { x: x - SUB_NODE_W / 2, y: y - SUB_NODE_H / 2 });
  }
  return positions;
}

// ── Bounding box helpers ──────────────────────────────────────────────────────

function getBBox(
  positions: Map<string, { x: number; y: number }>,
  padding = 0,
): BBox {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const { x, y } of positions.values()) {
    minX = Math.min(minX, x);
    minY = Math.min(minY, y);
    maxX = Math.max(maxX, x + SUB_NODE_W);
    maxY = Math.max(maxY, y + SUB_NODE_H);
  }
  return {
    x: minX - padding,
    y: minY - padding,
    w: maxX - minX + padding * 2,
    h: maxY - minY + padding * 2,
  };
}

function nodeBox(n: FlowNode): BBox {
  const w = (n.style?.width as number | undefined) ?? SUB_NODE_W;
  const h = (n.style?.height as number | undefined) ?? SUB_NODE_H;
  return { x: n.position.x, y: n.position.y, w, h };
}

function overlaps(a: BBox, b: BBox, pad = 0): boolean {
  return (
    a.x < b.x + b.w + pad &&
    a.x + a.w > b.x - pad &&
    a.y < b.y + b.h + pad &&
    a.y + a.h > b.y - pad
  );
}

// ── Attachment point ──────────────────────────────────────────────────────────

function findAttachmentPoint(
  newNodeIds: Set<string>,
  allEdges: FlowEdge[],
  existingPositions: Map<string, { x: number; y: number; w: number; h: number }>,
): { x: number; y: number } | null {
  const neighbors: { x: number; y: number }[] = [];

  for (const e of allEdges) {
    const srcIsNew = newNodeIds.has(e.source);
    const tgtIsNew = newNodeIds.has(e.target);

    const existingId = srcIsNew && !tgtIsNew ? e.target
      : tgtIsNew && !srcIsNew ? e.source
      : null;

    if (existingId) {
      const p = existingPositions.get(existingId);
      if (p) neighbors.push({ x: p.x + p.w / 2, y: p.y + p.h / 2 });
    }
  }

  if (!neighbors.length) return null;

  return {
    x: neighbors.reduce((s, p) => s + p.x, 0) / neighbors.length,
    y: neighbors.reduce((s, p) => s + p.y, 0) / neighbors.length,
  };
}

// ── Make room for new subgraph ────────────────────────────────────────────────

function pushExistingNodes(existing: FlowNode[], newBBox: BBox): FlowNode[] {
  const cx = newBBox.x + newBBox.w / 2;
  const cy = newBBox.y + newBBox.h / 2;

  // Phase 1 — axis-aligned vertical push
  const phase1 = existing.map(n => {
    const nb = nodeBox(n);
    if (!overlaps(nb, newBBox, GAP / 2)) return n;

    // Only push downward (nodes above the new bbox stay put)
    if (nb.y < newBBox.y) return n;

    const needed = newBBox.y + newBBox.h + GAP - nb.y;
    if (needed <= 0) return n;
    return { ...n, position: { x: nb.x, y: nb.y + needed } };
  });

  // Phase 2 — radial cleanup for any remaining overlaps
  return phase1.map(n => {
    const nb = nodeBox(n);
    if (!overlaps(nb, newBBox, GAP / 2)) return n;

    const nodeCx = nb.x + nb.w / 2;
    const nodeCy = nb.y + nb.h / 2;
    const dx = nodeCx - cx || 0.001;
    const dy = nodeCy - cy || 0.001;
    const dist = Math.sqrt(dx * dx + dy * dy);

    // Required clearance: half-diagonal of new bbox + half-diagonal of node + gap
    const requiredDist = Math.sqrt(
      Math.pow(newBBox.w / 2 + nb.w / 2 + GAP, 2) +
      Math.pow(newBBox.h / 2 + nb.h / 2 + GAP, 2),
    );

    if (dist >= requiredDist) return n;

    const scale = requiredDist / dist;
    return {
      ...n,
      position: {
        x: Math.round(cx + dx * scale - nb.w / 2),
        y: Math.round(cy + dy * scale - nb.h / 2),
      },
    };
  });
}

// ── Public API ────────────────────────────────────────────────────────────────

/**
 * Compute positions for `newNodeIds` and updated positions for `existingNodes`.
 *
 * Returns:
 *  - `newPositions` — top-left positions for each new node
 *  - `updatedExisting` — existing nodes with positions shifted to make room
 */
export function computeDiffLayout(
  newNodeIds: Set<string>,
  allFlowEdges: FlowEdge[],
  existingFlowNodes: FlowNode[],
): {
  newPositions: Map<string, { x: number; y: number }>;
  updatedExisting: FlowNode[];
} {
  // 1. Dagre on the subgraph
  const subPositions = layoutSubgraph(newNodeIds, allFlowEdges);

  // 2. Build lookup of existing positions (with dimensions for attachment)
  const existingPosMap = new Map<string, { x: number; y: number; w: number; h: number }>();
  for (const n of existingFlowNodes) {
    const w = (n.style?.width as number | undefined) ?? SUB_NODE_W;
    const h = (n.style?.height as number | undefined) ?? SUB_NODE_H;
    existingPosMap.set(n.id, { x: n.position.x, y: n.position.y, w, h });
  }

  // 3. Find attachment point
  const attachment = findAttachmentPoint(newNodeIds, allFlowEdges, existingPosMap);

  // 4. Translate subgraph
  const rawBBox = getBBox(subPositions); // no padding — use real bounds for translation
  let tx = 0;
  let ty = 0;

  if (attachment) {
    // Horizontally centre on attachment; place just below it
    tx = attachment.x - (rawBBox.x + rawBBox.w / 2);
    ty = attachment.y + SUB_NODE_H / 2 + GAP - rawBBox.y;
  } else {
    // Staging: below all existing nodes
    let maxY = 0;
    for (const p of existingPosMap.values()) {
      maxY = Math.max(maxY, p.y + p.h);
    }
    tx = -rawBBox.x; // left-align with x=0
    ty = maxY + GAP * 2 - rawBBox.y;
  }

  const newPositions = new Map<string, { x: number; y: number }>();
  for (const [id, pos] of subPositions) {
    newPositions.set(id, {
      x: Math.round(pos.x + tx),
      y: Math.round(pos.y + ty),
    });
  }

  // 5. Compute final bbox of placed subgraph (with clearance gap)
  const placedBBox = getBBox(newPositions, GAP);

  // 6. Push existing nodes out of the way
  const updatedExisting = pushExistingNodes(existingFlowNodes, placedBBox);

  return { newPositions, updatedExisting };
}
