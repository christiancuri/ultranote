/**
 * The Ask AI panel, rendered in the note's flow (a widget after the block
 * holding the end of the selection, or the cursor's line; see ./highlight.ts),
 * so the text below moves down instead of being covered. Presets before the first answer, a streamed
 * Markdown answer, result actions, and a follow-up input that keeps the
 * conversation. Closing it (any way) cancels a running request and sends
 * `aiReset`.
 */
import type { Editor } from '@tiptap/core'
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type KeyboardEvent,
} from 'react'
import { createPortal } from 'react-dom'

import type { Host } from '../bridge'
import { t, type MessageKey } from '../i18n'
import { useLocale } from '../editor/useLocale'
import { insertAnswer, noteMarkdown, renderAnswer, selectionMarkdown, type InsertMode } from './content'
import { getAIRange, panelHost, setAIRange, type AIRange } from './highlight'
import {
  AI_LANGUAGES,
  buildAskPayload,
  CURSOR_ACTIONS,
  newRequestId,
  SELECTION_ACTIONS,
  type AIAction,
  type AskInput,
} from './session'
import { aiStore, type AIStore } from './store'

interface PanelProps {
  editor: Editor
  host: Host
}

export function AskAIPanel({ editor, host }: PanelProps) {
  const store = aiStore(editor)
  const state = useSyncExternalStore(store.subscribe, store.getSnapshot)
  if (!state.open || !state.enabled) return null
  return createPortal(<Panel key={state.openId} editor={editor} host={host} store={store} />, panelHost(editor))
}

function actionLabelKey(action: AIAction, hasSelection: boolean): MessageKey {
  if (action === 'summarize' && !hasSelection) return 'ai.action.summarizeNote'
  return `ai.action.${action}` as MessageKey
}

/** The instruction sent with a preset: its English label, so prompts do not depend on the UI language. */
function presetInput(action: AIAction, hasSelection: boolean, language?: string): AskInput {
  if (action === 'translate' && language) return { instruction: t('ai.translateTo', { language }, 'en'), action, language }
  return { instruction: t(actionLabelKey(action, hasSelection), undefined, 'en'), action }
}

/** Moves focus to the next (or previous) control in `container`, wrapping around. */
export function cycleFocus(container: HTMLElement, backwards: boolean): void {
  const controls = [...container.querySelectorAll<HTMLElement>('textarea, button:not(:disabled)')]
  if (controls.length === 0) return
  const index = controls.indexOf(document.activeElement as HTMLElement)
  const next = index < 0 ? 0 : (index + (backwards ? -1 : 1) + controls.length) % controls.length
  controls[next]!.focus()
}

async function copyText(text: string): Promise<void> {
  try {
    await navigator.clipboard.writeText(text)
    return
  } catch {
    // Fall back to a selection copy (clipboard API unavailable or denied).
  }
  const area = document.createElement('textarea')
  area.value = text
  area.style.position = 'fixed'
  area.style.opacity = '0'
  document.body.append(area)
  area.select()
  document.execCommand('copy')
  area.remove()
}

function Panel({ editor, host, store }: PanelProps & { store: AIStore }) {
  useLocale()
  const state = useSyncExternalStore(store.subscribe, store.getSnapshot)
  const { session, providerName } = state
  const panelRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLTextAreaElement>(null)
  const [draft, setDraft] = useState('')
  const [translateOpen, setTranslateOpen] = useState(false)
  const [copied, setCopied] = useState(false)
  const lastInput = useRef<{ input: AskInput; followUp: boolean } | null>(null)

  // Fixed at open: what the panel works on.
  const initialRange = useMemo(() => getAIRange(editor.state) ?? { from: 0, to: 0 }, [editor])
  const hasSelection = initialRange.from < initialRange.to
  const selection = useMemo(() => selectionMarkdown(editor.state.doc, initialRange), [editor, initialRange])
  const liveRange = useCallback((): AIRange => getAIRange(editor.state) ?? initialRange, [editor, initialRange])

  const running = session.phase === 'running'
  const runningRef = useRef(running)
  runningRef.current = running
  const requestIdRef = useRef(session.requestId)
  requestIdRef.current = session.requestId

  // Leaving (close, discard, insert, AI turned off, editor gone): stop, forget, unhighlight.
  useEffect(
    () => () => {
      if (runningRef.current && requestIdRef.current) void host.post('aiCancel', { requestId: requestIdRef.current })
      void host.post('aiReset', {})
      setAIRange(editor, null)
    },
    [editor, host],
  )

  useEffect(() => {
    inputRef.current?.focus({ preventScroll: true })
    requestAnimationFrame(() => panelRef.current?.scrollIntoView({ block: 'nearest', behavior: 'smooth' }))
  }, [])

  // Keep the result actions in view once the answer settles.
  useEffect(() => {
    if (session.phase === 'idle' || session.phase === 'running') return
    panelRef.current?.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
    inputRef.current?.focus({ preventScroll: true })
  }, [session.phase])

  const close = useCallback(() => {
    store.close()
    editor.commands.focus()
  }, [editor, store])

  const ask = (input: AskInput, followUp = session.turns > 0) => {
    if (running) return
    const requestId = newRequestId()
    lastInput.current = { input, followUp }
    const payload = buildAskPayload(requestId, input, {
      selection: hasSelection ? selection : undefined,
      note: noteMarkdown(editor),
      followUp,
    })
    store.start(requestId)
    setDraft('')
    setTranslateOpen(false)
    setCopied(false)
    void host.post('aiAsk', payload)
  }

  const stop = () => {
    if (!session.requestId) return
    void host.post('aiCancel', { requestId: session.requestId })
    store.cancel()
  }

  const submit = () => {
    const instruction = draft.trim()
    if (instruction !== '') ask({ instruction })
  }

  const apply = (mode: InsertMode) => {
    const text = session.text
    const range = liveRange()
    if (text.trim() === '' || !insertAnswer(editor, text, range, mode)) return
    store.close()
    editor.commands.focus()
  }

  const onInputKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === 'Enter' && !event.shiftKey && !event.metaKey && !event.nativeEvent.isComposing) {
      event.preventDefault()
      submit()
    }
  }

  const onPanelKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.nativeEvent.isComposing) return
    // Focus stays in the panel: Tab never reaches the editor or its menus.
    if (event.key === 'Tab') {
      event.preventDefault()
      if (panelRef.current) cycleFocus(panelRef.current, event.shiftKey)
      return
    }
    if (event.key === 'Enter' && event.metaKey) {
      event.preventDefault()
      if (hasAnswer) apply(hasSelection ? 'replace' : 'below')
      return
    }
    if (event.key !== 'Escape') return
    event.preventDefault()
    event.stopPropagation()
    if (running) stop()
    else if (translateOpen) setTranslateOpen(false)
    else if (draft !== '') setDraft('')
    else close()
  }

  // A click outside closes a panel with nothing to lose.
  useEffect(() => {
    const onDown = (event: MouseEvent) => {
      const panel = panelRef.current
      if (!panel || (event.target instanceof Node && panel.contains(event.target))) return
      const current = store.getSnapshot().session
      if (current.phase === 'idle' && current.turns === 0 && (inputRef.current?.value ?? '') === '') store.close()
    }
    document.addEventListener('mousedown', onDown, true)
    return () => document.removeEventListener('mousedown', onDown, true)
  }, [store])

  // Auto-size the input up to a few lines.
  useLayoutEffect(() => {
    const input = inputRef.current
    if (!input) return
    input.style.height = 'auto'
    input.style.height = `${Math.min(input.scrollHeight, 160)}px`
  }, [draft])

  const showPresets = session.phase === 'idle' && session.turns === 0
  const hasAnswer = session.text.trim() !== '' && (session.phase === 'done' || session.phase === 'cancelled')
  const actions = hasSelection ? SELECTION_ACTIONS : CURSOR_ACTIONS

  return (
    <div
      ref={panelRef}
      className="ai-panel"
      role="dialog"
      aria-label={t('ai.label')}
      data-phase={session.phase}
      onKeyDown={onPanelKeyDown}
    >
      {session.phase !== 'idle' && (
        <div className="ai-answer" aria-live="polite">
          {session.phase === 'running' && session.text === '' && <div className="ai-thinking">{t('ai.thinking')}</div>}
          {session.text !== '' && <AnswerView editor={editor} host={host} markdown={session.text} />}
          {session.phase === 'cancelled' && <div className="ai-note">{t('ai.stopped')}</div>}
          {session.phase === 'failed' && (
            <div className="ai-error" role="alert">
              <span>{session.error?.message || t('ai.failed')}</span>
              {session.error?.canOpenSettings && (
                <button type="button" className="ai-button" onClick={() => void host.post('aiOpenSettings', {})}>
                  {t('ai.openSettings')}
                </button>
              )}
            </div>
          )}
        </div>
      )}

      <div className="ai-input-row">
        <span className="ai-sparkle" aria-hidden="true">
          ✦
        </span>
        <textarea
          ref={inputRef}
          className="ai-input"
          rows={1}
          value={draft}
          placeholder={session.turns > 0 || hasAnswer ? t('ai.placeholderFollowUp') : t('ai.placeholder')}
          aria-label={t('ai.label')}
          onChange={(event) => setDraft(event.target.value)}
          onKeyDown={onInputKeyDown}
        />
        {running ? (
          <button type="button" className="ai-button ai-stop" onClick={stop}>
            {t('ai.stop')}
          </button>
        ) : (
          <button
            type="button"
            className="ai-button ai-send"
            disabled={draft.trim() === ''}
            title={t('ai.send')}
            aria-label={t('ai.send')}
            onClick={submit}
          >
            ↑
          </button>
        )}
      </div>

      {showPresets && (
        <div className="ai-menu" role="menu">
          {actions.map((action) =>
            action === 'translate' ? (
              <div key={action} className="ai-submenu">
                <button
                  type="button"
                  role="menuitem"
                  className="ai-menu-item"
                  aria-expanded={translateOpen}
                  onClick={() => setTranslateOpen((open) => !open)}
                >
                  <span>{t('ai.action.translate')}</span>
                  <span className="ai-chevron" aria-hidden="true">
                    ▸
                  </span>
                </button>
                {translateOpen && (
                  <div className="ai-submenu-items">
                    {AI_LANGUAGES.map((language) => (
                      <button
                        key={language}
                        type="button"
                        role="menuitem"
                        className="ai-menu-item"
                        onClick={() => ask(presetInput('translate', true, language))}
                      >
                        {t(`ai.language.${language}` as MessageKey)}
                      </button>
                    ))}
                  </div>
                )}
              </div>
            ) : (
              <button
                key={action}
                type="button"
                role="menuitem"
                className="ai-menu-item"
                onClick={() => ask(presetInput(action, hasSelection))}
              >
                {t(actionLabelKey(action, hasSelection))}
              </button>
            ),
          )}
        </div>
      )}

      {(hasAnswer || session.phase === 'failed') && (
        <div className="ai-actions">
          {hasAnswer && hasSelection && (
            <button type="button" className="ai-button ai-primary" title={t('ai.primaryHint')} onClick={() => apply('replace')}>
              {t('ai.replace')}
            </button>
          )}
          {hasAnswer && (
            <button
              type="button"
              className={`ai-button${hasSelection ? '' : ' ai-primary'}`}
              title={hasSelection ? undefined : t('ai.primaryHint')}
              onClick={() => apply('below')}
            >
              {t('ai.insertBelow')}
            </button>
          )}
          {hasAnswer && (
            <button
              type="button"
              className="ai-button"
              onClick={() => {
                void copyText(session.text).then(() => setCopied(true))
              }}
            >
              {copied ? t('ai.copied') : t('ai.copy')}
            </button>
          )}
          {lastInput.current && (
            <button
              type="button"
              className="ai-button"
              onClick={() => lastInput.current && ask(lastInput.current.input, lastInput.current.followUp)}
            >
              {t('ai.retry')}
            </button>
          )}
          <button type="button" className="ai-button" onClick={close}>
            {t('ai.discard')}
          </button>
        </div>
      )}

      {providerName !== '' && <div className="ai-footer">{t('ai.provider', { provider: providerName })}</div>}
    </div>
  )
}

/** Read-only rendering of the (partial) answer. */
function AnswerView({ editor, host, markdown }: { editor: Editor; host: Host; markdown: string }) {
  const ref = useRef<HTMLDivElement>(null)
  useLayoutEffect(() => {
    ref.current?.replaceChildren(renderAnswer(editor.schema, markdown))
  }, [editor, markdown])
  return (
    <div
      ref={ref}
      className="ai-markdown"
      onClick={(event) => {
        const anchor = event.target instanceof Element ? event.target.closest('a') : null
        if (!anchor) return
        event.preventDefault()
        const url = anchor.getAttribute('href')
        if (url) void host.post('openLink', { url })
      }}
    />
  )
}
