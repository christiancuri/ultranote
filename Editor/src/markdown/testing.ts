/**
 * Helpers shared by the adapter tests. Nothing here is used by the app.
 */
import { readdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { getSchema } from '@tiptap/core'
import type { Schema } from '@tiptap/pm/model'

import { createExtensions } from '../editor/extensions'
import type { LooseNodeJSON, NodeJSON } from './types'

const here = dirname(fileURLToPath(import.meta.url))

export interface Fixture {
  name: string
  source: string
}

/** Fixtures in `corpus/<folder>` whose name ends with `suffix`, sorted by name. */
export function readFixtures(folder: string, suffix = '.md'): Fixture[] {
  const dir = join(here, 'corpus', folder)
  return readdirSync(dir)
    .filter((file) => file.endsWith(suffix))
    .sort()
    .map((file) => ({ name: file, source: readFileSync(join(dir, file), 'utf8') }))
}

export function readFixture(folder: string, name: string): string {
  return readFileSync(join(here, 'corpus', folder, name), 'utf8')
}

let cachedSchema: Schema | undefined

/** The real editor schema, so tests reject documents the editor could not load. */
export function editorSchema(): Schema {
  cachedSchema ??= getSchema(createExtensions({ mode: 'edit' }))
  return cachedSchema
}

/** Throws when `doc` is not a valid document for the editor schema. */
export function assertValidDocument(doc: LooseNodeJSON): void {
  editorSchema().nodeFromJSON(doc).check()
}

export interface FencedBlock {
  language: string
  body: string
}

/**
 * Finds fenced code blocks with a plain line scanner, on purpose independent of
 * the Markdown parser under test. Handles fences nested in lists and quotes by
 * stripping the opening line's prefix from every body line.
 */
export function scanFencedBlocks(markdown: string): FencedBlock[] {
  const blocks: FencedBlock[] = []
  const lines = markdown.split('\n')
  let index = 0
  while (index < lines.length) {
    const open = /^((?:[ >]|[-*+] |\d+[.)] )*)(`{3,}|~{3,})(.*)$/.exec(lines[index] as string)
    const [, prefix = '', fence = '', info = ''] = open ?? []
    // A backtick fence cannot have a backtick in its info string.
    if (!open || (fence.startsWith('`') && info.includes('`'))) {
      index++
      continue
    }
    const indent = prefix.replace(/[^>]/g, ' ')
    const marker = fence.charAt(0)
    const body: string[] = []
    index++
    while (index < lines.length) {
      const line = lines[index] as string
      const stripped = stripPrefix(line, indent)
      const close = new RegExp(`^ {0,3}\\${marker}{${fence.length},}\\s*$`)
      index++
      if (close.test(stripped)) break
      body.push(stripped)
    }
    blocks.push({ language: info.trim().split(/\s+/)[0] ?? '', body: body.join('\n') })
  }
  return blocks
}

/** Removes a container prefix (`> `, list indentation) from a line, tolerating blank lines. */
function stripPrefix(line: string, indent: string): string {
  let position = 0
  for (const expected of indent) {
    const actual = line.charAt(position)
    if (expected === '>') {
      if (actual !== '>') return line.slice(position)
      position++
    } else if (actual === ' ') {
      position++
    } else {
      break
    }
  }
  return line.slice(position)
}

/** Code blocks of a document in reading order. */
export function codeBlocksOf(node: LooseNodeJSON, out: FencedBlock[] = []): FencedBlock[] {
  if (node.type === 'codeBlock') {
    const language = typeof node.attrs?.language === 'string' ? node.attrs.language : ''
    out.push({ language, body: (node.content ?? []).map((child) => child.text ?? '').join('') })
  }
  for (const child of node.content ?? []) codeBlocksOf(child, out)
  return out
}

/** True when `markdown` holds an HTML character reference that is not escaped or inside code. */
export function hasCharacterReference(markdown: string): boolean {
  const withoutCode = markdown
    .replace(/^( {0,3}>? ?)*(`{3,}|~{3,})[\s\S]*?\n\1?\2.*$/gm, '')
    .replace(/(`+)[\s\S]*?\1/g, '')
  return /(^|[^\\])(\\\\)*&(?:#[xX][0-9A-Fa-f]+|#[0-9]+|[A-Za-z][A-Za-z0-9]*);/.test(withoutCode)
}

/** Small deterministic PRNG (mulberry32) so fuzz failures can be replayed by seed. */
export function createRandom(seed: number): () => number {
  let state = seed >>> 0
  return () => {
    state = (state + 0x6d2b79f5) >>> 0
    let value = state
    value = Math.imul(value ^ (value >>> 15), value | 1)
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61)
    return ((value ^ (value >>> 14)) >>> 0) / 4294967296
  }
}

export function pick<T>(random: () => number, items: readonly T[]): T {
  return items[Math.floor(random() * items.length)] as T
}

/** All text of a document, in order, without any whitespace. */
export function visibleText(node: LooseNodeJSON): string {
  if (node.type === 'text') return (node.text ?? '').replace(/\s+/g, '')
  return (node.content ?? []).map(visibleText).join('')
}

export const paragraph = (...content: NodeJSON[]): NodeJSON =>
  content.length > 0 ? { type: 'paragraph', content } : { type: 'paragraph' }

export const text = (value: string, ...marks: string[]): NodeJSON =>
  marks.length > 0
    ? { type: 'text', text: value, marks: marks.map((type) => ({ type })) }
    : { type: 'text', text: value }

export const doc = (...content: NodeJSON[]): NodeJSON & { type: 'doc' } => ({ type: 'doc', content })
