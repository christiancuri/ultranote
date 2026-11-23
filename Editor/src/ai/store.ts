/**
 * Ask AI state per editor: availability from the host (`setAIState`), whether
 * the panel is open, and the current conversation. The bridge feeds it, the
 * panel and the entry points (slash item, bubble button, `runCommand('askAI')`)
 * read it. The range the panel works on lives in the editor as plugin state
 * (see ./highlight.ts), so it follows edits.
 */
import type { Editor } from '@tiptap/core'

import { setAIRange } from './highlight'
import {
  applyEvent,
  cancelRequest,
  IDLE_SESSION,
  startRequest,
  type AIAvailability,
  type AIEvent,
  type AISession,
} from './session'

export interface AIState {
  enabled: boolean
  providerName: string
  open: boolean
  /** Increases on every open, so a reopened panel starts fresh. */
  openId: number
  session: AISession
}

type Listener = () => void

export class AIStore {
  private state: AIState = { enabled: false, providerName: '', open: false, openId: 0, session: IDLE_SESSION }
  private readonly listeners = new Set<Listener>()

  readonly subscribe = (listener: Listener): (() => void) => {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  readonly getSnapshot = (): AIState => this.state

  setAvailability({ enabled, providerName }: AIAvailability): void {
    // Disabling closes the panel; the panel's unmount cancels and resets on the host.
    this.set({ enabled, providerName, ...(enabled ? {} : { open: false, session: IDLE_SESSION }) })
  }

  open(): boolean {
    if (!this.state.enabled) return false
    this.set({ open: true, openId: this.state.openId + 1, session: IDLE_SESSION })
    return true
  }

  close(): void {
    if (!this.state.open) return
    this.set({ open: false, session: IDLE_SESSION })
  }

  start(requestId: string): void {
    this.set({ session: startRequest(this.state.session, requestId) })
  }

  cancel(): void {
    this.set({ session: cancelRequest(this.state.session) })
  }

  handleEvent(event: AIEvent): void {
    const session = applyEvent(this.state.session, event)
    if (session !== this.state.session) this.set({ session })
  }

  private set(patch: Partial<AIState>): void {
    this.state = { ...this.state, ...patch }
    for (const listener of this.listeners) listener()
  }
}

const stores = new WeakMap<Editor, AIStore>()

export function aiStore(editor: Editor): AIStore {
  let store = stores.get(editor)
  if (!store) {
    store = new AIStore()
    stores.set(editor, store)
  }
  return store
}

/**
 * Opens the panel on the current selection (or the cursor's block when it is
 * empty). False when AI is off or the editor is read-only.
 */
export function openAskAI(editor: Editor): boolean {
  if (!editor.isEditable) return false
  const store = aiStore(editor)
  if (!store.getSnapshot().enabled) return false
  const { from, to } = editor.state.selection
  setAIRange(editor, { from, to })
  return store.open()
}
