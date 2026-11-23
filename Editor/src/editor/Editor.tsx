import { EditorContent, useEditor } from '@tiptap/react'
import { useEffect, useMemo } from 'react'

import { onLocaleChange, t } from '../i18n'
import { createBridge, defaultHost, type Bridge } from '../bridge'
import { createExtensions, type EditorMode } from './extensions'
import { FormatMenu } from './FormatMenu'
import { TableMenu } from './TableMenu'

export interface EditorProps {
  mode: EditorMode
  /** Called once the bridge is installed, e.g. to load a demo note when running standalone. */
  onBridge?: (bridge: Bridge) => void
}

export function Editor({ mode, onBridge }: EditorProps) {
  const host = useMemo(() => defaultHost(), [])
  const extensions = useMemo(() => createExtensions({ mode, getHost: () => host }), [mode, host])

  const editor = useEditor({
    extensions,
    editable: mode === 'edit',
    immediatelyRender: true,
    // Menus subscribe to the state they need (useEditorState); the root does not re-render per keystroke.
    shouldRerenderOnTransaction: false,
    editorProps: {
      attributes: {
        class: 'note',
        spellcheck: mode === 'edit' ? 'true' : 'false',
        'aria-label': t('editor.label'),
      },
    },
  })

  // Locale switch: relabel the editor and recompute placeholder decorations.
  useEffect(() => {
    if (!editor) return
    return onLocaleChange(() => {
      if (editor.isDestroyed) return
      editor.view.dom.setAttribute('aria-label', t('editor.label'))
      editor.view.dispatch(editor.state.tr.setMeta('addToHistory', false).setMeta('localeChanged', true))
    })
  }, [editor])

  useEffect(() => {
    if (!editor) return
    const bridge = createBridge({ editor, mode, host })
    onBridge?.(bridge)
    return () => bridge.destroy()
  }, [editor, mode, host, onBridge])

  return (
    <>
      <EditorContent editor={editor} className="editor-root" />
      {editor && mode === 'edit' && (
        <>
          <FormatMenu editor={editor} />
          <TableMenu editor={editor} />
        </>
      )}
    </>
  )
}
