/**
 * ProseMirror JSON -> Markdown text.
 *
 * The document is mapped to mdast and written by `mdast-util-to-markdown`,
 * which knows when a character is unsafe in the place it is in and verifies
 * that emphasis markers pair the way CommonMark will read them. On top of its
 * defaults this file:
 *
 *   - fixes the output style (see `OPTIONS`), without column padding in tables;
 *   - narrows a few escape rules that are broader than the syntax they protect
 *     (see `RELAXED`), so ordinary text such as `AT&T`, `#tag`, `[1]` or
 *     `~/notes` is not littered with backslashes;
 *   - writes literal URLs back as literal URLs when that is safe.
 */
import type {
  BlockContent,
  Code,
  Link,
  List,
  ListItem,
  Literal,
  Paragraph,
  PhrasingContent,
  Root,
  RootContent,
  Table,
  TableCell,
  TableRow,
} from 'mdast'
import { gfmAutolinkLiteralToMarkdown } from 'mdast-util-gfm-autolink-literal'
import { gfmStrikethroughToMarkdown } from 'mdast-util-gfm-strikethrough'
import { gfmTableToMarkdown } from 'mdast-util-gfm-table'
import { gfmTaskListItemToMarkdown } from 'mdast-util-gfm-task-list-item'
import {
  defaultHandlers,
  toMarkdown,
  type Handle,
  type Join,
  type Options,
  type Unsafe,
} from 'mdast-util-to-markdown'

import { parseToMdast } from './fromMarkdown'
import { canonicalTree, flatFromJSON, type Flat, type InlineContext } from './inline'
import { NODE, type LooseNodeJSON } from './types'

/** A URL written as plain text that GFM turns into a link on its own. */
interface LiteralAutolink extends Literal {
  type: 'literalAutolink'
}

declare module 'mdast' {
  interface PhrasingContentMap {
    literalAutolink: LiteralAutolink
  }
  interface RootContentMap {
    literalAutolink: LiteralAutolink
  }
}

// ---------------------------------------------------------------------------
// Escaping
// ---------------------------------------------------------------------------

const CHARACTER_REFERENCE_CONSTRUCTS: Unsafe['inConstruct'] = [
  'codeFencedLangGraveAccent',
  'codeFencedLangTilde',
  'codeFencedMetaGraveAccent',
  'codeFencedMetaTilde',
  'destinationLiteral',
  'destinationRaw',
  'phrasing',
  'titleApostrophe',
  'titleQuote',
]

const NOT_IN_SPANS: Unsafe['notInConstruct'] = [
  'autolink',
  'destinationLiteral',
  'destinationRaw',
  'reference',
  'titleQuote',
  'titleApostrophe',
]

/**
 * Replacements for default rules that escape more than the syntax needs. Each
 * entry is at least as strict as the construct it guards, so anything that
 * really would change meaning is still escaped (with a backslash).
 */
const RELAXED: Unsafe[] = [
  // `&` only starts a character reference when a complete one follows
  // (`&amp;`, `&#38;`, `&#x26;`). `AT&T` and `?a=1&b=2` are plain text.
  {
    character: '&',
    after: '(?:#[xX][0-9A-Fa-f]{1,6}|#[0-9]{1,7}|[A-Za-z][A-Za-z0-9]{1,31});',
    inConstruct: CHARACTER_REFERENCE_CONSTRUCTS,
  },
  // `[` cannot start a link by itself: inline links need `](`, and `(` after
  // `]` is escaped by a default rule; reference links need a definition, and
  // the only way text can create one is `[label]:` at the start of a block.
  { atBreak: true, character: '[', after: '[^\\]\\r\\n]*\\]:' },
  // `[ ]` / `[x]` at the start of a list item is a task checkbox.
  { atBreak: true, character: '[', after: '[ \\txX]\\]', inConstruct: 'listItem' },
  // An ATX heading is one to six `#` followed by a blank or the end of the
  // line. `#tag` and `#1` are plain text.
  { atBreak: true, character: '#', after: '#{0,5}(?:[ \\t\\r\\n]|$)' },
  // The optional closing sequence of a heading is a run of `#` after a blank,
  // at the end of the line. Escaping its last `#` keeps it as text. A `#`
  // glued to a word (`# Notes on C#`) cannot close a heading.
  { character: '#', before: '[ \\t]#*', after: '(?:[\\r\\n]|$)', inConstruct: 'headingAtx' },
  // Strikethrough and tilde fences need two tildes in a row (single-tilde
  // strikethrough is turned off in the parser). Lookarounds keep the matches
  // from overlapping, so every tilde of a run is checked.
  { character: '~', after: '(?=~)', inConstruct: 'phrasing', notInConstruct: NOT_IN_SPANS },
  { character: '~', before: '(?<=~)', inConstruct: 'phrasing', notInConstruct: NOT_IN_SPANS },
  // A `www.` autolink needs exactly `www` at the start of a word. The default
  // rule escapes every `w.` (`view.state`, `window.location`).
  {
    character: '.',
    before: '(?:^|[^0-9A-Za-z])[Ww]{3}',
    after: '[\\-.\\w]',
    inConstruct: 'phrasing',
    notInConstruct: ['autolink', 'link', 'image', 'label'],
  },
]

const RELAXED_SET = new Set(RELAXED)

/** True for the default rules that `RELAXED` replaces. */
function isReplaced(pattern: Unsafe): boolean {
  if (RELAXED_SET.has(pattern)) return false
  switch (pattern.character) {
    case '&':
      return true
    case '[':
      return pattern.atBreak === true || pattern.inConstruct === 'phrasing'
    case '#':
      return pattern.atBreak === true || pattern.inConstruct === 'headingAtx'
    case '~':
      return pattern.atBreak === true || pattern.inConstruct === 'phrasing'
    case '.':
      return pattern.before === '[Ww]'
    default:
      return false
  }
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/**
 * Swaps the replaced escape rules out before anything is written. The rule
 * list lives on the serializer state, which is only reachable from a handler.
 */
const handleRoot: Handle = (node: Root, parent, state, info) => {
  state.unsafe = state.unsafe.filter((pattern) => !isReplaced(pattern))
  return defaultHandlers.root(node, parent, state, info)
}

/**
 * The first paragraph of a task item carries its checkbox. Unlike the stock
 * GFM handler, an empty task is written as a bare `[ ]` (the parser reads it
 * back, see `emptyTask`) instead of `[ ] &#x20;`.
 */
const handleParagraph: Handle = (node: Paragraph, parent, state, info) => {
  if (parent?.type === 'listItem' && typeof parent.checked === 'boolean' && parent.children[0] === node) {
    const checkbox = parent.checked ? '[x]' : '[ ]'
    if (node.children.length === 0) return checkbox
    const tracker = state.createTracker(info)
    tracker.move(`${checkbox} `)
    const value = defaultHandlers.paragraph(node, parent, state, { ...info, ...tracker.current() })
    return `${checkbox} ${value}`
  }
  return defaultHandlers.paragraph(node, parent, state, info)
}

/** A table cell cannot contain a line ending, so a hard break there is `<br>`. */
const handleBreak: Handle = (node, parent, state, info) => {
  if (state.stack.includes('tableCell')) return '<br>'
  return defaultHandlers.break(node, parent, state, info)
}

/**
 * Backticks cannot be escaped in the info string of a backtick fence (the
 * stock handler falls back to `&#x60;`), so such a block uses tildes.
 */
const handleCode: Handle = (node: Code, parent, state, info) => {
  const infoString = `${node.lang ?? ''}${node.meta ?? ''}`
  if (!infoString.includes('`')) return defaultHandlers.code(node, parent, state, info)
  const previous = state.options.fence
  state.options.fence = '~'
  try {
    return defaultHandlers.code(node, parent, state, info)
  } finally {
    state.options.fence = previous
  }
}

const handleLiteralAutolink: Handle & { peek?: Handle } = (node: LiteralAutolink) => node.value
handleLiteralAutolink.peek = (node: LiteralAutolink) => node.value.charAt(0)

const DELIMITER: Record<string, string> = { left: ':---', right: '---:', center: ':---:' }

/**
 * Tables are written without column padding: one space around each cell and
 * `---` delimiters. Padding would rewrite every row when one cell changes and
 * depends on how wide a character is taken to be.
 */
const handleTable: Handle = (node: Table, _parent, state, info) => {
  const exitTable = state.enter('table')
  const rows = node.children.map((row: TableRow) => {
    const exitRow = state.enter('tableRow')
    const cells = row.children.map((cell: TableCell) => state.handle(cell, row, state, info))
    exitRow()
    return cells
  })
  exitTable()

  const header = rows[0] ?? []
  const delimiters = header.map((_, column) => DELIMITER[node.align?.[column] ?? ''] ?? '---')
  const line = (cells: string[]) => `| ${cells.join(' | ')} |`
  return [line(header), line(delimiters), ...rows.slice(1).map(line)].join('\n')
}

/**
 * Blank lines inside a list item around blocks that would otherwise merge
 * with their neighbors (outside lists, blocks are always separated by one):
 *   - a table: the line before would swallow its header row as paragraph
 *     text, and a paragraph line after it would read as another row;
 *   - a block quote after a paragraph: micromark reads what starts the quote
 *     as if it interrupted that paragraph, so `> 10. item` is not a list.
 */
const joinInListItems: Join = (left, right, parent) => {
  if (!('spread' in parent)) return undefined
  if (left.type === 'table' || right.type === 'table' || right.type === 'blockquote') return 1
  return undefined
}

const OPTIONS: Options = {
  bullet: '-',
  bulletOther: '*',
  bulletOrdered: '.',
  emphasis: '*',
  strong: '*',
  fence: '`',
  fences: true,
  incrementListMarker: true,
  listItemIndent: 'one',
  rule: '-',
  ruleRepetition: 3,
  ruleSpaces: false,
  quote: '"',
  resourceLink: false,
  setext: false,
  closeAtx: false,
  extensions: [
    gfmAutolinkLiteralToMarkdown(),
    gfmStrikethroughToMarkdown(),
    gfmTableToMarkdown(),
    gfmTaskListItemToMarkdown(),
    {
      unsafe: RELAXED,
      join: [joinInListItems],
      handlers: {
        root: handleRoot,
        paragraph: handleParagraph,
        break: handleBreak,
        code: handleCode,
        table: handleTable,
        literalAutolink: handleLiteralAutolink,
      },
    },
  ],
}

// ---------------------------------------------------------------------------
// Literal autolinks
// ---------------------------------------------------------------------------

const verified = new Map<string, boolean>()

/**
 * Checks, with the real parser, that `sample` reads back as exactly one link
 * to `url` whose text is `label` (plus the given plain text around it).
 */
function readsBackAsLink(sample: string, before: string, label: string, url: string, after: string): boolean {
  const key = `${sample}\u0000${url}`
  const known = verified.get(key)
  if (known !== undefined) return known

  const block = parseToMdast(sample).children
  const children = block.length === 1 && block[0]?.type === 'paragraph' ? block[0].children : []
  const expected = (before ? 1 : 0) + 1 + (after ? 1 : 0)
  const link = children[before ? 1 : 0]
  const first = children[0]
  const last = children[children.length - 1]
  const ok =
    children.length === expected &&
    link?.type === 'link' &&
    link.url === url &&
    link.children.length === 1 &&
    link.children[0]?.type === 'text' &&
    link.children[0].value === label &&
    (!before || (first?.type === 'text' && first.value === before)) &&
    (!after || (last?.type === 'text' && last.value === after))

  if (verified.size > 2000) verified.clear()
  verified.set(key, ok)
  return ok
}

/**
 * Returns the text to write for a link that can go out as a bare URL
 * (`https://example.com/a_b`), or null to keep the `<…>` / `[…](…)` form.
 *
 * Only the plain cases qualify: the link text is the URL itself, a blank or
 * `(` comes before it, and what follows is the end of the block, a blank, or
 * closing punctuation. Whether GFM really reads the result as the same link
 * is then confirmed by parsing it.
 */
function bareAutolink(link: Link, previous: PhrasingContent | undefined, next: PhrasingContent | undefined): string | null {
  if (link.title) return null
  const only = link.children[0]
  if (link.children.length !== 1 || only?.type !== 'text') return null
  const label = only.value
  if (!/^(?:https?:\/\/|www\.)/i.test(label) && !label.includes('@')) return null

  let before = ''
  if (previous) {
    if (previous.type !== 'text') return null
    const last = previous.value.charAt(previous.value.length - 1)
    if (last === '(') before = '('
    else if (/\s/.test(last)) before = 'a '
    else return null
  }

  let after = ''
  if (next) {
    if (next.type !== 'text') return null
    const match = /^[.,;:!?)]*(?=\s|$)/.exec(next.value)
    if (!match) return null
    after = match[0] + (next.value.length > match[0].length ? ' a' : '')
  }

  return readsBackAsLink(before + label + after, before, label, link.url, after) ? label : null
}

function withLiteralAutolinks(children: PhrasingContent[]): PhrasingContent[] {
  return children.map((node, index) => {
    if (node.type !== 'link') return node
    const value = bareAutolink(node, children[index - 1], children[index + 1])
    return value === null ? node : { type: 'literalAutolink', value }
  })
}

// ---------------------------------------------------------------------------
// ProseMirror JSON -> mdast
// ---------------------------------------------------------------------------

function phrasing(flat: Flat[], context: InlineContext): PhrasingContent[] {
  return withLiteralAutolinks(canonicalTree(flat, context))
}

function textOf(node: LooseNodeJSON): string {
  if (node.type === NODE.text) return node.text ?? ''
  return (node.content ?? []).map(textOf).join('')
}

function codeInfo(attrs: LooseNodeJSON['attrs']): { lang: string | null; meta: string | null } {
  const language = typeof attrs?.language === 'string' ? attrs.language.trim() : ''
  const rest = typeof attrs?.meta === 'string' ? attrs.meta : ''
  // The first word of an info string is the language; anything after it is meta.
  const [lang = '', ...extra] = language.split(/\s+/)
  const meta = [...extra, rest].join(' ').replace(/\s+/g, ' ').trim()
  if (lang === '') return { lang: null, meta: null }
  return { lang, meta: meta === '' ? null : meta }
}

function listItems(node: LooseNodeJSON, task: boolean): ListItem[] {
  return (node.content ?? []).map((item) => {
    const children = blocks(item.content, task) as ListItem['children']
    const listItem: ListItem = { type: 'listItem', spread: false, children }
    if (task) listItem.checked = item.attrs?.checked === true
    return listItem
  })
}

function list(node: LooseNodeJSON, ordered: boolean, task: boolean): List {
  const value: List = { type: 'list', ordered, spread: false, children: listItems(node, task) }
  if (ordered) value.start = typeof node.attrs?.start === 'number' ? node.attrs.start : 1
  return value
}

interface Cell {
  align: 'left' | 'right' | 'center' | null
  children: PhrasingContent[]
}

function cellAlign(value: unknown): Cell['align'] {
  return value === 'left' || value === 'right' || value === 'center' ? value : null
}

/** A GFM cell holds one line of inline content; several paragraphs are joined with breaks. */
function cellContent(cell: LooseNodeJSON): PhrasingContent[] {
  const flat: Flat[] = []
  for (const block of cell.content ?? []) {
    const part = block.type === NODE.paragraph ? flatFromJSON(block.content) : flatFromJSON([{ type: NODE.text, text: textOf(block) }])
    if (part.length === 0) continue
    if (flat.length > 0) flat.push({ kind: 'break' })
    flat.push(...part)
  }
  return phrasing(flat, 'tableCell')
}

function table(node: LooseNodeJSON): Table | null {
  const rows: Cell[][] = (node.content ?? []).map((row) => {
    const cells: Cell[] = []
    for (const cell of row.content ?? []) {
      cells.push({ align: cellAlign(cell.attrs?.align), children: cellContent(cell) })
      // A merged cell cannot be written in GFM; keep the columns aligned.
      const span = typeof cell.attrs?.colspan === 'number' ? cell.attrs.colspan : 1
      for (let extra = 1; extra < span; extra++) cells.push({ align: null, children: [] })
    }
    return cells
  })
  const width = Math.max(0, ...rows.map((row) => row.length))
  if (rows.length === 0 || width === 0) return null

  const padded = rows.map((row) => {
    const cells = row.slice()
    while (cells.length < width) cells.push({ align: null, children: [] })
    return cells
  })
  return {
    type: 'table',
    align: (padded[0] ?? []).map((cell) => cell.align),
    children: padded.map((row) => ({
      type: 'tableRow',
      children: row.map((cell) => ({ type: 'tableCell', children: cell.children })),
    })),
  }
}

/**
 * @param keepFirstParagraph Keep an empty first paragraph (a task item needs
 *   it to carry its checkbox). Every other empty paragraph is dropped because
 *   Markdown has no way to write one.
 */
function blocks(nodes: LooseNodeJSON[] | undefined, keepFirstParagraph = false): RootContent[] {
  const out: RootContent[] = []
  ;(nodes ?? []).forEach((node, index) => {
    switch (node.type) {
      case NODE.paragraph: {
        const children = phrasing(flatFromJSON(node.content), 'paragraph')
        if (children.length > 0 || (keepFirstParagraph && index === 0)) {
          out.push({ type: 'paragraph', children })
        }
        break
      }
      case NODE.heading: {
        const level = typeof node.attrs?.level === 'number' ? node.attrs.level : 1
        const depth = Math.min(6, Math.max(1, Math.round(level))) as 1 | 2 | 3 | 4 | 5 | 6
        out.push({ type: 'heading', depth, children: phrasing(flatFromJSON(node.content), 'heading') })
        break
      }
      case NODE.blockquote:
        out.push({ type: 'blockquote', children: blocks(node.content) as BlockContent[] })
        break
      case NODE.bulletList:
        out.push(list(node, false, false))
        break
      case NODE.orderedList:
        out.push(list(node, true, false))
        break
      case NODE.taskList:
        out.push(list(node, false, true))
        break
      case NODE.codeBlock:
        out.push({ type: 'code', ...codeInfo(node.attrs), value: textOf(node) })
        break
      case NODE.horizontalRule:
        out.push({ type: 'thematicBreak' })
        break
      case NODE.table: {
        const value = table(node)
        if (value) out.push(value)
        break
      }
      case NODE.image: {
        // Block image: its own paragraph, `![alt](src "title")`.
        const children = phrasing(flatFromJSON([node]), 'paragraph')
        if (children.length > 0) out.push({ type: 'paragraph', children })
        break
      }
      default:
        // Unknown container: keep whatever blocks it holds.
        out.push(...blocks(node.content))
        break
    }
  })
  return out
}

/** ProseMirror JSON document -> Markdown text. */
export function serializeMarkdown(doc: LooseNodeJSON): string {
  const tree: Root = { type: 'root', children: blocks(doc.content) }
  const markdown = toMarkdown(tree, OPTIONS).replace(/\n+$/, '')
  // Exactly one trailing newline; an empty document is an empty file.
  return markdown === '' ? '' : `${markdown}\n`
}

