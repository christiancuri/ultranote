/**
 * Code block: syntax highlighting through lowlight, plus a rendered preview
 * when the language is `mermaid`.
 *
 * A Mermaid diagram is not a separate node type. It is a normal code block
 * whose language is `mermaid`, so it is stored as a plain ```mermaid fence and
 * any other Markdown tool still reads it. Only the node view differs.
 */
import { CodeBlockLowlight } from '@tiptap/extension-code-block-lowlight'
import type { Editor } from '@tiptap/core'
import type { Node as ProseMirrorNode } from '@tiptap/pm/model'
import { Plugin, PluginKey, Selection } from '@tiptap/pm/state'
import { Decoration, DecorationSet, type NodeView, type ViewMutationRecord } from '@tiptap/pm/view'
import { common, createLowlight } from 'lowlight'

import { onThemeChange, resolvedTheme } from '../appearance'
import { onLocaleChange, t } from '../i18n'
import { languageLabel, languageOptions, openLanguagePicker } from './code-block-language'
import { renderMermaid } from './mermaid-renderer'

export const MERMAID_LANGUAGE = 'mermaid'

/** Delay between the last keystroke in a diagram's source and its re-render. */
const RENDER_DELAY_MS = 250

const lowlight = createLowlight(common)

/**
 * What the highlight plugin gets. Language auto-detection is replaced by "no
 * highlighting": guessing is slow (it tries every grammar on each change) and
 * colors plain text and Mermaid source at random.
 */
const highlighter = {
  listLanguages: () => lowlight.listLanguages(),
  registered: (language: string) => lowlight.registered(language),
  highlight: (language: string, value: string) => lowlight.highlight(language, value),
  highlightAuto: (value: string) => ({ type: 'root', children: [{ type: 'text', value }] }),
}

type MermaidState = 'pending' | 'rendered' | 'error'

class CodeBlockView implements NodeView {
  readonly dom: HTMLElement
  readonly contentDOM: HTMLElement

  private node: ProseMirrorNode
  private readonly editor: Editor
  private readonly getPos: () => number | undefined
  private readonly pre: HTMLElement
  /** Corner label that opens the language list (edit mode only). */
  private readonly languageButton: HTMLButtonElement | null = null

  private preview: HTMLElement | null = null
  private diagram: HTMLElement | null = null
  private errorBox: HTMLElement | null = null

  private renderedSource: string | null = null
  private renderedTheme: string | null = null
  private renderToken = 0
  private timer: ReturnType<typeof setTimeout> | null = null
  private readonly stopThemeListener: () => void
  private readonly stopLocaleListener: () => void

  constructor(node: ProseMirrorNode, editor: Editor, getPos: () => number | undefined) {
    this.node = node
    this.editor = editor
    this.getPos = getPos

    this.dom = document.createElement('div')
    this.dom.className = 'code-block'
    this.pre = document.createElement('pre')
    this.contentDOM = document.createElement('code')
    // Code is not prose: no spelling marks, autocorrect or capitals.
    this.contentDOM.setAttribute('spellcheck', 'false')
    this.contentDOM.setAttribute('autocorrect', 'off')
    this.contentDOM.setAttribute('autocapitalize', 'off')
    this.pre.append(this.contentDOM)
    this.dom.append(this.pre)
    if (editor.isEditable) {
      this.languageButton = document.createElement('button')
      this.languageButton.type = 'button'
      this.languageButton.className = 'code-language'
      this.languageButton.contentEditable = 'false'
      this.languageButton.addEventListener('mousedown', (event) => {
        event.preventDefault()
        this.openLanguages()
      })
      this.dom.prepend(this.languageButton)
    }

    this.stopThemeListener = onThemeChange(() => this.syncMermaid(true))
    this.stopLocaleListener = onLocaleChange(() => this.syncLocale())
    this.syncLanguage()
    this.syncMermaid(true)
  }

  update(node: ProseMirrorNode): boolean {
    if (node.type !== this.node.type) return false
    this.node = node
    this.syncLanguage()
    this.syncMermaid(false)
    return true
  }

  /** The preview is ours; ProseMirror only needs to hear about the source. */
  ignoreMutation(mutation: ViewMutationRecord): boolean {
    if (mutation.type === 'selection') return false
    return !this.contentDOM.contains(mutation.target)
  }

  stopEvent(event: Event): boolean {
    if (!(event.target instanceof Node)) return false
    if (this.languageButton?.contains(event.target)) return true
    return this.preview !== null && this.preview.contains(event.target)
  }

  private openLanguages(): void {
    const button = this.languageButton
    if (!button) return
    openLanguagePicker(button, languageOptions(lowlight.listLanguages()), this.language, (language) => {
      const position = this.getPos()
      if (position === undefined) return
      const tr = this.editor.state.tr.setNodeMarkup(position, undefined, { ...this.node.attrs, language: language || null })
      this.editor.view.dispatch(tr)
      this.editor.commands.focus()
    })
  }

  destroy(): void {
    this.stopThemeListener()
    this.stopLocaleListener()
    this.cancelTimer()
    this.renderToken += 1
  }

  private get language(): string {
    const language: unknown = this.node.attrs.language
    return typeof language === 'string' ? language : ''
  }

  private syncLanguage(): void {
    const language = this.language
    if (language === '') delete this.dom.dataset.language
    else this.dom.dataset.language = language
    this.contentDOM.className = language === '' ? '' : `language-${language}`
    if (this.languageButton) {
      this.languageButton.textContent = languageLabel(language)
      this.languageButton.title = t('code.language')
    }
  }

  private syncMermaid(immediately: boolean): void {
    if (this.language !== MERMAID_LANGUAGE) {
      this.removePreview()
      return
    }
    this.ensurePreview()
    const source = this.node.textContent
    const theme = resolvedTheme()
    if (source === this.renderedSource && theme === this.renderedTheme) return

    this.cancelTimer()
    // Export renders once and must not wait; typing is debounced.
    if (immediately || !this.editor.isEditable) {
      this.render(source, theme)
    } else {
      this.timer = setTimeout(() => this.render(source, theme), RENDER_DELAY_MS)
    }
  }

  private render(source: string, theme: 'light' | 'dark'): void {
    this.timer = null
    this.renderedSource = source
    this.renderedTheme = theme
    const token = ++this.renderToken
    if (this.diagram?.childElementCount === 0) this.setState('pending')

    void renderMermaid(source, theme).then((result) => {
      // A newer render (or a destroyed view) wins over this one.
      if (token !== this.renderToken || !this.diagram || !this.errorBox) return
      if (result.ok) {
        this.diagram.innerHTML = result.svg
        this.errorBox.textContent = ''
        this.setState('rendered')
      } else {
        this.diagram.replaceChildren()
        this.errorBox.textContent = result.message
        this.setState('error')
      }
    })
  }

  /** Relabels the toggle and re-renders a failed diagram so its message follows the locale. */
  private syncLocale(): void {
    if (this.languageButton) this.syncLanguage()
    if (!this.preview) return
    const edit = this.preview.querySelector('.mermaid-toggle-edit')
    if (edit) edit.textContent = t('mermaid.edit')
    const done = this.preview.querySelector('.mermaid-toggle-done')
    if (done) done.textContent = t('mermaid.done')
    if (this.dom.dataset.mermaidState === 'error') {
      this.renderedSource = null
      this.syncMermaid(true)
    }
  }

  private setState(state: MermaidState): void {
    this.dom.dataset.mermaidState = state
  }

  private ensurePreview(): void {
    if (this.preview) return
    this.preview = document.createElement('div')
    this.preview.className = 'mermaid-preview'
    this.preview.contentEditable = 'false'

    this.diagram = document.createElement('div')
    this.diagram.className = 'mermaid-diagram'
    this.errorBox = document.createElement('div')
    this.errorBox.className = 'mermaid-error'
    this.errorBox.setAttribute('role', 'alert')
    this.preview.append(this.diagram, this.errorBox)

    if (this.editor.isEditable) {
      // Edit/preview toggle. The label follows `is-active` through CSS.
      const toggle = document.createElement('button')
      toggle.type = 'button'
      toggle.className = 'mermaid-toggle'
      const edit = document.createElement('span')
      edit.className = 'mermaid-toggle-edit'
      edit.textContent = t('mermaid.edit')
      const done = document.createElement('span')
      done.className = 'mermaid-toggle-done'
      done.textContent = t('mermaid.done')
      toggle.append(edit, done)
      this.preview.prepend(toggle)
    }

    // Clicking the diagram puts the cursor in its source, which reveals it;
    // "Concluir" moves the cursor past the block, back to the preview.
    this.preview.addEventListener('mousedown', (event) => {
      if (!this.editor.isEditable) return
      event.preventDefault()
      const position = this.getPos()
      if (position === undefined) return
      const editing = this.dom.classList.contains('is-active')
      const onToggle = event.target instanceof Element && event.target.closest('.mermaid-toggle') !== null
      if (editing && onToggle) leaveCodeBlock(this.editor, position, this.node.nodeSize)
      else if (!editing) this.editor.chain().focus().setTextSelection(position + 1).run()
    })

    this.dom.prepend(this.preview)
    this.setState('pending')
  }

  private removePreview(): void {
    if (!this.preview) return
    this.cancelTimer()
    this.renderToken += 1
    this.preview.remove()
    this.preview = null
    this.diagram = null
    this.errorBox = null
    this.renderedSource = null
    this.renderedTheme = null
    delete this.dom.dataset.mermaidState
  }

  private cancelTimer(): void {
    if (this.timer !== null) clearTimeout(this.timer)
    this.timer = null
  }
}

/** Puts the cursor in the first text position after the block, adding a paragraph if needed. */
function leaveCodeBlock(editor: Editor, position: number, size: number): boolean {
  const after = position + size
  const { state } = editor
  const next = state.doc.resolve(after).nodeAfter
  if (!next) {
    return editor.chain().insertContentAt(after, { type: 'paragraph' }).setTextSelection(after + 1).focus().run()
  }
  const selection = Selection.findFrom(state.doc.resolve(after), 1, true)
  if (!selection) return false
  editor.view.dispatch(state.tr.setSelection(selection).scrollIntoView())
  editor.view.focus()
  return true
}

/**
 * Marks the code block that holds the cursor with `is-active`. The stylesheet
 * uses it to show a Mermaid block's source only while it is being edited.
 */
function activeBlockPlugin(editor: Editor, nodeName: string): Plugin {
  return new Plugin({
    key: new PluginKey('activeCodeBlock'),
    props: {
      decorations(state) {
        if (!editor.isEditable || !editor.isFocused) return null
        const { $from, $to } = state.selection
        if ($from.parent.type.name !== nodeName || !$from.sameParent($to)) return null
        const start = $from.before()
        return DecorationSet.create(state.doc, [
          Decoration.node(start, start + $from.parent.nodeSize, { class: 'is-active' }),
        ])
      },
    },
  })
}

export const CodeBlock = CodeBlockLowlight.extend({
  addAttributes() {
    return {
      ...this.parent?.(),
      // The rest of a fence's info string (```js title="a.js"), kept so it survives a save.
      meta: { default: null, rendered: false },
    }
  },

  addKeyboardShortcuts() {
    return {
      ...this.parent?.(),
      // Esc in a diagram's source goes back to the preview.
      Escape: ({ editor }) => {
        const { $from } = editor.state.selection
        if ($from.parent.type.name !== this.name || $from.parent.attrs.language !== MERMAID_LANGUAGE) return false
        return leaveCodeBlock(editor, $from.before(), $from.parent.nodeSize)
      },
    }
  },

  addNodeView() {
    return ({ node, editor, getPos }) => new CodeBlockView(node, editor, getPos)
  },

  addProseMirrorPlugins() {
    return [...(this.parent?.() ?? []), activeBlockPlugin(this.editor, this.name)]
  },
}).configure({ lowlight: highlighter, defaultLanguage: null, exitOnTripleEnter: false, exitOnArrowDown: false })
