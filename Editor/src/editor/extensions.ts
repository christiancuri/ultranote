/**
 * The editor schema and behavior, shared by edit mode, export mode and the
 * Markdown adapter tests (which validate parsed documents against it).
 *
 * Rule of thumb: the schema only allows what Markdown can store. Anything the
 * adapter could not write back is switched off here rather than lost on save.
 */
import { Code } from '@tiptap/extension-code'
import { Image } from '@tiptap/extension-image'
import { TaskItem, TaskList } from '@tiptap/extension-list'
import { TableCell, TableHeader, TableKit } from '@tiptap/extension-table'
import { Placeholder } from '@tiptap/extensions'
import { Extension, type Extensions } from '@tiptap/core'
import { StarterKit } from '@tiptap/starter-kit'

import { AskAIHighlight } from '../ai/highlight'
import type { Host } from '../bridge'
import { t } from '../i18n'
import { CodeBlock } from '../extensions/code-block'
import { ImageDrop } from './images'
import { requestLinkEditor } from './linkEvents'
import { SlashMenu } from './slash/extension'

export type EditorMode = 'edit' | 'export'

export interface ExtensionOptions {
  mode: EditorMode
  /** The bridge host, for image attachments. Absent in tests of the schema. */
  getHost?: () => Host
}


/** ⌘K opens the inline link field (the bubble menu). */
const LinkShortcut = Extension.create({
  name: 'linkShortcut',
  addKeyboardShortcuts() {
    return { 'Mod-k': () => requestLinkEditor(this.editor) }
  },
})

/** Editing-only behavior: menus, shortcuts, attachments. Nothing here changes the schema. */
function editingExtensions(getHost: () => Host): Extensions {
  return [SlashMenu.configure({ getHost }), ImageDrop.configure({ getHost }), LinkShortcut, AskAIHighlight]
}

const offlineHost = (): Host => ({ native: false, post: () => Promise.resolve(null) })

/** GFM cells hold inline content only, so a cell is paragraphs, not arbitrary blocks. */
const CELL_CONTENT = 'paragraph+'

export function createExtensions({ mode, getHost = offlineHost }: ExtensionOptions): Extensions {
  return [
    StarterKit.configure({
      // Replaced below.
      codeBlock: false,
      code: false,
      // Markdown has no underline.
      underline: false,
      link: {
        // Clicks are routed to the host (see Editor.tsx), never followed here.
        openOnClick: false,
        autolink: true,
        linkOnPaste: true,
        defaultProtocol: 'https',
        HTMLAttributes: { target: null, rel: null, class: null },
      },
      // Keeps a paragraph after a trailing table or code block so the cursor
      // can leave it. Pointless in the read-only export view.
      trailingNode: mode === 'edit' ? {} : false,
    }),
    // Stock inline code excludes every other mark; Markdown allows
    // **`bold code`** and [`linked code`](url), so the editor does too.
    Code.extend({ excludes: '' }),
    CodeBlock,
    TaskList,
    TaskItem.configure({ nested: true }),
    TableKit.configure({
      // No column resizing: GFM cannot store widths.
      table: { resizable: false, renderWrapper: true },
      tableCell: false,
      tableHeader: false,
    }),
    TableCell.extend({ content: CELL_CONTENT }),
    TableHeader.extend({ content: CELL_CONTENT }),
    // Block image (own line, Notion-style) for a paragraph that is only an
    // image; `inlineImage` keeps images mixed with text or inside a link.
    Image.configure({ inline: false }),
    Image.extend({ name: 'inlineImage', draggable: false }).configure({ inline: true }),
    Placeholder.configure({
      placeholder: ({ node }) =>
        node.type.name === 'heading' ? t('placeholder.heading', { level: String(node.attrs.level) }) : t('placeholder.paragraph'),
    }),
    ...(mode === 'edit' ? editingExtensions(getHost) : []),
  ]
}
