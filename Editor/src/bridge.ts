/**
 * Bridge to the native host, exactly as written in docs/plan.md, "Contract
 * details". Message names, payloads and function names must not drift from it.
 *
 *   JS -> Swift   window.webkit.messageHandlers.ultranote.postMessage(JSON string)
 *                 envelope { v: 1, type, payload }; the call returns a Promise
 *                 with the reply (a JSON string or null).
 *   Swift -> JS   async functions on window.ultranote, called with
 *                 callAsyncJavaScript. Every function returns a Promise.
 *
 * Without `window.webkit` (plain browser, `pnpm dev`) messages are logged to
 * the console instead, so the editor works standalone.
 */
import type { Editor } from '@tiptap/core'
import { EditorState } from '@tiptap/pm/state'

import { aiStore } from './ai/store'
import { decodeAIAvailability, decodeAIEvent, type AIAskPayload, type AIAvailability, type AIEvent } from './ai/session'
import { applyAppearance, type Appearance } from './appearance'
import type { EditorMode } from './editor/extensions'
import { createCommands } from './editor/commands'
import { attachmentPath, insertImageAt } from './editor/images'
import { whenRenderSettled } from './export'
import { parseMarkdown, serializeMarkdown } from './markdown'
import { plainText } from './plainText'

export const BRIDGE_VERSION = 1

/** Debounce for `contentChanged` after the last edit. */
export const CONTENT_CHANGED_DELAY_MS = 300

// ---------------------------------------------------------------------------
// Messages, JS -> Swift
// ---------------------------------------------------------------------------

export interface OutgoingMessages {
  ready: { mode: EditorMode }
  contentChanged: { noteId: string; revision: number; markdown: string }
  openLink: { url: string }
  log: { level: 'info' | 'warn' | 'error'; message: string }
  /** Reply: JSON string `{"path":"attachments/<file>"}`. */
  saveAttachment: { name: string; mime: string; base64: string }
  /** Reply: same shape as `saveAttachment`, or null when the user cancelled. */
  pickImage: Record<string, never>
  /** Ask AI (Phase 7). Reply: null; the answer arrives through `aiEvent`. */
  aiAsk: AIAskPayload
  /** Stop the request; the host answers with a `cancelled` event (ignored once stopped here). */
  aiCancel: { requestId: string }
  /** The panel closed: forget the conversation. */
  aiReset: Record<string, never>
  aiOpenSettings: Record<string, never>
}

export type MessageType = keyof OutgoingMessages

export interface Envelope<T extends MessageType = MessageType> {
  v: typeof BRIDGE_VERSION
  type: T
  payload: OutgoingMessages[T]
}

interface MessageHandler {
  postMessage(body: string): Promise<unknown> | void
}

declare global {
  interface Window {
    webkit?: { messageHandlers?: { ultranote?: MessageHandler } }
    ultranote?: UltraNoteAPI
  }
}

/** Where messages go. Tests pass their own. */
export interface Host {
  readonly native: boolean
  post<T extends MessageType>(type: T, payload: OutgoingMessages[T]): Promise<unknown>
}

function parseReply(reply: unknown): unknown {
  if (typeof reply !== 'string') return reply ?? null
  try {
    return JSON.parse(reply) as unknown
  } catch {
    return reply
  }
}

/** Dispatched on `window` for every message posted without a native host. */
export const STANDALONE_POST_EVENT = 'ultranote:post'

/** The WebKit message handler when running inside the app, the console otherwise. */
export function defaultHost(): Host {
  const handler = typeof window === 'undefined' ? undefined : window.webkit?.messageHandlers?.ultranote
  if (handler) {
    return {
      native: true,
      async post(type, payload) {
        const envelope: Envelope = { v: BRIDGE_VERSION, type, payload }
        return parseReply(await handler.postMessage(JSON.stringify(envelope)))
      },
    }
  }
  return {
    native: false,
    post(type, payload) {
      console.info(`[ultranote bridge] ${type}`, payload)
      // Lets a standalone stub (see main.tsx) play the host.
      window.dispatchEvent(new CustomEvent(STANDALONE_POST_EVENT, { detail: { type, payload } }))
      return Promise.resolve(null)
    },
  }
}

// ---------------------------------------------------------------------------
// Functions, Swift -> JS
// ---------------------------------------------------------------------------

export interface DebugInfo {
  mode: EditorMode
  mermaidRendered: number
  mermaidFailed: number
  blocks: number
}

export interface UltraNoteAPI {
  setNote(args: { noteId: string; markdown: string }): Promise<void>
  getMarkdown(): Promise<string>
  getText(): Promise<string>
  runCommand(name: string): Promise<boolean>
  setAppearance(appearance: Appearance): Promise<void>
  renderExport(args: { markdown: string }): Promise<void>
  debugInfo(): Promise<DebugInfo>
  /**
   * Inserts `![](path)` for an `attachments/<file>` path the host stored (a file
   * dropped from Finder, handled natively). With `x`/`y` (CSS pixels in the
   * viewport) it goes to the document position under that point.
   */
  insertImage(args: { path: string; x?: number; y?: number }): Promise<boolean>
  /** Streams an Ask AI answer; events for another request than the panel's are ignored. */
  aiEvent(event: AIEvent): Promise<void>
  /** Shows (enabled) or hides every Ask AI entry point. Hidden until the host calls this. */
  setAIState(state: AIAvailability): Promise<void>
}

export interface BridgeOptions {
  editor: Editor
  mode: EditorMode
  host?: Host
  /** Set to false to skip `window.ultranote` (tests). */
  installGlobal?: boolean
}

export interface Bridge {
  api: UltraNoteAPI
  /** Sends `contentChanged` now if an edit is waiting for the debounce. */
  flush(): void
  destroy(): void
}

function describeError(error: unknown): string {
  if (error instanceof Error) return error.stack ?? error.message
  return String(error)
}

export function createBridge({ editor, mode, host = defaultHost(), installGlobal = true }: BridgeOptions): Bridge {
  let noteId: string | null = null
  let revision = 0
  /** Last Markdown loaded or reported for the current note; unchanged content is not re-sent. */
  let lastMarkdown: string | null = null
  let timer: ReturnType<typeof setTimeout> | null = null

  const post = <T extends MessageType>(type: T, payload: OutgoingMessages[T]): void => {
    void host.post(type, payload).catch((error: unknown) => {
      console.error(`[ultranote bridge] ${type} failed`, error)
    })
  }

  const currentMarkdown = (): string => serializeMarkdown(editor.getJSON())

  const cancelPending = (): void => {
    if (timer !== null) clearTimeout(timer)
    timer = null
  }

  const flush = (): void => {
    cancelPending()
    if (noteId === null) return
    const markdown = currentMarkdown()
    if (markdown === lastMarkdown) return
    lastMarkdown = markdown
    revision += 1
    post('contentChanged', { noteId, revision, markdown })
  }

  const onUpdate = (): void => {
    if (mode !== 'edit') return
    cancelPending()
    timer = setTimeout(flush, CONTENT_CHANGED_DELAY_MS)
  }
  editor.on('update', onUpdate)

  /** Replaces the whole state: new document, empty undo history, no update event. */
  const loadDocument = (markdown: string): void => {
    const doc = editor.schema.nodeFromJSON(parseMarkdown(markdown))
    doc.check()
    editor.view.updateState(EditorState.create({ schema: editor.schema, doc, plugins: editor.state.plugins }))
  }

  // Link clicks never navigate the web view; the host opens them.
  const onClick = (event: MouseEvent): void => {
    if (event.button !== 0 || !(event.target instanceof Element)) return
    const anchor = event.target.closest('a[href]')
    if (!anchor || !editor.view.dom.contains(anchor)) return
    event.preventDefault()
    // While editing, a click that extends a selection is about the text, not the link.
    if (mode === 'edit' && (event.shiftKey || !editor.state.selection.empty)) return
    const url = anchor.getAttribute('href')
    if (url) post('openLink', { url })
  }
  editor.view.dom.addEventListener('click', onClick)

  const commands: Record<string, () => boolean> = createCommands(editor, host)

  const api: UltraNoteAPI = {
    async setNote({ noteId: id, markdown }) {
      // Whatever was waiting belongs to the previous note; the host flushes
      // with getMarkdown() before switching, as the contract says.
      cancelPending()
      loadDocument(markdown)
      noteId = id
      lastMarkdown = currentMarkdown()
      ;(document.scrollingElement ?? document.documentElement).scrollTop = 0
    },

    async getMarkdown() {
      return currentMarkdown()
    },

    async getText() {
      return plainText(editor.getJSON())
    },

    async runCommand(name) {
      if (mode !== 'edit') return false
      const command = Object.hasOwn(commands, name) ? commands[name] : undefined
      return command ? command() : false
    },

    async setAppearance(appearance) {
      applyAppearance(appearance)
    },

    async renderExport({ markdown }) {
      if (mode !== 'export') throw new Error('renderExport is only available in export mode (?mode=export).')
      loadDocument(markdown)
      await whenRenderSettled(editor.view.dom)
    },

    async insertImage({ path, x, y }) {
      if (mode !== 'edit' || !editor.isEditable) return false
      const safe = attachmentPath({ path })
      if (!safe) return false
      const at =
        typeof x === 'number' && typeof y === 'number' ? editor.view.posAtCoords({ left: x, top: y })?.pos : undefined
      return insertImageAt(editor, safe, at)
    },

    async aiEvent(event) {
      const decoded = decodeAIEvent(event)
      if (decoded) aiStore(editor).handleEvent(decoded)
    },

    async setAIState(state) {
      aiStore(editor).setAvailability(decodeAIAvailability(state))
    },

    async debugInfo() {
      const dom = editor.view.dom
      return {
        mode,
        mermaidRendered: dom.querySelectorAll('[data-mermaid-state="rendered"]').length,
        mermaidFailed: dom.querySelectorAll('[data-mermaid-state="error"]').length,
        blocks: editor.state.doc.childCount,
      }
    },
  }

  const onError = (event: ErrorEvent): void => {
    post('log', { level: 'error', message: describeError(event.error ?? event.message) })
  }
  const onRejection = (event: PromiseRejectionEvent): void => {
    post('log', { level: 'error', message: `Unhandled rejection: ${describeError(event.reason)}` })
  }
  if (host.native) {
    window.addEventListener('error', onError)
    window.addEventListener('unhandledrejection', onRejection)
  }

  if (installGlobal) window.ultranote = api
  post('ready', { mode })

  return {
    api,
    flush,
    destroy() {
      cancelPending()
      editor.off('update', onUpdate)
      editor.view.dom.removeEventListener('click', onClick)
      window.removeEventListener('error', onError)
      window.removeEventListener('unhandledrejection', onRejection)
      if (installGlobal && window.ultranote === api) delete window.ultranote
    },
  }
}
