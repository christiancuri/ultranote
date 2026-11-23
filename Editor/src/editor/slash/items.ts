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

type SlashId = 'ai' | 'text' | 'h1' | 'h2' | 'h3' | 'bullet' | 'numbered' | 'todo' | 'table' | 'code' | 'mermaid' | 'quote' | 'divider' | 'image'

/** Title in the current locale. */
export function slashTitle(item: SlashItem): string {
  return t(`slash.${item.id}.title` as MessageKey)
}

/** Description in the current locale. */
export function slashDescription(item: SlashItem): string {
  return t(`slash.${item.id}.description` as MessageKey)
}

export const SLASH_ITEMS: SlashItem[] = [
  { id: 'ai', icon: '✦', aliases: ['ai', 'ia', 'gpt', 'claude', 'chatgpt', 'codex', 'perguntar'], command: 'askAI' },
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

/** The items to offer: Ask AI only while the host has AI enabled. */
export function availableSlashItems(aiEnabled: boolean): SlashItem[] {
  return aiEnabled ? SLASH_ITEMS : SLASH_ITEMS.filter((item) => item.command !== 'askAI')
}

/** Lowercase without accents, so "título" matches "titulo". */
export function fold(text: string): string {
  return text.normalize('NFD').replace(/\p{Diacritic}/gu, '').toLowerCase().trim()
}

/** Items matching the query: title matches before alias matches, prefixes before substrings. */
export function filterSlashItems(query: string, items: SlashItem[] = SLASH_ITEMS): SlashItem[] {
  const q = fold(query)
  if (q === '') return items
  const score = (name: string, weight: number): number => {
    if (name.startsWith(q)) return 3 * weight
    if (name.split(/[\s-]+/).some((word) => word.startsWith(q))) return 2 * weight
    return name.includes(q) ? 1 : 0
  }
  const scored: { item: SlashItem; score: number; index: number }[] = []
  items.forEach((item, index) => {
    // Titles of every locale are searchable, whatever the current one.
    const titles = LOCALES.map((locale) => fold(DICTIONARIES[locale][`slash.${item.id}.title` as MessageKey]))
    const best = Math.max(...titles.map((title) => score(title, 2)), ...item.aliases.map((alias) => score(fold(alias), 1)))
    if (best > 0) scored.push({ item, score: best, index })
  })
  return scored.sort((a, b) => b.score - a.score || a.index - b.index).map((entry) => entry.item)
}
