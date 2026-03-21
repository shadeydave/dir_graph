import dagre from 'dagre';
import type { Node, Edge } from '@xyflow/react';

const nodeWidth = 260;
const nodeHeight = 120;

// Creates a fresh dagre graph each call — avoids stale node accumulation
// across re-layouts when the graph topology changes (diff navigation, submit).
export const getLayoutedElements = (nodes: Node[], edges: Edge[], direction = 'TB') => {
  const dagreGraph = new dagre.graphlib.Graph();
  dagreGraph.setDefaultEdgeLabel(() => ({}));
  dagreGraph.setGraph({ rankdir: direction });

  nodes.forEach(node => {
    dagreGraph.setNode(node.id, { width: nodeWidth, height: nodeHeight });
  });

  edges.forEach(edge => {
    dagreGraph.setEdge(edge.source, edge.target);
  });

  dagre.layout(dagreGraph);

  const layoutedNodes = nodes.map(node => {
    const { x, y } = dagreGraph.node(node.id);
    return {
      ...node,
      position: {
        x: x - nodeWidth / 2,
        y: y - nodeHeight / 2,
      },
    };
  });

  return { nodes: layoutedNodes, edges };
};
