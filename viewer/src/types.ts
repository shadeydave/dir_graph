export interface ASTNode {
  id: string
  type: string
  name: string
  file: string
  line: number
  // Annotation-specific
  body?: string
  targets?: string[]
}

export interface ASTEdge {
  source: string
  target: string
  rel: string
}

export interface ASTData {
  project: string
  exported_at: string
  node_count: number
  edge_count: number
  nodes: ASTNode[]
  edges: ASTEdge[]
}

export interface Annotation {
  id: string
  body: string
  targets: string[]
  diff_id: number
}

export interface Diff {
  diff_id: number
  parent_diff_id: number | null
  author: 'user' | 'ai'
  timestamp: string
  label: string
  added_nodes: ASTNode[]
  removed_nodes: string[]
  added_edges: ASTEdge[]
  removed_edges: ASTEdge[]
  annotations: Annotation[]
}

export interface DiffLedger {
  project: string
  base_ast: string
  diffs: Diff[]
}

export type DiffStatus = 'added' | 'removed' | 'unchanged'
