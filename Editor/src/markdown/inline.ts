/**
 * Inline (phrasing) content: the one place that decides what a run of text
 * with marks looks like in Markdown.
 *
 * ProseMirror stores inline content flat (text nodes with a set of marks);
 * Markdown nests it (`**bold *and italic***`). Both directions go through the
 * same canonical tree built here:
 *
 *   parse:      mdast phrasing -> flat -> canonical tree -> flat -> ProseMirror JSON
 *   serialize:  ProseMirror JSON -> flat -> canonical tree -> mdast-util-to-markdown
 *
 * Because parsing ends with the very step serializing starts with, a parsed
 * document is already in the form the serializer writes, which is what makes
 * the round trip stable.
 *
 * The canonical form only contains what Markdown can express without HTML
 * character references:
 *   - emphasis, strong and strikethrough never start or end with whitespace
 *     (it moves outside the markers);
 *   - they never start or end with punctuation glued to a letter outside
 *     (`x**(y)**` cannot open in CommonMark, so it becomes `x(**y**)`);
 *   - hard breaks carry no marks, never sit at the edge of a block, and have no
 *     spaces around them;
 *   - text has no line endings and a block has no leading or trailing blanks.
 */
import type { Delete, Emphasis, Link, PhrasingContent, Strong, Text } from 'mdast'
import { classifyCharacter } from 'micromark-util-classify-character'

import { MARK, NODE, type LooseNodeJSON, type MarkJSON, type NodeJSON } from './types'

/** Where the inline content lives; it changes how hard breaks are written. */
export type InlineContext = 'paragraph' | 'heading' | 'tableCell'

export interface LinkAttrs {
  href: string
  title: string | null
}

export interface FlatText {
  kind: 'text'
  text: string
  code: boolean
  bold: boolean
  italic: boolean
  strike: boolean
  link: LinkAttrs | null
}

export interface FlatImage {
  kind: 'image'
  src: string
  alt: string | null
  title: string | null
  link: LinkAttrs | null
}

export interface FlatBreak {
  kind: 'break'
}

/** Inline content the way ProseMirror sees it: a flat list, marks as flags. */
export type Flat = FlatText | FlatImage | FlatBreak

export interface FlatMarks {
  code: boolean
  bold: boolean
  italic: boolean
  strike: boolean
  link: LinkAttrs | null
}

export const NO_MARKS: FlatMarks = {
  code: false,
  bold: false,
  italic: false,
  strike: false,
  link: null,
}

export function flatText(text: string, marks: FlatMarks = NO_MARKS): FlatText {
  return {
    kind: 'text',
    text,
    code: marks.code,
    bold: marks.bold,
    italic: marks.italic,
    strike: marks.strike,
    link: marks.link,
  }
}

// ---------------------------------------------------------------------------
// ProseMirror JSON <-> flat
// ---------------------------------------------------------------------------

function asString(value: unknown): string | null {
  return typeof value === 'string' && value !== '' ? value : null
}

function linkFromMarks(marks: LooseNodeJSON['marks']): LinkAttrs | null {
  const mark = marks?.find((candidate) => candidate.type === MARK.link)
  const href = asString(mark?.attrs?.href)
  if (href === null) return null
  return { href, title: asString(mark?.attrs?.title) }
}

/** Reads the inline children of a ProseMirror text block. Unknown nodes and marks are dropped. */
export function flatFromJSON(nodes: LooseNodeJSON[] | undefined): Flat[] {
  const out: Flat[] = []
  for (const node of nodes ?? []) {
    if (node.type === NODE.text) {
      if (!node.text) continue
      const has = (name: string) => node.marks?.some((mark) => mark.type === name) ?? false
      out.push({
        kind: 'text',
        text: node.text,
        code: has(MARK.code),
        bold: has(MARK.bold),
        italic: has(MARK.italic),
        strike: has(MARK.strike),
        link: linkFromMarks(node.marks),
      })
    } else if (node.type === NODE.image || node.type === NODE.inlineImage) {
      const src = asString(node.attrs?.src)
      if (src === null) continue
      out.push({
        kind: 'image',
        src,
        alt: asString(node.attrs?.alt),
        title: asString(node.attrs?.title),
        link: linkFromMarks(node.marks),
      })
    } else if (node.type === NODE.hardBreak) {
      out.push({ kind: 'break' })
    }
  }
  return out
}

function linkMark(link: LinkAttrs): MarkJSON {
  return { type: MARK.link, attrs: { href: link.href, title: link.title } }
}

/** Writes flat inline content as ProseMirror JSON, with marks in a fixed order. */
export function jsonFromFlat(flat: Flat[]): NodeJSON[] {
  const out: NodeJSON[] = []
  for (const node of flat) {
    if (node.kind === 'break') {
      out.push({ type: NODE.hardBreak })
    } else if (node.kind === 'image') {
      const json: NodeJSON = {
        type: NODE.inlineImage,
        attrs: { src: node.src, alt: node.alt, title: node.title },
      }
      if (node.link) json.marks = [linkMark(node.link)]
      out.push(json)
    } else {
      const marks: MarkJSON[] = []
      if (node.link) marks.push(linkMark(node.link))
      if (node.bold) marks.push({ type: MARK.bold })
      if (node.italic) marks.push({ type: MARK.italic })
      if (node.strike) marks.push({ type: MARK.strike })
      if (node.code) marks.push({ type: MARK.code })
      const json: NodeJSON = { type: NODE.text, text: node.text }
      if (marks.length > 0) json.marks = marks
      out.push(json)
    }
  }
  return out
}

// ---------------------------------------------------------------------------
// Flat cleanup
// ---------------------------------------------------------------------------

function sameLink(a: LinkAttrs | null, b: LinkAttrs | null): boolean {
  if (a === null || b === null) return a === b
  return a.href === b.href && a.title === b.title
}

function sameMarks(a: FlatText, b: FlatText): boolean {
  return (
    a.code === b.code &&
    a.bold === b.bold &&
    a.italic === b.italic &&
    a.strike === b.strike &&
    sameLink(a.link, b.link)
  )
}

function pushFlat(out: Flat[], node: Flat): void {
  const last = out[out.length - 1]
  if (node.kind === 'text' && last?.kind === 'text' && sameMarks(last, node)) {
    out[out.length - 1] = { ...last, text: last.text + node.text }
  } else {
    out.push(node)
  }
}

/**
 * Removes what Markdown cannot hold in inline content: line endings inside
 * text (a soft break is a space), empty text, and hard breaks in headings.
 * Adjacent text with the same marks is merged.
 */
function cleanFlat(flat: Flat[], context: InlineContext): Flat[] {
  const out: Flat[] = []
  for (const node of flat) {
    if (node.kind === 'break') {
      if (context === 'heading') pushFlat(out, flatText(' '))
      else out.push(node)
    } else if (node.kind === 'text') {
      const text = node.text.replace(/\r\n?|\n/g, ' ')
      if (text !== '') pushFlat(out, { ...node, text })
    } else {
      out.push(node)
    }
  }
  return out
}

// ---------------------------------------------------------------------------
// Flat -> nested tree
// ---------------------------------------------------------------------------

type WrapKey = 'link' | 'bold' | 'italic' | 'strike'

/**
 * Tie-break order when several marks cover the same run. A link goes outermost
 * so emphasis sits inside its brackets, and italic goes around bold so both
 * together are written `***text***` rather than `**_text_**`.
 */
const WRAP_ORDER: readonly WrapKey[] = ['link', 'strike', 'italic', 'bold']

function carries(node: Flat, key: WrapKey, reference: Flat): boolean {
  if (node.kind === 'break') return false
  if (key === 'link') {
    if (reference.kind === 'break') return false
    return node.link !== null && sameLink(node.link, reference.link)
  }
  return node.kind === 'text' && node[key]
}

function leaf(node: Flat): PhrasingContent {
  if (node.kind === 'break') return { type: 'break' }
  if (node.kind === 'image') {
    return { type: 'image', url: node.src, alt: node.alt ?? '', title: node.title }
  }
  if (node.code) return { type: 'inlineCode', value: node.text }
  return { type: 'text', value: node.text }
}

function wrap(key: WrapKey, first: Flat, children: PhrasingContent[]): PhrasingContent {
  if (key === 'bold') return { type: 'strong', children }
  if (key === 'italic') return { type: 'emphasis', children }
  if (key === 'strike') return { type: 'delete', children }
  const link = first.kind === 'break' ? null : first.link
  return { type: 'link', url: link?.href ?? '', title: link?.title ?? null, children }
}

/**
 * Turns flat marks into nested nodes. At each position the mark that stays
 * active the longest becomes the outer wrapper, so `*a **b** c*` keeps one
 * emphasis around everything instead of three separate ones.
 */
function nest(nodes: Flat[], used: ReadonlySet<WrapKey>): PhrasingContent[] {
  const out: PhrasingContent[] = []
  let index = 0
  while (index < nodes.length) {
    const node = nodes[index] as Flat
    let best: WrapKey | null = null
    let bestLength = 0
    for (const key of WRAP_ORDER) {
      if (used.has(key) || !carries(node, key, node)) continue
      let length = 1
      while (index + length < nodes.length && carries(nodes[index + length] as Flat, key, node)) {
        length++
      }
      if (length > bestLength) {
        best = key
        bestLength = length
      }
    }
    if (best === null) {
      out.push(leaf(node))
      index++
      continue
    }
    const group = nodes.slice(index, index + bestLength)
    out.push(wrap(best, node, nest(group, new Set([...used, best]))))
    index += bestLength
  }
  return out
}

// ---------------------------------------------------------------------------
// Tree canonicalization
// ---------------------------------------------------------------------------

type Attention = Emphasis | Strong | Delete

function isAttention(node: PhrasingContent): node is Attention {
  return node.type === 'emphasis' || node.type === 'strong' || node.type === 'delete'
}

function text(value: string): Text {
  return { type: 'text', value }
}

function pushPhrasing(out: PhrasingContent[], node: PhrasingContent): void {
  const last = out[out.length - 1]
  if (node.type === 'text') {
    if (node.value === '') return
    if (last?.type === 'text') {
      out[out.length - 1] = text(last.value + node.value)
      return
    }
  }
  out.push(node)
}

/**
 * What a character next to an emphasis marker counts as. CommonMark decides
 * whether `*` can open or close by looking at exactly this.
 */
type Kind = 'letter' | 'other'

const WHITESPACE = 1
const PUNCTUATION = 2

function lastCodePoint(value: string): number {
  const last = value.charCodeAt(value.length - 1)
  if (last >= 0xdc00 && last <= 0xdfff && value.length >= 2) {
    const point = value.codePointAt(value.length - 2)
    if (point !== undefined && point > 0xffff) return point
  }
  return last
}

function kindOf(code: number | undefined): Kind {
  return code !== undefined && classifyCharacter(code) === undefined ? 'letter' : 'other'
}

function kindAtEnd(node: PhrasingContent | undefined): Kind {
  if (node === undefined) return 'other'
  if (node.type === 'text') return kindOf(lastCodePoint(node.value))
  // Markers of adjacent emphasis merge into one run, so look through them.
  if (isAttention(node)) return kindAtEnd(node.children[node.children.length - 1])
  return 'other'
}

function kindAtStart(node: PhrasingContent | undefined): Kind {
  if (node === undefined) return 'other'
  if (node.type === 'text') return kindOf(node.value.codePointAt(0))
  if (isAttention(node)) return kindAtStart(node.children[0])
  return 'other'
}

/** Length (in UTF-16 units) of the run of characters of one class at the start of `value`. */
function leadingRun(value: string, group: number): number {
  let index = 0
  while (index < value.length) {
    const point = value.codePointAt(index) as number
    if (classifyCharacter(point) !== group) break
    index += point > 0xffff ? 2 : 1
  }
  return index
}

function trailingRun(value: string, group: number): number {
  let end = value.length
  while (end > 0) {
    const point = lastCodePoint(value.slice(0, end))
    if (classifyCharacter(point) !== group) break
    end -= point > 0xffff ? 2 : 1
  }
  return value.length - end
}

interface Expelled {
  pre: PhrasingContent[]
  body: PhrasingContent[]
  post: PhrasingContent[]
}

/**
 * Moves out of an emphasis/strong/strikethrough node whatever would stop its
 * markers from opening or closing: whitespace at its edges, and punctuation at
 * an edge that touches a letter on the outside.
 */
function expel(children: PhrasingContent[], before: Kind, after: Kind): Expelled {
  const body = children.slice()
  const pre: PhrasingContent[] = []
  const post: PhrasingContent[] = []

  for (;;) {
    const first = body[0]
    if (first === undefined || first.type !== 'text') break
    let cut = leadingRun(first.value, WHITESPACE)
    if (cut === 0 && before === 'letter') cut = leadingRun(first.value, PUNCTUATION)
    if (cut === 0) break
    pushPhrasing(pre, text(first.value.slice(0, cut)))
    before = 'other'
    if (cut === first.value.length) body.shift()
    else body[0] = text(first.value.slice(cut))
  }

  for (;;) {
    const last = body[body.length - 1]
    if (last === undefined || last.type !== 'text') break
    let cut = trailingRun(last.value, WHITESPACE)
    if (cut === 0 && after === 'letter') cut = trailingRun(last.value, PUNCTUATION)
    if (cut === 0) break
    const keep = last.value.length - cut
    post.unshift(text(last.value.slice(keep)))
    after = 'other'
    if (keep === 0) body.pop()
    else body[body.length - 1] = text(last.value.slice(0, keep))
  }

  return { pre, body, post }
}

function expelAll(children: PhrasingContent[], before: Kind, after: Kind): PhrasingContent[] {
  const out: PhrasingContent[] = []
  children.forEach((node, index) => {
    if (isAttention(node)) {
      const kindBefore = out.length > 0 ? kindAtEnd(out[out.length - 1]) : before
      const kindAfter = index + 1 < children.length ? kindAtStart(children[index + 1]) : after
      const inner = expelAll(node.children, kindBefore, kindAfter)
      const { pre, body, post } = expel(inner, kindBefore, kindAfter)
      for (const moved of pre) pushPhrasing(out, moved)
      if (body.length > 0) pushPhrasing(out, { ...node, children: body })
      for (const moved of post) pushPhrasing(out, moved)
    } else if (node.type === 'link') {
      // Link text sits between brackets: punctuation on both sides.
      pushPhrasing(out, { ...node, children: expelAll(node.children, 'other', 'other') })
    } else {
      pushPhrasing(out, node)
    }
  })
  return out
}

/**
 * Trims spaces and tabs at the edges of the block and around hard breaks, and
 * drops hard breaks at the edges. Markdown would strip all of these on the
 * next parse; the serializer could only keep them as `&#x20;`.
 */
function trimBlock(nodes: PhrasingContent[]): PhrasingContent[] {
  const out = nodes.slice()
  let changed = true
  while (changed) {
    changed = false
    for (let index = 0; index < out.length; index++) {
      const node = out[index] as PhrasingContent
      const atStart = index === 0
      const atEnd = index === out.length - 1
      if (node.type === 'break') {
        if (atStart || atEnd) {
          out.splice(index, 1)
          changed = true
          break
        }
        continue
      }
      if (node.type !== 'text') continue
      let value = node.value
      if (atStart || out[index - 1]?.type === 'break') value = value.replace(/^[ \t]+/, '')
      if (atEnd || out[index + 1]?.type === 'break') value = value.replace(/[ \t]+$/, '')
      if (value === node.value) continue
      if (value === '') out.splice(index, 1)
      else out[index] = text(value)
      changed = true
      break
    }
  }
  const merged: PhrasingContent[] = []
  for (const node of out) pushPhrasing(merged, node)
  return merged
}

/**
 * Flat inline content -> the canonical mdast phrasing tree (see the file header).
 *
 * Moving characters out of a mark can change which mark covers the longest
 * run, and so the nesting. The steps repeat until the flat content no longer
 * changes; that always happens, because each round can only take marks off
 * characters or drop blanks.
 */
export function canonicalTree(flat: Flat[], context: InlineContext): PhrasingContent[] {
  let current = cleanFlat(flat, context)
  let key = JSON.stringify(current)
  for (;;) {
    const tree = trimBlock(expelAll(nest(current, new Set()), 'other', 'other'))
    const next = flatFromTree(tree)
    const nextKey = JSON.stringify(next)
    if (nextKey === key) return tree
    current = next
    key = nextKey
  }
}

// ---------------------------------------------------------------------------
// Tree -> flat
// ---------------------------------------------------------------------------

function flattenInto(nodes: PhrasingContent[], marks: FlatMarks, out: Flat[]): void {
  for (const node of nodes) {
    switch (node.type) {
      case 'text':
        if (node.value !== '') pushFlat(out, flatText(node.value, marks))
        break
      case 'inlineCode':
        if (node.value !== '') pushFlat(out, flatText(node.value, { ...marks, code: true }))
        break
      case 'emphasis':
        flattenInto(node.children, { ...marks, italic: true }, out)
        break
      case 'strong':
        flattenInto(node.children, { ...marks, bold: true }, out)
        break
      case 'delete':
        flattenInto(node.children, { ...marks, strike: true }, out)
        break
      case 'link':
        flattenInto(node.children, { ...marks, link: linkOf(node) }, out)
        break
      case 'image':
        out.push({
          kind: 'image',
          src: node.url,
          alt: node.alt ? node.alt : null,
          title: node.title ?? null,
          link: marks.link,
        })
        break
      case 'break':
        out.push({ kind: 'break' })
        break
      default:
        break
    }
  }
}

export function linkOf(node: Link): LinkAttrs {
  return { href: node.url, title: node.title ? node.title : null }
}

/** Canonical tree -> flat inline content. Inverse of the nesting step. */
export function flatFromTree(tree: PhrasingContent[]): Flat[] {
  const out: Flat[] = []
  flattenInto(tree, NO_MARKS, out)
  return out
}

/** Flat inline content -> canonical ProseMirror JSON (used by the parser). */
export function canonicalInlineJSON(flat: Flat[], context: InlineContext): NodeJSON[] {
  return jsonFromFlat(flatFromTree(canonicalTree(flat, context)))
}
