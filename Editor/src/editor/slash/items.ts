/**
 * Slash menu entries. Each runs a named command (see ../commands.ts), so the
 * slash menu and the native menus always do the same thing.
 */
import { DICTIONARIES, LOCALES, t, type MessageKey } from '../../i18n'
import type { CommandName } from '../commands'

export interface SlashItem {
  id: SlashId
  /** Short glyph shown in the icon tile. */
  icon: string
  /** Extra search words, Portuguese and English. */
  aliases: string[]
  command: CommandName
}

type SlashId = 'text' | 'h1' | 'h2' | 'h3' | 'bullet' | 'numbered' | 'todo' | 'table' | 'code' | 'mermaid' | 'quote' | 'divider' | 'image'

/** Title in the current locale. */
export function slashTitle(item: SlashItem): string {
  return t(`slash.${item.id}.title` as MessageKey)
}

/** Description in the current locale. */
export function slashDescription(item: SlashItem): string {
  return t(`slash.${item.id}.description` as MessageKey)
}

export const SLASH_ITEMS: SlashItem[] = [
  { id: 'text', icon: 'Aa', aliases: ['texto', 'paragrafo', 'paragraph', 'p'], command: 'paragraph' },
  { id: 'h1', icon: 'H1', aliases: ['titulo 1', 'h1', 'cabecalho'], command: 'heading1' },
  { id: 'h2', icon: 'H2', aliases: ['titulo 2', 'h2', 'subtitulo'], command: 'heading2' },
  { id: 'h3', icon: 'H3', aliases: ['titulo 3', 'h3'], command: 'heading3' },
  { id: 'bullet', icon: '•', aliases: ['lista', 'marcadores', 'bullets', 'ul', 'unordered'], command: 'bulletList' },
  { id: 'numbered', icon: '1.', aliases: ['lista numerada', 'numerada', 'ordered', 'ol'], command: 'orderedList' },
  { id: 'todo', icon: '☑', aliases: ['tarefa', 'tarefas', 'todo', 'task', 'checklist', 'checkbox'], command: 'taskList' },
  { id: 'table', icon: '▦', aliases: ['tabela', 'grid', 'grade'], command: 'insertTable' },
  { id: 'code', icon: '</>', aliases: ['codigo', 'bloco de codigo', 'code', 'snippet', 'pre'], command: 'codeBlock' },
  { id: 'mermaid', icon: '◇', aliases: ['diagrama', 'fluxograma', 'flowchart', 'diagram', 'grafico', 'chart'], command: 'insertMermaid' },
  { id: 'quote', icon: '❝', aliases: ['citacao', 'citar', 'blockquote'], command: 'quote' },
  { id: 'divider', icon: '—', aliases: ['divisor', 'separador', 'linha', 'hr', 'rule', 'separator'], command: 'divider' },
  { id: 'image', icon: '▣', aliases: ['imagem', 'foto', 'figura', 'picture', 'photo', 'img'], command: 'insertImage' },
]

/** Lowercase without accents, so "título" matches "titulo". */
export function fold(text: string): string {
  return text.normalize('NFD').replace(/\p{Diacritic}/gu, '').toLowerCase().trim()
}

/** Items matching the query; prefix matches on any word come before substring matches. */
export function filterSlashItems(query: string, items: SlashItem[] = SLASH_ITEMS): SlashItem[] {
  const q = fold(query)
  if (q === '') return items
  const scored: { item: SlashItem; score: number; index: number }[] = []
  items.forEach((item, index) => {
    // Titles of every locale are searchable, whatever the current one.
    const titles = LOCALES.map((locale) => DICTIONARIES[locale][`slash.${item.id}.title` as MessageKey])
    const names = [...titles, ...item.aliases].map(fold)
    let score = 0
    for (const name of names) {
      if (name.startsWith(q)) score = Math.max(score, 3)
      else if (name.split(/[\s-]+/).some((word) => word.startsWith(q))) score = Math.max(score, 2)
      else if (name.includes(q)) score = Math.max(score, 1)
    }
    if (score > 0) scored.push({ item, score, index })
  })
  return scored.sort((a, b) => b.score - a.score || a.index - b.index).map((entry) => entry.item)
}
