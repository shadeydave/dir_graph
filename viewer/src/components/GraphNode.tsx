import { Handle, Position } from '@xyflow/react';
import { FileCode, Box, PhoneOutgoing, StickyNote, Layers } from 'lucide-react';
import type { DiffStatus } from '../types';

interface NodeData {
  id: string
  type: string
  name: string
  file?: string
  line?: number
  calls?: string[]
  body?: string        // Annotation body text
  diffStatus?: DiffStatus
}

const TYPE_CONFIG: Record<string, { cls: string; Icon: React.ElementType }> = {
  Function:     { cls: 'node-function',    Icon: FileCode },
  Module:       { cls: 'node-module',      Icon: Box },
  Class:        { cls: 'node-module',      Icon: Box },
  Call:         { cls: 'node-call',        Icon: PhoneOutgoing },
  File:         { cls: 'node-file',        Icon: Layers },
  Annotation:   { cls: 'node-annotation', Icon: StickyNote },
}

export default function GraphNode({ data }: { data: NodeData }) {
  const config = TYPE_CONFIG[data.type] ?? { cls: 'node-default', Icon: FileCode }
  const { cls, Icon } = config

  const diffCls =
    data.diffStatus === 'added'   ? 'node--added'   :
    data.diffStatus === 'removed' ? 'node--removed' :
    ''

  return (
    <div className={`graph-node ${cls} ${diffCls}`}>
      <Handle type="target" position={Position.Top} />

      <div className="node-header">
        <Icon size={16} />
        <span>{data.type}</span>
        {data.diffStatus === 'added'   && <span className="diff-badge diff-badge--added">+</span>}
        {data.diffStatus === 'removed' && <span className="diff-badge diff-badge--removed">−</span>}
      </div>

      <div className="node-title">{data.name}</div>

      {data.type === 'Annotation' && data.body && (
        <div className="node-annotation-body">{data.body}</div>
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

      <Handle type="source" position={Position.Bottom} />
    </div>
  );
}
