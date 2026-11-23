// @vitest-environment jsdom
/**
 * Bridge behavior against a real TipTap editor (in jsdom): the parts of the
 * contract that are easy to get subtly wrong.
 */
import { Editor } from '@tiptap/core'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { CONTENT_CHANGED_DELAY_MS, createBridge, type Bridge, type Host, type OutgoingMessages } from './bridge'
import { createExtensions, type EditorMode } from './editor/extensions'

type Sent = { [T in keyof OutgoingMessages]: { type: T; payload: OutgoingMessages[T] } }[keyof OutgoingMessages]

let editor: Editor
let bridge: Bridge
let sent: Sent[]

function mount(mode: EditorMode): void {
  sent = []
  const host: Host = {
    native: false,
    post(type, payload) {
      sent.push({ type, payload } as Sent)
      return Promise.resolve(null)
    },
  }
  const element = document.createElement('div')
  document.body.append(element)
  editor = new Editor({ element, extensions: createExtensions({ mode }), editable: mode === 'edit' })
  bridge = createBridge({ editor, mode, host })
}

const changes = () => sent.filter((message) => message.type === 'contentChanged')

/** Types text at the end of the last paragraph, as a user would. */
function type(text: string): void {
  editor.commands.insertContentAt(editor.state.doc.content.size - 1, text)
}

beforeEach(() => {
  vi.useFakeTimers()
})

afterEach(() => {
  bridge.destroy()
  editor.destroy()
  document.body.replaceChildren()
  vi.useRealTimers()
})

describe('edit mode', () => {
  beforeEach(() => mount('edit'))

  it('posts ready once, with the mode', () => {
    expect(sent).toEqual([{ type: 'ready', payload: { mode: 'edit' } }])
  })

  it('installs window.ultranote with the contract functions', () => {
    expect(Object.keys(window.ultranote ?? {}).sort()).toEqual(
      ['debugInfo', 'getMarkdown', 'getText', 'insertImage', 'renderExport', 'runCommand', 'setAppearance', 'setNote'].sort(),
    )
  })

  it('setNote loads the note without contentChanged and with an empty undo history', async () => {
    await bridge.api.setNote({ noteId: 'a', markdown: '# Title\n\nBody with snake_case_name.\n' })
    vi.advanceTimersByTime(CONTENT_CHANGED_DELAY_MS * 3)
    expect(changes()).toEqual([])
    expect(await bridge.api.getMarkdown()).toBe('# Title\n\nBody with snake_case_name.\n')
    // Nothing to undo: the loaded note is the start of history.
    expect(await bridge.api.runCommand('undo')).toBe(false)
    expect(await bridge.api.getMarkdown()).toBe('# Title\n\nBody with snake_case_name.\n')
  })

  it('debounces contentChanged and increases the revision', async () => {
    await bridge.api.setNote({ noteId: 'a', markdown: 'Start\n' })
    type(' one')
    type(' two')
    vi.advanceTimersByTime(CONTENT_CHANGED_DELAY_MS - 1)
    expect(changes()).toEqual([])
    vi.advanceTimersByTime(1)
    expect(changes()).toEqual([
      { type: 'contentChanged', payload: { noteId: 'a', revision: 1, markdown: 'Start one two\n' } },
    ])

    type(' three')
    vi.advanceTimersByTime(CONTENT_CHANGED_DELAY_MS)
    expect(changes().at(-1)).toEqual({
      type: 'contentChanged',
      payload: { noteId: 'a', revision: 2, markdown: 'Start one two three\n' },
    })
  })

  it('does not report the previous note after a switch', async () => {
    await bridge.api.setNote({ noteId: 'a', markdown: 'A\n' })
    type(' edited')
    await bridge.api.setNote({ noteId: 'b', markdown: 'B\n' })
    vi.advanceTimersByTime(CONTENT_CHANGED_DELAY_MS * 2)
    expect(changes()).toEqual([])
    type('!')
    vi.advanceTimersByTime(CONTENT_CHANGED_DELAY_MS)
    expect(changes()).toEqual([{ type: 'contentChanged', payload: { noteId: 'b', revision: 1, markdown: 'B!\n' } }])
  })

  it('undo and redo work after edits, and bold/italic toggle marks', async () => {
    await bridge.api.setNote({ noteId: 'a', markdown: 'Text\n' })
    type(' more')
    expect(await bridge.api.runCommand('undo')).toBe(true)
    expect(await bridge.api.getMarkdown()).toBe('Text\n')
    expect(await bridge.api.runCommand('redo')).toBe(true)
    expect(await bridge.api.getMarkdown()).toBe('Text more\n')

    editor.commands.selectAll()
    expect(await bridge.api.runCommand('bold')).toBe(true)
    expect(await bridge.api.runCommand('italic')).toBe(true)
    expect(await bridge.api.getMarkdown()).toBe('***Text more***\n')
    expect(await bridge.api.runCommand('strike')).toBe(true)
    expect(await bridge.api.runCommand('heading2')).toBe(true)
    expect(await bridge.api.runCommand('insertTable')).toBe(true)
    expect(await bridge.api.runCommand('unknown')).toBe(false)
    expect(await bridge.api.runCommand('toString')).toBe(false)
  })

  it('getText separates blocks with a blank line', async () => {
    await bridge.api.setNote({
      noteId: 'a',
      markdown: '# Title\n\nFirst **para**\\\nline two\n\n- one\n- [link](https://x.y)\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n',
    })
    expect(await bridge.api.getText()).toBe('Title\n\nFirst para\nline two\n\n- one\n- link\n\na\tb\n1\t2')
  })

  it('round-trips through the live editor without changes', async () => {
    const markdown = [
      '# Title',
      '',
      '- [ ] task with `code` and [a link](https://example.com/a_b)',
      '  - [x] nested',
      '',
      '| a | b |',
      '| :--- | ---: |',
      '| 1 | 2 |',
      '',
      '```js title="x.js"',
      'const a = 1',
      '```',
      '',
      '![image](attachments/a_b.png "Title")',
      '',
    ].join('\n')
    await bridge.api.setNote({ noteId: 'a', markdown })
    expect(await bridge.api.getMarkdown()).toBe(markdown)
  })

  it('routes link clicks to openLink and never navigates', async () => {
    await bridge.api.setNote({ noteId: 'a', markdown: 'See [docs](https://example.com/a_b).\n' })
    const anchor = editor.view.dom.querySelector('a')
    expect(anchor).not.toBeNull()
    const event = new MouseEvent('click', { bubbles: true, cancelable: true, button: 0 })
    anchor?.dispatchEvent(event)
    expect(event.defaultPrevented).toBe(true)
    expect(sent.filter((message) => message.type === 'openLink')).toEqual([
      { type: 'openLink', payload: { url: 'https://example.com/a_b' } },
    ])
  })

  it('debugInfo reports mode and block count', async () => {
    await bridge.api.setNote({ noteId: 'a', markdown: '# A\n\nB\n\n- c\n' })
    expect(await bridge.api.debugInfo()).toEqual({ mode: 'edit', mermaidRendered: 0, mermaidFailed: 0, blocks: 3 })
  })

  it('insertImage inserts an attachment path and refuses unsafe ones', async () => {
    await bridge.api.setNote({ noteId: 'a', markdown: 'Text\n' })
    expect(await bridge.api.insertImage({ path: '../etc/passwd' })).toBe(false)
    expect(await bridge.api.insertImage({ path: 'attachments/shot.png' })).toBe(true)
    expect(await bridge.api.getMarkdown()).toContain('![](attachments/shot.png)')
  })

  it('renderExport refuses to run outside export mode', async () => {
    await expect(bridge.api.renderExport({ markdown: '# A\n' })).rejects.toThrow(/export mode/)
  })
})

describe('export mode', () => {
  beforeEach(() => mount('export'))

  it('posts ready with mode export and is read-only', () => {
    expect(sent).toEqual([{ type: 'ready', payload: { mode: 'export' } }])
    expect(editor.isEditable).toBe(false)
  })
})
