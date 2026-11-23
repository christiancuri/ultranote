/**
 * Ask AI and the document: Markdown context out (through the adapter), answers
 * back in (parsed by the adapter, so they land as real nodes), and a safe
 * read-only rendering of an answer for the panel.
 */
import type { Editor } from '@tiptap/core'
import { Fragment, type Node as PMNode, type Schema, Slice } from '@tiptap/pm/model'
import { DOMSerializer } from '@tiptap/pm/model'
import { TextSelection } from '@tiptap/pm/state'

import { parseMarkdown, serializeMarkdown, type NodeJSON } from '../markdown'
import type { AIRange } from './highlight'

/** Markdown of `from..to`; empty for an empty range. */
export function selectionMarkdown(doc: PMNode, { from, to }: AIRange): string {
  if (from >= to) return ''
  const $from = doc.resolve(from)
  const depth = $from.sharedDepth(to)
  let content = doc.slice(from, to).content
  // The slice holds the shared parent's children. Inside one text block the
  // text is sent as a plain paragraph (no heading or list marker); otherwise
  // the parents are rebuilt so the adapter sees a document.
  if ($from.node(depth).isTextblock) {
    content = Fragment.from(doc.type.schema.nodes.paragraph!.create(null, content))
  } else {
    for (let d = depth; d >= 1; d -= 1) content = Fragment.from($from.node(d).copy(content))
  }
  const json = content.toJSON() as NodeJSON[] | null
  return serializeMarkdown({ type: 'doc', content: json ?? [] }).trim()
}

export function noteMarkdown(editor: Editor): string {
  return serializeMarkdown(editor.getJSON())
}

/** Parses an answer into a document of the editor's schema; plain text paragraphs if that fails. */
export function markdownToDoc(schema: Schema, markdown: string): PMNode {
  try {
    const doc = schema.nodeFromJSON(parseMarkdown(markdown))
    doc.check()
    return doc
  } catch {
    const paragraphs = markdown
      .split(/\n{2,}/)
      .filter((part) => part.trim() !== '')
      .map((part) => schema.nodes.paragraph!.create(null, schema.text(part)))
    return schema.topNodeType.create(null, paragraphs)
  }
}

export type InsertMode = 'replace' | 'below'

/**
 * Puts an answer into the note.
 * - `replace`: replaces `range`. A one-paragraph answer inside one text block
 *   goes in inline (the surrounding paragraph stays); anything else replaces
 *   the range with blocks.
 * - `below`: after the block holding `range.to`. An empty top-level paragraph
 *   (the line `/Ask AI` was typed on) is replaced instead.
 * Returns false when there is nothing to insert or the content does not fit.
 */
export function insertAnswer(editor: Editor, markdown: string, range: AIRange, mode: InsertMode): boolean {
  const { state } = editor
  const answer = markdownToDoc(state.schema, markdown)
  if (answer.childCount === 0) return false
  const tr = state.tr
  const from = Math.min(range.from, state.doc.content.size)
  const to = Math.min(Math.max(range.to, from), state.doc.content.size)
  let end: number
  try {
    if (mode === 'replace' && from < to) {
      const $from = state.doc.resolve(from)
      const $to = state.doc.resolve(to)
      const single = answer.childCount === 1 && answer.firstChild!.type.name === 'paragraph'
      if (single && $from.sameParent($to) && $from.parent.isTextblock && !$from.parent.type.spec.code) {
        tr.replaceWith(from, to, answer.firstChild!.content)
      } else {
        tr.replaceRange(from, to, new Slice(answer.content, 0, 0))
      }
      end = tr.mapping.map(to, 1)
    } else {
      const $to = state.doc.resolve(to)
      const block = $to.depth >= 1 ? $to.node(1) : null
      if (block && $to.depth === 1 && block.type.name === 'paragraph' && block.content.size === 0) {
        const start = $to.before(1)
        tr.replaceWith(start, $to.after(1), answer.content)
        end = start + answer.content.size
      } else {
        const at = $to.depth >= 1 ? $to.after(1) : state.doc.content.size
        tr.insert(at, answer.content)
        end = at + answer.content.size
      }
    }
  } catch {
    return false
  }
  if (!tr.docChanged) return false
  tr.setSelection(TextSelection.near(tr.doc.resolve(Math.min(end, tr.doc.content.size)), -1))
  editor.view.dispatch(tr.scrollIntoView())
  return true
}

const SAFE_LINK = /^(https?:|mailto:)/i

/**
 * DOM for an answer, built node by node by the schema's serializer (no HTML
 * strings). Links keep only http(s) and mailto targets; images only note
 * attachments, so nothing is fetched from the network.
 */
export function renderAnswer(schema: Schema, markdown: string, ownerDocument: Document = document): DocumentFragment | HTMLElement {
  const doc = markdownToDoc(schema, markdown)
  const fragment = DOMSerializer.fromSchema(schema).serializeFragment(Fragment.from(doc.content), { document: ownerDocument })
  for (const anchor of fragment.querySelectorAll('a')) {
    const href = anchor.getAttribute('href') ?? ''
    if (!SAFE_LINK.test(href)) anchor.removeAttribute('href')
  }
  for (const image of fragment.querySelectorAll('img')) {
    const src = image.getAttribute('src') ?? ''
    if (!src.startsWith('attachments/')) image.replaceWith(ownerDocument.createTextNode(image.getAttribute('alt') ?? ''))
  }
  return fragment
}
