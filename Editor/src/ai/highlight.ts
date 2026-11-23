/**
 * The range Ask AI works on, kept as plugin state so it maps through edits,
 * drawn as a highlight while the panel has focus (the editor's own selection
 * is not shown once focus leaves it), plus the block widget hosting the panel.
 */
import { Extension, type Editor } from '@tiptap/core'
import type { Node as PMNode } from '@tiptap/pm/model'
import { Plugin, PluginKey, type EditorState } from '@tiptap/pm/state'
import { Decoration, DecorationSet } from '@tiptap/pm/view'

export interface AIRange {
  from: number
  to: number
}

/** Where the panel goes: after the text block holding `to` (after the whole table inside one). */
export function panelPosition(doc: PMNode, to: number): number {
  const $to = doc.resolve(Math.min(to, doc.content.size))
  if ($to.depth === 0) return $to.pos
  for (let d = 1; d <= $to.depth; d += 1) if ($to.node(d).type.spec.tableRole === 'table') return $to.after(d)
  return $to.parent.isTextblock ? $to.after($to.depth) : $to.pos
}

const panelHosts = new WeakMap<Editor, HTMLElement>()

/**
 * The element the panel renders into: a block widget in the document flow
 * after the anchor block, so the text below moves down instead of being
 * covered. Not editable, not part of the document (nothing saved, no undo).
 */
export function panelHost(editor: Editor): HTMLElement {
  let host = panelHosts.get(editor)
  if (!host) {
    host = document.createElement('div')
    host.className = 'ai-panel-host'
    host.setAttribute('contenteditable', 'false')
    panelHosts.set(editor, host)
  }
  return host
}

export const aiRangeKey = new PluginKey<AIRange | null>('askAIRange')

export function getAIRange(state: EditorState): AIRange | null {
  return aiRangeKey.getState(state) ?? null
}

/** Plugin keys of the bubble menus (FormatMenu, TableMenu); hidden while the panel is open. */
export const FORMAT_MENU_KEY = 'formatMenu'
export const TABLE_MENU_KEY = 'tableMenu'

/** Sets (or clears, with null) the range. Not an undo step. Opening hides bubble menus already shown. */
export function setAIRange(editor: Editor, range: AIRange | null): void {
  if (editor.isDestroyed) return
  const tr = editor.state.tr.setMeta(aiRangeKey, range).setMeta('addToHistory', false)
  if (range) tr.setMeta(FORMAT_MENU_KEY, 'hide').setMeta(TABLE_MENU_KEY, 'hide')
  editor.view.dispatch(tr)
}

export const AskAIHighlight = Extension.create({
  name: 'askAIHighlight',

  addProseMirrorPlugins() {
    const { editor } = this
    return [
      new Plugin<AIRange | null>({
        key: aiRangeKey,
        state: {
          init: () => null,
          apply(tr, value) {
            const meta = tr.getMeta(aiRangeKey) as AIRange | null | undefined
            if (meta !== undefined) return meta
            if (!value || !tr.docChanged) return value
            // Text typed at either edge stays outside the range.
            const from = tr.mapping.map(value.from, 1)
            const to = Math.max(from, tr.mapping.map(value.to, -1))
            return { from, to }
          },
        },
        props: {
          decorations(state) {
            const range = aiRangeKey.getState(state)
            if (!range) return null
            const decorations = [
              Decoration.widget(panelPosition(state.doc, range.to), () => panelHost(editor), {
                key: 'ask-ai-panel',
                side: 1,
                ignoreSelection: true,
                // Keys, clicks and input in the panel belong to the panel, not the editor.
                stopEvent: () => true,
              }),
            ]
            if (range.from < range.to) decorations.push(Decoration.inline(range.from, range.to, { class: 'ai-selection' }))
            return DecorationSet.create(state.doc, decorations)
          },
        },
      }),
    ]
  },
})
