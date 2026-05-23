import { Handle, Position } from '@xyflow/react';
import { NodeResizer } from '@xyflow/react';
import { FileCode, Box, PhoneOutgoing, StickyNote, Layers, Globe, Zap, Eye, GitBranch, ExternalLink } from 'lucide-react';
import type { DiffStatus } from '../types';

interface NodeData {
  id: string
  type: string
  name: string
  file?: string
  line?: number
  // Metadata
  title?: string
  description?: string
  ref?: string
  groups?: string[]
  group?: string      // legacy
  // Group sizing
  nodeWidth?: number
  nodeHeight?: number
  // Annotation / call chain
  calls?: string[]
  body?: string
  diffStatus?: DiffStatus
  selected?: boolean
}

const TYPE_CONFIG: Record<string, { cls: string; Icon: React.ElementType }> = {
  // Code graph types
  Function:     { cls: 'node-function',    Icon: FileCode },
  Module:       { cls: 'node-module',      Icon: Box },
  Class:        { cls: 'node-module',      Icon: Box },
  Call:         { cls: 'node-call',        Icon: PhoneOutgoing },
  File:         { cls: 'node-file',        Icon: Layers },
  Annotation:   { cls: 'node-annotation', Icon: StickyNote },
  // Event modelling / design types
  Domain:       { cls: 'node-domain',      Icon: Globe },
  Contract:     { cls: 'node-contract',    Icon: Zap },
  Copy:         { cls: 'node-readmodel',   Icon: Eye },
  BusinessRule: { cls: 'node-policy',      Icon: GitBranch },
}

export default function GraphNode({ data, selected }: { data: NodeData; selected?: boolean }) {
  // ── Group node ─────────────────────────────────────────────────────────────
  if (data.type === 'Group') {
    return (
      <div
        className="graph-node-group"
        style={{ width: data.nodeWidth ?? 480, height: data.nodeHeight ?? 360 }}
      >
        <NodeResizer
          color="#8b949e"
          isVisible={!!selected}
          minWidth={200}
          minHeight={120}
          lineStyle={{ borderColor: '#58a6ff' }}
          handleStyle={{ background: '#58a6ff', borderColor: '#58a6ff' }}
        />
        <div className="group-label">{data.title ?? data.name}</div>
        {data.description && (
          <div className="group-description">{data.description}</div>
        )}
      </div>
    );
  }

  // ── Regular node ───────────────────────────────────────────────────────────
  const config = TYPE_CONFIG[data.type] ?? { cls: 'node-default', Icon: FileCode }
  const { cls, Icon } = config

  const diffCls =
    data.diffStatus === 'added'   ? 'node--added'   :
    data.diffStatus === 'removed' ? 'node--removed' :
    ''

  const displayName = data.title ?? data.name

  return (
    <div className={`graph-node ${cls} ${diffCls}`}>
      <NodeResizer
        isVisible={!!selected}
        minWidth={160}
        maxWidth={550}
        minHeight={60}
        lineStyle={{ borderColor: '#30363d' }}
        handleStyle={{ background: '#8b949e', borderColor: '#30363d', width: 8, height: 8 }}
      />
      <Handle type="target" position={Position.Top}    id="t-top"    />
      <Handle type="source" position={Position.Top}    id="s-top"    />
      <Handle type="target" position={Position.Right}  id="t-right"  />
      <Handle type="source" position={Position.Right}  id="s-right"  />
      <Handle type="target" position={Position.Left}   id="t-left"   />
      <Handle type="source" position={Position.Left}   id="s-left"   />

      <div className="node-header">
        <Icon size={16} />
        <span>{data.type}</span>
        {(() => {
          const groups = data.groups ?? (data.group ? [data.group] : []);
          if (!groups.length) return null;
          return (
            <>
              <span className="node-group-badge">{groups[0]}</span>
              {groups.length > 1 && <span className="node-group-badge node-group-badge--more">+{groups.length - 1}</span>}
            </>
          );
        })()}
        {data.diffStatus === 'added'   && <span className="diff-badge diff-badge--added">+</span>}
        {data.diffStatus === 'removed' && <span className="diff-badge diff-badge--removed">−</span>}
      </div>

      <div className="node-title">{displayName}</div>

      {data.description && (
        <div className="node-description">{data.description}</div>
      )}

      {data.type === 'Annotation' && data.body && (
        <div className="node-annotation-body">{data.body}</div>
      )}

      {data.ref && (
        <div className="node-ref" title={data.ref}>
          <ExternalLink size={11} />
          <span>{data.ref.replace(/^https?:\/\//, '').split('/')[0]}</span>
        </div>
      )}

      {data.file && data.file !== 'unknown' && data.file !== '' && (
        <div className="node-meta" title={data.file}>
          {data.file.split('/').pop()}:{data.line}
        </div>
      )}

      {data.calls && data.calls.length > 0 && (
        <div className="node-calls">
          {data.calls.map(c => (
            <span key={c} className="node-call-badge">{c}</span>
          ))}
        </div>
      )}

      <Handle type="target" position={Position.Bottom} id="t-bottom" />
      <Handle type="source" position={Position.Bottom} id="s-bottom" />
    </div>
  );
}
