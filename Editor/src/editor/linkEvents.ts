/**
 * The link field lives in the React bubble menu; ⌘K, the native menu and the
 * toolbar button ask it to open through a DOM event on the editor element.
 */
import type { Editor } from '@tiptap/core'

export const OPEN_LINK_EVENT = 'ultranote:open-link'

/** Opens the inline link field for the selection or the link under the cursor. */
export function requestLinkEditor(editor: Editor): boolean {
  if (!editor.isEditable) return false
  const { empty } = editor.state.selection
  if (empty && !editor.isActive('link')) return false
  editor.view.dom.dispatchEvent(new CustomEvent(OPEN_LINK_EVENT))
  return true
}

/**
 * Normalizes what the user typed into a link target. Bare domains get
 * `https://`; anything with a scheme, an anchor or a relative path is kept.
 */
export function normalizeHref(input: string): string {
  const value = input.trim()
  if (value === '') return ''
  if (/^[a-z][a-z0-9+.-]*:/i.test(value) || /^[#/.?]/.test(value)) return value
  if (/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value)) return `mailto:${value}`
  return `https://${value}`
}
