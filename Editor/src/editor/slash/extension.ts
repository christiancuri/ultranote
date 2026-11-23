/**
 * `/` opens the block menu at the start of a line or after a space. Typing
 * filters it; arrows, Enter, Esc and the mouse drive it.
 */
import { Extension } from '@tiptap/core'
import { PluginKey } from '@tiptap/pm/state'
import { Suggestion } from '@tiptap/suggestion'

import type { Host } from '../../bridge'
import { onLocaleChange } from '../../i18n'
import { createCommands } from '../commands'
import { aiStore } from '../../ai/store'
import { availableSlashItems, filterSlashItems, type SlashItem } from './items'
import { SlashMenuView } from './menuView'

export const slashPluginKey = new PluginKey('slashMenu')

export interface SlashOptions {
  getHost: () => Host
}

export const SlashMenu = Extension.create<SlashOptions>({
  name: 'slashMenu',

  addOptions() {
    return { getHost: () => ({ native: false, post: () => Promise.resolve(null) }) }
  },

  addProseMirrorPlugins() {
    const { editor } = this
    const getHost = this.options.getHost
    return [
      Suggestion<SlashItem, SlashItem>({
        editor,
        pluginKey: slashPluginKey,
        char: '/',
        startOfLine: false,
        allowedPrefixes: [' ', ' '],
        allow: ({ state, range }) => {
          const $from = state.doc.resolve(range.from)
          return !$from.parent.type.spec.code
        },
        items: ({ query }) => filterSlashItems(query, availableSlashItems(aiStore(editor).getSnapshot().enabled)),
        command: ({ editor: ed, range, props }) => {
          ed.chain().focus().deleteRange(range).run()
          createCommands(ed, getHost())[props.command]()
        },
        render: () => {
          let view: SlashMenuView | null = null
          let choose: (item: SlashItem) => void = () => undefined
          let stopLocale: (() => void) | null = null
          return {
            onStart(props) {
              choose = props.command
              view = new SlashMenuView((item) => choose(item))
              view.update(props.items, props.clientRect)
              stopLocale = onLocaleChange(() => view?.refreshLocale())
            },
            onUpdate(props) {
              choose = props.command
              view?.update(props.items, props.clientRect)
            },
            onKeyDown({ event }) {
              if (event.key === 'Escape') return false
              return view?.onKeyDown(event) ?? false
            },
            onExit() {
              stopLocale?.()
              stopLocale = null
              view?.destroy()
              view = null
            },
          }
        },
      }),
    ]
  },
})
