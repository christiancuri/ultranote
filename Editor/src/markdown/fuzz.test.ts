/**
 * Randomized round trips: builds editor documents out of awkward pieces
 * (markup-like text, every mark, nested containers) and checks that, after one
 * save, saving again changes nothing and the document reads back the same.
 *
 * Seeded, so a failure prints a seed that reproduces it.
 */
import { describe, expect, it } from 'vitest'

import { parseMarkdown, serializeMarkdown } from './index'
import { assertValidDocument, createRandom, pick } from './testing'
import type { MarkJSON, NodeJSON } from './types'

const WORDS = [
  'word', 'snake_case', 'a < b', '&', 'AT&T', '&amp;', '<kbd>', '</kbd>', '*', '**', '_', '__init__',
  '`', '``', '~', '~~', '#', '# ', '#tag', '- ', '+ ', '1. ', '1)', '> ', '|', '\\', '[', ']', '](', '(',
  ')', '!', '![', '[ ] ', '[x] ', '---', '===', 'https://example.com/a_b', 'www.example.com', 'me@example.com',
  'açúcar', '日本', '🎉', ' ', '  ', '.', ',', ':', '"', "'", '<br>', '<!--', '-->', '&#38;', 'x',
]

const MARKS = ['bold', 'italic', 'strike', 'code']
const LINKS = ['https://example.com/a_b', 'notes/my file.md', 'https://example.com/(x)', 'mailto:me@example.com']

type Random = () => number

function inline(random: Random, allowBreaks: boolean): NodeJSON[] {
  const out: NodeJSON[] = []
  const count = 1 + Math.floor(random() * 6)
  for (let index = 0; index < count; index++) {
    if (allowBreaks && random() < 0.08) {
      out.push({ type: 'hardBreak' })
      continue
    }
    if (random() < 0.05) {
      out.push({ type: 'inlineImage', attrs: { src: 'attachments/a_b.png', alt: pick(random, ['', 'alt *x*', 'a_b']), title: null } })
      continue
    }
    let value = ''
    const parts = 1 + Math.floor(random() * 3)
    for (let part = 0; part < parts; part++) value += pick(random, WORDS)
    const marks: MarkJSON[] = []
    if (random() < 0.15) marks.push({ type: 'link', attrs: { href: pick(random, LINKS), title: random() < 0.3 ? 'T "q"' : null } })
    for (const mark of MARKS) if (random() < 0.2) marks.push({ type: mark })
    const node: NodeJSON = { type: 'text', text: value }
    if (marks.length > 0) node.marks = marks
    out.push(node)
  }
  return out
}

function image(random: Random): NodeJSON {
  const title = random() < 0.3 ? 'T "q"' : null
  return { type: 'image', attrs: { src: pick(random, ['attachments/a_b.png', 'attachments/my pic.png']), alt: pick(random, ['', 'alt *x*']), title } }
}

function paragraph(random: Random, allowBreaks = true): NodeJSON {
  return { type: 'paragraph', content: inline(random, allowBreaks) }
}

function block(random: Random, depth: number): NodeJSON {
  const roll = random()
  if (depth > 2 || roll < 0.32) return paragraph(random)
  if (roll < 0.35) return image(random)
  if (roll < 0.45) {
    return { type: 'heading', attrs: { level: 1 + Math.floor(random() * 6) }, content: inline(random, false) }
  }
  if (roll < 0.52) {
    return {
      type: 'codeBlock',
      attrs: { language: pick(random, [null, 'js', 'mermaid', 'text']), meta: null },
      content: [{ type: 'text', text: pick(random, ['a\n  b', '```\nx\n```', '~~~', '  lead\ntrail  ', '<kbd> &amp; *x*']) }],
    }
  }
  if (roll < 0.58) return { type: 'blockquote', content: blocks(random, depth + 1) }
  if (roll < 0.66) return list(random, depth, 'bulletList', 'listItem')
  if (roll < 0.72) return { ...list(random, depth, 'orderedList', 'listItem'), attrs: { start: pick(random, [1, 3, 10]) } }
  if (roll < 0.8) return list(random, depth, 'taskList', 'taskItem')
  if (roll < 0.86) return { type: 'horizontalRule' }
  return table(random)
}

function blocks(random: Random, depth: number): NodeJSON[] {
  const count = 1 + Math.floor(random() * 3)
  return Array.from({ length: count }, () => block(random, depth))
}

function list(random: Random, depth: number, type: string, itemType: string): NodeJSON {
  const count = 1 + Math.floor(random() * 3)
  return {
    type,
    content: Array.from({ length: count }, () => {
      const item: NodeJSON = {
        type: itemType,
        content: [paragraph(random), ...(random() < 0.3 ? blocks(random, depth + 1) : [])],
      }
      if (itemType === 'taskItem') item.attrs = { checked: random() < 0.5 }
      return item
    }),
  }
}

function table(random: Random): NodeJSON {
  const columns = 1 + Math.floor(random() * 3)
  const rows = 1 + Math.floor(random() * 3)
  const align = Array.from({ length: columns }, () => pick(random, [null, 'left', 'center', 'right']))
  return {
    type: 'table',
    content: Array.from({ length: rows }, (_, row) => ({
      type: 'tableRow',
      content: align.map((value) => {
        const cell: NodeJSON = {
          type: row === 0 ? 'tableHeader' : 'tableCell',
          content: [random() < 0.2 ? { type: 'paragraph' } : paragraph(random)],
        }
        if (value) cell.attrs = { align: value }
        return cell
      }),
    })),
  }
}

describe('random documents', () => {
  const seeds = Array.from({ length: 1000 }, (_, index) => index + 1)

  it.each(seeds)('seed %i', (seed) => {
    const random = createRandom(seed)
    const document = { type: 'doc', content: blocks(random, 0) }
    assertValidDocument(document)

    const first = serializeMarkdown(document)
    const normalized = parseMarkdown(first)
    assertValidDocument(normalized)

    const second = serializeMarkdown(normalized)
    expect(second).toBe(first)
    expect(parseMarkdown(second)).toEqual(normalized)
    expect(second === '' || (second.endsWith('\n') && !second.endsWith('\n\n'))).toBe(true)
  })
})
