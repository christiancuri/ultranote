// @vitest-environment jsdom
/**
 * Ask AI: contract decoding, request building, the panel state machine,
 * Markdown in and out of the document, and the bridge wiring.
 */
import { Editor } from '@tiptap/core'
import { TextSelection } from '@tiptap/pm/state'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import { createBridge, type Bridge, type Host, type OutgoingMessages } from '../bridge'
import { createCommands } from '../editor/commands'
import { createExtensions } from '../editor/extensions'
import { availableSlashItems, filterSlashItems } from '../editor/slash/items'
import { serializeMarkdown } from '../markdown'
import { insertAnswer, renderAnswer, selectionMarkdown } from './content'
import { cycleFocus } from './AskAIPanel'
import { FORMAT_MENU_KEY, getAIRange, panelHost, setAIRange, TABLE_MENU_KEY } from './highlight'
import {
  applyEvent,
  buildAskPayload,
  cancelRequest,
  decodeAIAvailability,
  decodeAIEvent,
  IDLE_SESSION,
  startRequest,
  type AISession,
} from './session'
import { aiStore, openAskAI } from './store'

type Sent = { [T in keyof OutgoingMessages]: { type: T; payload: OutgoingMessages[T] } }[keyof OutgoingMessages]

let editor: Editor
let bridge: Bridge
let mounted = false
let sent: Sent[]

function mount(markdown: string): void {
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
  editor = new Editor({ element, extensions: createExtensions({ mode: 'edit', getHost: () => host }), editable: true })
  bridge = createBridge({ editor, mode: 'edit', host })
  void bridge.api.setNote({ noteId: 'n', markdown })
  mounted = true
}

const markdown = () => serializeMarkdown(editor.getJSON())

/** Document position of the first occurrence of `text`. */
function find(text: string): number {
  let found = -1
  editor.state.doc.descendants((node, pos) => {
    if (found >= 0 || !node.isText) return
    const index = node.text!.indexOf(text)
    if (index >= 0) found = pos + index
  })
  if (found < 0) throw new Error(`not found: ${text}`)
  return found
}

function select(from: number, to: number): void {
  editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, from, to)))
}

afterEach(() => {
  if (mounted) {
    bridge.destroy()
    editor.destroy()
    mounted = false
  }
  document.body.replaceChildren()
})

describe('contract decoding', () => {
  it('decodes events leniently and drops unusable ones', () => {
    expect(decodeAIEvent({ requestId: 'r', type: 'delta', text: 'hi' })).toEqual({ requestId: 'r', type: 'delta', text: 'hi' })
    expect(decodeAIEvent({ requestId: 'r', type: 'bogus' })).toBeNull()
    expect(decodeAIEvent({ type: 'delta' })).toBeNull()
    expect(decodeAIEvent(null)).toBeNull()
    expect(decodeAIEvent({ requestId: 'r', type: 'failed', error: { code: 'notInstalled', message: 'm', canOpenSettings: true } })).toEqual({
      requestId: 'r',
      type: 'failed',
      error: { code: 'notInstalled', message: 'm', canOpenSettings: true },
    })
    expect(decodeAIEvent({ requestId: 'r', type: 'failed' })?.error).toEqual({ code: 'unknown', message: '', canOpenSettings: false })
  })

  it('decodes availability, defaulting to disabled', () => {
    expect(decodeAIAvailability({ enabled: true, providerName: 'Claude Code' })).toEqual({ enabled: true, providerName: 'Claude Code' })
    expect(decodeAIAvailability({ enabled: 'yes' })).toEqual({ enabled: false, providerName: '' })
    expect(decodeAIAvailability(undefined)).toEqual({ enabled: false, providerName: '' })
  })
})

describe('request building', () => {
  it('free text has no action, language or empty selection', () => {
    expect(buildAskPayload('r1', { instruction: '  hello ' }, { selection: '', note: '# N\n', followUp: false })).toEqual({
      requestId: 'r1',
      instruction: 'hello',
      note: '# N\n',
      followUp: false,
    })
  })

  it('language goes only with translate', () => {
    const context = { selection: 'Olá', note: 'Olá\n', followUp: true }
    expect(buildAskPayload('r', { instruction: 'Translate to Spanish', action: 'translate', language: 'Spanish' }, context)).toEqual({
      requestId: 'r',
      instruction: 'Translate to Spanish',
      action: 'translate',
      language: 'Spanish',
      selection: 'Olá',
      note: 'Olá\n',
      followUp: true,
    })
    expect(buildAskPayload('r', { instruction: 'x', action: 'improve', language: 'Spanish' }, context).language).toBeUndefined()
  })

  it('selection Markdown is the selected slice through the adapter', () => {
    mount('# Title\n\nSome **bold** text here.\n\n- one\n- two\n')
    const from = find('bold')
    expect(selectionMarkdown(editor.state.doc, { from, to: from + 4 })).toBe('**bold**')
    const start = find('Some')
    const end = find('two') + 3
    expect(selectionMarkdown(editor.state.doc, { from: start, to: end })).toBe('Some **bold** text here.\n\n- one\n- two')
    expect(selectionMarkdown(editor.state.doc, { from: start, to: start })).toBe('')
    const item = find('one')
    expect(selectionMarkdown(editor.state.doc, { from: item, to: item + 3 })).toBe('one')
  })
})

describe('panel state machine', () => {
  const run = (session: AISession, ...events: Parameters<typeof applyEvent>[1][]) => events.reduce(applyEvent, session)

  it('idle -> running -> done, accumulating deltas, final text wins', () => {
    let s = startRequest(IDLE_SESSION, 'a')
    expect(s).toMatchObject({ phase: 'running', thinking: true, text: '' })
    s = run(s, { requestId: 'a', type: 'thinking' }, { requestId: 'a', type: 'delta', text: 'Hel' }, { requestId: 'a', type: 'delta', text: 'lo' })
    expect(s).toMatchObject({ phase: 'running', thinking: false, text: 'Hello' })
    s = applyEvent(s, { requestId: 'a', type: 'completed', text: 'Hello!' })
    expect(s).toMatchObject({ phase: 'done', text: 'Hello!', turns: 1 })
    // Follow-up keeps the turn count and clears the answer.
    expect(startRequest(s, 'b')).toMatchObject({ phase: 'running', requestId: 'b', text: '', turns: 1 })
  })

  it('failed keeps the error', () => {
    const error = { code: 'notLoggedIn', message: 'Log in', canOpenSettings: true }
    const s = applyEvent(startRequest(IDLE_SESSION, 'a'), { requestId: 'a', type: 'failed', error })
    expect(s).toMatchObject({ phase: 'failed', error, turns: 0 })
  })

  it('cancelled from the host keeps the partial text', () => {
    const s = run(startRequest(IDLE_SESSION, 'a'), { requestId: 'a', type: 'delta', text: 'part' }, { requestId: 'a', type: 'cancelled' })
    expect(s).toMatchObject({ phase: 'cancelled', text: 'part' })
  })

  it('stop settles locally and later events are ignored', () => {
    const s = cancelRequest(run(startRequest(IDLE_SESSION, 'a'), { requestId: 'a', type: 'delta', text: 'x' }))
    expect(s.phase).toBe('cancelled')
    expect(run(s, { requestId: 'a', type: 'delta', text: 'y' }, { requestId: 'a', type: 'completed', text: 'all' })).toBe(s)
  })

  it('ignores stale request ids', () => {
    const s = startRequest(IDLE_SESSION, 'new')
    expect(run(s, { requestId: 'old', type: 'delta', text: 'x' }, { requestId: 'old', type: 'completed', text: 'x' })).toBe(s)
  })
})

describe('inserting answers', () => {
  it('replaces a selection inside a paragraph inline with a one-paragraph answer', () => {
    mount('Hello wrold, again.\n')
    const from = find('wrold')
    expect(insertAnswer(editor, 'brave **world**\n', { from, to: from + 5 }, 'replace')).toBe(true)
    expect(markdown()).toBe('Hello brave **world**, again.\n')
  })

  it('replaces a selection with blocks for a multi-block answer', () => {
    mount('One.\n\nTwo.\n\nThree.\n')
    const from = find('One')
    const to = find('Two.') + 4
    expect(insertAnswer(editor, '## Heading\n\n- a\n- b\n', { from, to }, 'replace')).toBe(true)
    expect(markdown()).toBe('## Heading\n\n- a\n- b\n\nThree.\n')
  })

  it('inserts below the block holding the range', () => {
    mount('First.\n\nSecond.\n')
    const at = find('First') + 2
    expect(insertAnswer(editor, 'New **one**.\n\n- x\n', { from: at, to: at }, 'below')).toBe(true)
    expect(markdown()).toBe('First.\n\nNew **one**.\n\n- x\n\nSecond.\n')
  })

  it('replaces the empty line it was asked from', () => {
    mount('Intro.\n')
    editor.commands.insertContentAt(editor.state.doc.content.size, { type: 'paragraph' })
    const at = editor.state.doc.content.size - 1
    expect(insertAnswer(editor, 'Continued.\n', { from: at, to: at }, 'below')).toBe(true)
    expect(markdown()).toBe('Intro.\n\nContinued.\n')
  })

  it('renders answers as DOM without unsafe links or remote images', () => {
    mount('x\n')
    const holder = document.createElement('div')
    holder.append(renderAnswer(editor.schema, '# Hi\n\n[bad](javascript:alert(1)) [ok](https://a.b) ![r](https://x/y.png)\n\n<img src=x onerror=alert(1)>\n'))
    expect(holder.querySelector('h1')?.textContent).toBe('Hi')
    const links = [...holder.querySelectorAll('a')].map((a) => a.getAttribute('href'))
    expect(links).toEqual([null, 'https://a.b'])
    expect(holder.querySelector('img')).toBeNull()
    expect(holder.querySelector('[onerror]')).toBeNull()
  })
})

describe('bridge and entry points', () => {
  beforeEach(() => mount('Hello world.\n'))

  it('AI is hidden until the host enables it', async () => {
    expect(availableSlashItems(aiStore(editor).getSnapshot().enabled).some((item) => item.id === 'ai')).toBe(false)
    expect(await bridge.api.runCommand('askAI')).toBe(false)
    await bridge.api.setAIState({ enabled: true, providerName: 'Claude Code' })
    expect(aiStore(editor).getSnapshot()).toMatchObject({ enabled: true, providerName: 'Claude Code' })
    expect(availableSlashItems(true)[0]?.id).toBe('ai')
    expect(filterSlashItems('gpt', availableSlashItems(true))[0]?.id).toBe('ai')
  })

  it('runCommand askAI opens the panel on the selection and highlights it', async () => {
    await bridge.api.setAIState({ enabled: true, providerName: 'Claude Code' })
    const from = find('world')
    select(from, from + 5)
    expect(await bridge.api.runCommand('askAI')).toBe(true)
    expect(aiStore(editor).getSnapshot().open).toBe(true)
    expect(getAIRange(editor.state)).toEqual({ from, to: from + 5 })
    expect(editor.view.dom.querySelector('.ai-selection')?.textContent).toBe('world')
  })

  it('aiEvent reaches the open session; disabling closes the panel', async () => {
    await bridge.api.setAIState({ enabled: true, providerName: 'Codex' })
    expect(createCommands(editor, { native: false, post: () => Promise.resolve(null) }).askAI()).toBe(true)
    const store = aiStore(editor)
    store.start('r1')
    await bridge.api.aiEvent({ requestId: 'r1', type: 'delta', text: 'Hi' })
    await bridge.api.aiEvent({ requestId: 'zz', type: 'delta', text: 'stale' })
    expect(store.getSnapshot().session.text).toBe('Hi')
    await bridge.api.setAIState({ enabled: false, providerName: '' })
    expect(store.getSnapshot()).toMatchObject({ open: false, session: IDLE_SESSION })
    expect(openAskAI(editor)).toBe(false)
  })

  it('hosts the panel in the flow after the anchor block, outside the document and history', async () => {
    await bridge.api.setNote({ noteId: 'n', markdown: '# Title\n\nBody text.\n' })
    await bridge.api.setAIState({ enabled: true, providerName: 'Claude Code' })
    select(find('Title') + 2, find('Title') + 2)
    expect(openAskAI(editor)).toBe(true)
    const host = panelHost(editor)
    const dom = editor.view.dom
    expect(host.parentElement).toBe(dom)
    expect(host.getAttribute('contenteditable')).toBe('false')
    // Between the heading and the paragraph: the paragraph is pushed down, not covered.
    expect(host.previousElementSibling?.tagName).toBe('H1')
    expect(host.nextElementSibling?.tagName).toBe('P')
    expect(markdown()).toBe('# Title\n\nBody text.\n')
    expect(editor.can().undo()).toBe(false)
    setAIRange(editor, null)
    expect(host.isConnected).toBe(false)
  })

  it('from the slash menu on an empty line, the panel sits at that line', async () => {
    await bridge.api.setAIState({ enabled: true, providerName: 'Claude Code' })
    editor.commands.insertContentAt(editor.state.doc.content.size, [{ type: 'paragraph' }, { type: 'paragraph', content: [{ type: 'text', text: 'After.' }] }])
    const empty = editor.state.doc.child(0).nodeSize + 1
    select(empty, empty)
    expect(openAskAI(editor)).toBe(true)
    const host = panelHost(editor)
    expect(host.previousElementSibling?.textContent).toBe('')
    expect(host.nextElementSibling?.textContent).toBe('After.')
  })

  it('opening hides bubble menus that are already shown', async () => {
    await bridge.api.setAIState({ enabled: true, providerName: 'Claude Code' })
    const metas: unknown[] = []
    editor.on('transaction', ({ transaction }) => metas.push([transaction.getMeta(FORMAT_MENU_KEY), transaction.getMeta(TABLE_MENU_KEY)]))
    select(1, 6)
    metas.length = 0
    expect(openAskAI(editor)).toBe(true)
    expect(metas).toContainEqual(['hide', 'hide'])
  })
})

describe('panel focus', () => {
  it('Tab cycles inside the panel, skipping disabled buttons', () => {
    const panel = document.createElement('div')
    panel.innerHTML = '<textarea></textarea><button disabled>send</button><button>a</button><button>b</button>'
    document.body.append(panel)
    const [input, , a, b] = [...panel.children] as HTMLElement[]
    input!.focus()
    cycleFocus(panel, false)
    expect(document.activeElement).toBe(a)
    cycleFocus(panel, false)
    expect(document.activeElement).toBe(b)
    cycleFocus(panel, false)
    expect(document.activeElement).toBe(input)
    cycleFocus(panel, true)
    expect(document.activeElement).toBe(b)
  })
})
