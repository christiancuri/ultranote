/**
 * ProseMirror JSON, the shape `editor.getJSON()` returns and
 * `schema.nodeFromJSON()` accepts. The adapter only speaks this format so it
 * stays free of DOM and editor instances (and runs under plain Node in tests).
 */
export interface MarkJSON {
  type: string
  attrs?: Record<string, unknown>
}

export interface NodeJSON {
  type: string
  attrs?: Record<string, unknown>
  content?: NodeJSON[]
  marks?: MarkJSON[]
  text?: string
}

export interface DocJSON extends NodeJSON {
  type: 'doc'
  content: NodeJSON[]
}

/**
 * Loose input accepted by the serializer. It matches TipTap's `JSONContent`,
 * where every field is optional.
 */
export interface LooseNodeJSON {
  type?: string
  attrs?: Record<string, unknown>
  content?: LooseNodeJSON[]
  marks?: { type: string; attrs?: Record<string, unknown> }[]
  text?: string
}

/** Node and mark names shared with the editor schema (`src/editor/extensions.ts`). */
export const NODE = {
  doc: 'doc',
  paragraph: 'paragraph',
  heading: 'heading',
  blockquote: 'blockquote',
  bulletList: 'bulletList',
  orderedList: 'orderedList',
  listItem: 'listItem',
  taskList: 'taskList',
  taskItem: 'taskItem',
  codeBlock: 'codeBlock',
  horizontalRule: 'horizontalRule',
  table: 'table',
  tableRow: 'tableRow',
  tableHeader: 'tableHeader',
  tableCell: 'tableCell',
  /** Block image: a paragraph holding only one unlinked image. */
  image: 'image',
  /** Inline image: an image mixed with text, or wrapped in a link. */
  inlineImage: 'inlineImage',
  hardBreak: 'hardBreak',
  text: 'text',
} as const

export const MARK = {
  link: 'link',
  bold: 'bold',
  italic: 'italic',
  strike: 'strike',
  code: 'code',
} as const
