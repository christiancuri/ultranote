/**
 * Toolbar above a table while the cursor is in it. Only operations GFM can
 * store: no merge, no resize.
 */
import { getAIRange, TABLE_MENU_KEY } from '../ai/highlight'
import type { Editor } from '@tiptap/core'
import { findParentNode } from '@tiptap/core'
import { useEditorState } from '@tiptap/react'
import { BubbleMenu } from '@tiptap/react/menus'

import { t } from '../i18n'
import { useLocale } from './useLocale'

const PLUGIN_KEY = TABLE_MENU_KEY

function tableElement(editor: Editor): HTMLElement | null {
  const table = findParentNode((node) => node.type.name === 'table')(editor.state.selection)
  if (!table) return null
  const dom = editor.view.nodeDOM(table.pos)
  if (!(dom instanceof HTMLElement)) return null
  return dom.querySelector('table') ?? dom
}

export function TableMenu({ editor }: { editor: Editor }) {
  useLocale()
  const header = useEditorState({
    editor,
    selector: ({ editor: ed }) => {
      const table = findParentNode((node) => node.type.name === 'table')(ed.state.selection)
      return table?.node.firstChild?.firstChild?.type.name === 'tableHeader'
    },
  })

  const actions: { id: string; label: string; title: string; run: () => boolean; danger?: boolean; active?: boolean }[] = [
    { id: 'row-above', label: t('table.rowAbove.label'), title: t('table.rowAbove.title'), run: () => editor.chain().focus().addRowBefore().run() },
    { id: 'row-below', label: t('table.rowBelow.label'), title: t('table.rowBelow.title'), run: () => editor.chain().focus().addRowAfter().run() },
    { id: 'col-left', label: t('table.colLeft.label'), title: t('table.colLeft.title'), run: () => editor.chain().focus().addColumnBefore().run() },
    { id: 'col-right', label: t('table.colRight.label'), title: t('table.colRight.title'), run: () => editor.chain().focus().addColumnAfter().run() },
    { id: 'del-row', label: t('table.delRow.label'), title: t('table.delRow.title'), run: () => editor.chain().focus().deleteRow().run(), danger: true },
    { id: 'del-col', label: t('table.delCol.label'), title: t('table.delCol.title'), run: () => editor.chain().focus().deleteColumn().run(), danger: true },
    { id: 'header', label: t('table.header.label'), title: t('table.header.title'), run: () => editor.chain().focus().toggleHeaderRow().run(), active: header },
    { id: 'del-table', label: t('table.delTable.label'), title: t('table.delTable.title'), run: () => editor.chain().focus().deleteTable().run(), danger: true },
  ]

  return (
    <BubbleMenu
      editor={editor}
      pluginKey={PLUGIN_KEY}
      className="bubble-menu table-menu"
      updateDelay={0}
      options={{ placement: 'top-start', offset: 8, flip: false, shift: { padding: 8 } }}
      getReferencedVirtualElement={() => {
        const element = tableElement(editor)
        return element ? { getBoundingClientRect: () => element.getBoundingClientRect() } : null
      }}
      shouldShow={({ editor: ed }) => ed.isEditable && ed.isFocused && ed.isActive('table') && !getAIRange(ed.state)}
    >
      {actions.map((action, index) => (
        <span key={action.id} className="table-menu-group">
          {(index === 4 || index === 6 || index === 7) && <span className="menu-separator" />}
          <button
            type="button"
            className={`menu-button table-${action.id}`}
            data-danger={action.danger ? 'true' : undefined}
            data-active={action.active ? 'true' : undefined}
            title={action.title}
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => action.run()}
          >
            {action.label}
          </button>
        </span>
      ))}
    </BubbleMenu>
  )
}
