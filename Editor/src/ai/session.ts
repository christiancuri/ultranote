/**
 * Ask AI, the pure half: contract types (docs/plan.md, "Phase 7"), lenient
 * decoding of host events, request building and the panel state machine.
 * No DOM, no editor: everything here runs under plain Node in tests.
 */

export const AI_ACTIONS = [
  'improve',
  'grammar',
  'shorter',
  'longer',
  'summarize',
  'translate',
  'explain',
  'continue',
  'brainstorm',
  'outline',
] as const

export type AIAction = (typeof AI_ACTIONS)[number]

/** Presets offered with a selection, in menu order. */
export const SELECTION_ACTIONS: readonly AIAction[] = ['improve', 'grammar', 'shorter', 'longer', 'summarize', 'translate', 'explain']

/** Presets offered at the cursor (no selection), in menu order. */
export const CURSOR_ACTIONS: readonly AIAction[] = ['continue', 'summarize', 'brainstorm', 'outline']

/** Translation targets, sent to the host as English names. */
export const AI_LANGUAGES = ['English', 'Portuguese', 'Spanish', 'French', 'German', 'Italian', 'Japanese'] as const

export type AILanguage = (typeof AI_LANGUAGES)[number]

/** `aiAsk` payload, JS -> Swift. `selection` and `note` are Markdown (adapter output). */
export interface AIAskPayload {
  requestId: string
  instruction: string
  action?: AIAction
  /** Only with `action: 'translate'`. */
  language?: string
  selection?: string
  note: string
  followUp: boolean
}

export interface AIError {
  code: string
  message: string
  canOpenSettings: boolean
}

export const AI_EVENT_TYPES = ['thinking', 'delta', 'completed', 'failed', 'cancelled'] as const

export type AIEventType = (typeof AI_EVENT_TYPES)[number]

/** `aiEvent(...)` argument, Swift -> JS. */
export interface AIEvent {
  requestId: string
  type: AIEventType
  /** `delta`: the chunk; `completed`: the final Markdown; `cancelled`: the partial answer. */
  text?: string
  /** `failed` only. */
  error?: AIError
}

/** `setAIState(...)` argument, Swift -> JS. */
export interface AIAvailability {
  enabled: boolean
  providerName: string
}

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === 'object' && value !== null

/** Decodes a host event; null when it cannot be used (unknown type, no request id). */
export function decodeAIEvent(value: unknown): AIEvent | null {
  if (!isRecord(value) || typeof value.requestId !== 'string') return null
  const type = value.type
  if (typeof type !== 'string' || !(AI_EVENT_TYPES as readonly string[]).includes(type)) return null
  const event: AIEvent = { requestId: value.requestId, type: type as AIEventType }
  if (typeof value.text === 'string') event.text = value.text
  if (event.type === 'failed') {
    const error = isRecord(value.error) ? value.error : {}
    event.error = {
      code: typeof error.code === 'string' ? error.code : 'unknown',
      message: typeof error.message === 'string' ? error.message : '',
      canOpenSettings: error.canOpenSettings === true,
    }
  }
  return event
}

/** Decodes `setAIState`; missing or bad fields mean disabled / no name. */
export function decodeAIAvailability(value: unknown): AIAvailability {
  if (!isRecord(value)) return { enabled: false, providerName: '' }
  return {
    enabled: value.enabled === true,
    providerName: typeof value.providerName === 'string' ? value.providerName : '',
  }
}

/** What the user asked for: free text (no action) or a preset. */
export interface AskInput {
  instruction: string
  action?: AIAction
  language?: string
}

export interface AskContext {
  /** Markdown of the selection; empty or absent without one. */
  selection?: string
  note: string
  followUp: boolean
}

export function buildAskPayload(requestId: string, input: AskInput, context: AskContext): AIAskPayload {
  const payload: AIAskPayload = {
    requestId,
    instruction: input.instruction.trim(),
    note: context.note,
    followUp: context.followUp,
  }
  if (input.action) payload.action = input.action
  if (input.action === 'translate' && input.language) payload.language = input.language
  if (context.selection && context.selection.trim() !== '') payload.selection = context.selection
  return payload
}

let requestCounter = 0

/** Unique enough per web view; `crypto.randomUUID` needs a secure context the app scheme may not be. */
export function newRequestId(): string {
  requestCounter += 1
  return `ai-${Date.now().toString(36)}-${requestCounter}-${Math.random().toString(36).slice(2, 8)}`
}

// ---------------------------------------------------------------------------
// Panel state machine
// ---------------------------------------------------------------------------

export type AIPhase = 'idle' | 'running' | 'done' | 'failed' | 'cancelled'

export interface AISession {
  phase: AIPhase
  /** The request being (or last) answered; events for any other id are ignored. */
  requestId: string | null
  /** Between `thinking` and the first `delta`. */
  thinking: boolean
  text: string
  error: AIError | null
  /** Completed answers in this conversation; the next ask is a follow-up when > 0. */
  turns: number
}

export const IDLE_SESSION: AISession = { phase: 'idle', requestId: null, thinking: false, text: '', error: null, turns: 0 }

export function startRequest(session: AISession, requestId: string): AISession {
  return { phase: 'running', requestId, thinking: true, text: '', error: null, turns: session.turns }
}

/** Stop pressed: settles at once; the host's late `cancelled` is then ignored. */
export function cancelRequest(session: AISession): AISession {
  if (session.phase !== 'running') return session
  return { ...session, phase: 'cancelled', thinking: false }
}

export function applyEvent(session: AISession, event: AIEvent): AISession {
  if (session.phase !== 'running' || event.requestId !== session.requestId) return session
  switch (event.type) {
    case 'thinking':
      return { ...session, thinking: true }
    case 'delta':
      return { ...session, thinking: false, text: session.text + (event.text ?? '') }
    case 'completed':
      return { ...session, phase: 'done', thinking: false, text: event.text ?? session.text, turns: session.turns + 1 }
    case 'failed':
      return {
        ...session,
        phase: 'failed',
        thinking: false,
        error: event.error ?? { code: 'unknown', message: '', canOpenSettings: false },
      }
    case 'cancelled':
      return { ...session, phase: 'cancelled', thinking: false, text: event.text ?? session.text }
  }
}
