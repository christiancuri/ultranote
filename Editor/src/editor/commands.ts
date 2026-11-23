/**
 * Editor commands by name: what `runCommand` (native menus) and the slash menu run.
 * Names are part of the bridge contract; keep them stable.
 */
import type { Editor } from '@tiptap/core'

import { openAskAI } from '../ai/store'
import type { Host } from '../bridge'
import { pickImage } from './images'
import { requestLinkEditor } from './linkEvents'

export const MERMAID_STARTER = 'flowchart TD\n  A[Start] --> B{Decision}\n  B -->|Yes| C[Done]\n  B -->|No| D[Retry]'

export const COMMAND_NAMES = [
  'bold',
  'italic',
  'strike',
  'code',
  'link',
  'undo',
  'redo',
  'heading1',
  'heading2',
  'heading3',
  'paragraph',
  'bulletList',
  'orderedList',
  'taskList',
  'codeBlock',
  'quote',
  'divider',
  'insertTable',
  'insertMermaid',
  'insertImage',
  'askAI',
] as const

export type CommandName = (typeof COMMAND_NAMES)[number]

export function createCommands(editor: Editor, host: Host): Record<CommandName, () => boolean> {
  const chain = () => editor.chain().focus()
  return {
    bold: () => chain().toggleBold().run(),
    italic: () => chain().toggleItalic().run(),
    strike: () => chain().toggleStrike().run(),
    code: () => chain().toggleCode().run(),
    link: () => requestLinkEditor(editor),
    undo: () => chain().undo().run(),
    redo: () => chain().redo().run(),
    heading1: () => chain().toggleHeading({ level: 1 }).run(),
    heading2: () => chain().toggleHeading({ level: 2 }).run(),
    heading3: () => chain().toggleHeading({ level: 3 }).run(),
    paragraph: () => chain().setParagraph().run(),
    bulletList: () => chain().toggleBulletList().run(),
    orderedList: () => chain().toggleOrderedList().run(),
    taskList: () => chain().toggleTaskList().run(),
    codeBlock: () => chain().toggleCodeBlock().run(),
    quote: () => chain().toggleBlockquote().run(),
    divider: () => chain().setHorizontalRule().run(),
    insertTable: () => chain().insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run(),
    insertMermaid: () =>
      chain()
        .insertContent({ type: 'codeBlock', attrs: { language: 'mermaid' }, content: [{ type: 'text', text: MERMAID_STARTER }] })
        .run(),
    insertImage: () => {
      if (!editor.isEditable) return false
      void pickImage(editor, host).catch((error: unknown) => console.error('[ultranote] pickImage', error))
      return true
    },
    askAI: () => openAskAI(editor),
  }
}
