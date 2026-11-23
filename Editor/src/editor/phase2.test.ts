// @vitest-environment jsdom
/**
 * Editor commands, slash filtering, link normalization and image replies,
 * against a real editor where it matters.
 */
import { Editor } from '@tiptap/core'
import { afterEach, describe, expect, it } from 'vitest'

import type { Host, OutgoingMessages } from '../bridge'
import { normalizeMarkdown, parseMarkdown, serializeMarkdown } from '../markdown'
import { COMMAND_NAMES, createCommands, MERMAID_STARTER } from './commands'
import { createExtensions } from './extensions'
import { attachmentPath, insertImageAt, pickImage } from './images'
import { normalizeHref } from './linkEvents'
import { filterSlashItems, SLASH_ITEMS } from './slash/items'

const editors: Editor[] = []
afterEach(() => {
  editors.splice(0).forEach((editor) => editor.destroy())
  document.body.replaceChildren()
})

function makeEditor(markdown = '', reply: unknown = null) {
  const sent: { type: keyof OutgoingMessages; payload: unknown }[] = []
  const host: Host = {
    native: true,
    post(type, payload) {
      sent.push({ type, payload })
      return Promise.resolve(reply)
    },
  }
  const element = document.createElement('div')
  document.body.append(element)
  const editor = new Editor({ element, extensions: createExtensions({ mode: 'edit', getHost: () => host }), content: parseMarkdown(markdown) })
  editors.push(editor)
  return { editor, host, sent, markdown: () => serializeMarkdown(editor.getJSON()) }
}

describe('slash items', () => {
  it.each([
    ['tabela', 'table'],
    ['table', 'table'],
    ['tarefa', 'todo'],
    ['todo', 'todo'],
    ['título', 'h1'],
    ['diagrama', 'mermaid'],
    ['imagem', 'image'],
    ['citacao', 'quote'],
    ['divisor', 'divider'],
    ['numerada', 'numbered'],
  ])('%s finds %s first', (query, id) => {
    expect(filterSlashItems(query)[0]?.id).toBe(id)
  })

  it('shows everything for an empty query and nothing for nonsense', () => {
    expect(filterSlashItems('')).toHaveLength(SLASH_ITEMS.length)
    expect(filterSlashItems('zzzz')).toEqual([])
  })

  it('every item runs a known command', () => {
    for (const item of SLASH_ITEMS) expect(COMMAND_NAMES).toContain(item.command)
  })
})

describe('commands round-trip through Markdown', () => {
  it.each([
    ['heading1', '# x\n'],
    ['heading2', '## x\n'],
    ['heading3', '### x\n'],
    ['bulletList', '- x\n'],
    ['orderedList', '1. x\n'],
    ['taskList', '- [ ] x\n'],
    ['codeBlock', '```\nx\n```\n'],
    ['quote', '> x\n'],
  ] as const)('%s', (name, expected) => {
    const { editor, host, markdown } = makeEditor('x\n')
    editor.commands.setTextSelection(2)
    expect(createCommands(editor, host)[name]()).toBe(true)
    expect(markdown()).toBe(expected)
    expect(normalizeMarkdown(expected)).toBe(expected)
  })

  it('insertTable, insertMermaid and divider write stable Markdown', () => {
    const { editor, host, markdown } = makeEditor()
    const commands = createCommands(editor, host)
    expect(commands.insertTable()).toBe(true)
    expect(markdown()).toBe('|  |  |  |\n| --- | --- | --- |\n|  |  |  |\n|  |  |  |\n')
    editor.commands.setContent(parseMarkdown(''))
    expect(commands.insertMermaid()).toBe(true)
    expect(markdown()).toBe(`\`\`\`mermaid\n${MERMAID_STARTER}\n\`\`\`\n`)
    editor.commands.setContent(parseMarkdown(''))
    expect(commands.divider()).toBe(true)
    expect(markdown()).toBe('---\n')
    for (const output of [markdown()]) expect(normalizeMarkdown(output)).toBe(output)
  })

  it('a table without a header row is saved with its first row as the header (GFM needs one)', () => {
    const { editor, markdown } = makeEditor('| a | b |\n| --- | --- |\n| 1 | 2 |\n')
    editor.commands.setTextSelection(3)
    expect(editor.commands.toggleHeaderRow()).toBe(true)
    expect(editor.view.dom.querySelectorAll('th')).toHaveLength(0)
    expect(markdown()).toBe('| a | b |\n| --- | --- |\n| 1 | 2 |\n')
  })
})

describe('links', () => {
  it.each([
    ['example.com', 'https://example.com'],
    [' https://a.b/c ', 'https://a.b/c'],
    ['mailto:x@y.z', 'mailto:x@y.z'],
    ['x@y.z', 'mailto:x@y.z'],
    ['#section', '#section'],
    ['./other.md', './other.md'],
    ['', ''],
  ])('%j -> %j', (input, expected) => {
    expect(normalizeHref(input)).toBe(expected)
  })

  it('link opens the field only with a selection or inside a link', () => {
    const { editor, host } = makeEditor('plain [linked](https://a.b) text\n')
    let opened = 0
    editor.view.dom.addEventListener('ultranote:open-link', () => (opened += 1))
    const commands = createCommands(editor, host)
    editor.commands.setTextSelection(2)
    expect(commands.link()).toBe(false)
    editor.commands.setTextSelection({ from: 1, to: 6 })
    expect(commands.link()).toBe(true)
    editor.commands.setTextSelection(10)
    expect(commands.link()).toBe(true)
    expect(opened).toBe(2)
  })
})

describe('images', () => {
  it.each([
    [{ path: 'attachments/a.png' }, 'attachments/a.png'],
    [{ path: 'attachments/sub/a b.png' }, 'attachments/sub/a b.png'],
    [{ path: '../secret.png' }, null],
    [{ path: 'attachments/../x.png' }, null],
    [{ path: '/etc/passwd' }, null],
    [{ path: 42 }, null],
    [null, null],
    ['attachments/a.png', null],
  ])('attachmentPath(%j) is %j', (reply, expected) => {
    expect(attachmentPath(reply)).toBe(expected)
  })

  it('pickImage sends pickImage and inserts the returned path', async () => {
    const { editor, host, sent, markdown } = makeEditor('', { path: 'attachments/photo.png' })
    expect(await pickImage(editor, host)).toBe(true)
    expect(sent).toEqual([{ type: 'pickImage', payload: {} }])
    expect(markdown()).toBe('![](attachments/photo.png)\n')
  })

  it('reads a lone image as a block and keeps mixed or linked images inline', () => {
    const types = (md: string) => parseMarkdown(md).content.map((node) => [node.type, node.content?.map((child) => child.type) ?? []])
    expect(types('![a](attachments/a.png)\n')).toEqual([['image', []]])
    expect(types('Text ![a](attachments/a.png) more\n')).toEqual([['paragraph', ['text', 'inlineImage', 'text']]])
    expect(types('[![a](attachments/a.png)](https://x.com)\n')).toEqual([['paragraph', ['inlineImage']]])
    expect(types('- ![a](attachments/a.png)\n')).toEqual([['bulletList', ['listItem']]])
  })

  it('inserts a block after the current paragraph without splitting it', () => {
    const { editor, markdown } = makeEditor('Hello world\n\nNext\n')
    editor.commands.setTextSelection(3)
    expect(insertImageAt(editor, 'attachments/a.png')).toBe(true)
    expect(markdown()).toBe('Hello world\n\n![](attachments/a.png)\n\nNext\n')
    expect(editor.state.selection.constructor.name).toBe('NodeSelection')
    // A second insert goes after the selected image.
    insertImageAt(editor, 'attachments/b.png')
    expect(markdown()).toBe('Hello world\n\n![](attachments/a.png)\n\n![](attachments/b.png)\n\nNext\n')
  })

  it('replaces an empty paragraph, and inserts at a position between blocks', () => {
    const { editor, markdown } = makeEditor('One\n')
    editor.commands.setTextSelection(4)
    editor.commands.splitBlock()
    insertImageAt(editor, 'attachments/a.png')
    // The empty paragraph became the image (a trailing empty line may follow it).
    expect(editor.getJSON().content?.slice(0, 2).map((node) => node.type)).toEqual(['paragraph', 'image'])
    expect(markdown()).toBe('One\n\n![](attachments/a.png)\n')
    insertImageAt(editor, 'attachments/b.png', 0)
    expect(markdown()).toBe('![](attachments/b.png)\n\nOne\n\n![](attachments/a.png)\n')
  })

  it('inserts after a list item paragraph, keeping its text', () => {
    const { editor, markdown } = makeEditor('- item\n')
    editor.commands.setTextSelection(4)
    insertImageAt(editor, 'attachments/a.png')
    expect(markdown()).toBe('- item\n\n  ![](attachments/a.png)\n')
  })

  it('a cancelled pick inserts nothing', async () => {
    const { editor, host, markdown } = makeEditor('', null)
    expect(await pickImage(editor, host)).toBe(false)
    expect(markdown()).toBe('')
  })
})
