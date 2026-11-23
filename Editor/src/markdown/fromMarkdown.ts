/**
 * Markdown text -> ProseMirror JSON.
 *
 * Parsing is CommonMark + the GFM pieces the editor has nodes for (tables,
 * task lists, strikethrough, literal autolinks), done by micromark through
 * `mdast-util-from-markdown`. This file only maps the resulting tree onto the
 * editor schema.
 */
import type {
  Definition,
  List,
  ListItem,
  Nodes,
  Paragraph,
  PhrasingContent,
  Root,
  RootContent,
  Table,
} from 'mdast'
import { fromMarkdown } from 'mdast-util-from-markdown'
import { gfmAutolinkLiteralFromMarkdown } from 'mdast-util-gfm-autolink-literal'
import { gfmStrikethroughFromMarkdown } from 'mdast-util-gfm-strikethrough'
import { gfmTableFromMarkdown } from 'mdast-util-gfm-table'
import { gfmTaskListItemFromMarkdown } from 'mdast-util-gfm-task-list-item'
import { gfmAutolinkLiteral } from 'micromark-extension-gfm-autolink-literal'
import { gfmStrikethrough } from 'micromark-extension-gfm-strikethrough'
import { gfmTable } from 'micromark-extension-gfm-table'
import { gfmTaskListItem } from 'micromark-extension-gfm-task-list-item'

import {
  canonicalInlineJSON,
  flatText,
  linkOf,
  NO_MARKS,
  type Flat,
  type FlatMarks,
  type InlineContext,
} from './inline'
import { NODE, type DocJSON, type NodeJSON } from './types'

const micromarkExtensions = [
  gfmAutolinkLiteral(),
  // `~one tilde~` stays literal: paths like `~/notes` and "~5 min" are far more
  // common in notes than single-tilde strikethrough.
  gfmStrikethrough({ singleTilde: false }),
  gfmTable(),
  gfmTaskListItem(),
]

/**
 * Literal autolinks come from the tokenizer only. The stock mdast extension
 * also runs a find-and-replace over the finished text nodes, which links
 * `https\://example.com` again after its escape was resolved. Without it, an
 * escaped URL stays the plain text the user asked for.
 */
const { transforms: _unused, ...autolinkLiteralFromMarkdown } = gfmAutolinkLiteralFromMarkdown()

const mdastExtensions = [
  autolinkLiteralFromMarkdown,
  gfmStrikethroughFromMarkdown(),
  gfmTableFromMarkdown(),
  gfmTaskListItemFromMarkdown(),
]

/** Markdown text -> mdast, with line endings normalized to `\n`. */
export function parseToMdast(markdown: string): Root {
  return fromMarkdown(normalizeLineEndings(markdown), {
    extensions: micromarkExtensions,
    mdastExtensions,
  })
}

/** Drops a byte order mark and turns CRLF / CR into LF. */
export function normalizeLineEndings(value: string): string {
  return value.replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n')
}

interface ParseContext {
  source: string
  definitions: Map<string, Definition>
}

function collectDefinitions(node: Nodes, into: Map<string, Definition>): void {
  if (node.type === 'definition') {
    // The first definition of a label wins, as in CommonMark.
    if (!into.has(node.identifier)) into.set(node.identifier, node)
    return
  }
  if ('children' in node) {
    for (const child of node.children) collectDefinitions(child, into)
  }
}

// ---------------------------------------------------------------------------
// Inline
// ---------------------------------------------------------------------------

const HTML_BREAK = /^<br\s*\/?>$/i

function flatten(nodes: PhrasingContent[], marks: FlatMarks, ctx: ParseContext, out: Flat[]): void {
  for (const node of nodes) {
    switch (node.type) {
      case 'text':
        out.push(flatText(node.value, marks))
        break
      case 'inlineCode':
        out.push(flatText(node.value, { ...marks, code: true }))
        break
      case 'emphasis':
        flatten(node.children, { ...marks, italic: true }, ctx, out)
        break
      case 'strong':
        flatten(node.children, { ...marks, bold: true }, ctx, out)
        break
      case 'delete':
        flatten(node.children, { ...marks, strike: true }, ctx, out)
        break
      case 'break':
        out.push({ kind: 'break' })
        break
      case 'link':
        flattenLink(node.children, { ...marks, link: linkOf(node) }, ctx, out)
        break
      case 'linkReference': {
        const definition = ctx.definitions.get(node.identifier)
        if (definition) {
          const link = { href: definition.url, title: definition.title ? definition.title : null }
          flattenLink(node.children, { ...marks, link }, ctx, out)
        } else {
          flatten(node.children, marks, ctx, out)
        }
        break
      }
      case 'image':
        out.push({
          kind: 'image',
          src: node.url,
          alt: node.alt ? node.alt : null,
          title: node.title ? node.title : null,
          link: marks.link,
        })
        break
      case 'imageReference': {
        const definition = ctx.definitions.get(node.identifier)
        if (definition) {
          out.push({
            kind: 'image',
            src: definition.url,
            alt: node.alt ? node.alt : null,
            title: definition.title ? definition.title : null,
            link: marks.link,
          })
        }
        break
      }
      case 'html':
        // Raw HTML is not supported: `<br>` becomes a hard break, anything else
        // is kept as the literal text the user sees in the source.
        if (HTML_BREAK.test(node.value)) out.push({ kind: 'break' })
        else out.push(flatText(node.value, marks))
        break
      default:
        break
    }
  }
}

/** A link needs visible text to exist in the editor; `[](url)` shows its URL. */
function flattenLink(children: PhrasingContent[], marks: FlatMarks, ctx: ParseContext, out: Flat[]): void {
  const start = out.length
  flatten(children, marks, ctx, out)
  const visible = out.slice(start).some((node) => node.kind !== 'text' || node.text !== '')
  if (!visible && marks.link) out.push(flatText(marks.link.href, marks))
}

function inline(nodes: PhrasingContent[], context: InlineContext, ctx: ParseContext): NodeJSON[] {
  const flat: Flat[] = []
  flatten(nodes, NO_MARKS, ctx, flat)
  return canonicalInlineJSON(flat, context)
}

function withContent(node: NodeJSON, content: NodeJSON[]): NodeJSON {
  if (content.length > 0) node.content = content
  return node
}

// ---------------------------------------------------------------------------
// Blocks
// ---------------------------------------------------------------------------

function emptyParagraph(): NodeJSON {
  return { type: NODE.paragraph }
}

/**
 * A paragraph holding exactly one unlinked image becomes a block image (own
 * line, selectable, draggable). Any other paragraph keeps its images inline:
 * an image mixed with text, or wrapped in a link, stays an `inlineImage` in
 * the paragraph. Splitting mixed paragraphs into blocks would rewrite existing
 * files (new blank lines), so the inline path keeps every file byte-stable.
 * Both nodes are written as the same `![alt](src "title")`.
 */
function paragraphOrImage(content: NodeJSON[]): NodeJSON {
  const only = content.length === 1 ? content[0] : undefined
  if (only?.type === NODE.inlineImage && !only.marks) return { type: NODE.image, attrs: only.attrs }
  return { type: NODE.paragraph, content }
}

/** The inverse of `paragraphOrImage`, where the schema needs a paragraph. */
function asParagraph(node: NodeJSON): NodeJSON {
  return node.type === NODE.image ? { type: NODE.paragraph, content: [{ ...node, type: NODE.inlineImage }] } : node
}

function blocks(nodes: RootContent[], ctx: ParseContext): NodeJSON[] {
  const out: NodeJSON[] = []
  for (const node of nodes) {
    switch (node.type) {
      case 'paragraph': {
        const content = inline(node.children, 'paragraph', ctx)
        if (content.length > 0) out.push(paragraphOrImage(content))
        break
      }
      case 'heading':
        out.push(
          withContent(
            { type: NODE.heading, attrs: { level: node.depth } },
            inline(node.children, 'heading', ctx),
          ),
        )
        break
      case 'blockquote':
        out.push({ type: NODE.blockquote, content: atLeastOneBlock(blocks(node.children, ctx)) })
        break
      case 'list':
        out.push(list(node, ctx))
        break
      case 'code': {
        const language = node.lang ? node.lang : null
        out.push(
          withContent(
            {
              type: NODE.codeBlock,
              attrs: { language, meta: language !== null && node.meta ? node.meta : null },
            },
            node.value === '' ? [] : [{ type: NODE.text, text: node.value }],
          ),
        )
        break
      }
      case 'thematicBreak':
        out.push({ type: NODE.horizontalRule })
        break
      case 'table': {
        const converted = table(node, ctx)
        if (converted) out.push(converted)
        break
      }
      case 'html':
        // Block-level raw HTML is not supported either; it is kept verbatim as
        // an `html` code block so nothing the user wrote disappears.
        out.push({
          type: NODE.codeBlock,
          attrs: { language: 'html', meta: null },
          content: [{ type: NODE.text, text: node.value }],
        })
        break
      default:
        // Definitions are resolved into their links; nothing else can appear.
        break
    }
  }
  return out
}

function atLeastOneBlock(content: NodeJSON[]): NodeJSON[] {
  return content.length > 0 ? content : [emptyParagraph()]
}

/** List items must start with a paragraph in the editor schema. */
function itemContent(content: NodeJSON[]): NodeJSON[] {
  const [first, ...rest] = content
  // `- ![](a.png)`: the item's own line stays a paragraph with an inline image.
  if (first?.type === NODE.image) return [asParagraph(first), ...rest]
  return first?.type === NODE.paragraph ? content : [emptyParagraph(), ...content]
}

// ---------------------------------------------------------------------------
// Lists
// ---------------------------------------------------------------------------

const EMPTY_TASK = /^\[[ xX]\]$/

/**
 * GFM only reads `[ ]` as a checkbox when text follows it, so an empty to-do
 * item (`- [ ]`) arrives as a plain item whose paragraph is the text `[ ]`.
 * It is recognized here by its source, which also tells it apart from an
 * escaped `\[ ]` that really is text.
 */
function emptyTask(item: ListItem, ctx: ParseContext): boolean | null {
  if (typeof item.checked === 'boolean') return null
  const first = item.children[0]
  if (first?.type !== 'paragraph') return null
  const start = first.position?.start.offset
  const end = first.position?.end.offset
  if (start === undefined || end === undefined) return null
  const raw = ctx.source.slice(start, end)
  if (!EMPTY_TASK.test(raw)) return null
  return raw !== '[ ]'
}

function taskState(item: ListItem, ctx: ParseContext): boolean | null {
  return typeof item.checked === 'boolean' ? item.checked : emptyTask(item, ctx)
}

function list(node: List, ctx: ParseContext): NodeJSON {
  const states = node.children.map((item) => taskState(item, ctx))
  const isTaskList = !node.ordered && states.length > 0 && states.every((state) => state !== null)

  if (isTaskList) {
    return {
      type: NODE.taskList,
      content: node.children.map((item, index) => {
        const isEmptyTask = emptyTask(item, ctx) !== null
        const children = isEmptyTask ? item.children.slice(1) : item.children
        const content = blocks(children, ctx)
        return {
          type: NODE.taskItem,
          attrs: { checked: states[index] === true },
          content: isEmptyTask ? [emptyParagraph(), ...content] : itemContent(content),
        }
      }),
    }
  }

  const items = node.children.map((item) => ({
    type: NODE.listItem,
    content: itemContent(blocks(withLiteralCheckbox(item), ctx)),
  }))
  if (node.ordered) {
    return { type: NODE.orderedList, attrs: { start: node.start ?? 1 }, content: items }
  }
  return { type: NODE.bulletList, content: items }
}

/**
 * The editor's task list is an unordered list made only of tasks. A checkbox
 * anywhere else (an ordered list, or mixed with plain items) is kept as the
 * text it was written as.
 */
function withLiteralCheckbox(item: ListItem): RootContent[] {
  if (typeof item.checked !== 'boolean') return item.children
  const marker = item.checked ? '[x] ' : '[ ] '
  const index = item.children.findIndex((child) => child.type === 'paragraph')
  if (index === -1) return item.children
  const paragraph = item.children[index] as Paragraph
  const children = item.children.slice()
  children[index] = {
    type: 'paragraph',
    children: [{ type: 'text', value: marker }, ...paragraph.children],
  }
  return children
}

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

function table(node: Table, ctx: ParseContext): NodeJSON | null {
  const header = node.children[0]
  if (!header || header.children.length === 0) return null
  const width = header.children.length

  const rows = node.children.map((row, rowIndex) => {
    const cells: NodeJSON[] = []
    for (let column = 0; column < width; column++) {
      const cell = row.children[column]
      const content = cell ? inline(cell.children, 'tableCell', ctx) : []
      const align = node.align?.[column] ?? null
      const json: NodeJSON = {
        type: rowIndex === 0 ? NODE.tableHeader : NODE.tableCell,
        content: [withContent(emptyParagraph(), content)],
      }
      if (align) json.attrs = { align }
      cells.push(json)
    }
    return { type: NODE.tableRow, content: cells }
  })

  return { type: NODE.table, content: rows }
}

// ---------------------------------------------------------------------------

/** Markdown text -> ProseMirror JSON document. */
export function parseMarkdown(markdown: string): DocJSON {
  const source = normalizeLineEndings(markdown)
  const tree = parseToMdast(source)
  const ctx: ParseContext = { source, definitions: new Map() }
  collectDefinitions(tree, ctx.definitions)
  return { type: NODE.doc, content: atLeastOneBlock(blocks(tree.children, ctx)) }
}
