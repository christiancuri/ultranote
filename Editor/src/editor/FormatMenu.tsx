/**
 * Bubble menu on a text selection: bold, italic, strikethrough, inline code
 * and link. The link field (⌘K) edits or removes the link under the cursor;
 * with the cursor inside a link, a compact link bar shows its URL.
 */
import type { Editor } from '@tiptap/core'
import { NodeSelection } from '@tiptap/pm/state'
import { CellSelection } from '@tiptap/pm/tables'
import { useEditorState } from '@tiptap/react'
import { BubbleMenu } from '@tiptap/react/menus'
import { useCallback, useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore, type KeyboardEvent } from 'react'

import { FORMAT_MENU_KEY, getAIRange } from '../ai/highlight'
import { aiStore, openAskAI } from '../ai/store'
import { t } from '../i18n'
import { normalizeHref, OPEN_LINK_EVENT } from './linkEvents'
import { useLocale } from './useLocale'

const PLUGIN_KEY = FORMAT_MENU_KEY

function selectionAllowsFormatting(editor: Editor): boolean {
  const { selection } = editor.state
  if (selection instanceof NodeSelection || selection instanceof CellSelection) return false
  return !selection.$from.parent.type.spec.code
}

export function FormatMenu({ editor }: { editor: Editor }) {
  useLocale()
  const [linkOpen, setLinkOpen] = useState(false)
  const [draft, setDraft] = useState('')
  const linkOpenRef = useRef(false)
  const inputRef = useRef<HTMLInputElement>(null)
  const ai = aiStore(editor)
  const aiEnabled = useSyncExternalStore(ai.subscribe, () => ai.getSnapshot().enabled)

  const state = useEditorState({
    editor,
    selector: ({ editor: ed }) => ({
      bold: ed.isActive('bold'),
      italic: ed.isActive('italic'),
      strike: ed.isActive('strike'),
      code: ed.isActive('code'),
      link: ed.isActive('link'),
      href: (ed.getAttributes('link').href as string | undefined) ?? '',
      empty: ed.state.selection.empty,
    }),
  })

  const setOpen = useCallback(
    (open: boolean) => {
      linkOpenRef.current = open
      setLinkOpen(open)
      editor.view.dispatch(editor.state.tr.setMeta(PLUGIN_KEY, open ? 'show' : 'updatePosition').setMeta('addToHistory', false))
    },
    [editor],
  )

  // ⌘K, the native menu and the link button.
  useEffect(() => {
    const dom = editor.view.dom
    const open = () => {
      setDraft((editor.getAttributes('link').href as string | undefined) ?? '')
      setOpen(true)
    }
    dom.addEventListener(OPEN_LINK_EVENT, open)
    return () => dom.removeEventListener(OPEN_LINK_EVENT, open)
  }, [editor, setOpen])

  // Leaving the selection closes the field.
  useEffect(() => {
    const onSelection = () => {
      if (linkOpenRef.current && document.activeElement !== inputRef.current) setOpen(false)
    }
    editor.on('selectionUpdate', onSelection)
    return () => {
      editor.off('selectionUpdate', onSelection)
    }
  }, [editor, setOpen])

  useLayoutEffect(() => {
    if (linkOpen) inputRef.current?.select()
  }, [linkOpen])

  const close = (refocus: boolean) => {
    setOpen(false)
    if (refocus) editor.commands.focus()
  }

  const apply = () => {
    const href = normalizeHref(draft)
    const chain = editor.chain().focus().extendMarkRange('link')
    if (href === '') chain.unsetLink().run()
    else chain.setLink({ href }).run()
    close(false)
  }

  const remove = () => {
    editor.chain().focus().extendMarkRange('link').unsetLink().run()
    close(false)
  }

  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === 'Enter') {
      event.preventDefault()
      apply()
    } else if (event.key === 'Escape') {
      event.preventDefault()
      close(true)
    }
  }

  const button = (name: 'bold' | 'italic' | 'strike' | 'code', label: string, title: string, run: () => boolean) => (
    <button
      type="button"
      className={`menu-button menu-button-${name}`}
      data-active={state[name] ? 'true' : undefined}
      title={title}
      aria-label={title}
      aria-pressed={state[name]}
      onMouseDown={(event) => event.preventDefault()}
      onClick={() => run()}
    >
      {label}
    </button>
  )

  return (
    <BubbleMenu
      editor={editor}
      pluginKey={PLUGIN_KEY}
      className="bubble-menu format-menu"
      options={{ placement: 'top', offset: 8, flip: true, shift: { padding: 8 } }}
      shouldShow={({ editor: ed, from, to }) => {
        if (!ed.isEditable) return false
        // Focus in the Ask AI panel (inside the editor's DOM) is not focus in the text.
        if (getAIRange(ed.state)) return false
        if (linkOpenRef.current) return true
        if (!selectionAllowsFormatting(ed)) return false
        if (from === to) return ed.isActive('link') && ed.isFocused
        return ed.isFocused && ed.state.doc.textBetween(from, to).length > 0
      }}
    >
      {linkOpen ? (
        <div className="link-field">
          <input
            ref={inputRef}
            type="text"
            className="link-input"
            placeholder={t('link.placeholder')}
            aria-label={t('link.inputLabel')}
            value={draft}
            spellCheck={false}
            onChange={(event) => setDraft(event.target.value)}
            onKeyDown={onKeyDown}
          />
          <button type="button" className="menu-button menu-button-apply" title={t('link.apply')} onClick={apply}>
            ↵
          </button>
          {state.link && (
            <button type="button" className="menu-button menu-button-unlink" title={t('link.removeTitle')} onClick={remove}>
              {t('link.remove')}
            </button>
          )}
        </div>
      ) : state.empty ? (
        <div className="link-bar">
          <span className="link-href" title={state.href}>
            {state.href}
          </span>
          <button
            type="button"
            className="menu-button menu-button-edit-link"
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => {
              setDraft(state.href)
              setOpen(true)
            }}
          >
            {t('link.edit')}
          </button>
          <button type="button" className="menu-button menu-button-unlink" onMouseDown={(event) => event.preventDefault()} onClick={remove}>
            {t('link.remove')}
          </button>
        </div>
      ) : (
        <div className="format-buttons">
          {aiEnabled && (
            <>
              <button
                type="button"
                className="menu-button menu-button-ai"
                title={t('format.askAITitle')}
                aria-label={t('format.askAI')}
                onMouseDown={(event) => event.preventDefault()}
                onClick={() => openAskAI(editor)}
              >
                <span className="menu-button-ai-icon" aria-hidden="true">
                  ✦
                </span>
                {t('format.askAI')}
              </button>
              <span className="menu-separator" />
            </>
          )}
          {button('bold', 'B', t('format.bold'), () => editor.chain().focus().toggleBold().run())}
          {button('italic', 'I', t('format.italic'), () => editor.chain().focus().toggleItalic().run())}
          {button('strike', 'S', t('format.strike'), () => editor.chain().focus().toggleStrike().run())}
          {button('code', '</>', t('format.code'), () => editor.chain().focus().toggleCode().run())}
          <span className="menu-separator" />
          <button
            type="button"
            className="menu-button menu-button-link"
            data-active={state.link ? 'true' : undefined}
            title={t('format.linkTitle')}
            aria-label={t('format.link')}
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => {
              setDraft(state.href)
              setOpen(true)
            }}
          >
            {t('format.link')}
          </button>
        </div>
      )}
    </BubbleMenu>
  )
}
