/**
 * Typing code in a code block like in a code editor: Tab / Shift+Tab indent
 * and outdent, Enter keeps the line's indentation (one more level after an
 * opening bracket or colon), blank lines are allowed (no exit on triple
 * Enter), ⌘Enter or ArrowDown on the last line leave the block, and pasted
 * text goes in as plain text. Also: a paragraph holding only ```lang becomes a
 * code block on Enter, a closing bracket typed first on a line outdents it (sturdier than the input rule with dead-key keyboards),
 * and Tab never moves focus out of the editor.
 */
import { Extension, type Editor } from '@tiptap/core'
import { Plugin, PluginKey, TextSelection } from '@tiptap/pm/state'

export const INDENT = '  '

const CODE_BLOCK = 'codeBlock'

/** Text edit inside one block: new text and selection offsets. */
export interface BlockEdit {
  text: string
  from: number
  to: number
}

/** Start offset of the line holding `offset`. */
function lineStart(text: string, offset: number): number {
  return text.lastIndexOf('\n', offset - 1) + 1
}

/**
 * Indents (or outdents) every line touched by `from..to`. A line where the
 * selection only ends at its very start is not touched.
 */
export function indentLines(text: string, from: number, to: number, outdent: boolean): BlockEdit {
  const first = lineStart(text, from)
  const last = to > from && lineStart(text, to) === to ? to - 1 : to
  const starts: number[] = []
  for (let start = first; start <= last; ) {
    starts.push(start)
    const next = text.indexOf('\n', start)
    if (next < 0 || next >= last) break
    start = next + 1
  }
  let result = text
  const edits: { start: number; delta: number }[] = []
  // Right to left so earlier offsets stay valid.
  for (const start of [...starts].reverse()) {
    if (outdent) {
      const remove = Math.min(/^ */.exec(result.slice(start))![0].length, INDENT.length)
      if (remove === 0) continue
      result = result.slice(0, start) + result.slice(start + remove)
      edits.push({ start, delta: -remove })
    } else {
      result = result.slice(0, start) + INDENT + result.slice(start)
      edits.push({ start, delta: INDENT.length })
    }
  }
  const map = (offset: number): number =>
    edits.reduce((mapped, { start, delta }) => {
      if (delta > 0) return start <= offset ? mapped + delta : mapped
      return mapped - Math.min(Math.max(0, offset - start), -delta)
    }, offset)
  return { text: result, from: map(from), to: map(to) }
}

/** What Enter inserts at `offset`: a newline plus the line's indentation, one level more after `{ ( [ :`. */
export function newlineWithIndent(text: string, offset: number): string {
  const line = text.slice(lineStart(text, offset), offset)
  const indent = /^[ \t]*/.exec(line)![0]
  return `\n${indent}${/[{([:]\s*$/.test(line) ? INDENT : ''}`
}

/** Spaces to remove before a closer typed as the first non-space of a line (one level, if there). */
export function closerOutdent(lineBefore: string, typed: string): number {
  if (!/^[}\])]$/.test(typed) || !/^ *$/.test(lineBefore)) return 0
  return lineBefore.length >= INDENT.length ? INDENT.length : 0
}

/** The language of a ```lang line, or undefined when the line is not a fence. Stray backticks are dropped. */
export function fenceLanguage(line: string): string | null | undefined {
  const match = /^\s*```+([^\s]*)\s*$/.exec(line)
  if (!match) return undefined
  const language = match[1]!.replace(/`/g, '').toLowerCase()
  return language === '' ? null : language
}

function inCodeBlock(editor: Editor): boolean {
  const { $from, $to } = editor.state.selection
  return $from.parent.type.name === CODE_BLOCK && $from.sameParent($to)
}

/** Replaces the code block's text with `edit`, keeping it one undo step. */
function applyBlockEdit(editor: Editor, edit: BlockEdit): boolean {
  const { state } = editor
  const { $from } = state.selection
  const start = $from.start()
  const end = $from.end()
  const tr = state.tr
  if (edit.text === '') tr.delete(start, end)
  else tr.replaceWith(start, end, state.schema.text(edit.text))
  tr.setSelection(TextSelection.create(tr.doc, start + edit.from, start + edit.to))
  editor.view.dispatch(tr.scrollIntoView())
  return true
}

function indent(editor: Editor, outdent: boolean): boolean {
  const { $from, from, to, empty } = editor.state.selection
  const start = $from.start()
  const text = $from.parent.textContent
  if (empty && !outdent) return editor.commands.insertContent(INDENT)
  return applyBlockEdit(editor, indentLines(text, from - start, to - start, outdent))
}

function newline(editor: Editor): boolean {
  const { $from, from, to } = editor.state.selection
  const insert = newlineWithIndent($from.parent.textContent, from - $from.start())
  editor.view.dispatch(editor.state.tr.insertText(insert, from, to).scrollIntoView())
  return true
}

/** Puts the cursor in a new paragraph right after the code block. */
function exitBelow(editor: Editor): boolean {
  const { state } = editor
  const after = state.selection.$from.after()
  const tr = state.tr.insert(after, state.schema.nodes.paragraph!.create())
  tr.setSelection(TextSelection.create(tr.doc, after + 1))
  editor.view.dispatch(tr.scrollIntoView())
  return true
}

/** A paragraph that is only ```lang turns into a code block. */
function fenceToCodeBlock(editor: Editor): boolean {
  const { $from, empty } = editor.state.selection
  const parent = $from.parent
  if (!empty || parent.type.name !== 'paragraph' || $from.parentOffset !== parent.content.size) return false
  const language = fenceLanguage(parent.textContent)
  if (language === undefined) return false
  const start = $from.start()
  const tr = editor.state.tr.delete(start, $from.end())
  tr.setBlockType(start, start, editor.schema.nodes[CODE_BLOCK]!, { language })
  editor.view.dispatch(tr.scrollIntoView())
  return true
}

/** Runs before the list and table keymaps, so code blocks inside them still indent. */
export const CodeBlockKeys = Extension.create({
  name: 'codeBlockKeys',
  priority: 1000,

  addKeyboardShortcuts() {
    const editor = this.editor
    return {
      Tab: () => inCodeBlock(editor) && indent(editor, false),
      'Shift-Tab': () => inCodeBlock(editor) && indent(editor, true),
      Enter: () => (inCodeBlock(editor) ? newline(editor) : fenceToCodeBlock(editor)),
      'Shift-Enter': () => inCodeBlock(editor) && newline(editor),
      'Mod-Enter': () => inCodeBlock(editor) && exitBelow(editor),
      ArrowDown: () => {
        const { $from, empty } = editor.state.selection
        if (!empty || !inCodeBlock(editor)) return false
        const onLastLine = !$from.parent.textContent.slice($from.parentOffset).includes('\n')
        const lastNode = $from.after() === editor.state.doc.content.size
        return onLastLine && lastNode && exitBelow(editor)
      },
    }
  },

  addProseMirrorPlugins() {
    return [
      new Plugin({
        key: new PluginKey('codeBlockInput'),
        props: {
          // A closing bracket at the start of a line moves back one level.
          handleTextInput: (view, from, to, text) => {
            const { $from } = view.state.selection
            if (from !== to || $from.parent.type.name !== CODE_BLOCK || $from.pos !== from) return false
            const before = $from.parent.textContent.slice(0, $from.parentOffset)
            const remove = closerOutdent(before.slice(before.lastIndexOf('\n') + 1), text)
            if (remove === 0) return false
            view.dispatch(view.state.tr.insertText(text, from - remove, to))
            return true
          },
          handlePaste: (view, event) => {
            const { $from, $to } = view.state.selection
            if ($from.parent.type.name !== CODE_BLOCK || !$from.sameParent($to)) return false
            const text = event.clipboardData?.getData('text/plain')
            if (!text) return false
            view.dispatch(view.state.tr.insertText(text.replace(/\r\n?/g, '\n')).scrollIntoView())
            return true
          },
        },
      }),
    ]
  },
})

/**
 * Runs after every other keymap: a Tab nobody handled (outside code, lists
 * and tables, or a list item that cannot move) does nothing instead of moving
 * focus out of the editor.
 */
export const TabTrap = Extension.create({
  name: 'tabTrap',
  priority: 1,

  addKeyboardShortcuts() {
    return { Tab: () => true, 'Shift-Tab': () => true }
  },
})
