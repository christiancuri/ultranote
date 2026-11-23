// @vitest-environment jsdom
/**
 * Writing code in a code block: keys, paste, the fence on Enter, the language
 * picker; plus slash ranking for "/code".
 */
import { Editor } from '@tiptap/core'
import { TextSelection } from '@tiptap/pm/state'
import { afterEach, describe, expect, it } from 'vitest'

import { createExtensions } from '../editor/extensions'
import { filterSlashItems } from '../editor/slash/items'
import { parseMarkdown, serializeMarkdown } from '../markdown'
import { closerOutdent, fenceLanguage, indentLines, newlineWithIndent } from './code-block-keys'
import { filterLanguages, languageOptions, PLAIN_TEXT } from './code-block-language'

let editor: Editor | null = null

function mount(markdown: string): Editor {
  const element = document.createElement('div')
  document.body.append(element)
  editor = new Editor({ element, extensions: createExtensions({ mode: 'edit' }), content: parseMarkdown(markdown) })
  return editor
}

afterEach(() => {
  editor?.destroy()
  editor = null
  document.body.replaceChildren()
})

const md = (ed: Editor) => serializeMarkdown(ed.getJSON())

/** Cursor (or selection) at offsets inside the first code block's text. */
function selectInCode(ed: Editor, from: number, to = from): void {
  let start = -1
  ed.state.doc.descendants((node, pos) => {
    if (start < 0 && node.type.name === 'codeBlock') start = pos + 1
  })
  ed.view.dispatch(ed.state.tr.setSelection(TextSelection.create(ed.state.doc, start + from, start + to)))
}

/** Runs the editor's keymaps for a key, as a real keydown would. Mod is Ctrl under jsdom. */
function press(ed: Editor, key: string, modifiers: { shift?: boolean; mod?: boolean } = {}): boolean {
  const event = new KeyboardEvent('keydown', { key, shiftKey: modifiers.shift, ctrlKey: modifiers.mod, cancelable: true })
  return ed.view.someProp('handleKeyDown', (handler) => handler(ed.view, event)) ?? false
}

const codeText = (ed: Editor) => ed.state.doc.firstChild!.textContent

describe('pure helpers', () => {
  it('indents and outdents every touched line, keeping the selection on the text', () => {
    expect(indentLines('a\nb\nc', 0, 3, false)).toEqual({ text: '  a\n  b\nc', from: 2, to: 7 })
    expect(indentLines('  a\n    b', 0, 9, true)).toEqual({ text: 'a\n  b', from: 0, to: 5 })
    // A selection ending at the start of a line leaves that line alone.
    expect(indentLines('a\nb', 0, 2, false).text).toBe('  a\nb')
    expect(indentLines('x\n   y', 4, 4, true)).toEqual({ text: 'x\n y', from: 2, to: 2 })
  })

  it('Enter keeps indentation and adds a level after an opener', () => {
    expect(newlineWithIndent('    foo', 7)).toBe('\n    ')
    expect(newlineWithIndent('if (x) {', 8)).toBe('\n  ')
    expect(newlineWithIndent('  def f():', 10)).toBe('\n    ')
    expect(newlineWithIndent('a = [', 5)).toBe('\n  ')
    expect(newlineWithIndent('plain', 5)).toBe('\n')
  })

  it('reads fence languages, dropping stray backticks from dead keys', () => {
    expect(fenceLanguage('```js')).toBe('js')
    expect(fenceLanguage('```')).toBeNull()
    expect(fenceLanguage('````js`')).toBe('js')
    expect(fenceLanguage('```Python ')).toBe('python')
    expect(fenceLanguage('``js')).toBeUndefined()
    expect(fenceLanguage('```js x')).toBeUndefined()
  })
})

describe('code block keys', () => {
  it('Tab indents at the cursor and never leaves the editor', () => {
    const ed = mount('```js\nfoo\n```\n')
    selectInCode(ed, 0)
    expect(press(ed, 'Tab')).toBe(true)
    expect(codeText(ed)).toBe('  foo')
    expect(press(ed, 'Tab', { shift: true })).toBe(true)
    expect(codeText(ed)).toBe('foo')
  })

  it('Tab and Shift+Tab indent and outdent a multi-line selection', () => {
    const ed = mount('```\na\nb\n```\n')
    selectInCode(ed, 0, 3)
    press(ed, 'Tab')
    expect(codeText(ed)).toBe('  a\n  b')
    press(ed, 'Tab', { shift: true })
    expect(codeText(ed)).toBe('a\nb')
  })

  it('Tab outside code and lists is swallowed; in lists it still nests', () => {
    const ed = mount('Text\n\n- one\n- two\n')
    ed.commands.setTextSelection(2)
    expect(press(ed, 'Tab')).toBe(true)
    expect(md(ed)).toBe('Text\n\n- one\n- two\n')
    let two = -1
    ed.state.doc.descendants((node, pos) => {
      if (node.isText && node.text === 'two') two = pos
    })
    ed.commands.setTextSelection(two + 1)
    expect(press(ed, 'Tab')).toBe(true)
    expect(md(ed)).toBe('Text\n\n- one\n  - two\n')
    expect(press(ed, 'Tab', { shift: true })).toBe(true)
    expect(md(ed)).toBe('Text\n\n- one\n- two\n')
  })

  it('Enter allows blank lines (no exit on triple Enter) and keeps indentation', () => {
    const ed = mount('```\nif (x) {\n```\n')
    selectInCode(ed, 8)
    press(ed, 'Enter')
    expect(codeText(ed)).toBe('if (x) {\n  ')
    ed.commands.insertContent('a')
    press(ed, 'Enter')
    press(ed, 'Enter')
    press(ed, 'Enter')
    expect(ed.state.doc.firstChild!.type.name).toBe('codeBlock')
    expect(codeText(ed)).toBe('if (x) {\n  a\n  \n  \n  ')
    press(ed, 'Enter', { shift: true })
    expect(codeText(ed)).toBe('if (x) {\n  a\n  \n  \n  \n  ')
  })

  it('Mod+Enter leaves the block into a new paragraph', () => {
    const ed = mount('```\na\n```\n\nAfter\n')
    selectInCode(ed, 1)
    expect(press(ed, 'Enter', { mod: true })).toBe(true)
    ed.commands.insertContent('x')
    expect(md(ed)).toBe('```\na\n```\n\nx\n\nAfter\n')
  })

  it('a paragraph always follows a final code block, so ArrowDown on its last line leaves it', () => {
    const ed = mount('```\na\nb\n```\n')
    selectInCode(ed, 3)
    expect(ed.state.doc.lastChild!.type.name).toBe('paragraph')
    // Our own ArrowDown exit (for a block that is still last) is not needed here.
    expect(ed.state.doc.child(0).type.name).toBe('codeBlock')
  })

  it('Backspace at the start of an empty block turns it into a paragraph', () => {
    const ed = mount('Intro\n\n```js\n```\n')
    expect(ed.state.doc.child(1).type.name).toBe('codeBlock')
    selectInCode(ed, 0)
    expect(press(ed, 'Backspace')).toBe(true)
    expect(ed.state.doc.child(1).type.name).toBe('paragraph')
  })

  it('deleting the last character keeps the empty block and leaves the next one alone', () => {
    for (const [key, offset] of [['Backspace', 1], ['Delete', 0]] as const) {
      const ed = mount('```\n1\n```\n\n```\nabc\n```\n')
      selectInCode(ed, offset)
      expect(press(ed, key)).toBe(true)
      expect(ed.state.doc.child(0).type.name).toBe('codeBlock')
      expect(ed.state.doc.child(0).textContent).toBe('')
      expect(ed.state.doc.child(1).textContent).toBe('abc')
      expect(ed.state.selection.$from.parent).toBe(ed.state.doc.child(0))
      editor?.destroy()
    }
    // Not the last character: left to the browser.
    const ed = mount('```\n12\n```\n')
    selectInCode(ed, 2)
    expect(press(ed, 'Backspace')).toBe(false)
  })

  it('ArrowUp / ArrowDown move between neighbouring code blocks', () => {
    const ed = mount('```\n123\n```\n\n```\nabc\n```\n\nEnd\n')
    ed.view.endOfTextblock = () => true // jsdom has no layout
    const second = ed.state.doc.child(0).nodeSize + 1
    ed.view.dispatch(ed.state.tr.setSelection(TextSelection.create(ed.state.doc, second + 1)))
    expect(press(ed, 'ArrowUp')).toBe(true)
    expect(ed.state.selection.$from.parent.textContent).toBe('123')
    expect(press(ed, 'ArrowDown')).toBe(true)
    expect(ed.state.selection.$from.parent.textContent).toBe('abc')
    expect(press(ed, 'ArrowDown')).toBe(true)
    expect(ed.state.selection.$from.parent.textContent).toBe('End')
    // Between two paragraphs: the browser's own motion.
    const plain = mount('a\n\nb\n')
    plain.view.endOfTextblock = () => true
    plain.view.dispatch(plain.state.tr.setSelection(TextSelection.create(plain.state.doc, 4)))
    expect(press(plain, 'ArrowUp')).toBe(false)
  })

  it('Delete in an empty block removes that block, not the next one', () => {
    const ed = mount('```\n```\n\n```\nabc\n```\n')
    selectInCode(ed, 0)
    expect(press(ed, 'Delete')).toBe(true)
    expect(md(ed)).toBe('```\nabc\n```\n')
    expect(ed.state.selection.$from.parent.textContent).toBe('abc')
    expect(ed.state.selection.$from.parentOffset).toBe(0)
  })

  it('pastes plain text with its newlines', () => {
    const ed = mount('```\n\n```\n')
    selectInCode(ed, 0)
    const event = { clipboardData: { getData: (type: string) => (type === 'text/plain' ? 'a\r\n\r\n  b' : '<p>a</p>') } } as unknown as ClipboardEvent
    const handled = ed.view.someProp('handlePaste', (handler) => handler(ed.view, event, ed.state.doc.slice(0, 0)))
    expect(handled).toBe(true)
    expect(codeText(ed)).toBe('a\n\n  b')
    expect(ed.state.doc.firstChild!.type.name).toBe('codeBlock')
  })
})

describe('closing brackets', () => {
  it('outdent one level when typed first on a line', () => {
    expect(closerOutdent('    ', '}')).toBe(2)
    expect(closerOutdent(' ', ')')).toBe(0)
    expect(closerOutdent('  x', ']')).toBe(0)
    expect(closerOutdent('    ', 'a')).toBe(0)
    const ed = mount('```\nif (x) {\n    \n```\n')
    selectInCode(ed, 13)
    const { from, to } = ed.state.selection
    expect(ed.view.someProp('handleTextInput', (handler) => handler(ed.view, from, to, '}', () => ed.state.tr))).toBe(true)
    expect(codeText(ed)).toBe('if (x) {\n  }')
  })

  it('code is not spellchecked, autocorrected or capitalized', () => {
    const ed = mount('```\nx\n```\n')
    const code = ed.view.dom.querySelector('code')!
    expect([code.getAttribute('spellcheck'), code.getAttribute('autocorrect'), code.getAttribute('autocapitalize')]).toEqual(['false', 'off', 'off'])
  })
})

describe('fence on Enter', () => {
  it('turns ```lang typed through composition (dead keys) into a code block', () => {
    const ed = mount('Start\n')
    ed.commands.setTextSelection(ed.state.doc.content.size - 1)
    ed.commands.splitBlock()
    // What a pt-BR keyboard commits: the backticks as composed text, then the language.
    ed.view.dispatch(ed.state.tr.insertText('```'))
    ed.view.dispatch(ed.state.tr.insertText('js'))
    expect(press(ed, 'Enter')).toBe(true)
    const block = ed.state.doc.child(1)
    expect(block.type.name).toBe('codeBlock')
    expect(block.attrs.language).toBe('js')
    expect(block.textContent).toBe('')
  })
})

describe('language picker', () => {
  it('lists Plain text and Mermaid first, filters by prefix', () => {
    const options = languageOptions(['typescript', 'javascript', 'mermaid', 'java'])
    expect(options).toEqual([PLAIN_TEXT, 'mermaid', 'java', 'javascript', 'typescript'])
    expect(filterLanguages(options, 'ja')).toEqual(['java', 'javascript'])
    expect(filterLanguages(options, 'script')).toEqual(['javascript', 'typescript'])
    expect(filterLanguages(options, 'plain')).toEqual([PLAIN_TEXT])
  })

  it('the corner label opens the list and sets the language', () => {
    const ed = mount('```js\nx\n```\n')
    const button = ed.view.dom.querySelector<HTMLButtonElement>('.code-language')!
    expect(button.textContent).toBe('js')
    button.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }))
    const input = document.querySelector<HTMLInputElement>('.code-language-filter')!
    input.value = 'pyth'
    input.dispatchEvent(new Event('input'))
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', cancelable: true }))
    expect(ed.state.doc.firstChild!.attrs.language).toBe('python')
    expect(document.querySelector('.code-language-menu')).toBeNull()
    expect(md(ed)).toBe('```python\nx\n```\n')
  })
})

describe('slash ranking', () => {
  it('"/code" picks Code block, not Ask AI through an alias', () => {
    expect(filterSlashItems('code')[0]?.id).toBe('code')
    expect(filterSlashItems('ai')[0]?.id).toBe('ai')
  })
})
