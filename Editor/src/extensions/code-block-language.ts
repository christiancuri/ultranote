/**
 * The language label in a code block's corner, clickable while editing: a
 * filterable list of the highlighter's languages plus Plain text and Mermaid.
 * Choosing one sets the node's `language` attribute.
 */
import { autoUpdate, computePosition, flip, offset, shift } from '@floating-ui/dom'

import { t } from '../i18n'

export const PLAIN_TEXT = ''

/** Picker entries: Plain text first, then Mermaid, then the rest sorted. */
export function languageOptions(highlighted: readonly string[]): string[] {
  const rest = [...new Set(highlighted)].filter((name) => name !== 'mermaid' && name !== PLAIN_TEXT).sort()
  return [PLAIN_TEXT, 'mermaid', ...rest]
}

export function languageLabel(language: string): string {
  return language === PLAIN_TEXT ? t('code.plainText') : language
}

/** Entries matching `query` (by id or label), prefix matches first. */
export function filterLanguages(options: readonly string[], query: string): string[] {
  const q = query.trim().toLowerCase()
  if (q === '') return [...options]
  const names = (language: string) => [language, languageLabel(language).toLowerCase()]
  const prefix = options.filter((language) => names(language).some((name) => name.startsWith(q)))
  const inside = options.filter((language) => !prefix.includes(language) && names(language).some((name) => name.includes(q)))
  return [...prefix, ...inside]
}

/** One open picker at a time. */
let openPicker: { close: () => void } | null = null

export function closeLanguagePicker(): void {
  openPicker?.close()
}

/**
 * Opens the list under `anchor`. `current` is highlighted; `onChoose` gets the
 * chosen language (PLAIN_TEXT for none). Esc or a click outside closes it.
 */
export function openLanguagePicker(
  anchor: HTMLElement,
  options: readonly string[],
  current: string,
  onChoose: (language: string) => void,
): void {
  closeLanguagePicker()
  const element = document.createElement('div')
  element.className = 'code-language-menu'
  const input = document.createElement('input')
  input.className = 'code-language-filter'
  input.type = 'text'
  input.spellcheck = false
  input.placeholder = t('code.filterLanguages')
  input.setAttribute('aria-label', t('code.filterLanguages'))
  const list = document.createElement('div')
  list.className = 'code-language-list'
  list.setAttribute('role', 'listbox')
  element.append(input, list)
  document.body.append(element)

  let shown: string[] = []
  let selected = 0

  const render = () => {
    shown = filterLanguages(options, input.value)
    selected = Math.min(selected, Math.max(0, shown.length - 1))
    list.replaceChildren(
      ...shown.map((language, index) => {
        const row = document.createElement('div')
        row.className = 'code-language-item'
        row.setAttribute('role', 'option')
        row.setAttribute('aria-selected', String(index === selected))
        if (language === current) row.dataset.current = 'true'
        row.textContent = languageLabel(language)
        row.addEventListener('mousedown', (event) => {
          event.preventDefault()
          choose(language)
        })
        return row
      }),
    )
    list.children[selected]?.scrollIntoView?.({ block: 'nearest' })
  }

  const close = () => {
    stopAutoUpdate()
    document.removeEventListener('mousedown', onOutside, true)
    element.remove()
    if (openPicker === picker) openPicker = null
  }
  const choose = (language: string) => {
    close()
    onChoose(language)
  }
  const onOutside = (event: MouseEvent) => {
    if (event.target instanceof Node && (element.contains(event.target) || anchor.contains(event.target))) return
    close()
  }

  input.addEventListener('input', () => {
    selected = 0
    render()
  })
  input.addEventListener('keydown', (event) => {
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault()
      if (shown.length === 0) return
      selected = (selected + (event.key === 'ArrowDown' ? 1 : -1) + shown.length) % shown.length
      render()
    } else if (event.key === 'Enter') {
      event.preventDefault()
      const language = shown[selected]
      if (language !== undefined) choose(language)
    } else if (event.key === 'Escape') {
      event.preventDefault()
      close()
    }
  })

  const place = () => {
    void computePosition(anchor, element, {
      placement: 'bottom-end',
      strategy: 'fixed',
      middleware: [offset(4), flip({ padding: 8 }), shift({ padding: 8 })],
    }).then(({ x, y }) => Object.assign(element.style, { left: `${x}px`, top: `${y}px` }))
  }
  const stopAutoUpdate = autoUpdate(anchor, element, place, { animationFrame: false })
  document.addEventListener('mousedown', onOutside, true)

  const picker = { close }
  openPicker = picker
  selected = Math.max(0, options.indexOf(current))
  render()
  input.focus()
}
