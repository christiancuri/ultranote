/**
 * The slash menu popup: plain DOM positioned with Floating UI. Keyboard
 * handling comes from the suggestion plugin (onKeyDown), mouse from here.
 */
import { autoUpdate, computePosition, flip, offset, shift, size } from '@floating-ui/dom'

import { t } from '../../i18n'
import { slashDescription, slashTitle, type SlashItem } from './items'

export class SlashMenuView {
  readonly element: HTMLElement
  private items: SlashItem[] = []
  private selected = 0
  private stopAutoUpdate: (() => void) | null = null
  private getRect: () => DOMRect | null = () => null

  constructor(private readonly onChoose: (item: SlashItem) => void) {
    this.element = document.createElement('div')
    this.element.className = 'slash-menu'
    this.element.setAttribute('role', 'listbox')
    this.element.setAttribute('aria-label', t('slash.label'))
    // Keep focus (and the selection) in the editor.
    this.element.addEventListener('mousedown', (event) => event.preventDefault())
    document.body.append(this.element)
  }

  update(items: SlashItem[], getRect: (() => DOMRect | null) | null | undefined): void {
    const keep = this.items[this.selected]?.id
    this.items = items
    const index = items.findIndex((item) => item.id === keep)
    this.selected = index >= 0 ? index : 0
    if (getRect) this.getRect = getRect
    this.render()
    this.position()
    if (!this.stopAutoUpdate) {
      const reference = { getBoundingClientRect: () => this.getRect() ?? new DOMRect() }
      this.stopAutoUpdate = autoUpdate(reference, this.element, () => this.position(), { animationFrame: false })
    }
  }

  /** Returns true when the key was handled. */
  onKeyDown(event: KeyboardEvent): boolean {
    if (event.key === 'ArrowDown' || (event.key === 'n' && event.ctrlKey)) return this.move(1)
    if (event.key === 'ArrowUp' || (event.key === 'p' && event.ctrlKey)) return this.move(-1)
    if (event.key === 'Enter' || event.key === 'Tab') {
      const item = this.items[this.selected]
      if (!item) return false
      this.onChoose(item)
      return true
    }
    return false
  }

  /** Re-renders in the current locale. */
  refreshLocale(): void {
    this.element.setAttribute('aria-label', t('slash.label'))
    this.render()
  }

  destroy(): void {
    this.stopAutoUpdate?.()
    this.element.remove()
  }

  private move(delta: number): boolean {
    if (this.items.length === 0) return false
    this.selected = (this.selected + delta + this.items.length) % this.items.length
    this.render()
    return true
  }

  private render(): void {
    if (this.items.length === 0) {
      const empty = document.createElement('div')
      empty.className = 'slash-menu-empty'
      empty.textContent = t('slash.empty')
      this.element.replaceChildren(empty)
      return
    }
    const rows = this.items.map((item, index) => {
      const row = document.createElement('div')
      row.className = 'slash-menu-item'
      row.setAttribute('role', 'option')
      row.dataset.id = item.id
      row.setAttribute('aria-selected', String(index === this.selected))
      const icon = document.createElement('span')
      icon.className = 'slash-menu-icon'
      icon.textContent = item.icon
      const text = document.createElement('span')
      text.className = 'slash-menu-text'
      const title = document.createElement('span')
      title.className = 'slash-menu-title'
      title.textContent = slashTitle(item)
      const description = document.createElement('span')
      description.className = 'slash-menu-description'
      description.textContent = slashDescription(item)
      text.append(title, description)
      row.append(icon, text)
      row.addEventListener('mouseenter', () => {
        if (this.selected === index) return
        this.selected = index
        this.syncSelected()
      })
      row.addEventListener('click', () => this.onChoose(item))
      return row
    })
    this.element.replaceChildren(...rows)
    this.syncSelected()
  }

  private syncSelected(): void {
    ;[...this.element.children].forEach((row, index) => {
      row.setAttribute('aria-selected', String(index === this.selected))
      if (index === this.selected) row.scrollIntoView({ block: 'nearest' })
    })
  }

  private position(): void {
    const reference = { getBoundingClientRect: () => this.getRect() ?? new DOMRect() }
    void computePosition(reference, this.element, {
      placement: 'bottom-start',
      strategy: 'fixed',
      middleware: [
        offset(6),
        flip({ padding: 8 }),
        shift({ padding: 8 }),
        size({
          padding: 8,
          apply: ({ availableHeight }) => {
            this.element.style.maxHeight = `${Math.max(120, Math.min(360, availableHeight))}px`
          },
        }),
      ],
    }).then(({ x, y }) => {
      Object.assign(this.element.style, { left: `${x}px`, top: `${y}px` })
    })
  }
}
