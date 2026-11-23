/**
 * Golden corpus for the Markdown adapter (Gate B).
 *
 * `corpus/canonical/*.md` are files already in the form the adapter writes:
 * they must come back byte-identical. `corpus/normalized/*.in.md` are files in
 * other valid styles: they must come out as the paired `*.out.md`.
 *
 * Every fixture, in both folders, is also held to the general requirements:
 *   (a) semantic stability   parse(serialize(parse(x))) equals parse(x)
 *   (b) idempotence          a second pass is byte-identical
 *   (c) no HTML entities     nothing is escaped as a character reference
 *   (d) code fidelity        fenced code keeps its language and exact body
 *   (e) one final newline
 */
import { describe, expect, it } from 'vitest'

import { normalizeMarkdown, parseMarkdown, serializeMarkdown, type LooseNodeJSON } from './index'
import {
  assertValidDocument,
  codeBlocksOf,
  editorSchema,
  hasCharacterReference,
  readFixture,
  readFixtures,
  scanFencedBlocks,
} from './testing'

const canonical = readFixtures('canonical')
const normalized = readFixtures('normalized', '.in.md')

/** Topics the corpus has to cover; each must be backed by a canonical fixture. */
const REQUIRED_TOPICS = [
  'headings',
  'emphasis-inline-code',
  'links',
  'images',
  'blockquotes',
  'horizontal-rules',
  'lists',
  'task-lists',
  'tables',
  'code',
  'mermaid',
  'accents',
  'escaping',
]

describe('corpus coverage', () => {
  it.each(REQUIRED_TOPICS)('has a canonical fixture for %s', (topic) => {
    expect(canonical.some((fixture) => fixture.name.includes(topic))).toBe(true)
  })
})

describe.each([...canonical, ...normalized])('$name', ({ source }) => {
  const document = parseMarkdown(source)
  const output = serializeMarkdown(document)

  it('parses into a document the editor schema accepts', () => {
    expect(() => assertValidDocument(document)).not.toThrow()
  })

  it('serializes the same after a trip through the editor schema', () => {
    // What the app serializes is `editor.getJSON()`: schema defaults filled in,
    // marks sorted by the schema. The output must not depend on that.
    const viaSchema = editorSchema().nodeFromJSON(document).toJSON() as LooseNodeJSON
    expect(serializeMarkdown(viaSchema)).toBe(output)
  })

  it('(a) is semantically stable', () => {
    const reparsed = parseMarkdown(output)
    expect(reparsed).toEqual(document)
    // Same check through the real schema, which also normalizes mark order.
    const schema = editorSchema()
    expect(schema.nodeFromJSON(reparsed).eq(schema.nodeFromJSON(document))).toBe(true)
  })

  it('(b) is idempotent', () => {
    expect(normalizeMarkdown(output)).toBe(output)
    expect(normalizeMarkdown(normalizeMarkdown(output))).toBe(output)
  })

  it('(c) writes no HTML character references', () => {
    expect(hasCharacterReference(output)).toBe(false)
  })

  it('(d) keeps fenced code byte-for-byte', () => {
    const written = scanFencedBlocks(output)
    expect(written).toEqual(codeBlocksOf(document))
    expect(codeBlocksOf(parseMarkdown(output))).toEqual(written)
  })

  it('(e) ends with exactly one newline', () => {
    expect(output.endsWith('\n')).toBe(true)
    expect(output.endsWith('\n\n')).toBe(false)
  })
})

describe('canonical fixtures come back unchanged', () => {
  it.each(canonical)('$name', ({ source }) => {
    expect(normalizeMarkdown(source)).toBe(source)
  })

  it.each(canonical)('$name keeps the code blocks of the source', ({ source }) => {
    // The scanner reads the file without the Markdown parser, so this compares
    // the document against the bytes on disk.
    expect(codeBlocksOf(parseMarkdown(source))).toEqual(scanFencedBlocks(source))
  })
})

describe('other styles are normalized to the expected output', () => {
  it.each(normalized)('$name', ({ name, source }) => {
    const expected = readFixture('normalized', name.replace(/\.in\.md$/, '.out.md'))
    expect(normalizeMarkdown(source)).toBe(expected)
  })
})

describe('named requirements', () => {
  const twoTables = '| a | b |\n| --- | --- |\n| 1 | 2 |\n\n| c | d |\n| --- | --- |\n| 3 | 4 |\n'

  it('two consecutive tables stay byte-identical over many passes', () => {
    let current = twoTables
    for (let pass = 0; pass < 5; pass++) {
      current = normalizeMarkdown(current)
      expect(current).toBe(twoTables)
    }
    expect(parseMarkdown(twoTables).content.map((node) => node.type)).toEqual(['table', 'table'])
  })

  it.each([
    'snake_case_name\n',
    'a < b & c > d\n',
    'https://example.com/a_b_c/file_name.md?user_id=1&sort_by=created_at\n',
    'Mixed: snake_case_name, a < b & c > d and https://example.com/a_b_c.\n',
  ])('leaves %j unchanged', (source) => {
    expect(normalizeMarkdown(source)).toBe(source)
  })

  it('keeps a mermaid block as a plain fence with its exact body', () => {
    const body = 'graph TD\n  A[Start] --> B{Ok?}\n  B -- "yes & no" --> C[Done]\n\n  %% comment   '
    const source = `\`\`\`mermaid\n${body}\n\`\`\`\n`
    const document = parseMarkdown(source)
    expect(document.content).toEqual([
      { type: 'codeBlock', attrs: { language: 'mermaid', meta: null }, content: [{ type: 'text', text: body }] },
    ])
    expect(serializeMarkdown(document)).toBe(source)
  })

  it('writes an empty document as an empty file', () => {
    expect(serializeMarkdown({ type: 'doc', content: [{ type: 'paragraph' }] })).toBe('')
    expect(parseMarkdown('')).toEqual({ type: 'doc', content: [{ type: 'paragraph' }] })
    expect(parseMarkdown('\n\n  \n')).toEqual({ type: 'doc', content: [{ type: 'paragraph' }] })
  })
})
