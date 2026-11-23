/**
 * Requirement (c): no needless escaping, and what must be escaped is escaped
 * with a backslash and reads back as the same text.
 *
 * These tests start from an editor document (what the user typed), not from a
 * Markdown file, because that is where "text that looks like markup" comes from.
 */
import { describe, expect, it } from 'vitest'

import { parseMarkdown, serializeMarkdown } from './index'
import { assertValidDocument, doc, hasCharacterReference, paragraph, text } from './testing'
import type { NodeJSON } from './types'

/** Text that needs no escaping anywhere in a paragraph. */
const PLAIN = [
  'snake_case_name',
  'MAX_RETRY_COUNT and a_b_c',
  'a < b & c > d',
  'x <= y, 1 < 2 > 0, a -> b, a => b, a <- b',
  'AT&T, R&D, Q&A, a && b, ?a=1&b=2',
  'tags like #idea and item #1, C# and F#',
  '[WIP] draft, array[0], see [1], f(x)[y], [a] [b]',
  '~5 min, ~/Documents/UltraNote, a~b',
  'view.state, window.location, e.g. this, 3.14',
  '2 + 2 = 4, 50% off, $100, a^2, {braces}, a | b',
  'C:\\Users\\name and a \\ b',
  '"quoted", it\'s, (parens), a/b, a:b, a;b, wow! really?',
  'Olá, ação, coração, über, naïve, 日本語, 🎉',
  '1.5 times, version 2.0, step 1) done, 3 - 2',
]

/**
 * Text that looks like Markdown or HTML. Each entry must survive as the same
 * literal text, in every block that can hold text.
 */
const TRICKY = [
  '<kbd>',
  '<kbd>Cmd</kbd>',
  '<br>',
  '<br/>',
  '<!-- comment -->',
  '<div>',
  '</div>',
  '<a href="x">link</a>',
  '<?php echo 1 ?>',
  '<!DOCTYPE html>',
  '<![CDATA[x]]>',
  '<https://example.com>',
  '<me@example.com>',
  'x <y> z',
  '<',
  '>',
  '<<',
  '>>',
  '&amp;',
  '&lt;kbd&gt;',
  '&#38;',
  '&#x26;',
  '&copy;',
  '&nbsp;',
  '&copy',
  '&',
  '\\&amp;',
  '*x*',
  '**x**',
  '***x***',
  '_x_',
  '__x__',
  '__init__.py',
  'a*b*c',
  'a_b_c',
  '_',
  '*',
  '**',
  '* *',
  '2 * 3 * 4',
  '`code`',
  '``a`b``',
  '`',
  '~~x~~',
  '~x~',
  '~~',
  '~~~',
  '[a](b)',
  '[a](b "t")',
  '![a](b)',
  '[a][b]',
  '[a][]',
  '[a]',
  '[a]: b',
  '[a]: <b> "t"',
  '[^1]',
  '[^1]: note',
  '[',
  ']',
  '](',
  ')(',
  '[]()',
  '![]()',
  '!',
  '![',
  '# heading',
  '#',
  '######',
  '####### seven',
  '#tag',
  'trailing #',
  'trailing ##',
  '- item',
  '+ item',
  '* item',
  '-',
  '+',
  '1. item',
  '1) item',
  '1.',
  '12345. item',
  '> quote',
  '>',
  '---',
  '***',
  '___',
  '- - -',
  '===',
  '=',
  '```',
  '```js',
  '~~~js',
  '| a | b |',
  '|',
  'a | b',
  '--- | ---',
  ':---',
  '--',
  '[ ] task',
  '[x] done',
  '[ ]',
  '[x]',
  'https://example.com/a_b',
  'http://example.com',
  'www.example.com',
  'www.example.com/a_b',
  'me@example.com',
  'mailto:me@example.com',
  'see https://example.com/a_b.',
  'a@b',
  '@mention',
  'C:\\path\\to\\file',
  '\\',
  '\\\\',
  '\\*',
  '\\_',
  'ends with a backslash\\',
  '\\[x\\]',
  'a\u00a0b',
  'Setext',
  'a -- b --- c',
  '<b>*x*</b> & [y](z) `w`',
]

type Wrap = (content: NodeJSON[]) => NodeJSON

const CONTEXTS: Record<string, Wrap> = {
  paragraph: (content) => doc({ type: 'paragraph', content }),
  heading: (content) => doc({ type: 'heading', attrs: { level: 2 }, content }),
  'block quote': (content) => doc({ type: 'blockquote', content: [{ type: 'paragraph', content }] }),
  'bullet item': (content) =>
    doc({ type: 'bulletList', content: [{ type: 'listItem', content: [{ type: 'paragraph', content }] }] }),
  'ordered item': (content) =>
    doc({
      type: 'orderedList',
      attrs: { start: 1 },
      content: [{ type: 'listItem', content: [{ type: 'paragraph', content }] }],
    }),
  'task item': (content) =>
    doc({
      type: 'taskList',
      content: [{ type: 'taskItem', attrs: { checked: false }, content: [{ type: 'paragraph', content }] }],
    }),
  'table cell': (content) =>
    doc({
      type: 'table',
      content: [
        { type: 'tableRow', content: [{ type: 'tableHeader', content: [{ type: 'paragraph', content: [text('h')] }] }] },
        { type: 'tableRow', content: [{ type: 'tableCell', content: [{ type: 'paragraph', content }] }] },
      ],
    }),
  'second line of a paragraph': (content) =>
    doc({ type: 'paragraph', content: [text('first'), { type: 'hardBreak' }, ...content] }),
  'after a paragraph': (content) => doc(paragraph(text('first')), { type: 'paragraph', content }),
}

describe('plain text is written as it is', () => {
  it.each(PLAIN)('%s', (value) => {
    expect(serializeMarkdown(doc(paragraph(text(value))))).toBe(`${value}\n`)
  })
})

describe.each(Object.entries(CONTEXTS))('text that looks like markup, in a %s', (_name, wrap) => {
  it.each(TRICKY)('%s', (value) => {
    const document = wrap([text(value)])
    assertValidDocument(document)
    const markdown = serializeMarkdown(document)
    expect(parseMarkdown(markdown)).toEqual(document)
    expect(hasCharacterReference(markdown)).toBe(false)
  })
})

describe('escapes use backslashes', () => {
  it.each([
    ['<kbd>', '\\<kbd>'],
    ['<kbd>Cmd</kbd>', '\\<kbd>Cmd\\</kbd>'],
    ['&amp;', '\\&amp;'],
    ['&#38; and &#x26;', '\\&#38; and \\&#x26;'],
    ['*not italic*', '\\*not italic\\*'],
    ['__init__.py', '\\_\\_init\\_\\_.py'],
    ['[text](url)', '[text]\\(url)'],
    ['# not a heading', '\\# not a heading'],
    ['- not a list', '\\- not a list'],
    ['1. not a list', '1\\. not a list'],
    ['> not a quote', '\\> not a quote'],
    ['~~not struck~~', '\\~\\~not struck\\~\\~'],
    ['https://example.com/a_b', 'https\\://example.com/a_b'],
  ])('%s -> %s', (value, expected) => {
    expect(serializeMarkdown(doc(paragraph(text(value))))).toBe(`${expected}\n`)
  })

  it('escapes a pipe only inside a table', () => {
    expect(serializeMarkdown(CONTEXTS['table cell']!([text('a | b')]))).toBe('| h |\n| --- |\n| a \\| b |\n')
    expect(serializeMarkdown(doc(paragraph(text('a | b'))))).toBe('a | b\n')
  })
})

describe('links written as bare URLs', () => {
  const link = (href: string, label = href): NodeJSON => ({
    type: 'text',
    text: label,
    marks: [{ type: 'link', attrs: { href, title: null } }],
  })

  it.each([
    [[link('https://example.com/a_b_c')], 'https://example.com/a_b_c'],
    [[text('see '), link('https://example.com/a_b'), text(' now')], 'see https://example.com/a_b now'],
    [[text('see '), link('https://example.com/a_b'), text('.')], 'see https://example.com/a_b.'],
    [[text('('), link('https://example.com/a_b'), text(')')], '(https://example.com/a_b)'],
    [[link('http://www.example.com/a_b', 'www.example.com/a_b')], 'www.example.com/a_b'],
    [[link('mailto:me@example.com', 'me@example.com')], 'me@example.com'],
    // Not safe as a bare URL: fall back to an explicit form.
    [[text('see'), link('https://example.com/a_b'), text('now')], 'see<https://example.com/a_b>now'],
    [[link('https://example.com/a_b'), text('_x')], '<https://example.com/a_b>\\_x'],
    [[link('https://example.com/trailing_'), text(' x')], '<https://example.com/trailing_> x'],
    [[link('https://example.com/a_b', 'the docs')], '[the docs](https://example.com/a_b)'],
    [[link('other-note.md')], '[other-note.md](other-note.md)'],
  ] as [NodeJSON[], string][])('%#: %j', (content, expected) => {
    const document = doc(paragraph(...content))
    const markdown = serializeMarkdown(document)
    expect(markdown).toBe(`${expected}\n`)
    expect(parseMarkdown(markdown)).toEqual(document)
  })
})

describe('marks that Markdown cannot write as they are', () => {
  const marked = (value: string, ...marks: string[]) => text(value, ...marks)

  it.each([
    // Whitespace at the edge of emphasis moves outside the markers.
    [[marked('word ', 'bold'), text('next')], '**word** next'],
    [[text('a'), marked(' b ', 'italic'), text('c')], 'a *b* c'],
    [[marked('  ', 'bold')], ''],
    // Punctuation glued to a letter outside moves out too.
    [[text('word'), marked('(glued)', 'bold'), text('next')], 'word(**glued**)next'],
    [[marked('Note:', 'bold'), text('text')], '**Note**:text'],
    [[marked('Note:', 'bold'), text(' text')], '**Note:** text'],
    // Overlapping and nested marks.
    [[marked('a ', 'italic'), marked('b', 'italic', 'bold'), marked(' c', 'italic')], '*a **b** c*'],
    [[marked('both', 'bold', 'italic')], '***both***'],
    [[marked('x', 'code', 'bold')], '**`x`**'],
    // Hard breaks: none at the edges, no blanks around them.
    [[text('a '), { type: 'hardBreak' }, text(' b'), { type: 'hardBreak' }], 'a\\\nb'],
    [[marked('a', 'bold'), { type: 'hardBreak', marks: [{ type: 'bold' }] }, marked('b', 'bold')], '**a**\\\n**b**'],
    // Blanks at the edges of a block and line endings inside text.
    [[text('  padded  ')], 'padded'],
    [[text('one\ntwo')], 'one two'],
  ] as [NodeJSON[], string][])('%#: %j', (content, expected) => {
    const markdown = serializeMarkdown(doc(paragraph(...content)))
    expect(markdown).toBe(expected === '' ? '' : `${expected}\n`)
    expect(hasCharacterReference(markdown)).toBe(false)
    // After that one normalization the document is stable.
    const normalized = parseMarkdown(markdown)
    expect(serializeMarkdown(normalized)).toBe(markdown)
    expect(parseMarkdown(serializeMarkdown(normalized))).toEqual(normalized)
  })

  // Known limit, see README: emphasis markers that CommonMark cannot place
  // (nested marks inside one word, emphasized code glued to a letter) are kept
  // by the serializer through a character reference next to the marker. The
  // text and its marks still read back exactly.
  it.each([
    [[marked('ab', 'bold'), marked('cd', 'bold', 'italic'), marked('ef', 'italic')]],
    [[text('word'), marked('code', 'bold', 'code'), text('word')]],
  ] as [NodeJSON[]][])('keeps marks CommonMark cannot place, %#', (content) => {
    const document = doc(paragraph(...content))
    const markdown = serializeMarkdown(document)
    expect(hasCharacterReference(markdown)).toBe(true)
    expect(parseMarkdown(markdown)).toEqual(document)
    expect(serializeMarkdown(parseMarkdown(markdown))).toBe(markdown)
  })
})
